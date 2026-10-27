//
//  RecordingDetailView.swift
//  ushi
//

import SwiftUI

struct RecordingDetailView: View {
    let recordingID: Recording.ID
    @Bindable var store: RecordingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelManager.self) private var modelManager

    @State private var player = AudioPlayerModel()
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var transcriptText: String?

    init(recording: Recording, store: RecordingsStore) {
        self.recordingID = recording.id
        self._store = Bindable(store)
    }

    private var recording: Recording? {
        store.recordings.first(where: { $0.id == recordingID })
    }

    var body: some View {
        Group {
            if let rec = recording {
                content(for: rec)
            } else {
                ContentUnavailableView("Запись удалена", systemImage: "trash")
                    .task { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func content(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: rec)
                .padding(24)

            transcriptSection(for: rec)
                .padding([.horizontal, .bottom], 24)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    player.stop()
                    store.delete(rec)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        }
        .onAppear {
            loadAudio(for: rec)
            loadTranscript(for: rec)
        }
        .onChange(of: rec.status)             { _, _ in loadTranscript(for: rec) }
        .onChange(of: rec.transcriptFileName) { _, _ in loadTranscript(for: rec) }
        .onDisappear { player.stop() }
    }

    // MARK: - Header

    private func header(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            titleSection(for: rec)

            HStack(spacing: 12) {
                Label(rec.createdAt.formatted(
                    .dateTime.day().month(.abbreviated).year().hour().minute()
                        .locale(Locale(identifier: "ru_RU"))),
                      systemImage: "calendar")
                Label(formatDuration(rec.duration), systemImage: "clock")
                if rec.audioRemoved {
                    Label("аудио удалено", systemImage: "externaldrive.badge.minus")
                }
            }
            .font(.title3)
            .foregroundStyle(.secondary)

            if !rec.audioRemoved {
                // Для .mov берём аудиодорожку — слушать звук удобно прямо здесь,
                // а само видео открывается отдельной кнопкой в actionsRow.
                playerSection
                    .padding(.top, 8)
            }

            if hasTopActions(rec) {
                actionsRow(for: rec)
                    .padding(.top, 8)
            }
        }
    }

    private func isVideo(_ rec: Recording) -> Bool {
        rec.audioFileName.lowercased().hasSuffix(".mov")
    }

    private func openExternally(_ rec: Recording) {
        if let (url, fresh) = rec.resolveAudioURL() {
            if let fresh { store.setAudioBookmark(for: rec.id, fresh) }
            NSWorkspace.shared.open(url)
            return
        }
        promptToLocate(rec)
    }

    /// Файл не найден — спрашиваем пользователя где он сейчас.
    private func promptToLocate(_ rec: Recording) {
        let alert = NSAlert()
        alert.messageText = "Файл не найден"
        alert.informativeText = "Похоже, «\(rec.title)» был перемещён, переименован или удалён. Указать его расположение вручную?"
        alert.addButton(withTitle: "Указать")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Найдите файл «\(rec.audioFileName)»"
        panel.directoryURL = rec.storageDirectoryURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        store.relocateAudio(for: rec.id, to: url)
        NSWorkspace.shared.open(url)
    }

    private func hasTopActions(_ rec: Recording) -> Bool {
        (isVideo(rec) && !rec.audioRemoved)
        || (rec.status == .done && (transcriptText?.isEmpty == false))
        || store.canRetryTranscription(rec)
    }

    // Ряд действий наверху: открыть видео / скопировать / повторить транскрибацию.
    @ViewBuilder
    private func actionsRow(for rec: Recording) -> some View {
        HStack(spacing: 8) {
            if isVideo(rec), !rec.audioRemoved {
                Button {
                    openExternally(rec)
                } label: {
                    actionButtonLabel("Открыть видео", assetName: "Play")
                }
                .buttonStyle(.bordered)
            }

            if rec.status == .done, let text = transcriptText, !text.isEmpty {
                CopyButton(text: text)
            }

            if store.canRetryTranscription(rec) {
                Button {
                    store.retryTranscription(rec)
                } label: {
                    actionButtonLabel("Расшифровать заново", assetName: "RefreshReverse")
                }
                .buttonStyle(.bordered)
                .disabled(!modelManager.isReady)
                .help(modelManager.isReady ? "" : "Доступно после загрузки модели")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func titleSection(for rec: Recording) -> some View {
        if isEditingTitle {
            TextField("Название", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.largeTitle)
                .onSubmit { commitTitle(for: rec) }
        } else {
            Text(rec.title)
                .font(.largeTitle.bold())
                .onTapGesture(count: 2) {
                    draftTitle = rec.title
                    isEditingTitle = true
                }
        }
    }

    private var playerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                .disabled(player.duration == 0)

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.01)
                )
                .disabled(player.duration == 0)

                Text("\(formatTimecode(player.currentTime)) / \(formatTimecode(player.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 100, alignment: .trailing)
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            if let err = player.loadError {
                Text("Не удалось загрузить аудио: \(err)")
                    .font(.caption)
                    .foregroundStyle(AppColors.red)
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private func transcriptSection(for rec: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch rec.status {
                case .pending:
                    statusBlock(
                        modelManager.isReady
                            ? "Ожидает расшифровки…"
                            : "Ждёт загрузки модели распознавания…",
                        isError: false,
                        showsProgress: modelManager.isReady,
                        recording: rec
                    )
                case .transcribing:
                    statusBlock("Расшифровывается…", isError: false, recording: rec)
                case .failed:
                    statusBlock("Не удалось расшифровать запись", isError: true, recording: rec)
                case .done:
                    if let text = transcriptText,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TranscriptDialogView(text: text)
                    } else if transcriptText != nil {
                        // Расшифровка прошла, но слов нет — объясняем почему, а не «недоступна».
                        noSpeechBlock(for: rec)
                    } else {
                        Text("Файл расшифровки не найден. Нажмите «Расшифровать заново».")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Пустая расшифровка: в записи не нашлось речи.
    private func noSpeechBlock(for rec: Recording) -> some View {
        Text("В записи не найдена речь")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func statusBlock(
        _ text: String,
        isError: Bool,
        showsProgress: Bool = true,
        recording rec: Recording
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if isError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(AppColors.red)
                } else if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
                Text(text).foregroundStyle(isError ? AppColors.red : .secondary)
            }
            if isError, store.canRetryTranscription(rec) {
                Button {
                    store.retryTranscription(rec)
                } label: {
                    Label("Расшифровать заново", systemImage: "arrow.clockwise")
                }
                .disabled(!modelManager.isReady)
                .help(modelManager.isReady ? "" : "Доступно после загрузки модели")
            } else if isError {
                Text("Аудио уже удалено по политике хранения — расшифровать заново не получится.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Загрузка

    private func loadAudio(for rec: Recording) {
        // AVAudioPlayer открывает .mov по аудиодорожке — отдельной ветки для видео не нужно.
        guard !rec.audioFileName.isEmpty else { return }
        guard let (url, fresh) = rec.resolveAudioURL() else { return }
        if let fresh { store.setAudioBookmark(for: rec.id, fresh) }
        player.load(url: url)
    }

    private func loadTranscript(for rec: Recording) {
        guard let (url, fresh) = rec.resolveTranscriptURL() else {
            transcriptText = nil
            return
        }
        if let fresh { store.setTranscriptBookmark(for: rec.id, fresh) }
        do {
            transcriptText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            transcriptText = nil
        }
    }

    private func commitTitle(for rec: Recording) {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.rename(rec, to: trimmed)
        }
        isEditingTitle = false
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин \(s) с" }
        return "\(s) с"
    }

    private func formatTimecode(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Лейбл action-кнопки с Mage-иконкой фиксированного размера 14pt.
    /// Все три кнопки используют этот helper → иконки одинаковой высоты, тексты на одном baseline.
    private func actionButtonLabel(_ title: String, assetName: String) -> some View {
        HStack(spacing: 6) {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
            Text(title)
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(copied ? "Check" : "Copy")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)

                // Ширина текста фиксируется по самому длинному варианту,
                // чтобы кнопка не «росла» при смене «Скопировать» → «Скопировано».
                ZStack(alignment: .leading) {
                    Text("Скопировано").hidden()
                    Text(copied ? "Скопировано" : "Скопировать")
                }
            }
        }
        .buttonStyle(.bordered)
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

/// Расшифровка как диалог: имя говорящего («Я», «Собеседник») — заголовком
/// над его репликой. Без меток — обычный текст. Сам файл не меняется.
private struct TranscriptDialogView: View {
    let text: String

    private struct Block: Identifiable {
        let id: Int
        let speaker: String?
        var body: String
    }

    private static let labels = ["Я", "Собеседник"]

    private var blocks: [Block] {
        var result: [Block] = []
        for line in text.components(separatedBy: "\n") {
            if let label = Self.labels.first(where: { line.hasPrefix($0 + ":") }) {
                let rest = line.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
                result.append(Block(id: result.count, speaker: label, body: rest))
            } else if !result.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    result[result.count - 1].body += (result[result.count - 1].body.isEmpty ? "" : "\n") + trimmed
                }
            } else {
                result.append(Block(id: 0, speaker: nil, body: line))
            }
        }
        return result
    }

    var body: some View {
        let blocks = self.blocks
        if blocks.allSatisfy({ $0.speaker == nil }) {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 4) {
                        if let speaker = block.speaker {
                            // Как в живой расшифровке: подпись 13, текст 14/20.
                            Text(speaker)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Text(block.body)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
