// Test-only isolation: production stores operate exclusively in a temporary folder.
import Foundation

enum AppSettings {
    static var root = FileManager.default.temporaryDirectory.appendingPathComponent("UshiNextTests-" + UUID().uuidString)
    static func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func metadataDirectory() throws -> URL { try directory("") }
    static func defaultRecordingsDirectory() -> URL { root.appendingPathComponent("Recordings") }
    static func recordingsDirectory() throws -> URL { try directory("Recordings") }
    static func orphanRecordingsDirectory() throws -> URL { try recordingsDirectory() }
    static func transcriptsDirectory() throws -> URL { try directory("transcripts") }
    static func voiceTracksDirectory() throws -> URL { try directory("voices") }
    static func projectsParentDirectory() -> URL { root.appendingPathComponent("UshiProjects") }
    static func projectDirectory(projectId: UUID) throws -> URL { root.appendingPathComponent("Projects/" + projectId.uuidString) }
    static func projectRecordingsDirectory(projectId: UUID) throws -> URL { try directory("Projects/" + projectId.uuidString + "/recordings") }
    static func autoDeleteAudio() -> Bool { false }
    static func autoDeleteVideo() -> Bool { false }
    static func audioRetentionDays() -> Int { 7 }
    static func videoRetentionDays() -> Int { 7 }
    struct VideoQuality {
        let maxHeight: Int? = nil
        let bitrateBitsPerSecond = 4_000_000
        let fps = 30
    }
    static func videoQuality() -> VideoQuality { VideoQuality() }
    enum Language: String { case auto }
    static func transcriptionLanguage() -> Language { .auto }
}

@MainActor final class ModelManager {
    static let shared = ModelManager()
    var isReady = false
}
