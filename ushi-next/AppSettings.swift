//
//  AppSettings.swift
//  ushi
//

import Foundation

/// Язык транскрибации Whisper. `auto` — модель сама определит, лучший выбор для смешанного контента.
enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto = "auto"   // whisper-cli понимает "-l auto"
    case ru   = "ru"
    case en   = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .ru:   return "Русский"
        case .en:   return "Английский"
        }
    }
}

/// Пресет качества видео. Управляет максимальной высотой кадра, FPS и битрейтом.
/// Расход места на час 1440p-дисплея ≈ для оценки.
enum VideoQuality: String, CaseIterable, Identifiable {
    case high       // оригинал × 30 fps × 8 Mbps        — ~3.5 ГБ/ч
    case medium     // до 1080p × 30 fps × 4 Mbps        — ~1.8 ГБ/ч
    case low        // до 720p  × 15 fps × 2 Mbps        — ~0.9 ГБ/ч

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high:   return "Высокое"
        case .medium: return "Среднее"
        case .low:    return "Низкое"
        }
    }

    /// Краткое описание под пикером.
    var summary: String {
        switch self {
        case .high:   return "Оригинальное разрешение · 30 fps · ~3.5 ГБ/ч"
        case .medium: return "До 1080p · 30 fps · ~1.8 ГБ/ч"
        case .low:    return "До 720p · 15 fps · ~0.9 ГБ/ч"
        }
    }

    /// Если высота дисплея больше — кадр уменьшается до этой высоты с сохранением пропорций.
    /// nil = не масштабировать.
    var maxHeight: Int? {
        switch self {
        case .high:   return nil
        case .medium: return 1080
        case .low:    return 720
        }
    }

    var fps: Int {
        switch self {
        case .high, .medium: return 30
        case .low:           return 15
        }
    }

    var bitrateBitsPerSecond: Int {
        switch self {
        case .high:   return 8_000_000
        case .medium: return 4_000_000
        case .low:    return 2_000_000
        }
    }
}

enum AppSettings {
    private static let recordingsFolderPathKey = "settings.recordingsFolderPath"
    private static let audioRetentionDaysKey = "settings.audioRetentionDays"
    private static let videoRetentionDaysKey = "settings.videoRetentionDays"
    private static let autoDeleteAudioKey = "settings.autoDeleteAudio"
    private static let autoDeleteVideoKey = "settings.autoDeleteVideo"
    private static let videoQualityKey = "settings.videoQuality"
    private static let transcriptionLanguageKey = "settings.transcriptionLanguage"

    static let maxRetentionDays = 365
    static let defaultAudioRetentionDays = 7
    static let defaultVideoRetentionDays = 7
    static let defaultAutoDeleteAudio = false
    static let defaultAutoDeleteVideo = false
    static let defaultVideoQuality: VideoQuality = .medium
    static let defaultTranscriptionLanguage: TranscriptionLanguage = .auto

    static func transcriptionLanguage() -> TranscriptionLanguage {
        guard let raw = UserDefaults.standard.string(forKey: transcriptionLanguageKey),
              let v = TranscriptionLanguage(rawValue: raw) else {
            return defaultTranscriptionLanguage
        }
        return v
    }

    static func setTranscriptionLanguage(_ lang: TranscriptionLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: transcriptionLanguageKey)
    }

    static func videoQuality() -> VideoQuality {
        guard let raw = UserDefaults.standard.string(forKey: videoQualityKey),
              let v = VideoQuality(rawValue: raw) else {
            return defaultVideoQuality
        }
        return v
    }

    static func setVideoQuality(_ quality: VideoQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: videoQualityKey)
    }

    static func autoDeleteAudio() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: autoDeleteAudioKey) == nil {
            return defaultAutoDeleteAudio
        }
        return defaults.bool(forKey: autoDeleteAudioKey)
    }

    static func setAutoDeleteAudio(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoDeleteAudioKey)
    }

    static func autoDeleteVideo() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: autoDeleteVideoKey) == nil {
            return defaultAutoDeleteVideo
        }
        return defaults.bool(forKey: autoDeleteVideoKey)
    }

    static func setAutoDeleteVideo(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoDeleteVideoKey)
    }

    static func audioRetentionDays() -> Int {
        let defaults = UserDefaults.standard
        let value = defaults.integer(forKey: audioRetentionDaysKey)
        return defaults.object(forKey: audioRetentionDaysKey) == nil
            ? defaultAudioRetentionDays
            : clampedRetentionDays(value)
    }

    static func setAudioRetentionDays(_ days: Int) {
        UserDefaults.standard.set(clampedRetentionDays(days), forKey: audioRetentionDaysKey)
    }

    static func videoRetentionDays() -> Int {
        let defaults = UserDefaults.standard
        let value = defaults.integer(forKey: videoRetentionDaysKey)
        return defaults.object(forKey: videoRetentionDaysKey) == nil
            ? defaultVideoRetentionDays
            : clampedRetentionDays(value)
    }

    static func setVideoRetentionDays(_ days: Int) {
        UserDefaults.standard.set(clampedRetentionDays(days), forKey: videoRetentionDaysKey)
    }

    static func recordingsDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = resolvedRecordingsDirectory() ?? defaultRecordingsDirectory()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func setRecordingsDirectory(_ url: URL) throws {
        let folderURL = url.standardizedFileURL
        UserDefaults.standard.set(folderURL.path, forKey: recordingsFolderPathKey)
    }

    static func resetRecordingsDirectory() {
        UserDefaults.standard.removeObject(forKey: recordingsFolderPathKey)
    }

    static func metadataDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(AppContainer.name, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Папка для транскриптов (.txt). Отделена от пользовательской папки с медиа,
    /// чтобы Finder в «куда сохранять» не был засорён служебными файлами.
    static func transcriptsDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try metadataDirectory().appendingPathComponent("transcripts", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Служебные стерео-дорожки (L = микрофон, R = система) для разметки «Я / Собеседник».
    static func voiceTracksDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try metadataDirectory().appendingPathComponent("voices", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Куда складываем orphan-Записи (без Проекта). Phase 1: переехало из
    /// `~/Documents/UshiNext/` в `Application Support/UshiNext/Recordings/`,
    /// см. phase-1.md §7. Managed-всё-в-AppSupport, user-visible только через
    /// явный external-Проект (Phase 3).
    static func defaultRecordingsDirectory() -> URL {
        // Если юзер явно указал кастомную папку через настройки — уважаем.
        if let override = resolvedRecordingsDirectory() { return override }
        return (try? orphanRecordingsDirectory())
            ?? legacyDefaultRecordingsDirectory()
    }

    /// `~/Library/Application Support/UshiNext/Recordings/` — физическое место для
    /// записей без Проекта. Создаётся по требованию.
    static func orphanRecordingsDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try metadataDirectory().appendingPathComponent("Recordings", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// `~/Library/Application Support/UshiNext/Projects/{id}/recordings/` — для managed-Проектов.
    /// External-Проекты используют свой security-scoped путь (Phase 3).
    static func projectRecordingsDirectory(projectId: UUID) throws -> URL {
        let fm = FileManager.default
        let dir = try projectDirectory(projectId: projectId)
            .appendingPathComponent("recordings", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// `~/Documents/Ushi/` — здесь создаются папки новых Проектов («Альфа», «Дикси»…),
    /// чтобы записи было видно в Finder, а не прятать их внутри приложения.
    static func projectsParentDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ushi", isDirectory: true)
    }

    /// `~/Library/Application Support/UshiNext/Projects/{id}/` — корень managed-Проекта.
    /// Не создаётся: нужен для «Показать в Finder» и удаления папки вместе с Проектом.
    static func projectDirectory(projectId: UUID) throws -> URL {
        try metadataDirectory()
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
    }

    private static func resolvedRecordingsDirectory() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: recordingsFolderPathKey),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Унаследованный из Phase 0 путь `~/Documents/UshiNext/`. Больше не используется
    /// как default — оставлен только как страховочный фолбэк, если AppSupport
    /// почему-то недоступен. После миграции в Phase 6 будет удалён.
    private static func legacyDefaultRecordingsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return (docs ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent(AppContainer.name, isDirectory: true)
    }

    private static func clampedRetentionDays(_ days: Int) -> Int {
        min(max(1, days), maxRetentionDays)
    }
}
