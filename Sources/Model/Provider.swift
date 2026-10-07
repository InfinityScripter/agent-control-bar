import Foundation

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

/// A session file as listed on disk, before its mtime is read.
struct StateFileEntry: Equatable {
    /// "<provider>:<id>": the two agents mint their ids independently, and the dictionaries keyed
    /// by this must not be able to mix them up.
    let key: String
    let path: String
    let provider: String
    let id: String
}

extension Provider {
    /// The session files currently on disk, both agents' (ignores the .tmp files mid-write).
    /// `list` is a directory listing; a directory that cannot be read lists as empty.
    static func stateFiles(home: String, list: (String) -> [String]) -> [StateFileEntry] {
        all.flatMap { agent in
            let provider = agent.id, dir = agent.stateDir(home: home)
            return list(dir)
                .filter { $0.hasSuffix(".json") }
                .map { name in
                    let id = (name as NSString).deletingPathExtension
                    return StateFileEntry(key: provider + ":" + id,
                                          path: (dir as NSString).appendingPathComponent(name),
                                          provider: provider, id: id)
                }
        }
    }

    /// Where a session's own file lives — the one place that turns a session back into a path, so
    /// the reap cannot delete out of the wrong agent's directory.
    static func statePath(provider: String, id: String, home: String) -> String {
        (named(provider).stateDir(home: home) as NSString).appendingPathComponent(id + ".json")
    }
}
