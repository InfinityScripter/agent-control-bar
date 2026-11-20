import Cocoa

// Turning the app's live state into the plain values the panel draws.
//
// Every rule here was in the menu builder before it was here, and the comments that explain the
// non-obvious ones came with them: which sessions are allowed to show, why a skipped limit window
// is skipped rather than zeroed, what a server's right-hand column says when it did not answer.
// The rules are the product of a lot of reported bugs; the presentation is what changed.
// Two of them have since moved to the model half, where the model check holds them: which sessions
// show (SessionRows) and the server column (MCPServer.tail).
extension StatusController {

    // MARK: sessions

    /// The sessions a user should see, in the order they should see them.
    func panelSessions(now: Double) -> [PanelSession] {
        // Which sessions, and in what order, is decided in the model — see SessionRows. It reads
        // the effective state off the session, so one read since the last tick gets its state here.
        let known = sessions.mapValues { session -> Session in
            var s = session
            s.eff = effState(s, now: now)
            return s
        }
        return SessionRows.visible(Array(known.values), now: now, agents: agentDisplay,
                                   hiding: hiddenModelServices, stalePruneAge: stalePruneAge)
            .compactMap { known[$0] }
            .map { panelSession($0, now: now) }
    }

    private func panelSession(_ s: Session, now: Double) -> PanelSession {
        let eff = effState(s, now: now)
        let working = isWorkingState(eff) && s.startedAt > 0
        return PanelSession(
            id: s.key,
            sessionID: s.id,
            version: s.version,
            provider: s.provider,
            name: sessionName(s),
            branch: s.branch,
            status: panelStatus(s, eff: eff),
            eff: eff,
            asyncQuestion: s.asyncQuestion,
            elapsed: working ? elapsed(max(0, (now - s.startedAt).clampedInt)) : nil,
            pct: s.pct,
            assumed: s.assumed,
            tag: SessionFormat.surfaceTag(s),
            canOpen: SessionFormat.canOpen(s),
            // Decided here, in the model half, rather than at the click: which of the two places a
            // Codex session can be read is the right one is a rule about the session, and rules
            // about sessions are what the model checks cover.
            threadURL: SessionFormat.codexThreadURL(s),
            detail: PanelSessionDetail(
                model: s.model, dirty: s.dirty, tokens: s.tokens, window: s.window,
                cost: s.cost, duration: s.duration,
                linesAdded: s.linesAdded, linesRemoved: s.linesRemoved, cwd: s.cwd),
            modelService: s.modelService)
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

    var panelAccountUsage: [ModelService: ServiceUsageBoard.Status] {
        Dictionary(uniqueKeysWithValues: ServiceUsageBoard.services.compactMap { service in
            let status = serviceUsage[service].status
            guard !hiddenModelServices.contains(service), status.hasKey else { return nil }
            return (service, status)
        })
    }

    /// Each provider's windows, grouped, plus one line saying how old the figures are — or, when
    /// there are none at all, why.
    ///
    /// A provider with nothing to show is absent from the list rather than present and empty. An
    /// empty bar reads as "you have not used this", which is not what "not installed", "not
    /// signed in" or "last measured a week ago" mean.
    func panelLimitGroups(now: Double) -> ([PanelLimitGroup], String) {
        // Which providers appear, and with which windows, is decided in the model — see
        // LimitsBoard. What is left here is how the panel names and dates them.
        let sources = limitsBoard.shown(at: now)
        guard !sources.isEmpty else {
            // Empty means the poll has not succeeded yet: switched off in Settings, or Claude Code
            // is not signed in through the browser OAuth flow (a `setup-token` login lacks the
            // profile scope the endpoint wants). Saying so beats an empty strip, and beats
            // inventing a number.
            if !showsAccountLimits(for: Provider.claude.id) {
                guard showsAccountLimits(for: Provider.codex.id) else { return ([], "No visible account limits") }
                return ([], codexLimits ? "No Codex limit data yet" : "Codex limits are switched off in Settings")
            }
            return ([], LimitsStatus.emptyStripText(limitsStatus, oauthLimits: oauthLimits))
        }
        let odds = resetOddsOn ? resetOdds : nil
        let groups = sources.map { entry -> PanelLimitGroup in
            let agent = Provider.named(entry.set.provider)
            // Account windows first, the model's own window last: 5h and 7d are what every plan
            // has, Fable is a slice of the week only some plans carry. A window the writer did not
            // report is skipped, not zeroed — the model hands over only the windows it read. A
            // session the spent week blocks reads as the Usage window shows it: empty, no line,
            // the week's reset. The account sidecar is re-read on every tick, for the same plan.
            let account = usage.files.accounts[entry.set.provider]
            let rows = entry.set.usable(entry.windows, account: account, now: now).map { window in
                PanelLimit(title: window.title, badge: window.badge, used: window.window.used,
                           resets: window.window.resets.flatMap { $0 > now ? Self.until($0) : nil },
                           remaining: window.window.remaining,
                           timeLeft: window.timeLeftPercent(at: now), pace: window.pace(at: now))
            }
            let soonest = entry.windows.compactMap { $0.window.resets }.filter { $0 > now }.min()
            // Picked from the windows rather than from the rows above: the rule breaks a tie on
            // which window resets first, and a row carries its reset as "2h 10m" by then. Keys
            // are unique within a provider, so the row it names is unambiguous.
            let worst = LimitsSet.worst(entry.windows)
                .flatMap { pick in entry.windows.firstIndex { $0.key == pick.key } }
                .map { rows[$0] }
            return PanelLimitGroup(provider: agent.id, title: agent.title, glyph: agent.glyph,
                                   limits: rows,
                                   resets: soonest.map { Self.until($0) },
                                   age: LimitsNote.age(of: entry.set.ts, now: now),
                                   plan: entry.set.plan, worst: worst, source: entry.set.source,
                                   earlyReset: odds?.product(agent.id)?.p24
                                       .map { "Early reset chance in 24h: \($0)% (whenreset.app)" })
        }
        return (groups, LimitsNote.footer(groups.map { (title: $0.title, age: $0.age) }))
    }

    /// The block over the strip when the last poll brought no figures, or nil while there is
    /// nothing to explain.
    func panelLimitsNotice(now: Double, provider: String = "claude") -> PanelLimitsNotice? {
        guard showsAccountLimits(for: provider) else { return nil }
        let codex = provider == "codex"
        return LimitsStatus.notice(codex ? codexLimitsStatus : limitsStatus,
                                   oauthLimits: codex ? codexLimits : oauthLimits,
                                   figuresTs: codex ? codexWindows?.ts : limits?.ts, now: now, provider: provider)
            .map { PanelLimitsNotice(title: $0.title, hint: $0.hint, offerSignIn: $0.offerSignIn) }
    }

    private func showsAccountLimits(for provider: String) -> Bool {
        agentDisplay.inPanel(provider) && !hiddenModelServices.contains(.native(for: provider))
    }

    static func age(of ts: Double, now: Double) -> String {
        LimitsNote.age(of: ts, now: now)
    }

    // MARK: reset odds

    /// nil while the switch is off, so the card is absent rather than empty.
    func panelResetOdds(now: Double) -> PanelResetOdds? {
        guard resetOddsOn, !hiddenModelServices.isSuperset(of: [.anthropic, .openai]) else { return nil }
        let look = ResetOddsLook(odds: resetOdds, fetchedAt: resetOddsFetchedAt, problem: resetOddsProblem, now: now)
        let rows = look.products.filter { !hiddenModelServices.contains(.native(for: $0.id)) }
            .map { Self.resetOddsRow($0, agent: Provider.named($0.id), now: now) }
        return PanelResetOdds(state: look.state, rows: rows, stale: look.stale, note: look.note)
    }

    static func resetOddsRow(_ p: ResetOddsProduct, agent: Provider, now: Double) -> PanelResetOddsRow {
        PanelResetOddsRow(provider: agent.id, title: agent.title, glyph: agent.glyph,
                          p24: p.p24, p48: p.p48, p7d: p.p7d,
                          lastReset: ResetOddsFeed.lastReset(p.lastRegular, now: now),
                          counts: ResetOddsFeed.countsLine(total: p.total, last30d: p.last30d),
                          banked: ResetOddsFeed.bankedLine(banked: p.lastBanked, regular: p.lastRegular))
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
        // The reset-odds card sits above the scrolling half too, one line folded and a block per
        // provider unfolded.
        let open = panelStore.expanded.contains(PanelStore.resetOddsID)
        let odds = panelVisibility.chance
            ? panelResetOdds(now: Date().timeIntervalSince1970)?.cardHeight(open: open) ?? 0 : 0
        let accounts: CGFloat = panelVisibility.limits ? panelAccountUsage.values.reduce(0) { height, status in
            if case .ready(let data, _) = status { return height + 29 + CGFloat(data.metrics.count * 18) }
            return height + 54
        } : 0
        guard panelVisibility.limits,
              limitsBoard.shown(at: Date().timeIntervalSince1970).count > 1 else { return odds + accounts }
        return odds + accounts + (limitsLayout == .rows ? 97 : 40)
    }

    /// The banner, the limits strip, the tabs and the footer, plus the gap under the menu bar.
    /// Deliberately generous: over-reserving costs a little scrolling, under-reserving costs the
    /// panel its anchor.
    static let panelChromeHeight: CGFloat = 277

    // MARK: MCP

    func panelServer(_ server: MCPServer) -> PanelServer {
        // Asked once, of the server's own agent: the spinner and the word beside it share a slot,
        // and when the word was asked of Claude's model alone, a Codex server just switched on
        // turned its spinner next to "next session".
        let checking = model(of: server.provider).isChecking(server.name, backendBusy: mcpChecking)
        return PanelServer(
            id: server.provider + ":" + server.name,
            serverName: server.name,
            provider: server.provider,
            name: mcpShortName(server.name),
            state: server.state,
            tail: server.tail(checking: checking),
            enabled: !server.disabled,
            checking: checking,
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
    /// Which of them, and in what order they are checked, is decided in
    /// Sources/Model/UpdateOffer.swift. A Homebrew install whose cask has not caught up gets no
    /// banner: there is nothing in it to click yet.
    func panelUpdate() -> PanelUpdate? {
        switch updateOffer() {
        case .none, .brewPending:
            return nil
        case .restart(let version):
            return PanelUpdate(kind: .restart, version: version, stage: nil, command: nil)
        case .brew(let version):
            return PanelUpdate(kind: .brew, version: version, stage: nil, command: brewUpgradeCommand)
        case .available(let version):
            return PanelUpdate(kind: .available, version: version, stage: updateStage, command: nil)
        }
    }
}
