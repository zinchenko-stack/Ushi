//
//  AudioRecorder.swift
//  ushi
//
//  Движок записи созвона.
//  Звук — мимо ScreenCaptureKit, чтобы для аудио не нужен был доступ к экрану:
//  СИСТЕМНЫЙ звук через Core Audio process tap, МИКРОФОН через AVAudioEngine
//  (см. AudioSources.swift). Оба сводятся вживую в один моно-AAC.
//  ВИДЕО экрана (по флагу) — через ScreenCaptureKit, тогда выход .mov.
//  Все источники идут по часам хоста, поэтому совпадают по времени.
//  Если пишутся оба источника звука, рядом пишется стерео «голосовая дорожка»:
//  L = микрофон, R = система — по ней whisper размечает «Я / Собеседник».
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation
import CoreMedia

@Observable
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: Публичное состояние (UI наблюдает за ним)

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0          // 0...1, для индикатора

    /// Писать ли микрофон (твой голос). Меняется только когда запись не идёт.
    var micEnabled = true

    /// Писать ли видео всего экрана. Меняется только когда запись не идёт.
    /// false = только звук (.m4a), true = видео + звук (.mov).
    var captureVideo = false

    /// Писать ли системный звук (голос собеседника). Меняется только когда запись не идёт.
    /// false + micEnabled = пресет «Только микрофон».
    var systemAudioEnabled = true

    /// Получатель звука для живой расшифровки (см. `RecordingWriter.LiveSink`).
    /// Ставится перед start(); вызывается на очереди сэмплов.
    @ObservationIgnored var liveSink: RecordingWriter.LiveSink?

    /// Куда класть следующий файл. nil = общая папка записей (orphan).
    /// Ставится перед start() — например, в папку Проекта.
    var outputDirectory: URL?

    // MARK: Приватное

    @ObservationIgnored var onInterruption: (@MainActor (Error) async -> Void)?
    private var recordingActivity: NSObjectProtocol?
    private var isStopping = false
    private var stream: SCStream?
    private var systemTap: SystemAudioTap?
    private var microphone: MicrophoneCapture?
    private var writer: RecordingWriter?
    private var currentFileURL: URL?
    private var currentVoiceTrackURL: URL?
    private var startDate: Date?
    private var timer: Timer?

    // Очередь для колбэков ScreenCaptureKit. Сюда приходят аудио, микрофон и видео —
    // writer живёт на этой же очереди, поэтому ему не нужны блокировки.
    private let sampleQueue = DispatchQueue(label: "ushi.audio.samples")

    // Дросселирование UI-апдейтов уровня (макс ~20 fps).
    private var lastLevelUpdate: Date = .distantPast
    private let levelUpdateInterval: TimeInterval = 0.05

    // Последний RMS по каждому источнику отдельно — индикатор показывает максимум.
    private var lastSystemRMS: Float = 0
    private var lastMicRMS: Float = 0

    // MARK: Живучесть источников
    // Сменились наушники — источник звука может молча перестать отдавать буферы,
    // а таймер при этом идёт дальше. Сторож раз в секунду проверяет, что звук
    // приходит, и пересоздаёт замолчавший источник; смена устройства по умолчанию
    // пересоздаёт его сразу. Таймлайн не рвётся: дыру writer заполнит тишиной.

    private var recordsSystemAudio = false
    private var recordsMicrophone = false
    private var deviceMonitor: AudioDeviceMonitor?
    private var watchdog: Timer?
    private var pendingSystemRestart: DispatchWorkItem?
    private var pendingMicRestart: DispatchWorkItem?
    private var lastSystemRestart: TimeInterval = 0
    private var lastMicRestart: TimeInterval = 0
    // Время (systemUptime) последнего буфера системного звука и последнего
    // НЕнулевого буфера микрофона. Пишутся на sampleQueue.
    private var lastSystemBufferAt: TimeInterval = 0
    private var lastMicSoundAt: TimeInterval = 0

    /// Системный звук без буферов дольше этого — источник умер.
    private let systemStallTimeout: TimeInterval = 3
    /// Живой микрофон не отдаёт ровные нули (там всегда есть шум) — значит,
    /// поток с него оборвался. Перезапускаем не чаще раза в 10 с, на случай
    /// если громкость входа и правда выкручена в ноль.
    private let micStallTimeout: TimeInterval = 3
    private let micRestartInterval: TimeInterval = 10

    // MARK: Старт

    func start() async throws {
        guard !isRecording, !isStopping else { return }
        var started = false
        defer {
            if !started {
                sampleQueue.sync {
                    self.writer?.cancel()
                    self.writer = nil
                    self.currentFileURL = nil
                }
                stopAudioSources()
                stream = nil
                endRecordingActivity()
            }
        }

        // 0. Доступ к микрофону — до старта, чтобы prompt разрешился заранее
        //    и первая же запись писала твой голос.
        let useMic = micEnabled
        if useMic {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw NSError(domain: "ushi", code: 4, userInfo: [NSLocalizedDescriptionKey:
                        "Нет доступа к микрофону. Разреши его в Системных настройках → Конфиденциальность и безопасность → Микрофон, либо выключи микрофон, чтобы писать только системный звук."])
                }
            default:
                throw NSError(domain: "ushi", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "Нет доступа к микрофону. Разреши его в Системных настройках → Конфиденциальность и безопасность → Микрофон, либо выключи микрофон, чтобы писать только системный звук."])
            }
        }

        let wantSystemAudio = systemAudioEnabled
        guard wantSystemAudio || useMic else {
            throw NSError(domain: "ushi", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Выбери хотя бы один источник звука."])
        }

        // 1. Экран — только если нужно видео. Звук идёт мимо ScreenCaptureKit,
        //    поэтому без видео доступ к записи экрана не нужен вовсе.
        let wantVideo = captureVideo
        var videoSize = CGSize(width: 2, height: 2)
        var videoBitrate = 0
        var screenStream: SCStream?
        if wantVideo {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw NSError(domain: "ushi", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Не найден дисплей для захвата"])
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = false

            // Пресет качества из настроек: пропорциональное уменьшение по высоте.
            let quality = AppSettings.videoQuality()
            let srcW = max(2, display.width)
            let srcH = max(2, display.height)
            let (w, h): (Int, Int)
            if let maxH = quality.maxHeight, srcH > maxH {
                let scale = Double(maxH) / Double(srcH)
                w = max(2, Int((Double(srcW) * scale).rounded()))
                h = maxH
            } else {
                w = srcW
                h = srcH
            }
            videoSize = CGSize(width: w, height: h)
            videoBitrate = quality.bitrateBitsPerSecond
            config.width = w
            config.height = h
            config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(quality.fps))
            config.queueDepth = 8
            config.showsCursor = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            screenStream = stream
        }

        // 2. Готовим writer (на sampleQueue, чтобы избежать гонок).
        let fileURL = try makeOutputURL(video: wantVideo)
        // Стерео «голосовая дорожка» (L = микрофон, R = система) для разметки
        // «Я / Собеседник» — только когда пишутся оба источника.
        var voiceURL: URL?
        if useMic, wantSystemAudio, let dir = try? AppSettings.voiceTracksDirectory() {
            voiceURL = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        }
        let writer = try RecordingWriter(outputURL: fileURL, voiceTrackURL: voiceURL,
                                         video: wantVideo,
                                         videoSize: videoSize, videoBitrate: videoBitrate)
        writer.liveSink = liveSink

        sampleQueue.sync {
            self.currentFileURL = fileURL
            self.currentVoiceTrackURL = writer.voiceTrackURL
            self.writer = writer
        }

        // 3. Запускаем источники. Буферы приходят на sampleQueue, как и раньше.
        beginRecordingActivity()
        let now = ProcessInfo.processInfo.systemUptime
        sampleQueue.sync {
            self.lastSystemBufferAt = now
            self.lastMicSoundAt = now
        }
        recordsSystemAudio = wantSystemAudio
        recordsMicrophone = useMic
        if wantSystemAudio {
            try startSystemAudio()
        }
        if useMic {
            try startMicrophone()
        }
        if let screenStream {
            self.stream = screenStream
            try await screenStream.startCapture()
        }
        started = true

        await MainActor.run {
            self.startDate = Date()
            self.elapsed = 0
            self.isRecording = true
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
            self.timer = timer
            // Открытое меню переключает run loop в tracking mode.
            RunLoop.main.add(timer, forMode: .common)
            self.startSourceSupervision()
        }
    }

    // MARK: Стоп

    @discardableResult
    func stop() async throws -> (url: URL, voiceTrackURL: URL?, duration: TimeInterval) {
        guard isRecording, !isStopping else {
            throw NSError(domain: "ushi", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Запись не идёт"])
        }

        isStopping = true
        defer {
            isStopping = false
            startDate = nil
            endRecordingActivity()
        }
        // Сначала глушим источники звука, потом экран — после барьера на sampleQueue
        // новых буферов не будет.
        stopAudioSources()
        let stoppingStream = stream
        stream = nil // Delegate errors during an intentional stop must not finalize twice.
        if let stoppingStream {
            try? await stoppingStream.stopCapture()
        }
        await MainActor.run {
            self.timer?.invalidate()
            self.timer = nil
            self.isRecording = false
            self.level = 0
            self.elapsed = 0          // сбрасываем таймер сразу, чтобы не висели старые цифры
        }

        // На sampleQueue дописываем хвост и закрываем входы — после барьера гарантировано,
        // что все sample-колбэки отработали. finishWriting() ждём уже вне очереди.
        let (writer, url, voiceURL): (RecordingWriter?, URL?, URL?) = await withCheckedContinuation { cont in
            sampleQueue.async {
                let w = self.writer
                let u = self.currentFileURL
                w?.finishInputs()
                // Читаем после finishInputs: при сбое записи дорожка сбрасывается.
                let v = w?.voiceTrackURL
                self.writer = nil
                self.currentFileURL = nil
                self.currentVoiceTrackURL = nil
                self.lastSystemRMS = 0
                self.lastMicRMS = 0
                cont.resume(returning: (w, u, v))
            }
        }
        try await writer?.complete()

        await MainActor.run { self.startDate = nil }

        guard let url else {
            throw NSError(domain: "ushi", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Файл не создан"])
        }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "ushi", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Запись прервалась до получения звука или видео."])
        }
        let voiceTrack = voiceURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        return (url, voiceTrack, duration)
    }

    // MARK: Звук из Core Audio tap и AVAudioEngine (на sampleQueue)

    private func receive(_ pcm: AVAudioPCMBuffer, at pts: CMTime, source: RecordingWriter.Source) {
        switch source {
        case .system:
            lastSystemBufferAt = ProcessInfo.processInfo.systemUptime
        case .microphone:
            if Self.hasSignal(pcm) { lastMicSoundAt = ProcessInfo.processInfo.systemUptime }
        }
        let rms = writer?.appendAudio(pcm, at: pts, source: source) ?? 0
        updateLevel(rms: rms, source: source)
    }

    /// Есть ли в буфере хоть один ненулевой сэмпл. Не float — считаем живым.
    private static func hasSignal(_ pcm: AVAudioPCMBuffer) -> Bool {
        guard let channels = pcm.floatChannelData else { return true }
        let n = Int(pcm.frameLength)
        for c in 0..<Int(pcm.format.channelCount) {
            let ch = channels[c]
            for i in 0..<n where ch[i] != 0 { return true }
        }
        return false
    }

    private func startSystemAudio() throws {
        let tap = SystemAudioTap()
        try tap.start(queue: sampleQueue) { [weak self] pcm, pts in
            self?.receive(pcm, at: pts, source: .system)
        }
        tap.onFormatChange = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRestart(of: .system) }
        }
        systemTap = tap
    }

    private func startMicrophone() throws {
        let mic = MicrophoneCapture()
        try mic.start(queue: sampleQueue) { [weak self] pcm, pts in
            self?.receive(pcm, at: pts, source: .microphone)
        }
        mic.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRestart(of: .microphone) }
        }
        microphone = mic
    }

    private func stopAudioSources() {
        stopSourceSupervision()
        recordsSystemAudio = false
        recordsMicrophone = false
        systemTap?.stop()
        systemTap = nil
        microphone?.stop()
        microphone = nil
    }

    // MARK: Живучесть источников (главный поток)

    private func startSourceSupervision() {
        let monitor = AudioDeviceMonitor()
        monitor.start { [weak self] change in
            MainActor.assumeIsolated {
                switch change {
                case .output: self?.scheduleRestart(of: .system)
                case .input:  self?.scheduleRestart(of: .microphone)
                }
            }
        }
        deviceMonitor = monitor

        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSourcesAlive() }
        }
        self.watchdog = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
    }

    private func stopSourceSupervision() {
        deviceMonitor?.stop()
        deviceMonitor = nil
        watchdog?.invalidate()
        watchdog = nil
        pendingSystemRestart?.cancel()
        pendingSystemRestart = nil
        pendingMicRestart?.cancel()
        pendingMicRestart = nil
    }

    /// Bluetooth при подключении дёргает устройство по умолчанию несколько раз
    /// подряд — ждём, пока успокоится, и пересоздаём источник один раз.
    private func scheduleRestart(of source: RecordingWriter.Source) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restart(source, reason: "сменилось устройство") }
        }
        switch source {
        case .system:
            guard recordsSystemAudio else { return }
            pendingSystemRestart?.cancel()
            pendingSystemRestart = work
        case .microphone:
            guard recordsMicrophone else { return }
            pendingMicRestart?.cancel()
            pendingMicRestart = work
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func checkSourcesAlive() {
        guard isRecording, !isStopping else { return }
        let (systemAt, micAt) = sampleQueue.sync { (lastSystemBufferAt, lastMicSoundAt) }
        let now = ProcessInfo.processInfo.systemUptime
        if recordsSystemAudio, now - systemAt > systemStallTimeout,
           now - lastSystemRestart > systemStallTimeout {
            restart(.system, reason: "нет буферов \(Int(now - systemAt)) с")
        }
        if recordsMicrophone, now - micAt > micStallTimeout,
           now - lastMicRestart > micRestartInterval {
            restart(.microphone, reason: "тишина/нет буферов \(Int(now - micAt)) с")
        }
    }

    /// Пересоздаёт источник с текущим устройством по умолчанию. Не вышло —
    /// сторож попробует снова, запись не прерывается.
    private func restart(_ source: RecordingWriter.Source, reason: String) {
        guard isRecording, !isStopping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch source {
        case .system:
            guard recordsSystemAudio else { return }
            pendingSystemRestart = nil
            lastSystemRestart = now
            systemTap?.stop()
            systemTap = nil
            do {
                try startSystemAudio()
                print("🔁 system audio restarted (\(reason))")
            } catch {
                print("⚠️ system audio restart failed (\(reason)): \(error.localizedDescription)")
            }
        case .microphone:
            guard recordsMicrophone else { return }
            pendingMicRestart = nil
            lastMicRestart = now
            microphone?.stop()
            microphone = nil
            do {
                try startMicrophone()
                print("🔁 microphone restarted (\(reason))")
            } catch {
                print("⚠️ microphone restart failed (\(reason)): \(error.localizedDescription)")
            }
        }
    }

    // MARK: SCStreamOutput — приём буферов (на sampleQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .screen:
            if Self.isCompleteFrame(sampleBuffer) {
                writer?.appendVideo(sampleBuffer)
            }
        case .audio:
            let rms = writer?.appendAudio(sampleBuffer, source: .system) ?? 0
            updateLevel(rms: rms, source: .system)
        default:
            if #available(macOS 15.0, *), outputType == .microphone {
                let rms = writer?.appendAudio(sampleBuffer, source: .microphone) ?? 0
                updateLevel(rms: rms, source: .microphone)
            }
        }
    }

    /// Видеокадр считается готовым только со статусом .complete (иначе это пустой/повторный кадр).
    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = arr.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream, self.isRecording, !self.isStopping else { return }
            self.stream = nil
            await self.onInterruption?(error)
        }
    }

    func beginRecordingActivity() {
        guard recordingActivity == nil else { return }
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Ushi: идёт запись"
        )
    }

    func endRecordingActivity() {
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
    }

    // MARK: Уровень входа — с дросселированием

    private func updateLevel(rms: Float, source: RecordingWriter.Source) {
        switch source {
        case .system:     lastSystemRMS = rms
        case .microphone: lastMicRMS = rms
        }

        let now = Date()
        if now.timeIntervalSince(lastLevelUpdate) < levelUpdateInterval { return }
        lastLevelUpdate = now

        // Берём громкость самого активного источника — иначе тишина одного гасит другой.
        let combined = Swift.max(lastSystemRMS, lastMicRMS)
        let normalized = min(1, max(0, combined * 4))
        Task { @MainActor in
            self.level = self.level * 0.6 + normalized * 0.4
        }
    }

    // MARK: Файлы

    private func makeOutputURL(video: Bool) throws -> URL {
        let dir: URL
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            dir = outputDirectory
        } else {
            dir = try Self.documentsDirectory()
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let ext = video ? "mov" : "m4a"
        let name = formatter.string(from: Date()) + "." + ext
        return dir.appendingPathComponent(name)
    }

    static func documentsDirectory() throws -> URL {
        try AppSettings.recordingsDirectory()
    }
}

// MARK: - Writer: сведённый звук (+ опц. видео) в один файл через AVAssetWriter

/// Пишет аудио-микс (система + микрофон) и, если задано, видео экрана в один файл.
/// Параллельно (если задан voiceTrackURL) пишет стерео-дорожку L = микрофон, R = система —
/// по ней whisper размечает «Я / Собеседник».
/// Все методы вызываются на одной очереди (sampleQueue), кроме complete().
final class RecordingWriter {

    enum Source { case system, microphone }

    /// Готовый (сведённый) звук для живой расшифровки, 48 кГц моно, по порядку
    /// и без пропусков: микрофон и система раздельно (nil, если пишется один
    /// источник или голосовая дорожка отвалилась) и общий микс.
    typealias LiveSink = (_ microphone: [Float]?, _ system: [Float]?, _ mix: [Float]) -> Void
    var liveSink: LiveSink?

    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private let videoInput: AVAssetWriterInput?

    /// Стерео «голосовая дорожка» для разметки говорящих. nil — не пишем.
    private var voiceFile: AVAudioFile?
    private let voiceFormat: AVAudioFormat?
    private(set) var voiceTrackURL: URL?
    // Те же сэмплы, что в mix, но раздельно по источникам (индексация как у mix).
    private var micPart: [Float] = []
    private var systemPart: [Float] = []

    // Общая точка отсчёта таймлайна (PTS первого пришедшего буфера любого типа).
    private var anchor: CMTime?

    // Канонический формат микса: mono float32 48 kHz.
    private let canonical: AVAudioFormat
    private var audioFormatDesc: CMFormatDescription?
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?

    // Аккумулятор моно-микса (суммирование с перекрытием по абсолютным сэмплам).
    private var mix: [Float] = []
    private var mixBase: Int64 = 0          // абсолютный индекс сэмпла mix[0] (0 == anchor)
    private var maxFrame: Int64 = 0         // максимум (start+len) среди принятых
    private let lagFrames: Int64 = 14_400   // ~0.3 с запас перед флашем

    // Куда должен лечь следующий буфер каждого источника, если поток непрерывный.
    // Метки времени у Bluetooth в режиме звонка «дрожат» на миллисекунды: если
    // ставить каждый буфер строго по метке, между буферами появляются дырки, а
    // соседние наслаиваются — получается «электрический» звук. Поэтому кладём
    // буферы встык и сверяемся с меткой, только если ушли дальше допуска
    // (перезапуск источника, пропуск, накопившийся дрейф часов).
    private var nextSystemFrame: Int64?
    private var nextMicFrame: Int64?
    private let continuityTolerance: Int64 = 4_800   // 0.1 с

    init(outputURL: URL, voiceTrackURL: URL? = nil, video: Bool, videoSize: CGSize, videoBitrate: Int) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: video ? .mov : .m4a)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw NSError(domain: "ushi", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось добавить аудио-дорожку"])
        }
        writer.add(audioInput)

        if video {
            var compression: [String: Any] = [:]
            if videoBitrate > 0 {
                compression[AVVideoAverageBitRateKey] = videoBitrate
            }
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height),
            ]
            if !compression.isEmpty {
                videoSettings[AVVideoCompressionPropertiesKey] = compression
            }
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vi.expectsMediaDataInRealTime = true
            if writer.canAdd(vi) {
                writer.add(vi)
                videoInput = vi
            } else {
                videoInput = nil
            }
        } else {
            videoInput = nil
        }

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 48_000, channels: 1, interleaved: false) else {
            throw NSError(domain: "ushi", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось создать аудиоформат"])
        }
        canonical = fmt

        // Голосовая дорожка — не критична: если не открылась, запись идёт без неё.
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000, channels: 2, interleaved: false)
        voiceFormat = stereo
        if let voiceTrackURL, stereo != nil {
            let voiceSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000,
            ]
            do {
                voiceFile = try AVAudioFile(forWriting: voiceTrackURL, settings: voiceSettings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
                self.voiceTrackURL = voiceTrackURL
            } catch {
                print("⚠️ voice track disabled: \(error.localizedDescription)")
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ushi", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось начать запись"])
        }
    }

    // MARK: Видео

    func appendVideo(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isNumeric else { return }
        ensureAnchor(pts)
        guard let anchor, CMTimeCompare(pts, anchor) >= 0 else { return }
        guard let vi = videoInput, vi.isReadyForMoreMediaData else { return }
        vi.append(sb)
    }

    // MARK: Аудио (микс)

    /// Подмешивает буфер источника в аккумулятор и флашит готовую (старую) часть.
    /// Возвращает RMS этого куска — для индикатора уровня.
    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer, source: Source) -> Float {
        guard let pcm = pcmBuffer(from: sampleBuffer) else { return 0 }
        return appendAudio(pcm, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), source: source)
    }

    /// То же для PCM-буфера с временем по часам хоста — так приходят звук из
    /// Core Audio tap и микрофон из AVAudioEngine.
    @discardableResult
    func appendAudio(_ pcm: AVAudioPCMBuffer, at pts: CMTime, source: Source) -> Float {
        guard let mono = monoSamples(from: pcm, source: source) else { return 0 }
        guard pts.isNumeric else { return 0 }
        ensureAnchor(pts)
        guard let anchor else { return 0 }

        var start = Int64(((CMTimeGetSeconds(pts) - CMTimeGetSeconds(anchor)) * 48_000).rounded())
        let n = mono.count
        guard n > 0 else { return 0 }
        let expected = source == .system ? nextSystemFrame : nextMicFrame
        if let expected, abs(start - expected) <= continuityTolerance {
            start = expected
        }
        switch source {
        case .system:     nextSystemFrame = start + Int64(n)
        case .microphone: nextMicFrame = start + Int64(n)
        }

        // Куда писать в аккумуляторе. Если кусок старше уже флашнутого — отрезаем начало.
        var idx = Int(start - mixBase)
        var srcOffset = 0
        if idx < 0 {
            srcOffset = -idx
            idx = 0
        }
        guard srcOffset < n else { return 0 }

        let end = idx + (n - srcOffset)
        if end > mix.count {
            let grow = end - mix.count
            mix.append(contentsOf: repeatElement(0, count: grow))
            if voiceFile != nil {
                micPart.append(contentsOf: repeatElement(0, count: grow))
                systemPart.append(contentsOf: repeatElement(0, count: grow))
            }
        }

        var i = idx
        var s = srcOffset
        var sumSq: Float = 0
        let keepParts = voiceFile != nil
        while s < n {
            let v = mono[s]
            mix[i] += v
            if keepParts {
                switch source {
                case .microphone: micPart[i] += v
                case .system:     systemPart[i] += v
                }
            }
            sumSq += v * v
            i += 1
            s += 1
        }
        maxFrame = Swift.max(maxFrame, start + Int64(n))

        flush(upTo: maxFrame - lagFrames)
        return sqrt(sumSq / Float(n))
    }

    // MARK: Финал

    /// Дописывает остаток и помечает входы законченными. Вызывать на sampleQueue.
    func finishInputs() {
        guard writer.status == .writing else { dropVoiceTrack(); return }
        guard anchor != nil else { writer.cancelWriting(); dropVoiceTrack(); return }
        flush(upTo: maxFrame, force: true)
        voiceFile = nil          // деинициализация AVAudioFile дописывает и закрывает файл
        audioInput.markAsFinished()
        videoInput?.markAsFinished()
    }

    /// Дожидается записи файла на диск. Вызывать вне sampleQueue.
    func cancel() {
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        dropVoiceTrack()
    }

    func complete() async throws {
        if writer.status == .writing { await writer.finishWriting() }
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ushi", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось завершить файл записи. Проверь свободное место на диске."])
        }
    }

    // MARK: Внутреннее

    private func ensureAnchor(_ pts: CMTime) {
        guard anchor == nil else { return }
        anchor = pts
        writer.startSession(atSourceTime: pts)
    }

    private func flush(upTo absFrame: Int64, force: Bool = false) {
        guard let anchor else { return }
        let count = Int(absFrame - mixBase)
        guard count > 0, count <= mix.count else { return }
        guard force || audioInput.isReadyForMoreMediaData else { return }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: canonical,
                                         frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        if let dst = pcm.floatChannelData?[0] {
            mix.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: count)
                }
            }
        }

        let pts = CMTimeAdd(anchor, CMTime(value: mixBase, timescale: 48_000))
        guard let sb = makeAudioSampleBuffer(from: pcm, pts: pts) else { return }
        audioInput.append(sb)
        if let liveSink {
            let hasParts = voiceFile != nil && micPart.count >= count && systemPart.count >= count
            liveSink(hasParts ? Array(micPart[..<count]) : nil,
                     hasParts ? Array(systemPart[..<count]) : nil,
                     Array(mix[..<count]))
        }
        writeVoiceTrack(count: count)

        mix.removeFirst(count)
        mixBase += Int64(count)
    }

    /// Пишет первые `count` сэмплов раздельных источников в стерео-дорожку и сдвигает их.
    private func writeVoiceTrack(count: Int) {
        guard voiceFile != nil else { return }
        guard let file = voiceFile, let fmt = voiceFormat,
              micPart.count >= count, systemPart.count >= count,
              let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)),
              let ch = pcm.floatChannelData else {
            dropVoiceTrack()
            return
        }
        pcm.frameLength = AVAudioFrameCount(count)
        micPart.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { ch[0].update(from: base, count: count) }
        }
        systemPart.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { ch[1].update(from: base, count: count) }
        }
        micPart.removeFirst(count)
        systemPart.removeFirst(count)
        do {
            try file.write(from: pcm)
        } catch {
            print("⚠️ voice track write failed: \(error.localizedDescription)")
            dropVoiceTrack()
        }
    }

    /// Дорожка с дырой хуже, чем никакой: транскрипция по ней потеряет текст.
    /// Поэтому при любом сбое удаляем файл целиком — тогда распознаём основной микс.
    private func dropVoiceTrack() {
        guard voiceFile != nil || voiceTrackURL != nil else { return }
        voiceFile = nil
        micPart = []
        systemPart = []
        if let url = voiceTrackURL {
            try? FileManager.default.removeItem(at: url)
        }
        voiceTrackURL = nil
    }

    private func makeAudioSampleBuffer(from pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        if audioFormatDesc == nil {
            var fd: CMFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: pcm.format.streamDescription,
                layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &fd)
            guard status == noErr else { return nil }
            audioFormatDesc = fd
        }
        guard let fd = audioFormatDesc else { return nil }

        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fd, sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sb)
        guard createStatus == noErr, let sb else { return nil }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sb, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.mutableAudioBufferList)
        guard setStatus == noErr else { return nil }
        return sb
    }

    // MARK: CMSampleBuffer → mono float32 48k

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let inFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        inBuf.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return inBuf
    }

    private func monoSamples(from inBuf: AVAudioPCMBuffer, source: Source) -> [Float]? {
        let inFormat = inBuf.format
        let frames = inBuf.frameLength
        guard frames > 0, let converter = converter(for: source, from: inFormat) else { return nil }

        let ratio = canonical.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(frames) * ratio + 1_024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: outCap) else { return nil }

        var fed = false
        var convError: NSError?
        let result = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if result == .error { return nil }

        let outN = Int(outBuf.frameLength)
        guard outN > 0, let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: outN))
    }

    private func converter(for source: Source, from inFormat: AVAudioFormat) -> AVAudioConverter? {
        switch source {
        case .system:
            if systemConverter == nil || systemConverter?.inputFormat != inFormat {
                systemConverter = AVAudioConverter(from: inFormat, to: canonical)
            }
            return systemConverter
        case .microphone:
            if micConverter == nil || micConverter?.inputFormat != inFormat {
                micConverter = AVAudioConverter(from: inFormat, to: canonical)
            }
            return micConverter
        }
    }
}
