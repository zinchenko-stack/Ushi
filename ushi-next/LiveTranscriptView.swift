//
//  LiveTranscriptView.swift
//  UshiNext
//
//  Живая расшифровка на экране записи. Как в мессенджерах: пока окно Ushi
//  не на виду (ты в Zoom), новые реплики копятся, а когда возвращаешься —
//  над первой непрочитанной стоит черта «Новое» и список прокручен к ней.
//

import SwiftUI

struct LiveTranscriptPanel: View {
    let live: LiveTranscript
    @Environment(\.controlActiveState) private var activeState
    /// Индекс первой непрочитанной реплики на момент возвращения. nil — черты нет.
    @State private var dividerAt: Int?
    @State private var isOnScreen = false

    private var isWatching: Bool { isOnScreen && activeState != .inactive }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if live.turns.isEmpty {
                        Text("Текст разговора появится здесь примерно через полминуты.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(live.turns.enumerated()), id: \.offset) { index, turn in
                        if index == dividerAt {
                            newDivider.id("new")
                        }
                        turnView(turn)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                isOnScreen = true
                cameBack(proxy)
            }
            .onDisappear {
                isOnScreen = false
                markSeen()
            }
            .onChange(of: activeState) { _, state in
                if state == .inactive { markSeen() } else { cameBack(proxy) }
            }
            .onChange(of: live.turns.count) { _, count in
                // Смотришь прямо сейчас — новое сразу считается прочитанным.
                guard isWatching else { return }
                live.seenCount = count
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func cameBack(_ proxy: ScrollViewProxy) {
        guard isWatching else { return }
        let seen = live.seenCount
        if seen > 0, seen < live.turns.count {
            dividerAt = seen
            DispatchQueue.main.async { proxy.scrollTo("new", anchor: .top) }
        } else {
            dividerAt = nil
            DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        live.seenCount = live.turns.count
    }

    private func markSeen() {
        live.seenCount = live.turns.count
    }

    private var newDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(height: 1)
            Text("Новое")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(height: 1)
        }
    }

    private func turnView(_ turn: LiveTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let speaker = turn.speaker {
                    Text(speaker)
                }
                Text(live.startDate.addingTimeInterval(turn.start), format: .dateTime.hour().minute())
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(turn.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
