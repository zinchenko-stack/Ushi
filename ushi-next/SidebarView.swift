//
//  SidebarView.swift
//  UshiNext
//
//  Левая колонка в стиле Claude Code: своя, а не системный список macOS —
//  компактные строки, единый край, своя подсветка. Иерархия:
//  «Проекты» (серым) → проект с иконкой папки (открытой, если раскрыт) →
//  записи под названием проекта. «Записи» без проекта — отдельной секцией.
//  Внизу под разделителем — «Настройки».
//

import SwiftUI

struct SidebarView: View {
    @Bindable var model: SidebarViewModel
    @Binding var selection: MainSelection?

    private var controller: RecordingController { model.controller }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                    // Ведёт на экран «Новая запись»; во время записи — таймер.
                    SidebarRow(isSelected: selection == .home) {
                        selection = .home
                    } content: {
                        NewRecordingRowContent(controller: controller)
                    }

                    // Пока ведёт в список всех записей с поиском по названию и тексту.
                    SidebarRow(isSelected: selection == .search) {
                        selection = .search
                    } content: {
                        SidebarLabel(title: "Поиск") {
                            Image(systemName: "magnifyingglass")
                        }
                    }

                    SidebarSectionHeader(title: "Проекты") {
                        SidebarHoverButton(systemImage: "plus", help: "Новый проект") {
                            model.startCreatingProject()
                        }
                    }

                    if model.pinnedAndSortedProjects.isEmpty {
                        SidebarRow {
                            model.startCreatingProject()
                        } content: {
                            SidebarLabel(title: "Создать проект", isSecondary: true) {
                                Image(systemName: "plus")
                            }
                        }
                    }
                    ForEach(model.pinnedAndSortedProjects) { project in
                        projectBlock(project)
                    }

                    SidebarSectionHeader(
                        title: "Записи",
                        isExpanded: $model.isInboxExpanded
                    ) { EmptyView() }

                    if model.isInboxExpanded {
                        recordingRows(in: nil)
                    }
                }
                .padding(.horizontal, SidebarMetrics.outerPadding)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            HairlineDivider()

            SidebarRow(
                isSelected: selection == .settings,
                cornerRadius: SidebarMetrics.footerCornerRadius,
                minHeight: SidebarMetrics.footerRowHeight
            ) {
                selection = .settings
            } content: {
                SidebarLabel(title: "Настройки") {
                    Image("Bolt")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                }
            }
            .padding(.horizontal, SidebarMetrics.footerPadding)
            .padding(.vertical, SidebarMetrics.footerPadding - 2)
        }
        .font(.system(size: SidebarMetrics.fontSize))
        // «Новая запись» в sidebar — всегда «Без проекта» (§6.4); проект
        // подставляется, только если пришли через «+» у проекта.
        .onChange(of: selection) { _, newValue in
            model.selectionChanged(to: newValue)
        }
        .sheet(isPresented: $model.isCreatingProject) {
            CreateProjectSheet(projects: controller.projects) { project in
                model.didCreateProject(project)
            }
        }
        .sheet(item: $model.projectPendingDeletion) { project in
            DeleteProjectSheet(
                project: project,
                recordingCount: model.totalCount(in: project),
                mediaSize: controller.store.mediaSize(ofProject: project.id)
            ) { deleteRecordings in
                model.deleteProject(project, deleteRecordings: deleteRecordings)
            }
        }
        .sheet(item: Binding(
            get: { controller.store.activeMove.map(IdentifiedMove.init) },
            set: { _ in }
        )) { move in
            MoveProgressSheet(progress: move.progress) {
                controller.store.cancelMove()
            }
        }
        // Юзер мог удалить или переименовать папку проекта в Finder — перепроверяем.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.projects.refreshFolders()
        }
        .confirmationDialog(
            "Удалить запись?",
            isPresented: Binding(
                get: { model.recordingPendingDeletion != nil },
                set: { if !$0 { model.recordingPendingDeletion = nil } }
            ),
            presenting: model.recordingPendingDeletion
        ) { rec in
            Button("Удалить", role: .destructive) {
                if selection == .recording(rec.id) { selection = .home }
                model.delete(rec)
            }
        } message: { rec in
            Text("«\(rec.title)» будет удалена вместе с файлом.")
        }
        .alert(
            "Не получилось",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    // MARK: - Проект

    @ViewBuilder
    private func projectBlock(_ project: Project) -> some View {
        let expanded = model.isExpanded(project)
        let isRenaming = model.renamingProjectID == project.id
        SidebarRow(action: isRenaming ? nil : { model.setExpanded(project, !expanded) }) {
            ProjectRowContent(
                project: project,
                isExpanded: expanded,
                isAvailable: model.isAvailable(project),
                folderPath: model.folderPath(of: project),
                isRenaming: isRenaming,
                isRecordingHere: controller.isRecording && controller.activeProjectID == project.id,
                canStart: model.isAvailable(project),
                onStart: {
                    // Не стартуем сразу: открываем «Новую запись» с выбранным проектом —
                    // там видно и можно поменять источники.
                    model.prepareNewRecording(in: project, alreadyOnHome: selection == .home)
                    selection = .home
                },
                onCommitRename: { model.commitRename(project, to: $0) },
                onCancelRename: { model.renamingProjectID = nil }
            ) {
                projectMenu(project)
            }
        }
        .contextMenu { projectMenu(project) }

        if expanded {
            // Записи проекта начинаются ровно под его названием.
            recordingRows(in: project, indent: SidebarMetrics.iconColumn + SidebarMetrics.iconSpacing)
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        if !model.isAvailable(project) {
            Button("Подключить заново…") {
                model.reconnect(project)
            }
            Divider()
        }
        Button("Загрузить аудио…") {
            model.importAudio(into: project)
        }
        .disabled(!model.isAvailable(project))
        Divider()
        Button(project.isPinned ? "Открепить" : "Закрепить") {
            model.togglePinned(project)
        }
        Button("Показать в Finder") {
            model.revealInFinder(project)
        }
        Button("Переименовать") {
            model.renamingProjectID = project.id
        }
        Divider()
        Button("Удалить…", role: .destructive) {
            model.projectPendingDeletion = project
        }
    }

    // MARK: - Записи секции

    @ViewBuilder
    private func recordingRows(in project: Project?, indent: CGFloat = 0) -> some View {
        let recent = model.recentRecordings(in: project)
        if recent.isEmpty {
            Text(project == nil ? "Здесь появятся записи без проекта" : "Пока нет записей")
                .font(.system(size: SidebarMetrics.smallFontSize))
                .foregroundStyle(.tertiary)
                .padding(.leading, SidebarMetrics.rowPadding + indent)
                .frame(minHeight: SidebarMetrics.rowHeight)
        }
        ForEach(recent) { rec in
            let isRenaming = model.renamingRecordingID == rec.id
            SidebarRow(
                isSelected: selection == .recording(rec.id),
                indent: indent,
                action: isRenaming ? nil : { selection = .recording(rec.id) }
            ) {
                RecordingRowContent(
                    recording: rec,
                    isRenaming: isRenaming,
                    onCommitRename: { model.commitRename(rec, to: $0) },
                    onCancelRename: { model.renamingRecordingID = nil }
                )
            }
            .contextMenu { recordingMenu(rec) }
        }
        if model.hasMore(in: project) {
            SidebarRow(indent: indent) {
                model.toggleShowAll(project)
            } content: {
                Text(model.isShowingAll(project) ? "Показать меньше" : "Показать больше →")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func recordingMenu(_ rec: Recording) -> some View {
        Menu("Переместить в") {
            ForEach(model.pinnedAndSortedProjects) { project in
                Button(project.name) { model.move(rec, to: project) }
                    .disabled(rec.projectId == project.id)
            }
            if !model.pinnedAndSortedProjects.isEmpty { Divider() }
            Button("Без проекта") { model.move(rec, to: nil) }
                .disabled(rec.projectId == nil)
            Divider()
            Button("Создать проект…") { model.startCreatingProject(thenMove: rec) }
        }
        Button("Переименовать") {
            model.renamingRecordingID = rec.id
        }
        Button("Придумать название") {
            model.regenerateTitle(rec)
        }
        .disabled(rec.status != .done)
        Button("Показать в Finder") {
            model.revealInFinder(rec)
        }
        Divider()
        Button("Удалить", role: .destructive) {
            model.recordingPendingDeletion = rec
        }
    }
}

// MARK: - Размеры

/// Общие размеры левой колонки: компактно, как в Claude Code.
enum SidebarMetrics {
    static let width: CGFloat = 260
    static let fontSize: CGFloat = 13
    static let smallFontSize: CGFloat = 11.5
    /// Высота строки (кликабельная область).
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 1
    /// Отступ подсветки от краёв колонки.
    static let outerPadding: CGFloat = 8
    /// Отступ содержимого внутри строки — общий край для иконок и текста.
    static let rowPadding: CGFloat = 8
    static let cornerRadius: CGFloat = 7
    static let iconColumn: CGFloat = 16
    static let iconSize: CGFloat = 14
    static let iconSpacing: CGFloat = 8
    /// Отступ над заголовками секций.
    static let sectionTopSpacing: CGFloat = 14
    /// «Настройки» внизу: скругление созвучно большому углу окна macOS.
    static let footerCornerRadius: CGFloat = 12
    static let footerRowHeight: CGFloat = 34
    static let footerPadding: CGFloat = 10
}

// MARK: - Строка

/// Строка левой колонки: подсветка при наведении и выборе, клик по всей строке.
/// Кнопки внутри («+», «⋯») перехватывают клик сами.
private struct SidebarRow<Content: View>: View {
    var isSelected = false
    var indent: CGFloat = 0
    var cornerRadius: CGFloat = SidebarMetrics.cornerRadius
    var minHeight: CGFloat = SidebarMetrics.rowHeight
    var action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        content()
            .lineLimit(1)
            .padding(.leading, SidebarMetrics.rowPadding + indent)
            .padding(.trailing, SidebarMetrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : (isHovered && action != nil ? 0.05 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture { action?() }
            .onHover { isHovered = $0 }
    }
}

/// «иконка + текст» с иконкой в колонке фиксированной ширины — общий край.
private struct SidebarLabel<Icon: View>: View {
    let title: String
    var isSecondary = false
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: SidebarMetrics.iconSpacing) {
            icon()
                .font(.system(size: SidebarMetrics.iconSize))
                .frame(width: SidebarMetrics.iconColumn)
            Text(title)
        }
        .foregroundStyle(isSecondary ? Color.secondary : Color.primary)
    }
}

/// Заголовок секции серым. С `isExpanded` — сворачивается кликом (стрелка при наведении).
private struct SidebarSectionHeader<Trailing: View>: View {
    let title: String
    var isExpanded: Binding<Bool>?
    @ViewBuilder let trailing: () -> Trailing

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            if let isExpanded, isHovered {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            // «+» у «Проектов» виден всегда, не только при наведении.
            trailing()
        }
        .padding(.horizontal, SidebarMetrics.rowPadding)
        .frame(minHeight: 24)
        .padding(.top, SidebarMetrics.sectionTopSpacing)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let isExpanded else { return }
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
        }
        .onHover { isHovered = $0 }
    }
}

/// Маленькая кнопка-иконка в строке (видна при наведении).
private struct SidebarHoverButton: View {
    let systemImage: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }
}

// MARK: - «Новая запись» (§6.4)

/// Плюс в кружке; во время отсчёта и записи — красная точка, таймер и Проект
/// (если запись идёт в Проект).
private struct NewRecordingRowContent: View {
    let controller: RecordingController

    var body: some View {
        HStack(spacing: SidebarMetrics.iconSpacing) {
            Image(systemName: controller.isRecording ? "record.circle.fill" : "plus.circle")
                .font(.system(size: SidebarMetrics.iconSize + 1))
                .foregroundStyle(controller.isRecording ? AppColors.red : Color.primary)
                .frame(width: SidebarMetrics.iconColumn)
            Text(controller.isRecording ? "Идёт запись" : "Новая запись")
            if controller.isRecording || controller.isCountingDown,
               let project = controller.activeProject {
                Text(project.name)
                    .font(.system(size: SidebarMetrics.smallFontSize))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let cd = controller.countdown {
                Text("\(cd)")
                    .font(.system(size: SidebarMetrics.smallFontSize).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if controller.isRecording {
                Text(formatTime(controller.recorder.elapsed))
                    .font(.system(size: SidebarMetrics.smallFontSize).monospacedDigit())
                    .foregroundStyle(AppColors.red)
            }
        }
    }
}

extension Binding where Value == RecordingPreset {
    /// Галочка источника. Выключить последний звуковой источник нельзя —
    /// такое переключение молча игнорируется (пункт в UI и так disabled).
    func binding(for source: RecordingPreset.Source) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.contains(source) },
            set: { isOn in
                guard isOn != wrappedValue.contains(source),
                      let next = wrappedValue.toggling(source) else { return }
                wrappedValue = next
            }
        )
    }
}

// MARK: - Строка Проекта

private struct ProjectRowContent<MenuContent: View>: View {
    let project: Project
    let isExpanded: Bool
    /// false — папка external-Проекта пропала (degraded state, §7.6).
    let isAvailable: Bool
    /// Путь своей папки — в подсказке при наведении. nil — папка внутри Ushi.
    let folderPath: String?
    let isRenaming: Bool
    let isRecordingHere: Bool
    let canStart: Bool
    let onStart: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var isHovered = false

    private var helpText: String {
        if !isAvailable {
            return "Папка проекта недоступна. Правый клик → «Подключить заново…»"
        }
        return folderPath.map { "Папка: \($0)" } ?? project.name
    }

    var body: some View {
        HStack(spacing: SidebarMetrics.iconSpacing) {
            icon
                .frame(width: SidebarMetrics.iconColumn)

            if isRenaming {
                InlineRenameField(initial: project.name, onCommit: onCommitRename, onCancel: onCancelRename)
            } else {
                Text(project.name)
                    .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
                if project.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            if isHovered && !isRenaming {
                SidebarHoverButton(systemImage: "plus", help: "Новая запись в «\(project.name)»",
                                   isEnabled: canStart, action: onStart)
                Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .onHover { isHovered = $0 }
        .help(helpText)
    }

    /// Открытая папка — проект раскрыт, закрытая — свёрнут. Запись идёт — красная
    /// точка; папка пропала — жёлтый треугольник.
    @ViewBuilder
    private var icon: some View {
        if isRecordingHere {
            Image(systemName: "record.circle.fill")
                .font(.system(size: SidebarMetrics.iconSize))
                .foregroundStyle(AppColors.red)
        } else if !isAvailable {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: SidebarMetrics.iconSize - 1))
                .foregroundStyle(.yellow)
        } else {
            Image(isExpanded ? "FolderOpen" : "FolderClosed")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Строка записи

private struct RecordingRowContent: View {
    let recording: Recording
    let isRenaming: Bool
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if isRenaming {
                InlineRenameField(initial: recording.title, onCommit: onCommitRename, onCancel: onCancelRename)
            } else {
                Text(recording.title)
                Spacer(minLength: 4)
                if recording.status == .transcribing {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(RelativeTime.short(since: recording.createdAt))
                    .font(.system(size: SidebarMetrics.smallFontSize).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Inline rename

/// TextField на месте названия: Enter — сохранить, Esc или потеря фокуса — отменить.
struct InlineRenameField: View {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Название", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear {
                text = initial
                focused = true
            }
            .onSubmit { onCommit(text) }
            .onExitCommand { onCancel() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCancel() }
            }
    }
}

private func formatTime(_ t: TimeInterval) -> String {
    let total = Int(t)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
}

/// Обёртка для `.sheet(item:)`: id стабилен, пока меняется процент,
/// иначе SwiftUI пересоздавал бы окно на каждом шаге прогресса.
private struct IdentifiedMove: Identifiable {
    let progress: MoveProgress
    var id: UUID { progress.recordingID }
}

// MARK: - Фон колонки

/// Цвета окна как в Claude Code: колонка почти чёрная, основная часть чуть
/// светлее, разделитель едва заметный. Для светлой темы — такие же пары оттенков.
enum AppColors {
    static let sidebar = adaptive(dark: 0.075, light: 0.955)   // #131313 / #F4F4F4
    static let content = adaptive(dark: 0.094, light: 0.985)   // #181818 / #FBFBFB
    /// Разделители — тонкие линии в один пиксель (см. HairlineDivider).
    static let divider = pair(dark: 0x292929, light: 0xDEDEDE)
    /// Всплывающие плашки поверх окна: в светлой теме чисто белые, в тёмной — чуть светлее окна.
    static let elevated = pair(dark: 0x262626, light: 0xFFFFFF)

    /// Акцент на кнопках (запись, включённые источники): приглушённая подложка
    /// и значок в тон, а не яркий системный синий. В тёмной теме — как у
    /// Claude Code (#042040 / #6CA4EC), в светлой — светло-голубая с синим.
    static let accentFill = pair(dark: 0x042040, light: 0xCBE1F9)
    static let accentGlyph = pair(dark: 0x6CA4EC, light: 0x164E93)
    /// Красный записи, ошибок и удаления — приглушённый, а не системный яркий.
    static let red = pair(dark: 0xC62135, light: 0xC62135)
    /// Точка в кнопке записи: в тёмной теме белая; в светлой белая потерялась бы
    /// на светло-голубом — там синяя.
    static let recordDot = pair(dark: 0xFFFFFF, light: 0x164E93)

    /// Иконки и подписи в панели окна — цвета Claude Code.
    static let toolbarGlyph = pair(dark: 0xC3C2B7, light: 0x3D3D3A)
    static let toolbarGlyphHover = pair(dark: 0xF0EFEC, light: 0x141413)

    /// Подсказка при наведении: в тёмной теме — как у Claude Code.
    static let tooltipFill = pair(dark: 0x20201F, light: 0xFFFFFF)
    static let tooltipBorder = pair(dark: 0x363635, light: 0xDEDDD8)
    static let tooltipText = pair(dark: 0xF0EFEC, light: 0x141413)

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Цвет для тёмной и светлой темы, в виде 0xRRGGBB.
    private static func pair(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = isDark(appearance) ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    private static func adaptive(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}

/// Линия в один физический пиксель — как разделители у Claude Code.
struct HairlineDivider: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(AppColors.divider)
            .frame(
                width: axis == .vertical ? 1 / displayScale : nil,
                height: axis == .horizontal ? 1 / displayScale : nil
            )
    }
}

/// Фон левой колонки.
struct SidebarBackground: View {
    var body: some View {
        AppColors.sidebar
    }
}

/// Колонка тянется под заголовок окна: фон панели инструментов прозрачный (macOS 15+).
struct SidebarUnderTitlebar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
