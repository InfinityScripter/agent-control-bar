/// What tells one agent apart from the other, in one place. The id is the string the hooks write
/// into every file ("claude" or "codex"), and it stays a string on the data itself — see
/// Session.provider — so a third agent needs a third value here, not a synchronized enum edit.
struct Provider: Equatable {
    let id: String
    let title: String
    /// The SF Symbol the panel tells the agents apart by — in the limits strip and on session rows.
    let glyph: String
    private let stateDirPath: String
    private let configPath: String

    static let claude = Provider(id: "claude", title: "Claude", glyph: "sparkle",
                                 stateDirPath: ".claude/control-bar/state.d",
                                 configPath: ".claude/settings.json")
    /// Codex's sessions are written by the same two hooks with `--provider codex`, into a directory
    /// of their own: the Claude contract has its own reap rules, and a stray Codex file in state.d
    /// would be cleaned up by rules meant for somebody else.
    static let codex = Provider(id: "codex", title: "Codex",
                                glyph: "chevron.left.forwardslash.chevron.right",
                                stateDirPath: ".claude/control-bar/codex/state.d",
                                configPath: ".codex/config.toml")
    static let all = [claude, codex]

    /// A file without a known provider is Claude's: it was written before Codex existed.
    static func named(_ id: String) -> Provider { all.first { $0.id == id } ?? claude }

    /// Where the hooks write this agent's session files.
    func stateDir(home: String) -> String { home + "/" + stateDirPath }

    /// The file where this agent's MCP servers are configured.
    func configFile(home: String) -> String { home + "/" + configPath }
}
