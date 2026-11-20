import Foundation

/// A bounded page of metadata read from Claude Code's transcripts by `mcpbar.py claude-history`.
struct ClaudeHistory: Decodable, Equatable {
    let threads: [Thread]
    let hasMore: Bool

    struct Thread: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let cwd: String
        let updatedAt: Double
        let branch: String
        let source: String

        var title: String {
            if !name.isEmpty { return name }
            return workspace.isEmpty ? "Claude session" : workspace
        }

        var workspace: String { (cwd as NSString).lastPathComponent }

        var sourceLabel: String { SessionFormat.surfaceLabel(source) }

        /// Only the desktop app can be sent to a conversation by its id; T3 Code and the editor
        /// extension need a thread or a window that only a live session records.
        var opensInDesktop: Bool { source == "app" }

        /// The command Claude Code's own picker prints for a chat from another folder. Without a
        /// folder `claude --resume` still finds the chat by searching every project.
        var resumeCommand: String? {
            guard UUID(uuidString: id) != nil else { return nil }
            if cwd.isEmpty { return "claude --resume \(id)" }
            guard let directory = HistorySearch.shellPath(cwd) else { return nil }
            return "cd \(directory) && claude --resume \(id)"
        }
    }

    func matching(_ query: String, excluding liveIDs: Set<String>) -> [Thread] {
        threads.filter { thread in
            !liveIDs.contains(thread.id) && HistorySearch.matches(
                query, in: [thread.title, thread.cwd, thread.branch, thread.id, thread.sourceLabel])
        }
    }
}

enum ClaudeHistoryState: Equatable {
    case idle, loading, failed
    case loaded(ClaudeHistory)
}
