//
//  ProjectLocationTests.swift
//
//  Окно «Новый проект»: папка внутри Ushi, новая папка в выбранном месте,
//  готовая папка (с переименованием под название проекта).
//

import XCTest
import GRDB
@testable import UshiNextCore

@MainActor
final class ProjectLocationTests: XCTestCase {
    private var place: URL!

    private func makeModel() throws -> ProjectsModel {
        AppSettings.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        place = FileManager.default.temporaryDirectory.appendingPathComponent("place-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        return ProjectsModel(store: ProjectStore(dbQueue: try AppDatabase.makeInMemory()))
    }

    override func tearDownWithError() throws {
        if let place { try? FileManager.default.removeItem(at: place) }
        try super.tearDownWithError()
    }

    func testDefaultLocationIsFolderInDocumentsUshi() throws {
        let projects = try makeModel()
        let project = try projects.create(name: "Лекции", preset: .systemAndMic, location: .insideUshi)
        let folder = AppSettings.projectsParentDirectory().appendingPathComponent("Лекции")
        XCTAssertEqual(project.name, "Лекции")
        XCTAssertEqual(try ProjectFolders.rootFolder(for: project).standardizedFileURL, folder.standardizedFileURL)
        // Записи — прямо в папке проекта, без подпапки recordings.
        XCTAssertEqual(try ProjectFolders.recordingsDirectory(for: project).standardizedFileURL, folder.standardizedFileURL)
    }

    func testNewFolderIsCreatedWithProjectName() throws {
        let projects = try makeModel()
        let project = try projects.create(name: "Психолог", preset: .micOnly, location: .newFolder(in: place))
        let folder = place.appendingPathComponent("Психолог")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(project.name, "Психолог")
        XCTAssertEqual(try ProjectFolders.rootFolder(for: project).standardizedFileURL, folder.standardizedFileURL)
    }

    func testNewFolderRefusesToReuseExistingFolder() throws {
        let projects = try makeModel()
        try FileManager.default.createDirectory(at: place.appendingPathComponent("Дикси"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try projects.create(name: "Дикси", preset: .micOnly, location: .newFolder(in: place)))
        XCTAssertTrue(projects.projects.isEmpty)
    }

    func testExistingFolderKeepsNameWhenUnchanged() throws {
        let projects = try makeModel()
        let folder = place.appendingPathComponent("Учёба")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try projects.create(name: "Учёба", preset: .micOnly, location: .existing(folder))
        XCTAssertEqual(project.name, "Учёба")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testExistingFolderIsRenamedToProjectName() throws {
        let projects = try makeModel()
        let folder = place.appendingPathComponent("Учёба")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("старое".utf8).write(to: folder.appendingPathComponent("заметка.txt"))

        let project = try projects.create(name: "Лекции", preset: .micOnly, location: .existing(folder))

        let renamed = place.appendingPathComponent("Лекции")
        XCTAssertEqual(project.name, "Лекции")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("заметка.txt")), Data("старое".utf8),
                       "содержимое папки переезжает вместе с ней")
    }

    func testExistingFolderRenameRefusesNameTakenBySibling() throws {
        let projects = try makeModel()
        let folder = place.appendingPathComponent("Учёба")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: place.appendingPathComponent("Лекции"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try projects.create(name: "Лекции", preset: .micOnly, location: .existing(folder)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "чужую папку не трогаем")
    }
}
