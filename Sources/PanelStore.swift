import Combine
import SwiftUI

// What the panel draws, as plain values, plus the actions its controls perform.
//
// The panel is SwiftUI and the app's state lives on an NSObject that a 2.5 Hz timer rewrites, so
// something has to stand between them. This is that something, and it is deliberately a SNAPSHOT
// rather than a set of bindings the way SettingsStore is: a setting is one value a control owns,
// while this is a picture assembled from three sources (state.d, limits.json, mcp.json) that
// changes under the panel while it is open.
//
// Publishing only on a real change is the whole point of making these types Equatable. Without it
// every tick would redraw the panel four times a second whether or not a single figure moved —
// which is the one thing the old menu never did, because NSMenu would not let it.
final class PanelStore: ObservableObject {
    private weak var controller: StatusController?

    @Published private(set) var snapshot = PanelSnapshot()
    /// Which tab is showing. Held here rather than in the view so it survives the panel closing:
    /// someone who went to MCP to switch a server off expects to still be there next time.
    @Published var tab: PanelTab = .sessions
    /// The rows whose detail is expanded, by row id. Cleared when the panel closes.
    @Published var expanded: Set<String> = []

    /// The chosen pets' frames, by provider. Not in the snapshot and not published: a decoded
    /// picture is not a value to compare 2.5 times a second, and what actually changes — which pet
    /// was picked — is `snapshot.petID` and `snapshot.codexPetID`, whose change redraws the rows.
    private var petAtlases: [String: PetAtlas] = [:]

    /// The pet a row of this provider draws, or nil where there is none to draw.
    func petAtlas(of provider: String) -> PetAtlas? { petAtlases[provider] }

    /// What the cached MCP half was built from. Rebuilding it is by far the most expensive thing
    /// a refresh can do — every server and every tool, ~1100 allocations on a machine with a dozen
    /// servers — and at 2.5 Hz almost every refresh would rebuild a picture that had not moved,
    /// including while the Sessions tab is showing and nothing reads it at all.
    private struct MCPKey: Equatable {
        let revision: Int
        let checking: Bool
        let showingChange: Bool
    }
    private var mcpKey: MCPKey?
    private var mcpCache = PanelMCP()

    /// The update banner minus its progress text. `panelUpdate()` reads the installed bundle's
    /// Info.plist off disk to answer "is a newer copy already here", which must not happen 2.5
    /// times a second; only the stage moves that fast, and it is filled in per refresh.
    private var updateBase: PanelUpdate?

    init(controller: StatusController) { self.controller = controller }

    /// Re-read everything and publish if anything moved. Called from the tick while the panel is
    /// open, and once as the panel opens.
    func refresh() {
        guard let controller else { return }
        let key = MCPKey(revision: controller.mcp.revision,
                         checking: controller.mcpChecking,
                         showingChange: controller.mcp.freshChange() != nil)
        if mcpKey != key {
            mcpCache = PanelMCP(controller)
            mcpKey = key
        }
        // Both agents, every refresh: the controller keeps them by pet id, so the common case of
        // one pet for both is one atlas asked for twice rather than two decoded pictures.
        petAtlases = ["claude": controller.petAtlas(of: "claude"),
                      "codex": controller.petAtlas(of: "codex")].compactMapValues { $0 }
        let next = PanelSnapshot(controller, mcp: mcpCache, update: stagedUpdate(controller))
        if next != snapshot { snapshot = next }
    }

    /// Re-asks the disk questions the banner depends on. Called when the panel opens, which is the
    /// only moment a bundle could have been replaced without this process noticing.
    func refreshUpdateBase() {
        updateBase = controller?.panelUpdate()
    }

    private func stagedUpdate(_ c: StatusController) -> PanelUpdate? {
        guard let base = updateBase else { return nil }
        return PanelUpdate(kind: base.kind, version: base.version,
                           stage: c.updateStage, command: base.command)
    }

    /// Both switches are pure forwards: the controller answers the click locally before the
    /// backend has caught up and republishes, so the switch moves under the finger rather than at
    /// the end of a check that takes half a minute. Nothing here writes to the MCP model — that
    /// direction is closed off in .claude/rules/architecture.md.
    func setServer(_ server: PanelServer, enabled: Bool) {
        controller?.setMCPServer(server.serverName, provider: server.provider, enabled: enabled)
    }

    func setTool(server: PanelServer, tool: String, enabled: Bool) {
        controller?.setMCPTool(server: server.serverName, tool: tool, prefix: server.prefix,
                               provider: server.provider, enabled: enabled)
    }

    /// The switcher's pick. Written through the controller like every other setting, so the
    /// choice is remembered between opens, and republished at once so the strip moves under the
    /// finger rather than at the next tick.
    func selectLimitsProvider(_ provider: String) {
        controller?.applyLimitsProvider(provider)
        refresh()
    }

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Every open starts collapsed. Here rather than at the call site so the store owns what is
    /// open, and the window does not reach in to reset it.
    func collapseAll() { expanded.removeAll() }

    /// The waiting-for-authorisation list is expandable like any row, so it uses the same set
    /// rather than a second piece of state with its own animation gate. No server can collide
    /// with it: a server id is its name, and a name never contains a space.
    static let waitingAuthID = "waiting for authorisation"

    func openSession(_ session: PanelSession) {
        controller?.closePanel()
        controller?.openSession(session.sessionID, threadURL: session.threadURL,
                                entrypoint: session.entrypoint,
                                termProgram: session.termProgram, termBundle: session.termBundle,
                                tty: session.tty)
    }

    func openClaude() {
        controller?.closePanel()
        controller?.openClaude()
    }

    func checkMCPNow() { controller?.refreshMCP() }
    /// Stays open: the block the button sits in is what reports the answer.
    func checkHooks() { controller?.checkHooks() }
    /// Both stay open for the same reason — the block is the answer. Revealing the hooks file does
    /// bring the Finder forward, which closes the panel by itself; nothing is closed here, so a
    /// user who cancels out of the Finder still has the block in front of them.
    func approveCodexHooks() { controller?.approveCodexHooks() }
    func revealCodexHooks() { controller?.revealCodexHooks() }
    func openSettingsJSON() { controller?.closePanel(); controller?.openSettingsJSON() }
    func openSettings() { controller?.closePanel(); controller?.openSettingsWindow() }
    func openNotificationSettings() { controller?.closePanel(); controller?.openNotificationSettings() }
    func openFilesPrivacySettings() { controller?.closePanel(); controller?.openFilesPrivacySettings() }
    func showWhatsNew() { controller?.closePanel(); controller?.showWhatsNewLatest() }
    func quit() { controller?.quit() }

    /// The banner's own action, one per shape. The panel stays open for `.available`: the download
    /// reports its progress into the banner, and closing the panel would hide the only thing that
    /// says the click landed.
    func installUpdate() { controller?.installLatestUpdate() }
    func restartIntoInstalled() { controller?.closePanel(); controller?.restartIntoInstalledCopy() }

    /// The `tccutil` line that clears this app's network-volume decision, and the button that
    /// hands it over. Not run for the user: it resets a privacy decision, and that is theirs to
    /// make in a terminal they can read first.
    var resetCommand: String { controller?.networkVolumeResetCommand ?? "" }
    func copyResetCommand() { copyToPasteboard(resetCommand) }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - the picture

enum PanelTab: String, CaseIterable, Identifiable {
    case sessions, mcp

    var id: String { rawValue }
    var title: String { self == .sessions ? "Sessions" : "MCP" }
    /// Both are SF Symbols the app already relies on elsewhere; nothing is bundled for them.
    var icon: String { self == .sessions ? "terminal" : "powerplug" }
}

/// How the strip shows more than one provider. A setting rather than a decision taken here
/// because the two answers are both right and for different people: someone watching two agents
/// at once wants both rows on screen, someone who mostly uses one wants the figures big and the
/// other provider one click away. With a single provider the two look identical — there is
/// nothing to stack and nothing to switch between — so the setting only starts to mean anything
/// once Codex has figures of its own.
enum PanelLimitsLayout: String, CaseIterable, Identifiable {
    case rows, switcher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rows:     return "Two rows"
        case .switcher: return "Switcher"
        }
    }

    var detail: String {
        switch self {
        case .rows:
            return "Both providers at once, one row each. Everything is on screen; the strip is"
                + " twice as tall."
        case .switcher:
            return "One provider at a time, picked at the top of the strip. The figures get the"
                + " full width; the other provider is one click away."
        }
    }
}

/// One provider's windows, with the two things a header has to say about them: when the first of
/// them resets, and how old the figures are.
struct PanelLimitGroup: Equatable, Identifiable {
    /// "claude" or "codex" — also what the switcher stores, so the pick survives a provider
    /// having no figures for a while rather than jumping to the other one for good.
    let provider: String
    let title: String
    /// The SF Symbol beside the name. Providers are told apart by glyph everywhere in the panel.
    let glyph: String
    let limits: [PanelLimit]
    /// "2h 10m" until the first of these windows resets; nil when none of them said.
    let resets: String?
    /// "just now", "4 min ago" — how old this provider's figures are.
    let age: String
    /// The subscription the windows belong to, when the writer knew it. Codex reports one.
    let plan: String?
    /// The window that runs out first: what the switcher's tab draws under the provider's name,
    /// and the only figure a one-line summary of a provider can honestly carry. Chosen in
    /// PanelData, where the reset times are still numbers — at equal fullness the window that
    /// comes back sooner is the one that bites, and by here the resets are worded strings.
    let worst: PanelLimit?

    var id: String { provider }

    /// What the group's tooltip says: who, on what plan, measured when.
    var tip: String {
        [title, plan, "measured " + age].compactMap { $0 }.joined(separator: " · ")
    }
}

struct PanelSnapshot: Equatable {
    /// The panel's width, still the `boxWidth` knob in uiconfig.json that the menu honoured. It is
    /// read per refresh because the file is meant to be edited while the app runs.
    var width: CGFloat = PanelTheme.width
    /// How tall the scrolling half may get on the screen this panel opens on.
    var contentCap: CGFloat = PanelTheme.minContentHeight
    var sessions: [PanelSession] = []
    /// True when there is no live session but the desktop app is up — the panel offers a way back
    /// in rather than showing an empty tab.
    var offerOpenClaude = false
    /// True when Codex is skipping this app's hooks for want of trust AND no Codex session is
    /// showing. Both halves matter: the missing rows are the symptom a reader is looking at, and
    /// without the second half the line would appear beside Codex rows that are plainly there —
    /// which happens while one hook of the set is still waiting to be approved.
    var codexHooksBlocked = false
    /// How many of this app's hooks Codex is still skipping. Shown as a number because it is the
    /// one thing that makes the block checkable against what Codex itself puts on screen: a review
    /// screen listing eight and a panel saying eight are the same fact, and a panel that only said
    /// "some" would leave the reader to wonder whether it meant theirs.
    var codexHooksUntrusted = 0
    /// True while the block's own Approve is running.
    var codexHooksChecking = false
    /// What is wrong with this app's own hooks, when something is. Every row in the Sessions tab
    /// comes out of files those hooks write, so without this a failed install looked exactly like
    /// a machine with nothing running on it. Shown whether or not rows are there: a node that broke
    /// mid-session leaves the rows it already had, frozen, and they need the explanation too.
    var hooks: PanelHooks?
    /// One entry per provider that has figures. A provider with none is absent rather than
    /// drawn empty: an empty bar reads as "you have not used it", which is not what "no data"
    /// means.
    var limitGroups: [PanelLimitGroup] = []
    /// Why the strip is empty, or how old its figures are. One line, always present.
    var limitsNote = ""
    /// How the strip stacks the groups, and which one the switcher is showing — the remembered
    /// pick already resolved against the groups there are, see LimitsBoard.showing.
    var limitsLayout: PanelLimitsLayout = .rows
    var limitsProvider = "claude"
    /// Which pet the session rows draw, or "" for none — one per agent. In the snapshot rather
    /// than read from the setting at the row, so the whole panel changes pets in one redraw
    /// instead of row by row.
    var petID = ""
    var codexPetID = ""
    var mcp = PanelMCP()
    var update: PanelUpdate?
    var notificationsDenied = false
}

struct PanelSession: Equatable, Identifiable {
    /// "<provider>:<id>" — unique across agents, which is what a list identity has to be.
    let id: String
    /// The agent's own session id, which is what its own app answers to on a click.
    let sessionID: String
    /// "claude" or "codex". Only the rows of a second agent carry a visible pill: with Codex
    /// absent there is nothing to tell apart, and a "CLAUDE" pill on every row of a
    /// Claude-only panel is noise that pushes the branch name out of the line.
    let provider: String
    let name: String
    let branch: String
    /// "Thinking…", "Working…", "Needs you", or "Idle" — the row's own words for its state.
    let status: String
    let eff: String
    /// The live clock, present only while the session is working.
    let elapsed: String?
    let pct: Int?
    let assumed: Bool
    let tag: String
    let entrypoint: String
    let termProgram: String
    let termBundle: String
    /// The session's controlling terminal. Carried to the click so it can focus that exact window
    /// and tab; "" for anything not running in one.
    let tty: String
    /// Where a click should land when the session's own agent can open the conversation itself:
    /// only Codex's desktop app has such a link, and only for sessions it is the right place for.
    /// Nil means the ordinary rules apply — raise the terminal or the editor it runs in.
    let threadURL: URL?
    let detail: PanelSessionDetail

    var working: Bool { isWorkingState(eff) }

    /// The branch, what it is doing, and how long it has been doing it — the three things the old
    /// row carried across its width, now on one line under the name. Here rather than in the row
    /// because the text dump has to say the same sentence, and two spellings of it drift.
    var subtitle: String {
        [branch, status, elapsed].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// The hooks warning: what is wrong, why, and what usually fixes it.
struct PanelHooks: Equatable {
    let title: String
    let reason: String
    let hint: String?
    /// A look is running right now, so the button says so instead of offering another.
    let checking: Bool
}

/// What the row cannot carry, shown when the row is expanded: the same blocks the hover card drew.
struct PanelSessionDetail: Equatable {
    var model = ""
    var dirty: Int?
    var tokens: Int?
    var window: Int?
    var cost: Double?
    var duration: Int?
    var linesAdded: Int?
    var linesRemoved: Int?
    var cwd = ""
}

struct PanelLimit: Equatable, Identifiable {
    let title: String
    /// The short capsule after the name — only Fable has one, and only to say its window is weekly.
    /// It doubles as "this is the model's window, not the account's", which is what earns it a
    /// tint of its own; a separate flag saying the same thing was one bit stored twice.
    let badge: String?
    let used: Int
    /// "1h 3m" until the window resets; nil when the writer did not know.
    let resets: String?

    var id: String { title }
    var fraction: Double { Double(used) / 100 }
}

struct PanelMCP: Equatable {
    /// Servers that answered, out of the servers that are switched on. The tab badge and the
    /// section title show the same pair — they used to be one string parsed back apart, and the
    /// badge counted every row instead, so the header said 10 of 11 while the tab said 10/15.
    var live = 0
    var visible = 0
    var toolsLine = ""
    /// What moved in the last 45 seconds, already worded. nil once it has aged out.
    var change: String?
    var changeIsBad = false
    var groups: [PanelServerGroup] = []
    var waitingAuth: [String] = []
    var error: String?
    /// An EPERM error is macOS's network-volume permission in practice, and it has its own fix.
    var errorIsPermission = false
    var checking = false
    var summary: String { "\(live) of \(visible) connected" }
    var isEmpty: Bool { groups.isEmpty && waitingAuth.isEmpty && error == nil }

    /// How many server rows precede a group, so a staggered entrance counts down the whole list.
    func rowsBefore(group index: Int) -> Int {
        groups.prefix(index).reduce(0) { $0 + $1.servers.count }
    }
}

struct PanelServerGroup: Equatable, Identifiable {
    let id: String
    let title: String
    let servers: [PanelServer]
}

struct PanelServer: Equatable, Identifiable {
    /// "<provider>:<name>". The provider is in here because both agents can have a server of the
    /// same name, and a list identity that collides makes SwiftUI reuse the wrong row.
    let id: String
    /// The full name, which is what the agent's own config addresses and what the toggle passes
    /// back — never the shortened display name.
    let serverName: String
    /// Which agent configures this server. The switch is routed by it: the two are asked to
    /// change their own config by entirely different commands.
    let provider: String
    let name: String
    let state: String
    /// The right-hand column: a tool count, or the reason there is no count.
    let tail: String
    let enabled: Bool
    let checking: Bool
    let prefix: String
    let tip: String
    let tools: [PanelTool]
}

struct PanelTool: Equatable, Identifiable {
    let name: String
    /// Everything the hover card used to say, composed once here rather than on every redraw of
    /// every visible row: the real full tool name, what it does, and its parameters.
    let help: String
    let enabled: Bool

    var id: String { name }
}

/// The one banner the panel is allowed to show above the tabs, in the three shapes an out-of-date
/// copy can take: a release to fetch, one already on disk waiting for a restart, and a Homebrew
/// install where the fetching is brew's job and ours is to hand over the command.
struct PanelUpdate: Equatable {
    enum Kind: Equatable { case available, restart, brew }

    let kind: Kind
    let version: String
    /// "Downloading… 43%" while an install is running; nil when it has not started.
    let stage: String?
    /// The brew command to copy. Only `.brew` carries one.
    let command: String?
}

// MARK: - assembling it

extension PanelSnapshot {
    /// The MCP half and the update banner are handed in rather than built here: both are cached by
    /// the store, because both answer questions that cost far more than a tick is worth (walking
    /// every server and tool; reading the installed bundle's Info.plist off disk).
    init(_ c: StatusController, mcp: PanelMCP, update: PanelUpdate?) {
        let now = Date().timeIntervalSince1970
        width = c.boxWidth
        contentCap = c.panelContentCap
        sessions = c.panelSessions(now: now)
        offerOpenClaude = sessions.isEmpty && c.desktopRunning
        // Asked of every session this app knows about, not of the rows above: a Codex session that
        // has simply been resting longer than the hide-idle age is missing from the list too, and
        // saying "hidden — approve its hooks" about THAT one names the wrong cause entirely. Once
        // Codex writes down a session at all, its hooks are running, whatever else is unapproved.
        codexHooksBlocked = c.codexHooksUntrusted > 0
            && !c.sessions.values.contains { $0.provider == "codex" }
        codexHooksUntrusted = c.codexHooksUntrusted
        codexHooksChecking = c.codexHooksChecking
        hooks = c.panelHooks()
        (limitGroups, limitsNote) = c.panelLimitGroups(now: now)
        limitsLayout = c.limitsLayout
        limitsProvider = LimitsBoard.showing(c.limitsProvider, among: limitGroups.map(\.provider))
            ?? c.limitsProvider
        petID = c.petID
        codexPetID = c.codexPetID
        self.mcp = mcp
        self.update = update
        notificationsDenied = c.notificationsDenied
    }
}

extension PanelMCP {
    init(_ c: StatusController) {
        // Taken once. `MCPModel.visible` filters the server array on every read, and the four
        // figures below used to ask for it four times — five throwaway arrays per refresh, each
        // copy retaining every server's nested tool list.
        // Both agents in one picture. Concatenated rather than merged by name: two agents can
        // have a server of the same name, and they are two different servers.
        let shown = c.mcp.visible + (c.codexServers ? c.codexMCP.visible : [])
        live = shown.filter { $0.state == "ok" }.count
        visible = shown.count
        // Short on purpose: the header has to fit a title, this, and two buttons across 300pt,
        // and "440 of 440 tools on" wrapped the title onto a second line.
        let on = shown.reduce(0) { $0 + $1.liveTools }
        let total = shown.reduce(0) { $0 + max($1.tools.count, $1.reportedTools ?? 0) }
        toolsLine = "\(on)/\(total) tools"
        if let moved = c.mcp.freshChange() {
            change = Self.wording(moved)
            changeIsBad = !moved.down.isEmpty
        }
        checking = c.mcpChecking
        let all = c.mcp.servers + (c.codexServers ? c.codexMCP.servers : [])
        groups = mcpGroups.compactMap { group in
            let servers = all
                .filter { $0.source == group.key }
                .sorted { $0.name < $1.name }
                .map { c.panelServer($0) }
            return servers.isEmpty ? nil : PanelServerGroup(id: group.key, title: group.title,
                                                            servers: servers)
        }
        waitingAuth = c.mcp.waitingAuth.map(mcpShortName)
        // Both, joined, rather than one masking the other: when `claude mcp list` and Codex's
        // app-server fail at the same moment — a network volume unmounted, a machine asleep —
        // showing one reason and discarding the other sends the user looking in one place for a
        // problem that is in two. Claude's comes first; its failure is the one that can empty
        // the whole tab.
        let reasons = [c.mcp.error, c.codexServers ? c.codexMCP.error : nil].compactMap { $0 }
        error = reasons.isEmpty ? nil : reasons.joined(separator: " · ")
        // Asked of whichever reason carries it: the buttons this unlocks reset THIS app's
        // network-volume decision, and that decision is the app's, not one agent's.
        errorIsPermission = reasons.contains { $0.contains("EPERM")
            || $0.localizedCaseInsensitiveContains("operation not permitted") }
    }

    /// The same sentence the menu's "changed:" row carried, minus its layout.
    private static func wording(_ change: MCPChange) -> String {
        var parts: [String] = []
        if !change.down.isEmpty { parts.append("↓ " + change.down.map(mcpShortName).joined(separator: ", ")) }
        if !change.up.isEmpty { parts.append("↑ " + change.up.map(mcpShortName).joined(separator: ", ")) }
        if !change.appeared.isEmpty { parts.append("+\(change.appeared.count) server") }
        if !change.vanished.isEmpty { parts.append("−\(change.vanished.count) server") }
        if change.toolDelta != 0 {
            parts.append("\(change.toolDelta > 0 ? "+" : "−")\(abs(change.toolDelta)) tools")
        }
        return parts.joined(separator: "   ")
    }
}
