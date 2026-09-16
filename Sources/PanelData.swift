import Cocoa

// Turning the app's live state into the plain values the panel draws.
//
// Every rule here was in the menu builder before it was here, and the comments that explain the
// non-obvious ones came with them: which sessions are allowed to show, why a skipped limit window
// is skipped rather than zeroed, what a server's right-hand column says when it did not answer.
// The rules are the product of a lot of reported bugs; the presentation is what changed.
extension StatusController {

    // MARK: sessions

    /// The sessions a user should see, in the order they should see them.
    func panelSessions(now: Double) -> [PanelSession] {
        // Gate ONLY the desktop app: opening a conversation there seeds an idle session without
        // real activity, so a desktop session stays out until a prompt or tool fires. CLI, terminal
        // and editor sessions are launched deliberately and surface the moment they start.
        let ordered = sessions.values.sorted { $0.ts > $1.ts }.filter { s in
            let gated = s.entrypoint == "claude-desktop"
            return !gated || s.started || isActiveState(effState(s, now: now))
        }
        // Hiding is render-only — the file, and thus liveness, is untouched. The most recent
        // session is always kept, so the panel never goes empty while one is alive.
        var visible = ordered.filter { s in
            let resting = !isActiveState(effState(s, now: now))
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }
        return visible.map { panelSession($0, now: now) }
    }

    private func panelSession(_ s: Session, now: Double) -> PanelSession {
        let eff = effState(s, now: now)
        let working = isWorkingState(eff) && s.startedAt > 0
        return PanelSession(
            id: s.key,
            sessionID: s.id,
            provider: s.provider,
            name: sessionName(s),
            branch: s.branch,
            status: panelStatus(s, eff: eff),
            eff: eff,
            elapsed: working ? elapsed(max(0, (now - s.startedAt).clampedInt)) : nil,
            pct: s.pct,
            assumed: s.assumed,
            tag: SessionFormat.surfaceTag(s),
            entrypoint: s.entrypoint,
            termProgram: s.termProgram,
            termBundle: s.termBundle,
            tty: s.tty,
            // Decided here, in the model half, rather than at the click: which of the two places a
            // Codex session can be read is the right one is a rule about the session, and rules
            // about sessions are what the model checks cover.
            threadURL: SessionFormat.codexThreadURL(s),
            detail: PanelSessionDetail(
                model: s.model, dirty: s.dirty, tokens: s.tokens, window: s.window,
                cost: s.cost, duration: s.duration,
                linesAdded: s.linesAdded, linesRemoved: s.linesRemoved, cwd: s.cwd))
    }

    /// The row's own word for what the session is doing. Unlike the menu bar label, a row always
    /// says something: with thinking words switched off the bar shows no text because the icon and
    /// the timer already carry the state, but a row reading "main ·  · 14s" reads as broken.
    private func panelStatus(_ s: Session, eff: String) -> String {
        switch eff {
        case "permission": return "Needs you"
        case "thinking", "tool":
            let word = workingLabel(s).trimmingCharacters(in: CharacterSet(charactersIn: "… "))
            return word.isEmpty ? (eff == "tool" ? "Working" : "Thinking") : word
        default: return "Idle"
        }
    }

    // MARK: hooks

    /// The warning for the Sessions tab, or nil while the hooks are fine or not yet looked at.
    /// Nothing is said during the first look after launch: it takes a fraction of a second, and a
    /// "checking" line that flashes on every launch would teach the reader to ignore the block.
    func panelHooks() -> PanelHooks? {
        guard let problem = hookHealth.problem else { return nil }
        return PanelHooks(title: problem.title, reason: problem.reason, hint: problem.hint,
                          checking: hookCheckRunning)
    }

    // MARK: limits

    /// Each provider's windows, grouped, plus one line saying how old the figures are — or, when
    /// there are none at all, why.
    ///
    /// A provider with nothing to show is absent from the list rather than present and empty. An
    /// empty bar reads as "you have not used this", which is not what "not installed", "not
    /// signed in" or "last measured a week ago" mean.
    func panelLimitGroups(now: Double) -> ([PanelLimitGroup], String) {
        var sources: [(set: LimitsSet, windows: [NamedWindow], title: String, glyph: String)] = []
        // `drawable` rather than the windows as written: a window whose reset has passed since it
        // was measured reads as empty. Its old percentage is about a window that is over, and
        // for the five minutes before the next poll lands it was drawn as if it were current.
        if let claude = limits?.set, !claude.isEmpty {
            sources.append((claude, claude.drawable(at: now), "Claude", "sparkle"))
        }
        if let codex = codexWindows {
            let rows = codex.drawable(at: now)
            if !rows.isEmpty {
                sources.append((codex, rows, "Codex",
                                "chevron.left.forwardslash.chevron.right"))
            }
        }
        guard !sources.isEmpty else {
            // Empty means the poll has not succeeded yet: switched off in Settings, or Claude Code
            // is not signed in through the browser OAuth flow (a `setup-token` login lacks the
            // profile scope the endpoint wants). Saying so beats an empty strip, and beats
            // inventing a number.
            return ([], oauthLimits ? "No data yet — is Claude Code signed in?"
                                    : "Limits are switched off in Settings")
        }
        let groups = sources.map { entry -> PanelLimitGroup in
            // Account windows first, the model's own window last: 5h and 7d are what every plan
            // has, Fable is a slice of the week only some plans carry. A window the writer did not
            // report is skipped, not zeroed — the model hands over only the windows it read.
            let rows = entry.windows.map { window in
                PanelLimit(title: window.title, badge: window.badge, used: window.window.used,
                           resets: window.window.resets.flatMap { $0 > now ? Self.until($0) : nil })
            }
            let soonest = entry.windows.compactMap { $0.window.resets }.filter { $0 > now }.min()
            // Picked from the windows rather than from the rows above: the rule breaks a tie on
            // which window resets first, and a row carries its reset as "2h 10m" by then. Keys
            // are unique within a provider, so the row it names is unambiguous.
            let worst = LimitsSet.worst(entry.windows)
                .flatMap { pick in entry.windows.firstIndex { $0.key == pick.key } }
                .map { rows[$0] }
            return PanelLimitGroup(provider: entry.set.provider, title: entry.title,
                                   glyph: entry.glyph, limits: rows,
                                   resets: soonest.map { Self.until($0) },
                                   age: Self.age(of: entry.set.ts, now: now),
                                   plan: entry.set.plan, worst: worst)
        }
        // The oldest of them in the one shared line: it is the figure furthest from the truth, and
        // a footer that quotes the fresher of two sources would flatter the staler one.
        return (groups, Self.age(of: sources.map { $0.set.ts }.min() ?? 0, now: now))
    }

    /// How old a figure is, in the words the footer uses. Short: the line shares the footer with
    /// two buttons across 300pt, and "measured 4 minutes ago" truncated to "Limits measured 2…",
    /// which says nothing at all.
    static func age(of ts: Double, now: Double) -> String {
        let minutes = (now - ts).clampedInt / 60
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        // Rolled up past an hour for the same reason `until` drops the minutes past a day: a
        // Codex snapshot is allowed to be days old while its weekly window is still open, and
        // "8640 min ago" is arithmetic in a line that has to fit beside two buttons.
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }

    /// How long until a window resets. A weekly window is days away, and "76h 12m" is arithmetic
    /// the reader has to do, so past a day the minutes go.
    static func until(_ stamp: Double) -> String {
        let left = (stamp - Date().timeIntervalSince1970).clampedInt
        let hours = left / 3600
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        // Below a day this is exactly SessionFormat.elapsed, which the session card already uses:
        // the same "1h 3m" / "36m" shape, spelled once.
        return SessionFormat.elapsed(left)
    }

    /// How tall the panel's scrolling half may get, measured rather than guessed: the screen the
    /// status item is on, minus the menu bar it hangs from and the fixed chrome around the list.
    /// A constant here would be a guess about someone else's display, and when it ran long the
    /// panel's top edge got pushed up off the icon to make room.
    var panelContentCap: CGFloat {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 600)
            - Self.panelChromeHeight - panelStripExtra
        return max(PanelTheme.minContentHeight, available)
    }

    /// How much taller a second provider makes the strip than the one row the constant below
    /// assumes. Without it the list is allowed to grow into space the strip has taken, and a long
    /// session list pushes the panel's top edge up off the icon it hangs from.
    ///
    /// Two numbers rather than a measurement because the cap is computed before the strip is laid
    /// out: in rows, a second header, a second row of cells and the gap between them; in the
    /// switcher, the tabs above the one row of cells that is already counted.
    var panelStripExtra: CGFloat {
        guard limitProviderCount > 1 else { return 0 }
        return limitsLayout == .rows ? 80 : 40
    }

    /// How many providers have figures right now, asked cheaply: `panelLimitGroups` builds every
    /// row and is already called once per refresh, and the cap has no use for any of that.
    private var limitProviderCount: Int {
        var count = 0
        if let limits, !limits.isEmpty { count += 1 }
        if let codexWindows,
           !codexWindows.drawable(at: Date().timeIntervalSince1970).isEmpty { count += 1 }
        return count
    }

    /// The banner, the limits strip, the tabs and the footer, plus the gap under the menu bar.
    /// Deliberately generous: over-reserving costs a little scrolling, under-reserving costs the
    /// panel its anchor.
    static let panelChromeHeight: CGFloat = 260

    // MARK: MCP

    func panelServer(_ server: MCPServer) -> PanelServer {
        PanelServer(
            id: server.provider + ":" + server.name,
            serverName: server.name,
            provider: server.provider,
            name: mcpShortName(server.name),
            state: server.state,
            tail: serverTail(server),
            enabled: !server.disabled,
            checking: model(of: server.provider).isChecking(server.name,
                                                            backendBusy: mcpChecking),
            prefix: server.toolPrefix,
            tip: serverTip(server),
            tools: server.tools.map { tool in
                PanelTool(name: tool.name,
                          help: Self.toolHelp(tool, prefix: server.toolPrefix),
                          enabled: tool.enabled)
            })
    }

    /// Everything the old hover card said, as one string. Composed here, once per rebuild of the
    /// MCP picture, rather than in the row: a row rebuilds its body on every publish, and an
    /// expanded server with a hundred tools was re-concatenating a hundred of these a second.
    ///
    /// The identifier line carries the REAL full tool name, which is what a permissions.deny rule
    /// has to match — for a plugin or a claude.ai connector that is not the display name.
    private static func toolHelp(_ tool: MCPTool, prefix: String) -> String {
        var text = MCPServer.fullToolName(prefix: prefix, tool: tool.name)
        if !tool.doc.isEmpty { text += "\n\n" + tool.doc }
        if !tool.params.isEmpty {
            text += "\n\nParameters\n" + tool.params.map { p in
                p.name + (p.required ? "*" : "") + (p.type.isEmpty ? "" : " (\(p.type))")
                    + (p.doc.isEmpty ? "" : ": " + p.doc)
            }.joined(separator: "\n")
        }
        return text
    }

    /// What the right-hand column says for a server. A server that did not answer says so in
    /// words — a bare "!" next to a plainly-ON switch reads as a contradiction rather than an
    /// explanation, especially since "pending" here means "switched on, waiting for a new session".
    private func serverTail(_ server: MCPServer) -> String {
        let count = server.tools.isEmpty
            ? (server.reportedTools.map(String.init) ?? "—")
            : "\(server.enabledTools)/\(server.tools.count)"
        switch server.state {
        case "ok", "off": return count
        // A server from a repo's .mcp.json that Claude Code has not been told to trust yet: it is
        // not switched on and waiting, it is waiting to be allowed at all, and only the user can
        // answer that — in Claude Code, not here.
        case "pending" where server.needsApproval: return "approve in Claude Code"
        // Empty while the check runs: the spinner in this same slot is the answer, and a word
        // beside a turning arc reads as two competing statuses.
        case "pending":
            return mcp.isChecking(server.name, backendBusy: mcpChecking) ? "" : "next session"
        // A remote (http/sse) project server: there is no probe for it, and claiming either green
        // or red would be inventing.
        case "unknown": return "not checked"
        default: return "failed"
        }
    }

    private func serverTip(_ server: MCPServer) -> String {
        let name = server.name
        switch server.state {
        case "ok": return server.project.map { "\(name) — project \($0)" } ?? name
        case "pending" where server.needsApproval:
            return name + "\nConfigured in this project's .mcp.json, which came with the"
                + " repository. Claude Code asks once before trusting a server from there, and"
                + " this app does not start it — or read its tools — until you have said yes."
                + "\nRun /mcp in that project to decide."
        case "pending":
            return name + "\nSwitched on. Claude Code builds a session's list of servers when the"
                + " session starts, so one that is already open keeps what it had."
                + "\nThe tool count returns here once the check finishes."
        // The project belongs here most of all. One name is one row (settings.json addresses a
        // server by serverName alone), so when two open projects both configure a `db`, the row
        // takes the worse of the two states — and "failed" without a project name leaves the user
        // checking the wrong repository.
        default:
            return name + " · " + server.status + (server.project.map { "\nproject \($0)" } ?? "")
        }
    }

    /// The command that resets the network-volume permission, offered beside an EPERM error.
    var networkVolumeResetCommand: String {
        "tccutil reset SystemPolicyNetworkVolumes "
            + (Bundle.main.bundleIdentifier ?? "io.github.infinityscripter.claude-control-bar")
    }

    // MARK: update

    /// The banner across the top of the panel, or nil when this copy is current.
    ///
    /// The order matters and is not arbitrary: a newer copy already sitting on disk is checked
    /// before the download line and instead of it, because there is nothing left to fetch and
    /// offering "Update to 0.5.1" next to a 0.5.1 bundle sends the user to download what they
    /// installed an hour ago.
    func panelUpdate() -> PanelUpdate? {
        guard let latest = UserDefaults.standard.string(forKey: "latestVersion"),
              Self.versionIsNewer(latest, than: currentVersion) else { return nil }
        if let onDisk = installedVersion, Self.versionIsNewer(onDisk, than: currentVersion) {
            return PanelUpdate(kind: .restart, version: onDisk, stage: nil, command: nil)
        }
        if brewManaged {
            // Silent until the cask catches up (autobump lag): never offer a command that would
            // report "already up to date".
            guard let cask = UserDefaults.standard.string(forKey: "brewCaskVersion"),
                  Self.versionIsNewer(cask, than: currentVersion) else { return nil }
            return PanelUpdate(kind: .brew, version: cask, stage: nil,
                               command: brewUpgradeCommand)
        }
        return PanelUpdate(kind: .available, version: latest, stage: updateStage, command: nil)
    }
}
