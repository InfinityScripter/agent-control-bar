import Foundation

/// A bounded page of metadata from Codex's local thread index.
struct CodexHistory: Decodable, Equatable {
    let threads: [Thread]
    let hasMore: Bool
    let error: String?
    let codexHome: String?

    struct Thread: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let cwd: String
        let updatedAt: Double
        let branch: String
        let source: String
        private let modelService: String?

        var service: ModelService { ModelService(reported: modelService, agent: Provider.codex.id) }

        var title: String {
            if !name.isEmpty { return name }
            return workspace.isEmpty ? "Codex session" : workspace
        }

        var workspace: String { (cwd as NSString).lastPathComponent }

        var sourceLabel: String { SessionFormat.surfaceLabel(source) }

        var threadURL: URL? {
            guard UUID(uuidString: id) != nil else { return nil }
            return SessionFormat.codexThreadURL(id: id)
        }

        func resumeCommand(codexHome: String?) -> String? {
            guard UUID(uuidString: id) != nil, let codexHome,
                  let home = HistorySearch.shellPath(codexHome), let directory = HistorySearch.shellPath(cwd)
            else { return nil }
            return "CODEX_HOME=\(home) codex resume --cd \(directory) \(id)"
        }
    }

    func matching(_ query: String, excluding liveIDs: Set<String>,
                  hiding hiddenServices: Set<ModelService> = []) -> [Thread] {
        threads.filter { thread in
            guard !liveIDs.contains(thread.id), !hiddenServices.contains(thread.service) else { return false }
            return HistorySearch.matches(
                query, in: [thread.title, thread.cwd, thread.branch, thread.id, thread.sourceLabel, thread.service.title])
        }
    }
}

enum CodexHistoryState: Equatable {
    case idle, loading
    case failed(upgradeRequired: Bool)
    case loaded(CodexHistory, canOpenInCodex: Bool)
}
