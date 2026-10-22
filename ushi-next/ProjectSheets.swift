//
//  ProjectSheets.swift
//  UshiNext
//
//  Модалки Проектов: создание (§6.5, с Phase 3 — и в своей папке),
//  удаление (§6.8), прогресс переноса между дисками (Phase 3).
//

import SwiftUI

// MARK: - Новый проект

/// Название — любое. Отдельно и явно — папка, где будут лежать записи:
/// по умолчанию новая папка внутри Ushi, либо готовая папка юзера (тогда название
/// подставляется из неё; поменяли — папка переименуется). Новую папку в другом
/// месте юзер создаёт сам прямо в окне выбора («Новая папка»).
/// Что записывать, не спрашиваем: проект стартует с источниками последней записи.
struct CreateProjectSheet: View {
    let projects: ProjectsModel
    var onCreated: (Project) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location: NewProjectLocation = .insideUshi
    /// Название, вписанное до выбора готовой папки — вернём, если от неё откажутся.
    @State private var nameBeforeExisting: String?
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Имя, которое получит папка (без «/» и «:»).
    private var folderName: String {
        ProjectFolders.folderName(from: trimmedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Новый проект")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Название")
                    .font(.headline)
                TextField("Например, «Лекции»", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
                if case .existing(let folder) = location,
                   !folderName.isEmpty, folderName != folder.lastPathComponent {
                    Text("Папка «\(folder.lastPathComponent)» будет переименована в «\(folderName)».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Папка")
                    .font(.headline)
                folderBox
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(AppColors.red)
            }

            HStack {
                Spacer()
                Button("Отменить", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Создать", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }

    // MARK: Блок «Папка»

    private var folderBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: folderIcon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(folderSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    pickExisting()
                } label: {
                    Label("Выбрать готовую…", systemImage: "folder")
                }
                if location != .insideUshi {
                    Button("В Ushi", action: resetToUshi)
                        .help("Хранить записи внутри приложения")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    private var shownFolderName: String {
        folderName.isEmpty ? "Название" : folderName
    }

    private var folderIcon: String {
        switch location {
        case .insideUshi, .newFolder: return "folder.badge.plus"
        case .existing:               return "folder.fill"
        }
    }

    private var folderTitle: String {
        switch location {
        case .insideUshi:        return "Новая папка «\(shownFolderName)»"
        case .newFolder:         return "Новая папка «\(shownFolderName)»"
        case .existing(let url): return "Готовая папка «\(url.lastPathComponent)»"
        }
    }

    private var folderSubtitle: String {
        switch location {
        case .insideUshi:
            return "Будет создана в Документы → Ushi"
        case .newFolder(let parent):
            return "Будет создана в \(ProjectFolders.displayPath(parent.path))"
        case .existing(let url):
            return ProjectFolders.displayPath(url.path)
        }
    }

    // MARK: Действия

    private func pickExisting() {
        guard let folder = FolderPicker.chooseFolder(
            message: "Выберите папку, где будут лежать записи проекта"
        ) else { return }
        if nameBeforeExisting == nil { nameBeforeExisting = name }
        name = folder.lastPathComponent
        location = .existing(folder)
        errorMessage = nil
    }

    private func resetToUshi() {
        restoreNameIfNeeded()
        location = .insideUshi
        errorMessage = nil
    }

    /// Уходим с готовой папки — возвращаем название, которое юзер вписывал сам.
    private func restoreNameIfNeeded() {
        if case .existing = location, let typed = nameBeforeExisting {
            name = typed
        }
        nameBeforeExisting = nil
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        do {
            // Источники — как у последней записи; дальше проект запоминает свои.
            let project = try projects.create(
                name: trimmedName,
                preset: AppState.mostRecentPreset(),
                location: location
            )
            onCreated(project)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Удаление проекта

struct DeleteProjectSheet: View {
    let project: Project
    let recordingCount: Int
    let mediaSize: Int64
    var onDelete: (_ deleteRecordings: Bool) -> Void

    /// Выше этого объёма удаление файлов требует ввести имя Проекта (§6.8).
    static let typedConfirmThreshold: Int64 = 500 * 1024 * 1024

    @Environment(\.dismiss) private var dismiss
    @State private var deleteRecordings = false
    @State private var typedName = ""

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: mediaSize, countStyle: .file)
    }

    private var needsTypedConfirm: Bool {
        deleteRecordings && mediaSize > Self.typedConfirmThreshold
    }

    private var canDelete: Bool {
        !needsTypedConfirm || typedName.trimmingCharacters(in: .whitespaces) == project.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Удалить «\(project.name)»?")
                .font(.title2.weight(.semibold))

            Text(summary)
                .foregroundStyle(.secondary)

            if recordingCount > 0 {
                Toggle("Удалить также записи (\(sizeText))", isOn: $deleteRecordings)

                Text(deleteRecordings
                     ? "Записи и их файлы будут удалены без возможности восстановления."
                     : keepText)
                    .font(.callout)
                    .foregroundStyle(deleteRecordings ? AppColors.red : Color.secondary)

                if needsTypedConfirm {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Чтобы подтвердить, введите название проекта:")
                            .font(.callout)
                        TextField(project.name, text: $typedName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Отменить", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Удалить", role: .destructive) {
                    onDelete(deleteRecordings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canDelete)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    /// Что будет с записями, если их не удалять. Папку external-Проекта не трогаем.
    private var keepText: String {
        guard let path = project.storage.displayPath else {
            return "Если оставить — записи переместятся в «Записи»."
        }
        return "Если оставить — записи появятся в «Записях», а файлы останутся в папке \(ProjectFolders.displayPath(path))."
    }

    private var summary: String {
        guard recordingCount > 0 else { return "В проекте нет записей." }
        return "В проекте \(recordingCount) \(Self.recordingsWord(recordingCount)) (\(sizeText))."
    }

    /// «1 запись», «2 записи», «5 записей».
    static func recordingsWord(_ n: Int) -> String {
        let mod100 = n % 100
        let mod10 = n % 10
        if (11...14).contains(mod100) { return "записей" }
        switch mod10 {
        case 1: return "запись"
        case 2, 3, 4: return "записи"
        default: return "записей"
        }
    }
}

// MARK: - Перенос между дисками

/// Прогресс копирования записи на другой диск (Phase 3, п. 5). «Отменить» —
/// частичная копия удаляется, запись остаётся на старом месте.
struct MoveProgressSheet: View {
    let progress: MoveProgress
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Переношу запись")
                .font(.title3.weight(.semibold))
            Text("«\(progress.recordingTitle)» → «\(progress.destinationName)»")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ProgressView(value: progress.fraction)
            HStack {
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отменить", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}
