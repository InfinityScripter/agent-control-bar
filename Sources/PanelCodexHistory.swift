import SwiftUI

struct PanelCodexHistory: View {
    @ObservedObject var store: PanelStore
    private struct Controls {
        var query = ""
        var visibleCount = 8
        var copiedID: String?
        var actionError: String?
    }
    private let _controls = State(initialValue: Controls())
    private var controls: Controls {
        get { _controls.wrappedValue }
        nonmutating set { _controls.wrappedValue = newValue }
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search Codex history", text: _controls.projectedValue.query)
                    .textFieldStyle(.plain)
                    .onChange(of: controls.query) { _ in controls.visibleCount = 8 }
                if !controls.query.isEmpty {
                    Button { controls.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filter")
                }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(store.snapshot.codexHistory == .loading)
                    .help("Refresh Codex history")
                    .accessibilityLabel("Refresh Codex history")
            }
            .font(.system(size: 11))
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            if let actionError = controls.actionError {
                message(actionError)
            }
            switch store.snapshot.codexHistory {
            case .idle, .loading:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading Codex history…").font(.system(size: 11))
                }
                .padding(.vertical, 12)
            case .failed(let upgradeRequired):
                message(upgradeRequired
                        ? "Update to a stable Codex version 0.168 or later to browse its history."
                        : "Couldn't load Codex history. Use Refresh to try again.")
            case .loaded(let history, let canOpenInCodex):
                results(history, canOpenInCodex: canOpenInCodex)
            }
        }
        .padding(.top, 8)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func results(_ history: CodexHistory, canOpenInCodex: Bool) -> some View {
        let shownLive = Set(store.snapshot.sessions.lazy.filter { $0.provider == Provider.codex.id }.map(\.sessionID))
        let matches = history.matching(controls.query, excluding: shownLive, hiding: store.snapshot.hiddenModelServices)
        let visibleCount = controls.visibleCount
        if matches.isEmpty {
            message(controls.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No recent Codex chats match the current view."
                    : "No matches in recent Codex chats.")
        } else {
            PanelCard {
                VStack(spacing: 0) {
                    ForEach(Array(matches.prefix(visibleCount).enumerated()), id: \.element.id) { index, thread in
                        if index > 0 { PanelHairline() }
                        historyRow(thread, history: history, canOpenInCodex: canOpenInCodex)
                    }
                }
            }
            if matches.count > visibleCount {
                Button("Show more (\(matches.count - visibleCount))") { controls.visibleCount += 8 }
                    .buttonStyle(PanelButtonStyle())
            }
        }
        if history.hasMore {
            Text("Search covers the \(history.threads.count) most recent entries.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    private func historyRow(_ thread: CodexHistory.Thread, history: CodexHistory,
                            canOpenInCodex: Bool) -> some View {
        let live = store.snapshot.liveCodexIDs.contains(thread.id)
        let openLabel = live ? "Focus live session" : "Open in ChatGPT"
        return HStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(subtitle(thread, live: live))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if thread.service != .openai {
                        PanelTag(text: thread.service.title).fixedSize()
                    } else if !thread.sourceLabel.isEmpty {
                        PanelTag(text: thread.sourceLabel).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help([thread.title, thread.cwd, thread.branch].filter { !$0.isEmpty }.joined(separator: "\n"))
            if live || (canOpenInCodex && thread.threadURL != nil) {
                Button {
                    controls.actionError = nil
                    store.openCodexHistoryThread(thread) { opened in
                        if !opened { controls.actionError = "Couldn't open this chat. Refresh and try again." }
                    }
                } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(PanelButtonStyle())
                    .help(openLabel)
                    .accessibilityLabel("\(openLabel): \(thread.title)")
            }
            if !live, thread.resumeCommand(codexHome: history.codexHome) != nil {
                let copied = controls.copiedID == thread.id
                Button {
                    controls.actionError = nil
                    controls.copiedID = store.copyCodexResumeCommand(thread) ? thread.id : nil
                    if controls.copiedID == nil {
                        controls.actionError = "Couldn't copy the command. Refresh and try again."
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "terminal")
                }
                .buttonStyle(PanelButtonStyle())
                .help(copied ? "Resume command copied" : "Copy resume command")
                .accessibilityLabel(copied ? "Resume command copied" : "Copy resume command for \(thread.title)")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private func subtitle(_ thread: CodexHistory.Thread, live: Bool) -> String {
        let date = Date(timeIntervalSince1970: thread.updatedAt)
        let source = thread.service == .openai ? "" : thread.sourceLabel
        return [live ? "Live" : "", thread.workspace, thread.branch, source, date.formatted(.relative(presentation: .named))]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private func refresh() {
        controls.actionError = nil
        controls.copiedID = nil
        store.refreshCodexHistory()
    }
}
