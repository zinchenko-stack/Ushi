//
//  RecordingsStore.swift
//  ushi
//

import Foundation
import GRDB
import Observation
import AVFoundation

@MainActor
@Observable
final class RecordingsStore {
    @ObservationIgnored private let dbQueue: DatabaseQueue
    @ObservationIgnored private let fileCoordinator = RecordingFileCoordinator()
    var recordings: [Recording] = [] {
        didSet { scheduleSave() }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isProcessingPending = false

    init(dbQueue: DatabaseQueue? = nil) {
        self.dbQueue = dbQueue ?? AppDatabase.shared
        load()
        recoverStuckRecordings()
        normalizeLegacyFallbackTitles()
        cleanupOrphanedSummaries()
        migrateTranscriptsToServiceFolder()
        sweepStrayTranscriptsFromMediaFolders()
        purgeOldSourceMedia()
    }

    // MARK: - Mutations

    func delete(_ recording: Recording) {
        fileCoordinator.deleteFiles(for: recording)
        recordings.removeAll { $0.id == recording.id }
    }

    func rename(_ recording: Recording, to newTitle: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recordings[idx].title = trimmed
        recordings[idx].titleSource = .manual
        renameFilesOnDisk(at: idx)
    }

    // MARK: - Проекты (Phase 2)
    //
    // Все мутации записей идут через этот стор, а не через ProjectStore:
    // `recordings` — кэш, который целиком upsert-ится в БД. Если поменять
    // project_id в обход кэша, следующий save() откатит изменение обратно.

    /// Записи Проекта (или orphan-Записи при `projectID == nil`), новые сверху.
    func recordings(inProject projectID: UUID?) -> [Recording] {
        recordings.filter { $0.projectId == projectID }
    }

    /// Можно ли сейчас переносить запись: пока whisper читает файл, не трогаем его.
    func canMove(_ recording: Recording) -> Bool {
        recording.status != .transcribing
    }

    /// Идущий сейчас перенос между дисками (для окна с прогрессом). nil — переноса нет
    /// или он мгновенный (тот же диск).
    private(set) var activeMove: MoveProgress?
    @ObservationIgnored private var moveTask: Task<URL, Error>?

    /// Отменить перенос: частичная копия удаляется, оригинал остаётся на месте.
    func cancelMove() {
        moveTask?.cancel()
    }

    /// Move to (§7.4 брифа): файл физически переезжает в папку целевого Проекта,
    /// затем меняется projectId. На одном диске — мгновенно, между дисками —
    /// копирование с прогрессом (`activeMove`). Если файл не удалось перенести
    /// или перенос отменили — запись остаётся в исходном Проекте, ошибка
    /// пробрасывается в UI.
    func move(_ recording: Recording, to project: Project?) async throws {
        guard let current = recordings.first(where: { $0.id == recording.id }) else { return }
        guard current.projectId != project?.id else { return }
        guard canMove(current) else { throw RecordingsStoreError.busyTranscribing }
        guard moveTask == nil else { throw RecordingsStoreError.anotherMoveInProgress }

        let targetDir = try ProjectFolders.recordingsDirectory(for: project)
        var moved = current
        moved.projectId = project?.id
        moved.storageFolderPath = targetDir.path

        if let source = mediaURL(for: current) {
            if FileMover.needsCopy(from: source, toDirectory: targetDir) {
                activeMove = MoveProgress(
                    recordingID: current.id,
                    recordingTitle: current.title,
                    destinationName: project?.name ?? "Записи",
                    fraction: 0
                )
            }
            let task = Task { [weak self] in
                try await FileMover().moveFile(at: source, toDirectory: targetDir) { fraction in
                    Task { @MainActor in self?.activeMove?.fraction = fraction }
                }
            }
            moveTask = task
            defer {
                moveTask = nil
                activeMove = nil
            }
            let newURL = try await task.value
            moved.audioFileName = newURL.lastPathComponent
            moved.audioBookmark = FileBookmark.create(from: newURL) ?? moved.audioBookmark
        }

        // Пока шло копирование, массив мог поменяться — ищем запись заново.
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        var rec = recordings[idx]
        rec.projectId = moved.projectId
        rec.storageFolderPath = moved.storageFolderPath
        rec.audioFileName = moved.audioFileName
        rec.audioBookmark = moved.audioBookmark
        recordings[idx] = rec

        if let project {
            // Проект «всплывает» в sidebar по recency (§6.2).
            let projectID = project.id.uuidString
            try? await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE project SET updated_at = ? WHERE id = ?",
                    arguments: [Date(), projectID]
                )
            }
        }
    }

    /// Готовит удаление Проекта (§6.8): либо удаляет его записи вместе с файлами,
    /// либо переносит их в «Записи» (orphan). Файлы managed-Проекта переезжают
    /// в «Записи», потому что его папка будет удалена; файлы external-Проекта
    /// остаются в папке юзера — её мы не трогаем. Сразу пишет в БД, чтобы
    /// ON DELETE у project не разошёлся с кэшем.
    func detachRecordings(fromProject projectID: UUID, deleteFiles: Bool, moveFiles: Bool) async throws {
        defer { saveNow() }
        for rec in recordings(inProject: projectID) {
            if deleteFiles {
                delete(rec)
            } else if !moveFiles {
                update(id: rec.id) { $0.projectId = nil }
            } else {
                // Не удаляем проект и его папку, если хотя бы один файл не переехал.
                try await move(rec, to: nil)
            }
        }
    }

    /// После «Подключить заново» (Phase 3): записи Проекта, чей файл потерялся,
    /// ищем по имени в новой папке и перепривязываем. Остальные не трогаем.
    func relink(projectID: UUID, toDirectory dir: URL) {
        for rec in recordings(inProject: projectID) where !rec.audioRemoved && !rec.audioFileName.isEmpty {
            guard rec.resolveAudioURL() == nil else { continue }
            let candidate = dir.appendingPathComponent(rec.audioFileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                relocateAudio(for: rec.id, to: candidate)
            }
        }
    }

    /// Суммарный размер медиа Проекта в байтах — для диалога удаления.
    func mediaSize(ofProject projectID: UUID) -> Int64 {
        recordings(inProject: projectID).reduce(0) { sum, rec in
            guard !rec.audioRemoved else { return sum }
            if rec.fileSize > 0 { return sum + rec.fileSize }
            guard let (url, _) = rec.resolveAudioURL(),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return sum }
            return sum + Int64(size)
        }
    }

    /// Файл записи на диске (для «Показать в Finder»). nil — файла нет.
    func mediaURL(for recording: Recording) -> URL? {
        guard !recording.audioRemoved else { return nil }
        return recording.resolveAudioURL()?.url
    }

    /// Сбросить отложенное сохранение и записать кэш в БД прямо сейчас.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Подгоняет имена файлов (.m4a / .mov / .txt) под текущий title.
    /// Безопасно: пока транскрибация в процессе — не трогаем (whisper-cli ещё пишет в старый путь).
    private func renameFilesOnDisk(at idx: Int) {
        var rec = recordings[idx]

        // Транскрибация в процессе — пропускаем, иначе сломаем whisper.
        if rec.status == .transcribing || rec.status == .pending { return }

        let mediaDir = mediaDirectory(for: rec)
        let result = fileCoordinator.renameFilesOnDisk(
            recording: rec,
            newTitle: rec.title,
            mediaDir: mediaDir
        )

        rec.audioFileName = result.audioFileName
        rec.audioBookmark = result.audioBookmark
        rec.transcriptFileName = result.transcriptFileName
        rec.transcriptBookmark = result.transcriptBookmark

        recordings[idx] = rec
    }

    // MARK: - Перенос из старого Ushi (Phase 6)

    /// Идёт перенос: сколько записей готово из скольких. nil — не идёт.
    private(set) var legacyImportProgress: (done: Int, total: Int)?

    var legacyImportError: String?

    /// Сколько записей старого Ushi ещё не перенесено.
    func pendingLegacyCount() -> Int {
        LegacyUshiImporter.pendingRecordings(existingIDs: Set(recordings.map(\.id))).count
    }

    /// Перенести (скопировать) записи старого Ushi в «Записи». Возвращает число перенесённых.
    @discardableResult
    func importFromLegacyUshi() async -> Int {
        guard legacyImportProgress == nil, let legacyDir = LegacyUshiImporter.legacyDirectory else { return 0 }
        let pending = LegacyUshiImporter.pendingRecordings(existingIDs: Set(recordings.map(\.id)))
        guard !pending.isEmpty else { return 0 }

        legacyImportError = nil
        legacyImportProgress = (0, pending.count)
        defer { legacyImportProgress = nil }
        var count = 0
        for old in pending {
            let rec: Recording
            do {
                rec = try await LegacyUshiImporter.prepare(old, legacyDir: legacyDir)
            } catch {
                legacyImportError = "Не удалось перенести часть записей. Старые файлы сохранены. Повторите перенос в Настройках.\n" + error.localizedDescription
                continue
            }
            if !recordings.contains(where: { $0.id == rec.id }) {
                recordings.append(rec)
                count += 1
            }
            legacyImportProgress = (count, pending.count)
        }
        recordings.sort { $0.createdAt > $1.createdAt }
        saveNow()
        // Записи без расшифровки, но со звуком — в очередь.
        await processPendingTranscriptions()
        return count
    }

    /// Форматы, которые умеет расшифровка (afconvert → wav). Только аудио.
    static let importableAudioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aif", "aiff", "caf"]

    /// Загрузка готового аудиофайла на расшифровку. Файл **копируется** в папку
    /// Проекта (или «Записи»), оригинал не трогаем. Дальше — как у обычной
    /// записи: расшифровка и авто-название. Пресет Проекта не меняется.
    @discardableResult
    func importAudio(from source: URL, into project: Project?) async throws -> Recording {
        guard Self.importableAudioExtensions.contains(source.pathExtension.lowercased()) else {
            throw RecordingsStoreError.unsupportedFile(source.lastPathComponent)
        }
        let asset = AVURLAsset(url: source)
        let duration: Double
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration).seconds
            guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
                throw RecordingsStoreError.invalidAudio
            }
        } catch {
            throw RecordingsStoreError.invalidAudio
        }
        let dir = try ProjectFolders.recordingsDirectory(for: project)
        let destination = FileMover.uniqueDestination(for: source.lastPathComponent, in: dir)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value

        let fileSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let canTranscribe = ModelManager.shared.isReady
        let preset = RecordingPreset.systemAndMic

        let rec = Recording(
            title: source.deletingPathExtension().lastPathComponent,
            duration: duration.isFinite ? duration : 0,
            audioFileName: destination.lastPathComponent,
            storageFolderPath: dir.path,
            status: canTranscribe ? .transcribing : .pending,
            audioBookmark: FileBookmark.create(from: destination),
            projectId: project?.id,
            presetSnapshot: preset,
            hasMicrophone: preset.hasMicrophone,
            hasSystemAudio: preset.hasSystemAudio,
            hasScreen: false,
            titleSource: .fallback,   // имя файла заменится авто-названием после расшифровки
            fileSize: fileSize
        )
        recordings.insert(rec, at: 0)

        if canTranscribe {
            let recordingID = rec.id
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.runTranscription(id: recordingID, audioURL: destination)
            }
        }
        return rec
    }

    @discardableResult
    func addRecording(
        audioURL: URL,
        duration: TimeInterval,
        project: Project? = nil,
        preset: RecordingPreset? = nil,
        voiceTrackURL: URL? = nil,
        liveTranscript: (() async -> String?)? = nil
    ) -> Recording {
        let canTranscribe = ModelManager.shared.isReady
        let resolvedPreset = preset
            ?? project?.lastUsedPreset
            ?? AppState.lastUsedPreset()
        let fileSize: Int64 = {
            let v = try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size]
            return (v as? Int64) ?? Int64((v as? Int) ?? 0)
        }()

        let rec = Recording(
            title: Self.fallbackTitle(project: project),
            duration: duration,
            audioFileName: audioURL.lastPathComponent,
            storageFolderPath: audioURL.deletingLastPathComponent().path,
            status: canTranscribe ? .transcribing : .pending,
            audioBookmark: FileBookmark.create(from: audioURL),
            projectId: project?.id,
            presetSnapshot: resolvedPreset,
            hasMicrophone: resolvedPreset.hasMicrophone,
            hasSystemAudio: resolvedPreset.hasSystemAudio,
            hasScreen: resolvedPreset.hasScreen,
            titleSource: .fallback,
            fileSize: fileSize,
            voiceTrackFileName: voiceTrackURL?.lastPathComponent
        )
        recordings.insert(rec, at: 0)

        // Sticky-пресет: обновляем тот контекст, в который пошла запись (§7.2 брифа).
        if let project {
            try? dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE project SET last_used_preset = ?, updated_at = ? WHERE id = ?",
                    arguments: [resolvedPreset.rawValue, Date(), project.id.uuidString]
                )
            }
        } else {
            AppState.setLastUsedPreset(resolvedPreset)
        }

        if canTranscribe {
            let recordingID = rec.id
            Task.detached(priority: .userInitiated) { [weak self] in
                // Живая расшифровка уже распознала запись кусками — берём её.
                // Не вышло (ошибка куска, пусто) — распознаём целиком, как раньше.
                if let live = await liveTranscript?(), !live.isEmpty,
                   await self?.completeTranscription(id: recordingID, text: live) == true {
                    return
                }
                await self?.runTranscription(id: recordingID, audioURL: audioURL)
            }
        }
        return rec
    }

    /// Сохранить готовый текст расшифровки (из живой расшифровки) так же,
    /// как результат обычной: файл в папке расшифровок, статус, авто-название.
    private func completeTranscription(id: UUID, text: String) async -> Bool {
        do {
            let txtURL = try AppSettings.transcriptsDirectory()
                .appendingPathComponent(UUID().uuidString + ".txt")
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
            let transcriptBookmark = FileBookmark.create(from: txtURL)
            update(id: id) {
                $0.transcriptFileName = txtURL.lastPathComponent
                $0.transcriptBookmark = transcriptBookmark
                $0.status = .done
            }
            await applyAutoTitle(id: id, transcriptURL: txtURL)
            return true
        } catch {
            print("⚠️ live transcript save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Может ли запись быть перетранскрибирована (аудио ещё на диске).
    /// Проверка через bookmark-резолвер, т.к. файл мог быть переименован/перемещён.
    func canRetryTranscription(_ recording: Recording) -> Bool {
        guard !recording.audioRemoved,
              !recording.audioFileName.isEmpty else { return false }
        return recording.resolveAudioURL() != nil
    }

    /// Перезапуск транскрипции (для failed или явного "перетранскрибировать").
    func retryTranscription(_ recording: Recording) {
        guard let (audioURL, fresh) = recording.resolveAudioURL() else { return }
        if let fresh { setAudioBookmark(for: recording.id, fresh) }

        if let (oldTxt, _) = recording.resolveTranscriptURL() {
            try? FileManager.default.removeItem(at: oldTxt)
        }
        update(id: recording.id) {
            $0.transcriptFileName = nil
            $0.transcriptBookmark = nil
            $0.status = ModelManager.shared.isReady ? .transcribing : .pending
        }

        guard ModelManager.shared.isReady else { return }

        let recordingID = recording.id
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runTranscription(id: recordingID, audioURL: audioURL)
        }
    }

    // MARK: - Bookmark helpers (public)

    /// Обновить аудио-bookmark для записи (например, после ручного выбора через NSOpenPanel).
    func setAudioBookmark(for id: UUID, _ bookmark: Data) {
        update(id: id) { $0.audioBookmark = bookmark }
    }

    /// Обновить transcript-bookmark для записи.
    func setTranscriptBookmark(for id: UUID, _ bookmark: Data) {
        update(id: id) { $0.transcriptBookmark = bookmark }
    }

    /// Полное обновление расположения аудио-файла: bookmark + filename + folder.
    /// Зовём из UI после того как пользователь указал файл через NSOpenPanel.
    func relocateAudio(for id: UUID, to url: URL) {
        let bookmark = FileBookmark.create(from: url)
        update(id: id) {
            $0.audioFileName = url.lastPathComponent
            $0.storageFolderPath = url.deletingLastPathComponent().path
            $0.audioBookmark = bookmark
        }
    }

    // MARK: - Recovery

    /// Старые авто-имена «Запись от 29.09.2026, 17:47» (из Ushi и ранних сборок)
    /// → единый формат «Запись · 29 сент., 17:47». Только нетронутые юзером (.fallback).
    private func normalizeLegacyFallbackTitles() {
        let pattern = #"^Запись от \d{2}\.\d{2}\.\d{4}, \d{2}:\d{2}$"#
        for idx in recordings.indices where recordings[idx].titleSource == .fallback {
            guard recordings[idx].title.range(of: pattern, options: .regularExpression) != nil else { continue }
            recordings[idx].title = Self.fallbackTitle(project: nil, date: recordings[idx].createdAt)
        }
    }

    /// Зависшие в transcribing после краша — переводим в failed.
    /// pending остаются в очереди: они могли ждать загрузки модели.
    private func recoverStuckRecordings() {
        for idx in recordings.indices {
            if recordings[idx].status == .transcribing {
                recordings[idx].status = .failed
            }
        }
    }

    /// Удаляет исходный медиафайл у старых записей. Транскрипт оставляем.
    /// Помечает `audioRemoved = true`, чтобы UI скрыл плеер / кнопку открытия.
    private func purgeOldSourceMedia() {
        let fm = FileManager.default

        for idx in recordings.indices {
            var rec = recordings[idx]
            guard !rec.audioRemoved,
                  !rec.audioFileName.isEmpty else { continue }

            let isVideo = rec.audioFileName.lowercased().hasSuffix(".mov")
            let shouldDelete = isVideo ? AppSettings.autoDeleteVideo() : AppSettings.autoDeleteAudio()
            guard shouldDelete else { continue }

            let retentionDays = isVideo ? AppSettings.videoRetentionDays() : AppSettings.audioRetentionDays()
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            guard rec.createdAt < cutoff else { continue }

            let dir = mediaDirectory(for: rec)
            let url = dir.appendingPathComponent(rec.audioFileName)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
            // Голосовая дорожка — та же речь, живёт не дольше основного файла.
            if let voiceURL = rec.voiceTrackURL() {
                try? fm.removeItem(at: voiceURL)
            }
            rec.voiceTrackFileName = nil
            rec.audioRemoved = true
            recordings[idx] = rec
        }
    }

    /// Одноразовая миграция: переносит .txt из пользовательской медиа-папки в служебную
    /// `transcripts/`, чтобы пользовательская папка содержала только медиа.
    /// После переноса метаданные не меняются (имя файла то же), меняется только локация.
    private func migrateTranscriptsToServiceFolder() {
        let fm = FileManager.default
        guard let txtDir = try? AppSettings.transcriptsDirectory() else { return }

        for rec in recordings {
            guard let name = rec.transcriptFileName, !name.isEmpty else { continue }
            let mediaDir = mediaDirectory(for: rec)
            let oldURL = mediaDir.appendingPathComponent(name)
            let newURL = txtDir.appendingPathComponent(name)

            // Уже в служебной папке — пропускаем. Если и там и там лежит — старый удаляем.
            let newExists = fm.fileExists(atPath: newURL.path)
            let oldExists = fm.fileExists(atPath: oldURL.path)

            if newExists, oldExists {
                try? fm.removeItem(at: oldURL)
                continue
            }
            if newExists { continue }
            guard oldExists else { continue }

            do {
                try fm.moveItem(at: oldURL, to: newURL)
            } catch {
                print("⚠️ migrate transcript failed: \(error.localizedDescription)")
            }
        }
    }

    /// Чистит «осиротевшие» .txt в медиа-папках: записи в JSON для них нет
    /// (или это дубликат уже мигрировавшего транскрипта). Безопасно: трогаем
    /// только файлы, чьё имя точно соответствует нашему шаблону `YYYY-MM-DD_HHmmss.txt`
    /// (так формирует AudioRecorder.makeOutputURL) — пользовательские .txt в этой
    /// папке не пострадают. Отправляем в Корзину, чтобы можно было вернуть.
    private func sweepStrayTranscriptsFromMediaFolders() {
        let fm = FileManager.default

        // Все папки, в которых могли осесть наши .txt. Папки external-Проектов
        // (Phase 3) — личные папки юзера, туда не лезем: чистим только внутри
        // служебной папки приложения и общей папки записей.
        let appRoot = (try? AppSettings.metadataDirectory().standardizedFileURL.path) ?? ""
        var dirs: Set<String> = []
        for rec in recordings {
            let dir = mediaDirectory(for: rec).standardizedFileURL.path
            if !appRoot.isEmpty, dir.hasPrefix(appRoot) { dirs.insert(dir) }
        }
        dirs.insert(AppSettings.defaultRecordingsDirectory().path)
        if let user = try? AppSettings.recordingsDirectory() { dirs.insert(user.path) }

        let pattern = #"^\d{4}-\d{2}-\d{2}_\d{6}\.txt$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        for dirPath in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for name in items {
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                guard regex.firstMatch(in: name, range: range) != nil else { continue }
                let url = URL(fileURLWithPath: dirPath).appendingPathComponent(name)
                var trashed: NSURL?
                try? fm.trashItem(at: url, resultingItemURL: &trashed)
            }
        }
    }

    /// На прошлых версиях оставались .summary.md и .vtt в каталоге — чистим.
    private func cleanupOrphanedSummaries() {
        guard let dir = try? AudioRecorder.documentsDirectory() else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items where name.hasSuffix(".summary.md") || name.hasSuffix(".vtt") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Pipeline

    /// Последовательно обрабатывает записи, накопившиеся пока модель скачивалась.
    func processPendingTranscriptions() async {
        guard ModelManager.shared.isReady, !isProcessingPending else { return }
        isProcessingPending = true
        defer { isProcessingPending = false }

        let pendingIDs = recordings
            .filter { $0.status == .pending }
            .map(\.id)

        for id in pendingIDs {
            guard ModelManager.shared.isReady,
                  let recording = recordings.first(where: { $0.id == id }),
                  recording.status == .pending else { continue }

            guard !recording.audioRemoved, let (audioURL, _) = recording.resolveAudioURL() else {
                update(id: id) { $0.status = .failed }
                continue
            }

            update(id: id) { $0.status = .transcribing }
            await runTranscription(id: id, audioURL: audioURL)
        }
    }

    private func runTranscription(id: UUID, audioURL: URL) async {
        // Есть стерео-дорожка — расшифровка разметит «Я / Собеседник».
        let voiceTrackURL = recordings.first(where: { $0.id == id })?.voiceTrackURL()
        do {
            let outputDir = try AppSettings.transcriptsDirectory()
            let txtURL = try await TranscriptionService.transcribe(
                audioURL: audioURL,
                voiceTrackURL: voiceTrackURL,
                outputDirectory: outputDir
            )
            let transcriptBookmark = FileBookmark.create(from: txtURL)
            self.update(id: id) {
                $0.transcriptFileName = txtURL.lastPathComponent
                $0.transcriptBookmark = transcriptBookmark
                $0.status = .done
            }
            await applyAutoTitle(id: id, transcriptURL: txtURL)
        } catch {
            print("❌ transcription failed: \(error.localizedDescription)")
            self.update(id: id) { $0.status = .failed }
        }
    }

    /// Авто-название из транскрипта (Phase 4, §7.3; Phase 4b: Summarizer). Не трогает названия,
    /// которые юзер задал руками. Если включены «Умные названия» и модель готова — используем
    /// локальную LLM (Gemma 3), иначе/при ошибке — fallback на AutoTitle.make (первая фраза).
    /// Файлы переименовываются под новое название, как при ручном переименовании.
    /// `force` — юзер сам попросил «Придумать название»: тогда и ручное название
    /// можно заменить. Возвращает, получилось ли.
    @discardableResult
    private func applyAutoTitle(id: UUID, transcriptURL: URL, force: Bool = false) async -> Bool {
        guard let idx = recordings.firstIndex(where: { $0.id == id }),
              force || recordings[idx].titleSource != .manual,
              let labeled = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return false }
        // Метки «Я:» / «Собеседник:» в название не тащим.
        let text = TranscriptionService.removingSpeakerLabels(labeled)

        var finalTitle: String? = nil
        if SmartTitleModelManager.shared.isReady {
            finalTitle = await Summarizer.shared.title(for: text)
        }
        if finalTitle == nil {
            finalTitle = AutoTitle.make(fromTranscript: text)
        }

        guard let title = finalTitle,
              let currentIdx = recordings.firstIndex(where: { $0.id == id }),
              force || recordings[currentIdx].titleSource != .manual else { return false }

        recordings[currentIdx].title = title
        recordings[currentIdx].titleSource = .auto
        renameFilesOnDisk(at: currentIdx)
        return true
    }

    /// «Придумать название»: заново по готовой расшифровке, без повторной расшифровки.
    func regenerateTitle(_ recording: Recording) async -> Bool {
        guard recording.status == .done,
              let (txtURL, _) = recording.resolveTranscriptURL() else { return false }
        return await applyAutoTitle(id: recording.id, transcriptURL: txtURL, force: true)
    }

    /// Fallback-имя до авто-названия (§7.3): «Психолог · 29 сент., 19:40».
    nonisolated static func fallbackTitle(project: Project?, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return "\(project?.name ?? "Запись") · \(f.string(from: date))"
    }

    private func update(id: UUID, _ mutate: (inout Recording) -> Void) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        mutate(&recordings[idx])
    }

    // MARK: - Persistence (Phase 1: GRDB)
    //
    // Источник правды на диске — SQLite (`store.sqlite`). В памяти держим
    // `recordings: [Recording]` как @Observable-кэш для UI. Любая мутация
    // через didSet триггерит `scheduleSave()`, который дебаунсит и делает
    // транзакционный upsert всего массива в DB. JSON больше не пишем; старый
    // recordings.json остаётся как страховка только для миграции при первом
    // запуске.

    private func load() {
        do {
            let count = try dbQueue.read { try Recording.fetchCount($0) }
            if count > 0 {
                recordings = try dbQueue.read { try Recording
                    .order(Recording.Columns.createdAt.desc)
                    .fetchAll($0)
                }
                return
            }

            // DB пустая — пробуем миграцию из старого JSON-стора.
            let legacy = migrateLegacyStores()
            recordings = legacy
            if !legacy.isEmpty { save() }
        } catch {
            print("❌ store load failed: \(error.localizedDescription)")
            recordings = []
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        let snapshot = recordings
        do {
            try dbQueue.write { db in
                let livingIDs = Set(snapshot.map { $0.id.uuidString })
                // Удалить записи, которых больше нет в памяти.
                let storedIDs = try String.fetchAll(db, sql: "SELECT id FROM recording")
                for id in storedIDs where !livingIDs.contains(id) {
                    try db.execute(sql: "DELETE FROM recording WHERE id = ?", arguments: [id])
                }
                // Upsert текущих.
                for var rec in snapshot {
                    try rec.save(db)
                }
            }
        } catch {
            print("❌ store save failed: \(error.localizedDescription)")
        }
    }

    private func mediaDirectory(for recording: Recording) -> URL {
        recording.storageDirectoryURL()
    }

    /// Импорт из старого JSON-стора (`Application Support/UshiNext/recordings.json`
    /// и legacy-локаций) — выполняется один раз при первом запуске после миграции на GRDB.
    private func migrateLegacyStores() -> [Recording] {
        var candidates: [URL] = []
        if let meta = try? AppSettings.metadataDirectory() {
            candidates.append(meta)
        }
        candidates.append(AppSettings.defaultRecordingsDirectory())
        if let user = try? AppSettings.recordingsDirectory() {
            candidates.append(user)
        }

        var merged: [UUID: Recording] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dir in candidates {
            let url = dir.appendingPathComponent("recordings.json")
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty,
                  let items = try? decoder.decode([Recording].self, from: data) else { continue }

            for var item in items {
                if item.storageFolderPath == nil || item.storageFolderPath?.isEmpty == true {
                    item.storageFolderPath = dir.path
                }
                merged[item.id] = item
            }
        }

        return merged.values.sorted { $0.createdAt > $1.createdAt }
    }

    private func normalizeStoragePaths() {
        let defaultPath = AppSettings.defaultRecordingsDirectory().path
        for idx in recordings.indices {
            if recordings[idx].storageFolderPath == nil || recordings[idx].storageFolderPath?.isEmpty == true {
                recordings[idx].storageFolderPath = defaultPath
            }
        }
    }

}

enum RecordingsStoreError: LocalizedError {
    case busyTranscribing
    case anotherMoveInProgress
    case unsupportedFile(String)
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .invalidAudio:
            return "Не удалось прочитать аудио. Файл повреждён или не содержит звука. Выберите другой файл."
        case .unsupportedFile(let name):
            return "«\(name)» — неподдерживаемый формат. Можно загрузить аудио: mp3, m4a, wav, aac, aiff."
        case .busyTranscribing:
            return "Запись сейчас расшифровывается. Перенести её можно после окончания расшифровки."
        case .anotherMoveInProgress:
            return "Уже идёт перенос другой записи. Дождитесь его окончания."
        }
    }
}

/// Состояние переноса между дисками — для окна с прогрессом.
struct MoveProgress: Equatable {
    let recordingID: UUID
    let recordingTitle: String
    let destinationName: String
    var fraction: Double
}
