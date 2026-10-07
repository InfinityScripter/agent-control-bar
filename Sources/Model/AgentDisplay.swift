/// Which agents the app shows: the one setting that decides whose sessions and limits reach the
/// menu bar icon, and whose rows, limits and servers the panel lists.
///
/// An enum and not a string like a session's provider, because this value is never written by a
/// hook: it is the user's pick, saved by this app and read back by it, so there is no second
/// language to keep in step with.
enum AgentDisplay: String, CaseIterable, Identifiable {
    case claude
    case codex
    case both
    /// The menu bar keeps only its icon: no status, no timer, no limit bars. The panel still lists
    /// both agents — it is the only place left to look, and a click on the icon is a deliberate ask.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .both: return "Both"
        case .hidden: return "Hidden"
        }
    }

    /// What applies when nothing has been picked: whatever the app showed before the setting
    /// existed. That was both agents, which on a Mac without Codex is Claude alone — so the
    /// default reads "Claude Code" there, and "Both" on a Mac where Codex is installed and its
    /// sessions were already in the list. An update must not quietly take away rows somebody was
    /// using. Resolved on every read and never saved, so installing Codex later behaves the way it
    /// did before this setting: its sessions simply show up.
    static func resolve(saved: String?, codexInstalled: Bool) -> AgentDisplay {
        if let saved, let pick = AgentDisplay(rawValue: saved) { return pick }
        return codexInstalled ? .both : .claude
    }

    /// The providers whose sessions and limits the menu bar icon reads.
    var barProviders: Set<String> {
        switch self {
        case .claude: return [Provider.claude.id]
        case .codex: return [Provider.codex.id]
        case .both: return Set(Provider.all.map(\.id))
        case .hidden: return []
        }
    }

    /// The providers the panel lists. Hidden is about the menu bar only; see the case above.
    var panelProviders: Set<String> {
        self == .hidden ? Set(Provider.all.map(\.id)) : barProviders
    }

    func inBar(_ provider: String) -> Bool { barProviders.contains(provider) }
    func inPanel(_ provider: String) -> Bool { panelProviders.contains(provider) }

    /// Both limit sets, with the ones this pick leaves out taken away, so the rules in LimitsBoard
    /// — which bars the icon draws, which groups the strip lists — see only what may be shown.
    func limits(claude: LimitsSet?, codex: LimitsSet?, forBar: Bool) -> LimitsBoard {
        let shows = forBar ? barProviders : panelProviders
        return LimitsBoard(claude: shows.contains(Provider.claude.id) ? claude : nil,
                           codex: shows.contains(Provider.codex.id) ? codex : nil)
    }
}
