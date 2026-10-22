//
//  ProjectFolders.swift
//  UshiNext
//
//  Где физически лежат файлы Проекта (Phase 3, §5 брифа).
//  managed  → Application Support/UshiNext/Projects/{id}/recordings/
//  external → прямо в выбранной папке, папку находим по bookmark —
//             он переживает переименование и перенос папки в Finder.
//  Приложение не sandboxed, поэтому bookmark обычный (не security-scoped).
//

import Foundation

enum ProjectFolderError: LocalizedError {
    case unavailable(projectName: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            return "Папка проекта «\(name)» недоступна: её удалили, переименовали или отключили диск. Правый клик по проекту → «Подключить заново…»."
        }
    }
}

enum ProjectFolders {
    /// Результат поиска внешней папки.
    struct Resolution {
        let folder: URL
        /// Не nil, если bookmark устарел или папка переехала — надо сохранить в БД.
        let updatedStorage: ProjectStorage?
    }

    /// Найти папку external-Проекта. nil — папки нет (degraded state, §7.6).
    /// Папка в Корзине тоже считается пропавшей: bookmark находит её и там,
    /// но писать записи в Корзину нельзя.
    static func resolveExternal(bookmark: Data, displayPath: String) -> Resolution? {
        guard let (url, fresh) = FileBookmark.resolve(bookmark) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isInTrash(url) else { return nil }

        let moved = url.standardizedFileURL.path != displayPath
        guard moved || fresh != nil else { return Resolution(folder: url, updatedStorage: nil) }
        return Resolution(
            folder: url,
            updatedStorage: .external(bookmark: fresh ?? bookmark, displayPath: url.standardizedFileURL.path)
        )
    }

    /// Корневая папка Проекта (для «Показать в Finder»).
    static func rootFolder(for project: Project) throws -> URL {
        switch project.storage {
        case .managed:
            return try AppSettings.projectDirectory(projectId: project.id)
        case .external(let bookmark, let displayPath):
            guard let res = resolveExternal(bookmark: bookmark, displayPath: displayPath) else {
                throw ProjectFolderError.unavailable(projectName: project.name)
            }
            return res.folder
        }
    }

    /// Куда пишутся записи Проекта. У external — прямо в папку Проекта,
    /// без подпапки: в Finder «Ushi → Дикси → файлы».
    /// `project == nil` — orphan-«Записи».
    static func recordingsDirectory(for project: Project?) throws -> URL {
        guard let project else { return try AppSettings.recordingsDirectory() }
        switch project.storage {
        case .managed:
            return try AppSettings.projectRecordingsDirectory(projectId: project.id)
        case .external:
            return try rootFolder(for: project)
        }
    }

    /// Storage для выбранной юзером папки (создание Проекта и «Подключить заново»).
    static func externalStorage(for folder: URL) throws -> ProjectStorage {
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return .external(bookmark: bookmark, displayPath: folder.standardizedFileURL.path)
    }

    /// Лежит ли путь в Корзине — домашней (~/.Trash) или на внешнем диске (/.Trashes).
    static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    /// Имя папки из названия Проекта: без «/» и «:», которые Finder не пропустит.
    static func folderName(from projectName: String) -> String {
        let invalid: Set<Character> = ["/", ":", "\0"]
        var s = String(projectName.map { invalid.contains($0) ? "-" : $0 })
        while s.hasPrefix(".") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Путь для показа в UI: «~/Documents/Психолог».
    static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
