//
//  RecordingController.swift
//  ushi
//
//  Единая точка старта/стопа записи для окна и menu bar.
//  Phase 2: запись стартует с пресетом и целевым Проектом (или в «Записи»),
//  см. §7.1 брифа. Обратный отсчёт тоже живёт здесь, чтобы кнопка в sidebar,
//  ⏺ у Проекта и hero-экран делили одно состояние.
//

import Foundation
import AppKit
import AVFoundation
import Observation

@MainActor
@Observable
final class RecordingController {
    let recorder: AudioRecorder
    let store: RecordingsStore
    let projects: ProjectsModel

    var isCreatingProjectFromMenu = false

    private(set) var isBusy = false
    private(set) var errorMessage: String?
    /// errorMessage — не сбой, а подсказка про разрешения (macOS как раз показывает
    /// свой запрос). UI рисует её спокойно, без красного.
    private(set) var errorIsPermissionHint = false
    private(set) var lastSavedRecording: Recording?
    /// Живая расшифровка текущей (или только что законченной) записи.
    private(set) var liveTranscript: LiveTranscript?

    /// Идёт обратный отсчёт перед стартом (3…2…1). nil — отсчёта нет.
    private(set) var countdown: Int?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    private let countdownStart = 3
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    /// Куда и с каким пресетом пишется текущая (или готовящаяся) запись.
    private(set) var activePreset: RecordingPreset?
    private(set) var activeProjectID: UUID?

    /// Глобальный `app.lastUsedPreset` (§6.4, §13). Зеркалит таблицу app_state,
    /// чтобы chip-ы в UI обновлялись без перечитывания БД.
    var globalPreset: RecordingPreset {
        didSet {
            guard globalPreset != oldValue else { return }
            AppState.setLastUsedPreset(globalPreset)
        }
    }

    init() {
        self.recorder = AudioRecorder()
        self.store = RecordingsStore()
        self.projects = ProjectsModel()
        self.globalPreset = AppState.lastUsedPreset()
        observeInterruptions()
    }

    init(
        recorder: AudioRecorder,
        store: RecordingsStore,
        projects: ProjectsModel
    ) {
        self.recorder = recorder
        self.store = store
        self.projects = projects
        self.globalPreset = AppState.lastUsedPreset()
        observeInterruptions()
    }

    private func observeInterruptions() {
        recorder.onInterruption = { [weak self] error in
            await self?.stop(alertOnFailure: false, interruption: "Захват прерван: \(error.localizedDescription)")
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.stop(alertOnFailure: false, interruption: "Mac переходит в сон.")
            }
        }
    }

    deinit {
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    var isRecording: Bool { recorder.isRecording }
    var isCountingDown: Bool { countdown != nil }

    /// Проект, в который идёт текущая запись (nil — «Записи»).
    var activeProject: Project? { projects.project(id: activeProjectID) }

    // MARK: - Старт

    /// Главная кнопка / menu bar «Начать запись»: в «Записи» с глобальным пресетом (§7.1, путь 1).
    func startInInbox(withCountdown: Bool = true, alertOnFailure: Bool = false) async {
        await start(preset: globalPreset, project: nil, withCountdown: withCountdown, alertOnFailure: alertOnFailure)
    }

    /// ⏺ у Проекта: в Проект с его пресетом (§7.1, путь 2).
    func startInProject(_ project: Project, withCountdown: Bool = true, alertOnFailure: Bool = false) async {
        await start(preset: project.lastUsedPreset, project: project, withCountdown: withCountdown, alertOnFailure: alertOnFailure)
    }

    /// Общий путь старта, в т.ч. из hero-экрана с выбранными chip-ами (§7.1, путь 3).
    func start(
        preset: RecordingPreset,
        project: Project?,
        withCountdown: Bool = true,
        alertOnFailure: Bool = false
    ) async {
        guard !isBusy, !recorder.isRecording, countdown == nil else { return }
        errorMessage = nil
        activePreset = preset
        activeProjectID = project?.id

        if withCountdown {
            let task = Task { await runCountdown() }
            countdownTask = task
            await task.value
            countdownTask = nil
            guard !task.isCancelled else {
                activePreset = nil
                activeProjectID = nil
                return
            }
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try configureRecorder(for: preset, project: project)
            try await ensurePermissionsForCurrentConfiguration()
            // Живая расшифровка — только если модель распознавания уже скачана.
            if ModelManager.shared.isReady {
                let live = LiveTranscript(projectName: project?.name)
                recorder.liveSink = { [engine = live.engine!] mic, system, mix in
                    engine.append(microphone: mic, system: system, mix: mix)
                }
                liveTranscript = live
            }
            try await recorder.start()
            errorMessage = nil
        } catch {
            recorder.liveSink = nil
            liveTranscript = nil
            activePreset = nil
            activeProjectID = nil
            handle(error, alertOnFailure: alertOnFailure)
        }
    }

    /// Тап во время отсчёта = отмена.
    func cancelCountdown() {
        countdownTask?.cancel()
        countdown = nil
    }

    private func runCountdown() async {
        for n in stride(from: countdownStart, through: 1, by: -1) {
            countdown = n
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                countdown = nil
                return
            }
        }
        countdown = nil
    }

    // MARK: - Стоп

    func stop(alertOnFailure: Bool = true, interruption: String? = nil) async {
        guard !isBusy, recorder.isRecording else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await recorder.stop()
            recorder.liveSink = nil
            let live = liveTranscript
            let project = activeProject
            let preset = activePreset ?? project?.lastUsedPreset ?? globalPreset
            // addRecording сам обновляет sticky-пресет контекста (§7.2).
            let recording = store.addRecording(
                audioURL: result.url,
                duration: result.duration,
                project: project,
                preset: preset,
                voiceTrackURL: result.voiceTrackURL,
                liveTranscript: live.map { live in { await live.finish() } }
            )
            if project == nil {
                globalPreset = preset
            }
            store.saveNow()
            projects.reload()
            lastSavedRecording = recording
            errorMessage = interruption.map { "\($0) Записанная часть сохранена." }
        } catch {
            handle(error, alertOnFailure: alertOnFailure)
        }
        activePreset = nil
        activeProjectID = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    func consumeLastSavedRecording() -> Recording? {
        defer { lastSavedRecording = nil }
        return lastSavedRecording
    }

    // MARK: - Конфигурация

    /// Бросает `ProjectFolderError.unavailable`, если папка external-Проекта пропала:
    /// лучше не начать запись, чем молча положить её не туда (§10 Phase 3, п. 6).
    private func configureRecorder(for preset: RecordingPreset, project: Project?) throws {
        guard !recorder.isRecording else { return }
        do {
            recorder.outputDirectory = try project.map { try ProjectFolders.recordingsDirectory(for: $0) }
        } catch {
            projects.refreshFolders()
            throw error
        }
        recorder.micEnabled = preset.hasMicrophone
        recorder.systemAudioEnabled = preset.hasSystemAudio
        recorder.captureVideo = preset.hasScreen
    }

    private func ensurePermissionsForCurrentConfiguration() async throws {
        // Доступ к экрану — только для видео: звук пишется мимо ScreenCaptureKit.
        if recorder.captureVideo {
            try ensureScreenRecordingAccess()
        }
        if recorder.micEnabled {
            try await ensureMicrophoneAccess()
        }
    }

    /// Доступ к записи экрана нужен только для видео экрана. Настройки сами не открываем — системный запрос
    /// macOS уже содержит кнопку «Открыть Системные настройки».
    private func ensureScreenRecordingAccess() throws {
        guard !ScreenRecordingPermission.isGranted else { return }
        guard ScreenRecordingPermission.request() else {
            throw RecordingControllerError.screenPermissionDenied
        }
    }

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw RecordingControllerError.microphonePermissionDenied
            }
        default:
            throw RecordingControllerError.microphonePermissionDenied
        }
    }

    private func handle(_ error: Error, alertOnFailure: Bool) {
        let message = (error as NSError).localizedDescription
        errorMessage = message
        errorIsPermissionHint = error is RecordingControllerError
        if alertOnFailure {
            presentAlert(message: message)
        }
    }

    private func presentAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Проблема с записью"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private enum RecordingControllerError: LocalizedError {
    case microphonePermissionDenied
    case screenPermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Нет доступа к микрофону. Разреши его в Системных настройках → Конфиденциальность и безопасность → Микрофон."
        case .screenPermissionDenied:
            return "Для записи экрана нужен доступ. Разреши его в окне macOS (или в Системных настройках → Конфиденциальность и безопасность → Запись экрана) и нажми запись ещё раз."
        }
    }
}
