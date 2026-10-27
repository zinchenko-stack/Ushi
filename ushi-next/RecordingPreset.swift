//
//  RecordingPreset.swift
//  UshiNext
//
//  Пресет записи. Один глобальный (app.lastUsedPreset) + по одному
//  на каждый Проект (project.lastUsedPreset). См. §4, §7.2 брифа.
//
//  Три независимых источника (§14 брифа — выбрали гранулярные флаги вместо enum):
//  системный звук, микрофон, экран. Хотя бы один звуковой источник обязателен.
//  В БД хранится строкой вида "system,mic,screen"; старые значения enum
//  ("micOnly" / "systemAndMic" / "screen") читаются как раньше.
//

import Foundation

struct RecordingPreset: Hashable, Codable, RawRepresentable {
    var systemAudio: Bool
    var microphone: Bool
    var screen: Bool

    init(systemAudio: Bool, microphone: Bool, screen: Bool) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.screen = screen
    }

    // MARK: - Готовые сочетания

    static let micOnly = RecordingPreset(systemAudio: false, microphone: true, screen: false)
    static let systemAndMic = RecordingPreset(systemAudio: true, microphone: true, screen: false)
    static let screen = RecordingPreset(systemAudio: true, microphone: true, screen: true)

    /// По умолчанию — как в текущем Ushi: собеседник в созвоне + твой голос.
    static let `default` = systemAndMic

    // MARK: - Хранение

    var rawValue: String {
        var parts: [String] = []
        if systemAudio { parts.append("system") }
        if microphone { parts.append("mic") }
        if screen { parts.append("screen") }
        return parts.joined(separator: ",")
    }

    init?(rawValue: String) {
        switch rawValue {
        // Значения из Phase 1, когда пресет был enum.
        case "micOnly":      self = .micOnly
        case "systemAndMic": self = .systemAndMic
        case "screen":       self = .screen
        default:
            let parts = Set(rawValue.split(separator: ",").map(String.init))
            let preset = RecordingPreset(
                systemAudio: parts.contains("system"),
                microphone: parts.contains("mic"),
                screen: parts.contains("screen")
            )
            guard preset.hasAnyAudio else { return nil }
            self = preset
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let preset = RecordingPreset(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown preset: \(raw)")
        }
        self = preset
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    // MARK: - Snapshot для записи (Recording.hasMicrophone/hasSystemAudio/hasScreen)

    var hasMicrophone: Bool { microphone }
    var hasSystemAudio: Bool { systemAudio }
    var hasScreen: Bool { screen }
    var hasAnyAudio: Bool { systemAudio || microphone }

    // MARK: - Источники

    enum Source: CaseIterable, Hashable {
        case systemAudio, microphone, screen

        var title: String {
            switch self {
            case .systemAudio: return "Системный звук"
            case .microphone:  return "Микрофон"
            case .screen:      return "Экран"
            }
        }

        /// Короткая подпись под кнопкой на экране записи.
        var shortTitle: String {
            switch self {
            case .systemAudio: return "Звук"
            case .microphone:  return "Микрофон"
            case .screen:      return "Экран"
            }
        }

        var systemImage: String {
            switch self {
            case .systemAudio: return "speaker.wave.2.fill"
            case .microphone:  return "mic.fill"
            case .screen:      return "display"
            }
        }

        /// Все источники доступны на любой поддерживаемой macOS: микрофон идёт через
        /// AVAudioEngine, а не ScreenCaptureKit (там он был только с macOS 15).
        var isAvailable: Bool { true }

        /// Источники, которые можно выбрать на этом Mac.
        static var available: [Source] { allCases.filter(\.isAvailable) }
    }

    func contains(_ source: Source) -> Bool {
        switch source {
        case .systemAudio: return systemAudio
        case .microphone:  return microphone
        case .screen:      return screen
        }
    }

    /// Пресет с переключённым источником. nil — если после этого не останется
    /// ни одного звукового источника (такое переключение UI не даёт сделать).
    func toggling(_ source: Source) -> RecordingPreset? {
        var copy = self
        switch source {
        case .systemAudio: copy.systemAudio.toggle()
        case .microphone:  copy.microphone.toggle()
        case .screen:      copy.screen.toggle()
        }
        return copy.resolvedForThisMac.hasAnyAudio ? copy : nil
    }

    /// Можно ли сейчас переключить источник (последний звуковой выключить нельзя).
    func canToggle(_ source: Source) -> Bool {
        toggling(source) != nil
    }

    // MARK: - Доступность

    /// Сохранённый пресет, приведённый к этому Mac: на macOS 14 без системного
    /// звука записать нечего, поэтому включаем его.
    var resolvedForThisMac: RecordingPreset {
        guard !Source.microphone.isAvailable, !systemAudio else { return self }
        var copy = self
        copy.systemAudio = true
        return copy
    }

    // MARK: - UI

    private var enabledSources: [Source] {
        Source.available.filter(contains)
    }

    /// Полное название — «Системный звук + Микрофон + Экран».
    var title: String {
        enabledSources.map(\.title).joined(separator: " + ")
    }

    /// Короткое название для chip-ов.
    var shortTitle: String {
        let audio: String
        switch (systemAudio, microphone && Source.microphone.isAvailable) {
        case (true, true):  audio = "Звук + микрофон"
        case (false, true): audio = "Микрофон"
        default:            audio = "Системный звук"
        }
        return screen ? "Экран · \(audio.lowercased())" : audio
    }

    /// SF Symbol.
    var systemImage: String {
        if screen { return Source.screen.systemImage }
        if microphone && !systemAudio { return Source.microphone.systemImage }
        return Source.systemAudio.systemImage
    }
}
