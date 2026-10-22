//
//  AudioSources.swift
//  UshiNext
//
//  Источники звука без ScreenCaptureKit — чтобы для записи звука не нужен был
//  доступ к экрану (и пугающее окно macOS про «обход выбора окон»).
//
//  - SystemAudioTap: системный звук через Core Audio process tap (macOS 14.4+).
//    Разрешение — «Только запись системного звука» (NSAudioCaptureUsageDescription).
//    Звук самого Ushi исключён, как раньше excludesCurrentProcessAudio.
//  - MicrophoneCapture: микрофон через AVAudioEngine (разрешение «Микрофон»).
//    Работает и на macOS 14, в отличие от микрофона ScreenCaptureKit.
//
//  Оба отдают PCM-буферы с временем по часам хоста — теми же, что у кадров
//  ScreenCaptureKit, поэтому звук и видео совпадают по времени.
//

import Foundation
import AVFoundation
import CoreAudio
import CoreMedia

nonisolated enum AudioSourceError: LocalizedError {
    case systemAudio(String, OSStatus)
    case microphone(String)

    var errorDescription: String? {
        switch self {
        case .systemAudio(let step, let status):
            return "Не удалось подключиться к системному звуку (\(step), код \(status)). Проверь доступ: Системные настройки → Конфиденциальность и безопасность → Запись звука."
        case .microphone(let reason):
            return "Не удалось включить микрофон: \(reason)"
        }
    }
}

/// Время буфера по часам хоста → CMTime (как PTS у ScreenCaptureKit).
nonisolated func hostTimeToCMTime(_ hostTime: UInt64) -> CMTime {
    CMClockMakeHostTimeFromSystemUnits(hostTime)
}

// MARK: - Системный звук

nonisolated final class SystemAudioTap: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer, CMTime) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapList: UnsafeMutableAudioBufferListPointer?
    private var rateListener: AudioObjectPropertyListenerBlock?

    /// Частота устройства сменилась — захват надо пересоздать. Главный поток.
    var onFormatChange: (() -> Void)?

    /// Запустить захват. `handler` вызывается на `queue` для каждого буфера.
    func start(queue: DispatchQueue, handler: @escaping Handler) throws {
        // 1. Tap на весь системный звук, кроме самого Ushi.
        let ownProcess = try Self.ownProcessObject()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioSourceError.systemAudio("tap", status) }

        do {
            // 2. Приватное агрегатное устройство: основное выходное + tap.
            let outputUID = try Self.defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Ushi System Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            guard status == noErr else { throw AudioSourceError.systemAudio("aggregate", status) }

            // 3. Формат буферов и колбэк.
            // Каналы — как у tap-а, но ЧАСТОТА — агрегатного устройства: tap
            // пересэмплируется под него. AirPods в режиме звонка работают на
            // 24 кГц, а tap сообщает свои 48 кГц — если верить tap-у, голос
            // собеседника выходит ускоренным вдвое и с дырками («инопланетный»).
            var asbd = try Self.tapFormat(tapID)
            asbd.mSampleRate = try Self.nominalSampleRate(aggregateID)
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw AudioSourceError.systemAudio("format", -1)
            }
            // У агрегата бывают и чужие входы: в режиме звонка у AirPods есть
            // микрофон, его поток идёт в списке раньше tap-а. Берём последние
            // буферы — это всегда tap.
            let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
            let tapList = AudioBufferList.allocate(maximumBuffers: tapBuffers)
            self.tapList = tapList
            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, inInputData, inInputTime, _, _ in
                let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                guard all.count >= tapBuffers else { return }
                for i in 0..<tapBuffers {
                    tapList[i] = all[all.count - tapBuffers + i]
                }
                guard let pcm = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: tapList.unsafePointer,
                    deallocator: nil
                ) else { return }
                let time = inInputTime.pointee
                let pts = time.mFlags.contains(.hostTimeValid)
                    ? hostTimeToCMTime(time.mHostTime)
                    : hostTimeToCMTime(mach_absolute_time())
                handler(pcm, pts)
            }
            guard status == noErr else { throw AudioSourceError.systemAudio("ioproc", status) }

            status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw AudioSourceError.systemAudio("start", status) }

            // Частота устройства сменилась на ходу (наушники ушли в режим
            // звонка или вернулись) — формат выше устарел, источник надо пересоздать.
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onFormatChange?()
            }
            if AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddress, .main, listener) == noErr {
                rateListener = listener
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        onFormatChange = nil
        if let rateListener, aggregateID != kAudioObjectUnknown {
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(aggregateID, &rateAddress, .main, rateListener)
        }
        rateListener = nil
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapList?.unsafeMutablePointer.deallocate()
        tapList = nil
    }

    // MARK: Core Audio хелперы

    private static func ownProcessObject() throws -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        // Процесс ещё не зарегистрирован в Core Audio — исключать нечего.
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr else { throw AudioSourceError.systemAudio("output device", status) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AudioSourceError.systemAudio("output uid", status) }
        return uid.takeRetainedValue() as String
    }

    private static func nominalSampleRate(_ device: AudioObjectID) throws -> Float64 {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { throw AudioSourceError.systemAudio("sample rate", status) }
        return rate
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw AudioSourceError.systemAudio("tap format", status) }
        return asbd
    }
}

// MARK: - Смена устройств

/// Следит за сменой микрофона / выхода по умолчанию (подключили или сняли
/// наушники, Zoom переключил AirPods и т.п.). Колбэки — на главном потоке.
nonisolated final class AudioDeviceMonitor: @unchecked Sendable {
    enum Change { case input, output }

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start(_ onChange: @escaping (Change) -> Void) {
        let selectors: [(AudioObjectPropertySelector, Change)] = [
            (kAudioHardwarePropertyDefaultInputDevice, .input),
            (kAudioHardwarePropertyDefaultOutputDevice, .output),
            (kAudioHardwarePropertyDefaultSystemOutputDevice, .output),
        ]
        for (selector, change) in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange(change) }
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block
            ) == noErr {
                listeners.append((address, block))
            }
        }
    }

    func stop() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block
            )
        }
        listeners = []
    }
}

// MARK: - Микрофон

nonisolated final class MicrophoneCapture: @unchecked Sendable {
    typealias Handler = (AVAudioPCMBuffer, CMTime) -> Void

    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var queue: DispatchQueue?
    private var handler: Handler?

    /// Сменили микрофон или подключили наушники — движок остановился.
    /// Вызывается на главном потоке; владелец пересоздаёт захват целиком
    /// (перезапуск того же AVAudioEngine после смены Bluetooth-устройства
    /// часто «тихо» не взлетает — так сегодня пропал голос в созвоне).
    var onConfigurationChange: (() -> Void)?

    /// Запустить захват с микрофона по умолчанию. `handler` вызывается на `queue`.
    func start(queue: DispatchQueue, handler: @escaping Handler) throws {
        self.queue = queue
        self.handler = handler
        try startEngine()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        onConfigurationChange = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        handler = nil
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceError.microphone("микрофон не найден")
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, time in
            guard let self, let queue = self.queue,
                  let copy = Self.copy(buffer) else { return }
            let pts = time.isHostTimeValid
                ? hostTimeToCMTime(time.hostTime)
                : hostTimeToCMTime(mach_absolute_time())
            queue.async { self.handler?(copy, pts) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioSourceError.microphone(error.localizedDescription)
        }
    }

    /// Буфер tap-а переиспользуется движком — копируем перед отправкой на очередь.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }
}
