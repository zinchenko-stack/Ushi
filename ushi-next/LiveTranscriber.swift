//
//  LiveTranscriber.swift
//  UshiNext
//
//  Живая расшифровка во время созвона: звук нарезается на куски по паузам,
//  каждый кусок распознаётся whisper тем же способом, что и запись целиком,
//  реплики склеиваются. Чтобы текст появился сразу, в начале куски короткие:
//  первый ~5 с, до минуты ~15 с, дальше ~30 с (длинные точнее распознаются). После остановки эти же куски и есть итоговая расшифровка —
//  второй раз запись не распознаётся.
//
//  Куски идут встык, без нахлёста: каждый сэмпл попадает ровно в один кусок,
//  поэтому нет ни пропусков, ни повторов. Режем в тишине, чтобы не разрубить слово.
//

import Foundation
import Observation

/// Реплика живой расшифровки.
nonisolated struct LiveTurn: Equatable, Sendable {
    /// «Я» / «Собеседник»; nil — запись без разметки (один источник звука).
    var speaker: String?
    var text: String
    /// Секунды от начала записи (начало куска, в котором реплика началась).
    var start: TimeInterval
}

// MARK: - Нарезка по паузам

/// Копит звук 16 кГц и отдаёт куски, разрезанные в тишине. Без потоков —
/// чистая логика, тестируется отдельно.
nonisolated struct LiveChunker {
    static let rate = 16_000

    struct Chunk: Equatable {
        /// Номер первого сэмпла куска от начала записи.
        let start: Int
        let left: [Float]
        /// nil — моно.
        let right: [Float]?
    }

    /// Границы длины куска в зависимости от того, где он начинается
    /// (в сэмплах от начала записи): первый ~5 с, до минуты ~15 с, дальше ~30 с.
    static func limits(forPosition position: Int) -> (min: Int, max: Int) {
        switch position {
        case ..<(5 * rate):  return (3 * rate, 8 * rate)
        case ..<(60 * rate): return (12 * rate, 20 * rate)
        default:             return (25 * rate, 40 * rate)
        }
    }
    /// Тишина: окно 0.3 с с громкостью ниже порога (≈ −44 дБ).
    private let frame = 800                    // 50 мс
    private let windowFrames = 6               // 0.3 с
    private let silenceRMS: Float = 0.006

    private var left: [Float] = []
    private var right: [Float]?
    private var frameEnergy: [Float] = []      // средний квадрат по кадрам 50 мс
    private var consumed = 0

    init(stereo: Bool) {
        right = stereo ? [] : nil
    }

    var isStereo: Bool { right != nil }
    var pendingSamples: Int { left.count }

    /// Добавить звук (для моно `right` игнорируется) и забрать готовые куски.
    mutating func append(left newLeft: [Float], right newRight: [Float]?) -> [Chunk] {
        let oldFrames = frameEnergy.count
        left.append(contentsOf: newLeft)
        if right != nil {
            right!.append(contentsOf: newRight ?? newLeft)
        }
        // Досчитываем энергию для появившихся целых кадров.
        let fullFrames = left.count / frame
        if fullFrames > oldFrames {
            for f in oldFrames..<fullFrames {
                frameEnergy.append(energy(from: f * frame, count: frame))
            }
        }
        var chunks: [Chunk] = []
        while let cut = cutPoint() {
            chunks.append(take(cut))
        }
        return chunks
    }

    /// Остаток в конце записи — последний кусок.
    mutating func flush() -> Chunk? {
        left.isEmpty ? nil : take(left.count)
    }

    /// Где резать: первая тишина после минимальной длины; нет тишины до
    /// максимума — самое тихое место. nil — ещё рано.
    private func cutPoint() -> Int? {
        let (minSamples, maxSamples) = Self.limits(forPosition: consumed)
        let minFrame = minSamples / frame
        guard frameEnergy.count >= minFrame + windowFrames else { return nil }
        let threshold = silenceRMS * silenceRMS
        var best: (frame: Int, energy: Float)?
        for f in minFrame...(frameEnergy.count - windowFrames) {
            let e = windowEnergy(at: f)
            if e < threshold { return (f + windowFrames / 2) * frame }
            if best == nil || e < best!.energy { best = (f, e) }
        }
        if left.count >= maxSamples, let best {
            return (best.frame + windowFrames / 2) * frame
        }
        return nil
    }

    private func windowEnergy(at f: Int) -> Float {
        var sum: Float = 0
        for i in f..<(f + windowFrames) { sum += frameEnergy[i] }
        return sum / Float(windowFrames)
    }

    private func energy(from start: Int, count: Int) -> Float {
        var sum: Float = 0
        for i in start..<(start + count) {
            let v = right.map { (left[i] + $0[i]) * 0.5 } ?? left[i]
            sum += v * v
        }
        return sum / Float(count)
    }

    private mutating func take(_ count: Int) -> Chunk {
        let chunk = Chunk(start: consumed, left: Array(left[..<count]), right: right.map { Array($0[..<count]) })
        left.removeFirst(count)
        right?.removeFirst(count)
        frameEnergy.removeFirst(min(frameEnergy.count, count / frame))
        // Срез мог прийтись на середину кадра — пересчитываем кадры заново.
        if count % frame != 0 {
            frameEnergy = (0..<(left.count / frame)).map { energy(from: $0 * frame, count: frame) }
        }
        consumed += count
        return chunk
    }
}

// MARK: - Движок

/// Принимает звук от записи (на очереди сэмплов), режет, распознаёт куски по
/// очереди и отдаёт реплики на главный поток.
nonisolated final class LiveTranscriber: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ushi.live-transcriber")
    private var chunker: LiveChunker?
    // Остатки при прореживании 48 → 16 кГц (по 3 сэмпла).
    private var carryMic: [Float] = []
    private var carrySystem: [Float] = []
    private var carryMix: [Float] = []

    private var lastJob: Task<Void, Never>?
    private let workDir: URL
    private let onTurns: @MainActor ([LiveTurn]) -> Void

    // Меняются только внутри цепочки задач (они идут строго по очереди).
    private var language: String
    private var languageLocked: Bool
    private var failed = false

    init(language: String, onTurns: @escaping @MainActor ([LiveTurn]) -> Void) {
        self.language = language
        self.languageLocked = language != "auto"
        self.onTurns = onTurns
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ushi-live-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    /// Для `RecordingWriter.liveSink`.
    func append(microphone: [Float]?, system: [Float]?, mix: [Float]) {
        queue.async { [self] in
            if chunker == nil {
                chunker = LiveChunker(stereo: microphone != nil && system != nil)
            }
            let stereo = chunker!.isStereo
            let left: [Float]
            var right: [Float]?
            if stereo {
                // Голосовая дорожка отвалилась посреди записи — тот же микс в оба канала.
                left = Self.decimate(microphone ?? mix, carry: &carryMic)
                right = Self.decimate(system ?? mix, carry: &carrySystem)
            } else {
                left = Self.decimate(mix, carry: &carryMix)
            }
            for chunk in chunker!.append(left: left, right: right) {
                enqueue(chunk)
            }
        }
    }

    /// Дорасшифровать остаток. true — все куски распознаны без ошибок.
    func finish() async -> Bool {
        let (job, hadAudio): (Task<Void, Never>?, Bool) = await withCheckedContinuation { cont in
            queue.async { [self] in
                if let chunk = chunker?.flush() { enqueue(chunk) }
                cont.resume(returning: (lastJob, chunker != nil))
            }
        }
        await job?.value
        try? FileManager.default.removeItem(at: workDir)
        return !failed && hadAudio
    }

    // MARK: Внутреннее (на `queue`)

    private func enqueue(_ chunk: LiveChunker.Chunk) {
        let previous = lastJob
        lastJob = Task.detached(priority: .userInitiated) { [self] in
            await previous?.value
            await transcribe(chunk)
        }
    }

    private func transcribe(_ chunk: LiveChunker.Chunk) async {
        let wav = workDir.appendingPathComponent("chunk-\(chunk.start).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let stereo = chunk.right != nil
        do {
            try Self.writeWAV(chunk, to: wav)
            let result = try await TranscriptionService.transcribeChunk(
                wavURL: wav, diarize: stereo, language: language
            )
            // «Авто»: язык определяем на первом уверенном куске и дальше не гадаем —
            // на коротком куске автоопределение иногда промахивается.
            if !languageLocked, let code = result.detectedLanguage, (result.probability ?? 0) >= 0.8 {
                language = code
                languageLocked = true
            }
            let start = TimeInterval(chunk.start) / TimeInterval(LiveChunker.rate)
            let turns: [LiveTurn]
            if stereo {
                turns = TranscriptionService.speakerTurns(result.raw)
                    .map { LiveTurn(speaker: $0.speaker, text: $0.text, start: start) }
            } else {
                let text = TranscriptionService.cleanTranscript(result.raw)
                turns = text.isEmpty ? [] : [LiveTurn(speaker: nil, text: text, start: start)]
            }
            if !turns.isEmpty {
                await MainActor.run { onTurns(turns) }
            }
        } catch {
            print("⚠️ live chunk failed: \(error.localizedDescription)")
            failed = true
        }
    }

    /// 48 → 16 кГц: среднее по тройкам (простой фильтр от наложения частот).
    private static func decimate(_ input: [Float], carry: inout [Float]) -> [Float] {
        let all = carry + input
        let n = all.count / 3
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = (all[3 * i] + all[3 * i + 1] + all[3 * i + 2]) / 3
        }
        carry = Array(all[(n * 3)...])
        return out
    }

    /// WAV 16 бит. Стерео — с половинной громкостью: whisper складывает каналы,
    /// и громкий сложенный сигнал хуже распознаётся.
    private static func writeWAV(_ chunk: LiveChunker.Chunk, to url: URL) throws {
        let channels = chunk.right == nil ? 1 : 2
        let gain: Float = channels == 2 ? 0.5 : 1
        var samples = [Int16]()
        samples.reserveCapacity(chunk.left.count * channels)
        func pcm(_ v: Float) -> Int16 { Int16(max(-1, min(1, v * gain)) * 32_767) }
        for i in 0..<chunk.left.count {
            samples.append(pcm(chunk.left[i]))
            if let right = chunk.right { samples.append(pcm(right[i])) }
        }
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(channels))
        le(UInt32(LiveChunker.rate)); le(UInt32(LiveChunker.rate * channels * 2))
        le(UInt16(channels * 2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(bytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}

// MARK: - Модель для экрана

/// Текст живой расшифровки текущей записи. Пишется ещё и в файл
/// `live-transcript.txt` — его читает Claude («что он сейчас говорит»).
@Observable
final class LiveTranscript {
    private(set) var turns: [LiveTurn] = []
    private(set) var isFinished = false
    let startDate: Date
    let projectName: String?

    /// Сколько реплик пользователь уже видел (для черты «Новое»).
    var seenCount = 0

    @ObservationIgnored private(set) var engine: LiveTranscriber!

    init(projectName: String?, startDate: Date = Date()) {
        self.projectName = projectName
        self.startDate = startDate
        engine = LiveTranscriber(language: AppSettings.transcriptionLanguage().rawValue) { [weak self] new in
            self?.add(new)
        }
        writeFile()
    }

    /// Дождаться последнего куска. Итоговый текст — или nil, если какой-то
    /// кусок не распознался (тогда запись расшифруется целиком, как раньше).
    func finish() async -> String? {
        let ok = await engine.finish()
        isFinished = true
        writeFile()
        guard ok else { return nil }
        return Self.format(turns)
    }

    func add(_ new: [LiveTurn]) {
        turns = Self.merge(turns, new)
        writeFile()
    }

    /// Реплика одного говорящего, разрезанная между кусками, склеивается обратно.
    nonisolated static func merge(_ turns: [LiveTurn], _ new: [LiveTurn]) -> [LiveTurn] {
        var result = turns
        for turn in new {
            if let last = result.last, last.speaker == turn.speaker {
                result[result.count - 1].text += (turn.speaker == nil ? "\n" : " ") + turn.text
            } else {
                result.append(turn)
            }
        }
        return result
    }

    /// Тот же вид, что у обычной расшифровки: «Я: …» / «Собеседник: …».
    nonisolated static func format(_ turns: [LiveTurn]) -> String {
        turns.map { turn in turn.speaker.map { "\($0): \(turn.text)" } ?? turn.text }
            .joined(separator: turns.contains { $0.speaker != nil } ? "\n\n" : "\n")
    }

    // MARK: Файл для Claude

    static func fileURL() throws -> URL {
        try AppSettings.metadataDirectory().appendingPathComponent("live-transcript.txt")
    }

    private func writeFile() {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let project = projectName.map { " · проект «\($0)»" } ?? ""
        var lines = [isFinished
            ? "# Ushi: запись закончена в \(clock.string(from: Date()))\(project), начало \(clock.string(from: startDate))"
            : "# Ushi: идёт запись\(project), начало \(clock.string(from: startDate))",
            "# Текст отстаёт от разговора на 10–40 секунд. Время — начало куска, в котором прозвучала реплика.",
            ""]
        for turn in turns {
            let at = clock.string(from: startDate.addingTimeInterval(turn.start))
            lines.append("[\(at)] " + (turn.speaker.map { "\($0): " } ?? "") + turn.text)
            lines.append("")
        }
        if let url = try? Self.fileURL() {
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
