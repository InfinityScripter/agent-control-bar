import SwiftUI

struct PanelClaudeHistory: View {
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
            PanelHistorySearchField(prompt: "Search Claude history", refreshLabel: "Refresh Claude history",
                                    query: _controls.projectedValue.query,
                                    refreshing: store.snapshot.claudeHistory == .loading, refresh: refresh)
                .onChange(of: controls.query) { _ in controls.visibleCount = 8 }
            if let actionError = controls.actionError {
                PanelHistoryMessage(text: actionError)
            }
            switch store.snapshot.claudeHistory {
            case .idle, .loading:
                PanelHistoryLoading(text: "Loading Claude history…")
            case .failed:
                PanelHistoryMessage(text: "Couldn't load Claude history. Use Refresh to try again.")
            case .loaded(let history):
                results(history)
            }
        }
        .padding(.top, 8)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func results(_ history: ClaudeHistory) -> some View {
        let shownLive = Set(store.snapshot.sessions.lazy.filter { $0.provider == Provider.claude.id }.map(\.sessionID))
        let matches = history.matching(controls.query, excluding: shownLive.union(store.snapshot.hiddenLiveClaudeIDs))
        let visibleCount = controls.visibleCount
        if matches.isEmpty {
            PanelHistoryMessage(text: controls.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "No recent Claude chats match the current view."
                                : "No matches in recent Claude chats.")
        } else {
            PanelCard {
                VStack(spacing: 0) {
                    ForEach(Array(matches.prefix(visibleCount).enumerated()), id: \.element.id) { index, thread in
                        if index > 0 { PanelHairline() }
                        historyRow(thread)
                    }
                }
            }
            if matches.count > visibleCount {
                Button("Show more (\(matches.count - visibleCount))") { controls.visibleCount += 8 }
                    .buttonStyle(PanelButtonStyle())
            }
        }
        if history.hasMore {
            PanelHistoryPageNote(count: history.threads.count)
        }
    }

    private func historyRow(_ thread: ClaudeHistory.Thread) -> some View {
        let live = store.snapshot.liveClaudeIDs.contains(thread.id)
        let openLabel = live ? "Focus live session" : "Open in Claude"
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
                    if !thread.sourceLabel.isEmpty {
                        PanelTag(text: thread.sourceLabel).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help([thread.title, thread.cwd, thread.branch].filter { !$0.isEmpty }.joined(separator: "\n"))
            if live ? store.snapshot.focusableClaudeIDs.contains(thread.id) : thread.opensInDesktop {
                Button {
                    controls.actionError = store.openClaudeHistoryThread(thread)
                        ? nil : "Couldn't open this chat in Claude. Copy its resume command instead."
                } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(PanelButtonStyle())
                    .help(openLabel)
                    .accessibilityLabel("\(openLabel): \(thread.title)")
            }
            if !live, thread.resumeCommand != nil {
                let copied = controls.copiedID == thread.id
                Button {
                    controls.actionError = nil
                    controls.copiedID = store.copyClaudeResumeCommand(thread) ? thread.id : nil
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

    private func subtitle(_ thread: ClaudeHistory.Thread, live: Bool) -> String {
        let date = Date(timeIntervalSince1970: thread.updatedAt)
        return [live ? "Live" : "", thread.workspace, thread.branch, date.formatted(.relative(presentation: .named))]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func refresh() {
        controls.actionError = nil
        controls.copiedID = nil
        store.refreshClaudeHistory()
    }
}
