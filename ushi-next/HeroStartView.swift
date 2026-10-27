//
//  HeroStartView.swift
//  UshiNext
//
//  Hero-стейт (§6.4, §7.1 путь 3): «Начать запись» с chip-ами пресета и Проекта.
//  Во время отсчёта и записи — таймер, уровень и кнопка стопа (как в старом
//  RecordingView), chip-ы показывают, куда и как идёт запись.
//

import SwiftUI

struct HeroStartView: View {
    @Bindable var controller: RecordingController
    /// Целевой Проект для старта из hero. nil — «Без проекта». Живёт снаружи:
    /// «+» у проекта в sidebar открывает hero уже с выбранным проектом.
    @Binding var targetProjectID: UUID?
    /// Открыть запись по тапу на тост «Запись сохранена».
    var onOpenRecording: (Recording) -> Void
    @State private var isCreatingProject = false
    @State private var projectMenu = PopUpMenuAnchor()

    @State private var sourceHint: String?
    @State private var hintTask: Task<Void, Never>?

    @State private var savedRecording: Recording?     // показанный тост (nil = скрыт)
    @State private var toastTask: Task<Void, Never>?

    private var recorder: AudioRecorder { controller.recorder }
    private var projects: ProjectsModel { controller.projects }

    /// Идёт отсчёт или запись — chip-ы показывают активную запись и заблокированы.
    private var isActive: Bool { controller.isRecording || controller.isCountingDown }

    private var targetProject: Project? { projects.project(id: targetProjectID) }

    var body: some View {
        Group {
            // Во время записи главное — текст разговора: наверху узкая полоса
            // со стопом и временем, всё остальное место — расшифровке.
            if controller.isRecording, let live = controller.liveTranscript {
                recordingLayout(live)
            } else {
                heroLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { savedToast }
        .animation(.spring(duration: 0.3), value: savedRecording)
        // Без заголовка в окне: на экране и так крупное «Начать запись».
        .modifier(HiddenWindowTitle())
        // Загрузка готового аудио — кнопкой справа вверху, как в Claude Code.
        .toolbar {
            TrailingToolbarButton(
                imageName: "Download",
                title: "Загрузить",
                help: "Аудио для расшифровки",
                isEnabled: !isActive
            ) {
                importAudio()
            }
        }
        .sheet(isPresented: $isCreatingProject) {
            CreateProjectSheet(projects: projects) { project in
                targetProjectID = project.id
            }
        }
        // Запись могли остановить из sidebar или menu bar — тост показываем всё равно.
        .onChange(of: controller.lastSavedRecording) { _, rec in
            guard rec != nil, let saved = controller.consumeLastSavedRecording() else { return }
            showSavedToast(saved)
        }
    }

    // MARK: - Экран без записи (и отсчёт)

    private var heroLayout: some View {
        VStack(spacing: 0) {
            // Что и куда записываем: заголовок и Проект — одним блоком над кнопкой.
            VStack(spacing: 20) {
                Group {
                    if let cd = controller.countdown {
                        Text("\(cd)")
                            .foregroundStyle(Color.accentColor)
                    } else if controller.isRecording {
                        Text(formatTime(recorder.elapsed))
                            .foregroundStyle(.primary)
                    } else {
                        Text("Начать запись")
                            .foregroundStyle(.primary)
                    }
                }
                .font(controller.isRecording || controller.isCountingDown
                      ? .system(size: 80, weight: .medium, design: .rounded).monospacedDigit()
                      : .system(size: 36, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: controller.countdown)

                projectChip
            }
            .padding(.bottom, 44)
            .frame(maxHeight: .infinity, alignment: .bottom)

            // Кнопка записи — посередине и на месте: не уезжает из-под курсора,
            // когда заголовок сменяется таймером или внизу появляется ошибка.
            Button(action: handleTap) {
                ZStack {
                    Circle()
                        .fill(buttonFill)
                        .frame(width: 120, height: 120)
                    buttonGlyph
                }
                .opacity(controller.isBusy ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)

            // Под кнопкой: источники и уровень сигнала.
            VStack(spacing: 28) {
                // Источники — три круглые кнопки-переключателя с подписями.
                HStack(spacing: 16) {
                    ForEach(RecordingPreset.Source.available, id: \.self) { source in
                        SourceToggleButton(
                            source: source,
                            isOn: presetBinding.wrappedValue.contains(source),
                            isEnabled: !isActive
                        ) {
                            toggleSource(source)
                        }
                    }
                }

                // Индикатор уровня — заполняется от реального сигнала. Виден только
                // во время записи; место под ним остаётся, чтобы ничего не прыгало.
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 240, height: 8)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(levelColor)
                                .frame(width: geo.size.width * CGFloat(recorder.level))
                                .animation(.easeOut(duration: 0.1), value: recorder.level)
                        }
                        .frame(height: 8)
                    }
                    .opacity(controller.isRecording ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: controller.isRecording)
                    .accessibilityHidden(!controller.isRecording)

                if let errorMessage = controller.errorMessage {
                    // Про разрешения — спокойная подсказка: macOS в этот момент сама
                    // показывает запрос, пользователь ничего не сделал не так.
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(controller.errorIsPermissionHint ? Color.secondary : AppColors.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.top, 64)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // Кнопка записи чуть выше середины окна.
        .offset(y: -3)
    }

    // MARK: - Экран во время записи

    /// Текст расшифровки не шире этого — длинные строки трудно читать.
    /// Полоса записи при этом во всю ширину окна.
    static let recordingContentWidth: CGFloat = 920

    private func recordingLayout(_ live: LiveTranscript) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                // Слева: стоп, время и уровень звука под ним.
                HStack(spacing: 16) {
                    Button(action: handleTap) {
                        ZStack {
                            Circle().fill(AppColors.red).frame(width: 48, height: 48)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white)
                                .frame(width: 16, height: 16)
                        }
                        .opacity(controller.isBusy ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isBusy)
                    .help("Остановить запись")
                    .accessibilityLabel("Остановить запись")

                    VStack(alignment: .leading, spacing: 10) {
                        Text(formatTime(recorder.elapsed))
                            .font(.system(size: 28, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText())
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(width: 160, height: 6)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(levelColor)
                                        .frame(width: geo.size.width * CGFloat(recorder.level))
                                        .animation(.easeOut(duration: 0.1), value: recorder.level)
                                }
                            }
                            .accessibilityHidden(true)
                    }
                }

                Spacer(minLength: 16)

                // Справа: что пишется и куда — только для взгляда, не кнопки.
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        ForEach(RecordingPreset.Source.available, id: \.self) { source in
                            ActiveSourceBadge(source: source, isOn: presetBinding.wrappedValue.contains(source))
                        }
                    }
                    RecordingProjectBadge(name: controller.activeProject?.name ?? "Без проекта")
                }
            }
            .padding(24)

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(controller.errorIsPermissionHint ? Color.secondary : AppColors.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            LiveTranscriptPanel(live: live, contentWidth: Self.recordingContentWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Chip-ы

    /// Пресет: для «Без проекта» — глобальный app.lastUsedPreset, для Проекта — его
    /// lastUsedPreset (§6.4). Во время записи показывает фактический пресет.
    private var presetBinding: Binding<RecordingPreset> {
        Binding(
            get: {
                if isActive, let active = controller.activePreset { return active }
                return targetProject?.lastUsedPreset ?? controller.globalPreset
            },
            set: { newValue in
                if let project = targetProject {
                    projects.updateLastUsedPreset(project, newValue)
                } else {
                    controller.globalPreset = newValue
                }
            }
        )
    }

    /// Куда пойдёт запись — такой же кнопкой, как «Загрузить»: папка, название
    /// и стрелка; по клику — список Проектов.
    private var projectChip: some View {
        let shown = isActive ? controller.activeProject : targetProject
        return ClaudeButton(isEnabled: !isActive, action: { projectMenu.popUp(projectMenuItems) }) {
            HStack(spacing: 6) {
                Image("FolderClosed")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text(shown?.name ?? "Без проекта")
                    .font(.system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .background(PopUpMenuAnchorView(anchor: projectMenu))
        .fixedSize()
        .accessibilityLabel("Проект: \(shown?.name ?? "Без проекта")")
    }

    private var projectMenuItems: [PopUpMenuItem] {
        var items: [PopUpMenuItem] = [
            .item("Без проекта", isChecked: targetProjectID == nil) { targetProjectID = nil }
        ]
        if !projects.projects.isEmpty {
            items.append(.separator)
            for project in projects.projects {
                items.append(.item(project.name, isChecked: project.id == targetProjectID) {
                    targetProjectID = project.id
                })
            }
        }
        items.append(.separator)
        items.append(.item("Создать проект…") { isCreatingProject = true })
        return items
    }

    // MARK: - Загрузка аудио

    /// Файлы уходят в выбранный на chip-е Проект (или в «Записи»).
    private func importAudio() {
        let files = FolderPicker.chooseAudioFiles()
        guard !files.isEmpty else { return }
        let project = targetProject
        Task {
            var imported: Recording?
            for file in files {
                do {
                    imported = try await controller.store.importAudio(from: file, into: project)
                } catch {
                    showSourceHint(error.localizedDescription)
                }
            }
            controller.projects.reload()
            if let imported, files.count == 1 {
                showSavedToast(imported)
            }
        }
    }

    // MARK: - Источники

    /// Выключить последний звуковой источник нельзя — вместо молчаливой
    /// блокировки показываем подсказку на пару секунд.
    private func toggleSource(_ source: RecordingPreset.Source) {
        let preset = presetBinding.wrappedValue
        guard preset.canToggle(source) else {
            showSourceHint("Выберите хотя бы один источник звука")
            return
        }
        presetBinding.binding(for: source).wrappedValue.toggle()
    }

    private func showSourceHint(_ text: String) {
        withAnimation { sourceHint = text }
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                withAnimation { sourceHint = nil }
            }
        }
    }

    // MARK: - Кнопка

    private func handleTap() {
        if controller.isCountingDown {
            controller.cancelCountdown()
            return
        }
        if controller.isRecording {
            Task { await controller.stop(alertOnFailure: false) }
            return
        }
        dismissToast()
        let preset = presetBinding.wrappedValue
        let project = targetProject
        Task { await controller.start(preset: preset, project: project) }
    }

    private var buttonFill: Color {
        if controller.isRecording { return AppColors.red }
        if controller.isCountingDown { return .secondary.opacity(0.6) }
        return AppColors.accentFill
    }

    @ViewBuilder
    private var buttonGlyph: some View {
        if controller.isRecording {
            Image(systemName: "stop.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
        } else if controller.isCountingDown {
            // X = «отменить отсчёт»: визуально это не stop, не вводит в заблуждение
            // «уже идёт запись».
            Image(systemName: "xmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            // Красная точка = универсальный «record» (Voice Memos / QuickTime).
            Image(systemName: "circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.recordDot)
        }
    }

    private var levelColor: Color {
        if recorder.level > 0.85 { return AppColors.red }
        if recorder.level > 0.6 { return .yellow }
        return .green
    }

    // MARK: - Тост «Запись сохранена»

    @ViewBuilder
    private var savedToast: some View {
        if let sourceHint {
            // Подсказка — в той же плашке, что и «Запись сохранена».
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(sourceHint)
                    .fontWeight(.medium)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let rec = savedRecording {
            Button {
                dismissToast()
                onOpenRecording(rec)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Запись сохранена")
                        .fontWeight(.medium)
                    Image(systemName: "chevron.right")
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showSavedToast(_ rec: Recording) {
        savedRecording = rec
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                savedRecording = nil
            }
        }
    }

    private func dismissToast() {
        toastTask?.cancel()
        savedRecording = nil
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

/// Круглая кнопка-переключатель источника с подписью снизу, как в Telegram:
/// включена — залита акцентом, выключена — серая.
/// Источник на полосе записи — кружок со значком, не кнопка. Включён —
/// приглушённый голубой, выключен — серый в рамке.
private struct ActiveSourceBadge: View {
    let source: RecordingPreset.Source
    let isOn: Bool

    var body: some View {
        Image(systemName: source.outlineImage)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(isOn ? AppColors.accentGlyph : Color.secondary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(isOn ? AppColors.accentFill.opacity(0.7) : Color.secondary.opacity(0.15)))
            .overlay(Circle().strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.35)))
            .opacity(isOn ? 1 : 0.8)
            .help(isOn ? "\(source.title): пишется" : "\(source.title): не пишется")
            .accessibilityLabel(source.title)
            .accessibilityValue(isOn ? "пишется" : "не пишется")
    }
}

/// Проект, в который идёт запись, — серая плашка, во время записи не меняется.
private struct RecordingProjectBadge: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Image("FolderClosed")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .padding(8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
        .opacity(0.45)
        .fixedSize()
        .accessibilityLabel("Проект: \(name)")
    }
}

private struct SourceToggleButton: View {
    let source: RecordingPreset.Source
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: source.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isOn ? AppColors.accentGlyph : Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(isOn ? AppColors.accentFill : Color.secondary.opacity(0.18)))
                Text(source.shortTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.6)
        .help(isOn ? "\(source.title): включено" : "\(source.title): выключено")
        .accessibilityLabel(source.title)
        .accessibilityValue(isOn ? "включено" : "выключено")
    }
}

