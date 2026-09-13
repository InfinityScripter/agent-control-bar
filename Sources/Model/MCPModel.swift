import Cocoa

// The MCP half of the app: what servers exist, whether they answered, which of their tools are
// still in Claude's context, and what moved since the last look.
//
// Nothing here talks to a server. The picture is assembled by scripts/mcpbar.py — `claude mcp
// list` for liveness, a JSON-RPC tools/list round trip for names, descriptions and parameters,
// ~/.claude/settings.json for what the user switched off — and lands in mcp.json. This file only
// reads that.

struct MCPParam {
    let name: String
    let type: String
    let required: Bool
    let doc: String
}

struct MCPTool {
    let name: String
    let doc: String
    let params: [MCPParam]
    /// A denied tool is not merely blocked at call time — Claude Code drops it from the context
    /// entirely, so this is the flag that decides whether it costs tokens at all.
    /// Mutable so a click can be answered before the backend has finished thinking about it.
    var enabled: Bool
}

struct MCPServer {
    let name: String
    /// How Claude Code spells this server INSIDE a tool name — `mcp__<toolPrefix>__<tool>`, which
    /// is what a permissions.deny rule has to match. Not the display name: a claude.ai connector
    /// travels under its uuid and `plugin:claude-mem:mcp-search` under
    /// `plugin_claude-mem_mcp-search`. Resolved by mcpbar.py, which is the side that can see the
    /// transcripts and the desktop cache, and carried here rather than recomputed — the second
    /// copy of that logic is exactly what produced rules that matched nothing.
    let toolPrefix: String
    var state: String   // ok | failed | pending | off | unknown (remote project server, unprobed)
    let source: String  // user | claude.ai | plugin | project | codex | codex-plugin
    /// Which agent configures this server: "claude" or "codex". A switch on the row is routed by
    /// this — the two agents are asked to change their own config by completely different
    /// commands, and a file written before Codex existed has to keep reading as Claude's.
    let provider: String
    /// The Codex plugin a server arrived with, "" for one declared in config.toml. Carried
    /// because the setting for a plugin server lives in the plugin's own table, and writing to
    /// the ordinary path would create a second, empty server of the same name instead of
    /// changing this one.
    let plugin: String
    /// The project a local/project-scoped server belongs to. These exist only for the session
    /// working in that directory — the row has to say which one, or two sessions in different
    /// projects read the menu as contradicting itself.
    let project: String?
    /// A `.mcp.json` server the user has not approved in Claude Code yet. It shares the pending
    /// state with "switched on, waiting for a new session", and the two need opposite advice.
    let needsApproval: Bool
    var status: String
    /// What the server itself reported at startup. Can exceed `tools.count`: the count comes from
    /// the server's own stderr, the names from a separate probe that some servers refuse.
    let reportedTools: Int?
    var tools: [MCPTool]

    var disabled: Bool { state == "off" }
    var enabledTools: Int { tools.filter(\.enabled).count }
    /// Tools actually reaching Claude. Falls back to the reported count when names are unknown,
    /// because "12" beats "—" for a server that plainly has tools.
    var liveTools: Int { tools.isEmpty ? (reportedTools ?? 0) : enabledTools }

    /// The one spelling of a full tool name. Every consumer — the deny rule, the hover card —
    /// goes through here: hand-assembling `mcp__…__…` at a call site is how a display name
    /// ends up where a toolPrefix belongs, twice now (the deny rule in 0.5.0, the card in 0.5.3).
    static func fullToolName(prefix: String, tool: String) -> String { "mcp__\(prefix)__\(tool)" }
}

/// What moved between two reads. Drives both the notification and the "it changed" marker in the
/// menu — the user asked to see that a count moved, not just its new value.
struct MCPChange {
    let at: Date
    let up: [String]
    let down: [String]
    let appeared: [String]
    let vanished: [String]
    let toolDelta: Int

    var isEmpty: Bool {
        up.isEmpty && down.isEmpty && appeared.isEmpty && vanished.isEmpty && toolDelta == 0
    }
    /// Servers falling over is news worth interrupting for. A tool count moving is not — the user
    /// usually moved it themselves, one click ago, in this very menu.
    var deservesNotification: Bool { !up.isEmpty || !down.isEmpty }
}

private struct MCPSnapshot {
    let states: [String: String]
    let enabledTools: Int

    func diff(to next: MCPSnapshot, at now: Date) -> MCPChange {
        // Only servers present in BOTH reads can be said to have risen or fallen; one that just
        // appeared has no previous state to have moved from.
        let common = Set(states.keys).intersection(next.states.keys)
        return MCPChange(
            at: now,
            up: common.filter { states[$0] != "ok" && next.states[$0] == "ok" }.sorted(),
            down: common.filter { states[$0] == "ok" && next.states[$0] != "ok" }.sorted(),
            appeared: Set(next.states.keys).subtracting(states.keys).sorted(),
            vanished: Set(states.keys).subtracting(next.states.keys).sorted(),
            toolDelta: next.enabledTools - enabledTools)
    }
}

final class MCPModel {
    /// How long a change stays visible in the menu after it happened.
    static let changeWindow: TimeInterval = 45

    /// Bumped every time the picture behind this model moves — a re-read that found something
    /// different, or a switch answered locally. It exists so a reader can tell "nothing changed"
    /// without walking every server and tool to find out: the panel refreshes 2.5 times a second
    /// and the answer is almost always no.
    private(set) var revision = 0

    private(set) var servers: [MCPServer] = []
    private(set) var waitingAuth: [String] = []
    private(set) var checkedAt: Double = 0
    private(set) var error: String?
    private(set) var change: MCPChange?

    private let path: String
    private var mtime: Date?
    private var previous: MCPSnapshot?

    init(path: String) { self.path = path }

    var visible: [MCPServer] { servers.filter { !$0.disabled } }
    var live: Int { visible.filter { $0.state == "ok" }.count }
    var toolsOn: Int { visible.reduce(0) { $0 + $1.liveTools } }
    /// Everything the enabled servers offer, including what the user muted — the denominator the
    /// "N of M tools" line needs.
    var toolsTotal: Int {
        visible.reduce(0) { $0 + max($1.tools.count, $1.reportedTools ?? 0) }
    }

    /// The change worth showing right now, or nil once it has aged out.
    func freshChange(now: Date = Date()) -> MCPChange? {
        guard let change, !change.isEmpty,
              now.timeIntervalSince(change.at) < MCPModel.changeWindow else { return nil }
        return change
    }

    /// Re-read only when the file actually changed. Returns true when anything moved, so the
    /// caller can redraw without diffing again. Writes are atomic renames, so a bumped mtime
    /// always means a whole new file — never a torn read.
    @discardableResult
    func reloadIfChanged(force: Bool = false) -> Bool {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date
        guard force || stamp != mtime else { return false }
        mtime = stamp
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        checkedAt = root["checked_at"] as? Double ?? 0
        waitingAuth = root["auth"] as? [String] ?? []
        error = root["error"] as? String
        servers = (root["servers"] as? [[String: Any]] ?? []).map(Self.server(from:))

        let snapshot = MCPSnapshot(
            states: Dictionary(servers.map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a }),
            enabledTools: toolsOn)
        // The first read has nothing to compare against: announcing every server as "appeared" on
        // launch would fire a notification storm for a picture that was already true.
        if let previous {
            let moved = previous.diff(to: snapshot, at: Date())
            if !moved.isEmpty { change = moved }
        }
        previous = snapshot
        revision += 1
        return true
    }

    /// Answer the click now, before the backend has caught up. Flipping a tool means rewriting
    /// ~/.claude/settings.json and re-deriving the whole picture, and until that lands the menu
    /// would keep showing the old counts — which reads as "the switch did nothing". The backend's
    /// own result overwrites this a moment later; if it disagrees, its version wins.
    func setToolLocally(server: String, tool: String, enabled: Bool) {
        guard let s = servers.firstIndex(where: { $0.name == server }),
              let t = servers[s].tools.firstIndex(where: { $0.name == tool }) else { return }
        servers[s].tools[t].enabled = enabled
        revision += 1
    }

    /// Whether this server's row should show a spinner instead of a state.
    ///
    /// Both halves matter. "pending" alone is not enough: a server can sit pending for reasons no
    /// check will resolve — an authorisation nobody has granted — and an arc turning next to work
    /// nobody is doing claims progress that is not happening. A running backend alone is not
    /// enough either: the servers that already answered are not being waited on.
    func isChecking(_ name: String, backendBusy: Bool) -> Bool {
        guard backendBusy else { return false }
        return servers.first(where: { $0.name == name })?.state == "pending"
    }

    func setServerLocally(_ name: String, enabled: Bool) {
        guard let s = servers.firstIndex(where: { $0.name == name }) else { return }
        // Not "ok": switching a server back on does not reconnect it. The list of servers is
        // assembled when a session starts, so the truthful state until then is "pending".
        servers[s].state = enabled ? "pending" : "off"
        servers[s].status = enabled ? "on in a new session" : "disabled"
        revision += 1
    }

    /// The one door into the parser for the model checks: the reader half of the python→swift
    /// seam is this function, and a private one could only be tested through a temp file.
    static func parse(server raw: [String: Any]) -> MCPServer { self.server(from: raw) }

    private static func server(from raw: [String: Any]) -> MCPServer {
        let denied = Set(raw["deniedTools"] as? [String] ?? [])
        let docs = raw["toolDocs"] as? [String: String] ?? [:]
        let params = raw["toolParams"] as? [String: [[String: Any]]] ?? [:]
        let tools = (raw["toolNames"] as? [String] ?? []).map { name in
            MCPTool(
                name: name,
                doc: docs[name] ?? "",
                params: (params[name] ?? []).map {
                    MCPParam(
                        name: $0["name"] as? String ?? "",
                        type: $0["type"] as? String ?? "",
                        required: $0["required"] as? Bool ?? false,
                        doc: $0["description"] as? String ?? "")
                },
                enabled: !denied.contains(name))
        }
        let name = raw["name"] as? String ?? "?"
        return MCPServer(
            name: name,
            toolPrefix: raw["toolPrefix"] as? String ?? name,
            state: raw["state"] as? String ?? "failed",
            source: raw["source"] as? String ?? "user",
            provider: raw["provider"] as? String ?? "claude",
            plugin: raw["plugin"] as? String ?? "",
            project: raw["project"] as? String,
            needsApproval: raw["needsApproval"] as? Bool ?? false,
            status: raw["status"] as? String ?? "",
            reportedTools: raw["tools"] as? Int,
            tools: tools)
    }
}

/// Servers grouped the way they are configured, because that is where the user goes to change
/// them: a plugin server is fixed in the plugin, a project one lives in the repo's .mcp.json.
/// Codex's two come last and name their agent: with both agents on screen "Local config" alone
/// would not say whose, and the two Codex groups are separate because the user changes them in
/// different places — its config.toml versus a plugin's own manifest.
let mcpGroups: [(key: String, title: String)] = [
    ("user", "Local config"),
    ("claude.ai", "claude.ai connectors"),
    ("plugin", "From plugins"),
    ("project", "Project"),
    ("codex", "Codex · config.toml"),
    ("codex-plugin", "Codex · plugins"),
]

/// Drops the bookkeeping prefix: "claude.ai Figma" -> "Figma", "plugin:figma:figma" -> "figma".
func mcpShortName(_ name: String) -> String {
    if name.hasPrefix("claude.ai ") { return String(name.dropFirst("claude.ai ".count)) }
    if name.hasPrefix("plugin:") { return String(name.split(separator: ":").last ?? "") }
    return name
}

func mcpGlyph(_ state: String) -> String {
    switch state {
    case "ok": return "●"
    case "failed": return "✗"
    case "pending": return "⏸"
    case "off": return "○"
    default: return "◌"
    }
}

func mcpTint(_ state: String) -> NSColor {
    switch state {
    case "ok": return .systemGreen
    case "failed": return .systemRed
    case "off": return .tertiaryLabelColor
    default: return .systemOrange
    }
}
