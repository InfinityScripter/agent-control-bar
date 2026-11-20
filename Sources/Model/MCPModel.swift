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

    /// What the right-hand column of the server's row says. A server that did not answer says so
    /// in words — a bare "!" next to a plainly-ON switch reads as a contradiction rather than an
    /// explanation, especially since "pending" here means "switched on, waiting for a new session".
    ///
    /// `checking` is the row's own spinner flag (MCPModel.isChecking, asked of this server's
    /// agent), handed in so the word and the spinner are decided from one answer.
    func tail(checking: Bool) -> String {
        let count = tools.isEmpty
            ? (reportedTools.map(String.init) ?? "—")
            : "\(enabledTools)/\(tools.count)"
        switch state {
        case "ok", "off": return count
        // A server from a repo's .mcp.json that Claude Code has not been told to trust yet: it is
        // not switched on and waiting, it is waiting to be allowed at all, and only the user can
        // answer that — in Claude Code, not here.
        case "pending" where needsApproval: return "approve in Claude Code"
        // Empty while the check runs: the spinner in this same slot is the answer, and a word
        // beside a turning arc reads as two competing statuses.
        case "pending": return checking ? "" : "next session"
        // A remote (http/sse) project server: there is no probe for it, and claiming either green
        // or red would be inventing.
        case "unknown": return "not checked"
        default: return "failed"
        }
    }

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

    /// The banners this change posts, down before up: one server by name, several by count, with
    /// every name in the body.
    var notifications: [(title: String, body: String)] {
        var out: [(title: String, body: String)] = []
        if !down.isEmpty {
            out.append((title: down.count == 1
                            ? "MCP: \(mcpShortName(down[0])) went down"
                            : "MCP: \(down.count) servers went down",
                        body: down.map(mcpShortName).joined(separator: ", ")))
        }
        if !up.isEmpty {
            out.append((title: up.count == 1
                            ? "MCP: \(mcpShortName(up[0])) is back"
                            : "MCP: \(up.count) servers are back",
                        body: up.map(mcpShortName).joined(separator: ", ")))
        }
        return out
    }
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

/// One switch in the panel: a server's, or one of its tools'.
private struct MCPClick: Hashable {
    let server: String
    let tool: String?
}

private struct MCPClickState {
    let enabled: Bool
    /// Switch commands for it not yet back. Only the last one to come back settles the position.
    var unanswered: Int
    /// When the last of them came back applied; nil while one is still on its way.
    var writtenAt: Double?
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

    /// Switches clicked in the panel that the file cannot be trusted to show yet, by server and,
    /// for a tool, by tool name. A re-read does not undo them: a check that read the config before
    /// the write lands after it and would put the old position back for as long as the check
    /// behind it takes. They go once a read that began after the write has landed, or the switch
    /// failed.
    private var clicks: [MCPClick: MCPClickState] = [:]

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
        for (click, state) in clicks { show(click, enabled: state.enabled) }

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
    /// would keep showing the old counts — which reads as "the switch did nothing". Held over
    /// re-reads until one from after the write lands (`clicks`); if that one disagrees, it wins.
    func setToolLocally(server: String, tool: String, enabled: Bool) {
        click(MCPClick(server: server, tool: tool), enabled: enabled)
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
        click(MCPClick(server: name, tool: nil), enabled: enabled)
    }

    /// The switch command for a click has come back. `ownRead` is whether the file it leaves
    /// behind was read after its write with no check of the agent beside it
    /// (MCPRefreshPoll.switchLanded): then that file is the answer to every click already written.
    /// A switch that was not applied drops its click, so the next re-read shows the real state.
    func switchLanded(_ command: BackendCommand, applied: Bool, ownRead: Bool, at now: Double) {
        let key: MCPClick
        switch command {
        case .toggleServer(_, let name, _): key = MCPClick(server: name, tool: nil)
        case .toggleTool(_, let server, let tool, _, _): key = MCPClick(server: server, tool: tool)
        default: return
        }
        guard var state = clicks[key] else { return }
        state.unanswered -= 1
        // A later click on the same switch is still on its way: its position stays on screen.
        if state.unanswered > 0 {
            clicks[key] = state
        } else if applied {
            state.writtenAt = now
            clicks[key] = state
            if ownRead { forgetClicks(readStartedAt: now) }
        } else {
            clicks[key] = nil
        }
    }

    /// A full check begun at `start` (uptime) and `wallStart` (the clock file times are in) has
    /// landed. Only one that rewrote the file read the config after the clicks: a check that found
    /// its agent's refresh lock busy — held by a switch's own re-read, say — exits at once and
    /// writes nothing, and the file left is the picture from before them.
    @discardableResult
    func checkLanded(startedAt start: Double, wallStart: Date) -> Bool {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date
        guard let stamp, stamp >= wallStart else { return false }
        return forgetClicks(readStartedAt: start)
    }

    /// A read that began at `start` has landed: the clicks written before it are now in the file,
    /// which re-reading shows as it is. True when any was dropped and the caller has to re-read.
    @discardableResult
    func forgetClicks(readStartedAt start: Double) -> Bool {
        let held = clicks.count
        clicks = clicks.filter { $0.value.writtenAt.map { $0 > start } ?? true }
        return clicks.count != held
    }

    private func click(_ click: MCPClick, enabled: Bool) {
        guard servers.contains(where: { $0.name == click.server }) else { return }
        clicks[click] = MCPClickState(enabled: enabled,
                                      unanswered: (clicks[click]?.unanswered ?? 0) + 1)
        show(click, enabled: enabled)
        revision += 1
    }

    private func show(_ click: MCPClick, enabled: Bool) {
        guard let s = servers.firstIndex(where: { $0.name == click.server }) else { return }
        if let tool = click.tool {
            if let t = servers[s].tools.firstIndex(where: { $0.name == tool }) {
                servers[s].tools[t].enabled = enabled
            }
        } else if !enabled {
            servers[s].state = "off"
            servers[s].status = "disabled"
        } else if servers[s].state == "off" {
            // Not "ok": switching a server back on does not reconnect it. The list of servers is
            // assembled when a session starts, so the truthful state until then is "pending".
            servers[s].state = "pending"
            servers[s].status = "on in a new session"
        }
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

/// Which agents' full MCP checks are running, and which were asked for again meanwhile.
///
/// A full check starts every configured server of its agent and takes about half a minute, so a
/// second one behind a running one buys nothing but all of that again. It is remembered, not
/// discarded, and runs once when the first lands — the run in flight started BEFORE whatever
/// prompted the second and cannot know about it.
///
/// Per agent, because the two checks share nothing: one flag for both made a click on a Claude
/// server start every Codex server too, and a slow Codex check hold back Claude's.
struct MCPRefreshPoll {
    private var running: Set<String> = []
    private var again: Set<String> = []
    /// Switch commands of each agent on their way, and the agents whose check ran beside one.
    private var switching: [String: Int] = [:]
    private var crossed: Set<String> = []

    /// The agents whose check starts now. One still being checked is remembered instead.
    mutating func begin(_ providers: Set<String>) -> Set<String> {
        again.formUnion(providers.intersection(running))
        let starting = providers.subtracting(running)
        running.formUnion(starting)
        cross(starting)
        return starting
    }

    /// This agent's check has landed. True when it was asked for again meanwhile, and is due once more.
    mutating func finish(_ provider: String) -> Bool {
        running.remove(provider)
        return again.remove(provider) != nil
    }

    /// A switch of this agent is on its way: clicked, queued or running.
    mutating func switchStarted(_ provider: String) {
        switching[provider, default: 0] += 1
        cross([provider])
    }

    /// The switch has come back. True when no check of its agent ran beside it, so the file it
    /// leaves behind was read after its write and is the truth. Otherwise it is not: the check
    /// read the config before the write, or held the lock the switch's own re-read then found
    /// busy, and the caller checks the agent once more (`refreshMCP(of:)`, which waits for a check
    /// still out).
    mutating func switchLanded(_ provider: String) -> Bool {
        cross([provider])
        let alone = !crossed.contains(provider)
        switching[provider, default: 1] -= 1
        if switching[provider] == 0 { crossed.remove(provider) }
        return alone
    }

    /// A check and a switch of the same agent out at once — at the click, started while the
    /// switch waits or runs, or still out when it lands — and the picture that check writes may be
    /// from before the write. Only marked here; the one check more is ordered as the switch lands.
    /// A check started meanwhile ordering it instead spun: Codex's finds the lock held by the
    /// switch's own re-read, exits at once, and ordered the next, until the switch came back.
    private mutating func cross(_ providers: Set<String>) {
        crossed.formUnion(providers.filter { running.contains($0) && switching[$0, default: 0] > 0 })
    }
}
