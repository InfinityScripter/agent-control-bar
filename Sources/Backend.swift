import Cocoa

// Every mcpbar.py run, and the switches that cause one. Nothing here parses the script's output:
// it writes its file, and the models re-read it (see .claude/rules/architecture.md).

extension StatusController {
    // MARK: MCP backend

    /// Any mcpbar.py command: off the main queue, UI updated back on it. Nothing here parses the
    /// script's output — the script writes mcp.json and the model re-reads it.
    ///
    /// Serial, a full check on backendQueue and a switch on switchQueue (main.swift says why).
    func runBackend(_ command: BackendCommand, then done: (() -> Void)? = nil) {
        guard !backend.script.isEmpty else {
            NSLog("ClaudeControlBar: no mcpbar.py — neither inside the app nor where paths.json points")
            done?()
            return
        }
        backendRunning += 1
        mcpBusy = true
        let switched = command.switchProvider
        // Told about the switch twice, now and when the write has landed (below). Landing is the
        // one that matters: a check that began after the click can still have read the config
        // before the write. This one is for the check that lands in the instant between the
        // script exiting and that block running — by then it no longer looks in flight.
        if let switched { mcpRefresh.switched(switched) }
        (switched == nil ? backendQueue : switchQueue).async { [weak self] in
            guard let self else { return }
            let run = self.spawnBackend(command)
            DispatchQueue.main.async {
                self.backendRunning = max(0, self.backendRunning - 1)
                self.mcpBusy = self.backendRunning > 0
                if let switched {
                    // nil for a switch that took — which is also what clears the last refusal.
                    // Not kept for a panel closed meanwhile: it would greet the next open, hours
                    // later, as if it were about something just clicked.
                    self.mcpSwitchRefusal = self.panelIsOpen ? command.refusal(run) : nil
                    self.mcpRefresh.switched(switched)
                }
                self.mcp.reloadIfChanged(force: true)
                // Both models, or the promise in the comment below holds for one agent only.
                // A refused Codex toggle leaves codex/mcp.json exactly as it was — same mtime,
                // so the tick's gated re-read sees nothing to do — and the optimistic flip sat
                // on screen looking applied until the ten-minute refresh came round. Forced,
                // because "unchanged file" is precisely the case that has to be re-read.
                self.codexMCP.reloadIfChanged(force: true)
                self.notifyMCPChange()
                // The backend's own answer has to land in the open menu too, not just the
                // optimistic guess that preceded it — otherwise a toggle the backend refused
                // would keep showing as applied.
                self.refreshCounts()
                self.evaluate()
                done?()
            }
        }
    }

    /// Both agents: the ten-minute timer, an opened panel, the Check button.
    @objc func refreshMCP() { refreshMCP(of: ["claude", "codex"]) }

    /// Refreshes coalesce, each agent's on its own (MCPRefreshPoll says why): a second full check
    /// behind one still running buys nothing but another half-minute of every configured server
    /// being started again. It is remembered, not discarded, and runs once the current one lands.
    func refreshMCP(of providers: Set<String>) {
        // Codex's check starts every configured Codex server to ask it for its tools. Gated on
        // the switch AND on Codex being installed, so a Mac without it spawns nothing.
        let wanted = codexServers && codexInstalled ? providers : providers.subtracting(["codex"])
        let starting = mcpRefresh.begin(wanted)
        guard !starting.isEmpty else { return }
        if starting.contains("codex") {
            runQuietCommand(.mcpRefresh(provider: "codex")) { [weak self] _ in
                self?.finishRefresh(of: "codex")
            }
        }
        // Asked on the same occasions, and not gated on either Codex switch: this one explains an
        // empty Sessions tab, which is not a thing either switch turns off. It is gated on its own
        // INPUT instead, and that gate is not an optimisation: refreshes also run 2.5 s after every
        // Claude server switch, so without it a handful of clicks in the MCP tab would spawn a
        // `codex app-server` each — for an answer that can only change when a human has answered a
        // trust prompt, which is exactly what rewrites one of the two files below.
        if askCodexAboutHooks() {
            runQuietCommand(.codexHooks) { [weak self] succeeded in
                // A question Codex did not answer was not asked: without this the gate holds the
                // next one back until Codex rewrites one of its two files, which may be never.
                if !succeeded { self?.codexTrustInputs = nil }
            }
        }
        if starting.contains("claude") {
            runBackend(.mcpRefresh(provider: "claude")) { [weak self] in
                self?.finishRefresh(of: "claude")
            }
        }
    }

    private func finishRefresh(of provider: String) {
        if mcpRefresh.finish(provider) { refreshMCP(of: [provider]) }
    }

    /// Current account limits, with each provider's own switch and debounce.
    func pollLimits() {
        let now = Date().timeIntervalSince1970
        pollClaudeLimits(now: now)
        pollCodexLimits(now: now)
        pollServiceUsage(now: Date(timeIntervalSince1970: now))
    }

    func pollCodexLimits(now: Double) {
        guard codexLimits, codexInstalled, codexLimitsPoll.begin(now: now) else { return }
        codexLimitsTimer?.fireDate = Date(timeIntervalSince1970: now + 300)
        runQuietCommand(.limits(provider: "codex")) { [weak self] _ in
            self?.codexLimitsPoll.finish()
            self?.loadCodexLimits()
            self?.loadCodexLimitsStatus()
            self?.refreshCounts()
        }
    }

    /// Ask again the moment a window rolls over, rather than waiting out the five-minute timer.
    ///
    /// The figures are right when they are written and wrong the instant a window resets: 94% a
    /// minute before the weekly rollover is ~0% a minute after it. On the timer alone the bars
    /// spent up to five minutes showing a nearly full bar at the exact moment the truth was
    /// "empty" — the largest error this app can make, made at every single reset. The panel draws
    /// such a window empty meanwhile; this is what keeps "meanwhile" down to a couple of seconds.
    ///
    /// Claude's rollover check; Codex refreshes on its own five-minute timer and panel opens.
    /// Which rollovers count at all is decided in the model, where the check covers it — see
    /// LimitsSet.rolledOver(since:at:), which already makes one rollover ask for one reading
    /// rather than one per tick.
    ///
    /// The minute on top of that is for the one case it cannot see: a poll already on its way.
    /// Its answer lands a second or two after the request, and until it does, the file still
    /// describes the window that just ended. Launch is exactly that — pollLimits() fires as the
    /// app starts, and the tick 0.4 s later reads a file written before the machine was last
    /// closed, every window in it long since rolled over. Without the minute that is a second
    /// request for the answer already coming.
    func pollLimitsIfRolledOver(now: Double) {
        guard oauthLimits, now - lastLimitsPoll >= 60,
              let newest = limits?.set.rolledOver(since: rolledOverHandled, at: now)
        else { return }
        rolledOverHandled = newest
        pollClaudeLimits(now: now)
    }

    /// Ask Anthropic now and push the five-minute timer back to count from this question, so a
    /// poll made on opening the panel is not followed seconds later by the timer's own.
    func pollClaudeLimits(now: Double) {
        guard oauthLimits, now - lastLimitsPoll >= 60 else { return }
        lastLimitsPoll = now
        limitsTimer?.fireDate = Date(timeIntervalSince1970: now + 300)
        runQuietCommand(.limits(provider: "claude"))
    }

    /// Run one backend command for the file it writes and nothing else. Not routed through runBackend:
    /// that toggles mcpBusy and re-reads mcp.json, and a poll that only rewrites its own file
    /// has nothing to say about either — the tick's mtime gate picks the file up.
    func runQuietCommand(_ command: BackendCommand, then done: ((Bool) -> Void)? = nil) {
        guard !backend.script.isEmpty else { done?(false); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let succeeded = self.spawnBackend(command).succeeded
            if let done { DispatchQueue.main.async { done(succeeded) } }
        }
    }

    func pollCodexAttention(now: Double) {
        // The same path mcpbar_codex.py connects to. Only its presence is asked here; whether it
        // is a socket of ours that is safe to talk to stays the script's question.
        let socket = (codexHome as NSString)
            .appendingPathComponent("app-server-control/app-server-control.sock")
        guard codexAttentionPoll.begin(now: now, sessions: Array(sessions.values),
                                       socketExists: { FileManager.default.fileExists(atPath: socket) },
                                       pidAlive: pidAlive) else { return }
        runQuietCommand(.codexAttention) { [weak self] _ in
            guard let self else { return }
            self.codexAttentionPoll.finish()
            self.loadCodexAttention()
            self.evaluate()
            self.refreshCounts()
        }
    }

    func refreshCodexHistory() {
        guard codexHistory != .loading else { return }
        codexHistory = .loading
        refreshCounts()
        runQuietCommand(.codexHistory) { [weak self] succeeded in
            guard let self else { return }
            let path = (self.root as NSString).appendingPathComponent("codex/history.json")
            let history = succeeded ? FileManager.default.contents(atPath: path)
                .flatMap { try? JSONDecoder().decode(CodexHistory.self, from: $0) } : nil
            if let history, history.error == nil {
                let canOpen = history.codexHome == self.codexHome
                    && NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleID) != nil
                self.codexHistory = .loaded(history, canOpenInCodex: canOpen)
            } else {
                self.codexHistory = .failed(upgradeRequired: history?.error == "upgrade_required")
            }
            self.refreshCounts()
        }
    }

    /// Run mcpbar.py once and wait for it, off the main queue. Both runBackend and runQuietCommand
    /// come through here, so neither can die unheard: stderr and the exit code used to go to
    /// /dev/null together on the quiet path, and a backend that died on a traceback looked exactly
    /// like one that had nothing to report — every question to Codex once failed that way with a
    /// NameError, unnoticed. Surfaced only when the run did not exit 0, so a healthy run stays
    /// quiet.
    ///
    /// Every run has a deadline (BackendCommand.deadline), and the caller is answered either way.
    /// Only the attention poll had one: any other run that never returned kept the serial queue,
    /// and whichever of "checking", "loading" or "approving" was waiting on it, until the app was
    /// restarted. HookInstall.run collects stderr in a file because a pipe is read to EOF, and
    /// EOF waits for every holder of the write end — the server a stopped script had started
    /// would have kept this thread exactly where the deadline was meant to free it.
    @discardableResult
    func spawnBackend(_ command: BackendCommand) -> HookInstall.Run {
        let backend = self.backend
        let arguments = command.arguments
        // Absolute paths: a GUI process gets a stripped PATH with no pyenv and no nvm in it.
        let run = HookInstall.run(backend.python, [backend.script] + arguments,
                                  timeout: command.deadline, errorsOnly: true)
        let words = arguments.joined(separator: " ")
        if run.end == .timedOut, case .codexAttention = command {
            // Not in problems.log: this one is asked every five seconds, and a socket that has
            // stopped answering would add a line to that file each time for as long as it lasts.
            NSLog("ClaudeControlBar: Codex attention poll exceeded its deadline")
        } else if run.end == .timedOut {
            logProblem("mcpbar.py \(words) was stopped after \(Int(command.deadline)) s without finishing")
        } else if !run.succeeded {
            NSLog("ClaudeControlBar: mcpbar.py \(words) \(HookInstall.describe(run)):"
                  + " \(run.output.suffix(2000))")
        }
        return run
    }

    /// Re-publish the panel's picture if it is on screen. The menu needed a list of closures for
    /// this, because NSMenu would not let rows be added or removed while it tracked and the only
    /// thing that could move was the text already in them. A window has no such rule: the store
    /// re-reads, and only a real difference redraws anything.
    func refreshCounts() {
        if panelIsOpen { panelStore.refresh() }
        if settingsWindow?.isVisible == true { settingsStore.refresh() }
    }

    /// Which model holds a provider's servers. One place, so a new provider cannot be half-wired.
    func model(of provider: String) -> MCPModel { provider == "codex" ? codexMCP : mcp }

    func setMCPServer(_ name: String, provider: String = "claude", enabled: Bool) {
        // Two agents, two configs, two commands. The provider comes off the row the user
        // clicked rather than being guessed from the name: the same server name can be
        // configured in both agents, and asking Claude to switch off Codex's copy would edit
        // the wrong file and leave the row lying about what happened.
        model(of: provider).setServerLocally(name, enabled: enabled)
        runBackend(.toggleServer(provider: provider, name: name, on: enabled))
        // Claude's switch only patches mcp.json, so something has to go and ask the servers.
        // Codex's command ends in its own full re-read: a recheck on top of it started every
        // Codex server a second time for the same click.
        if provider != "codex" { scheduleRecheck() }
        // Last, not first: the row draws a spinner while a check is running or ordered, so it has
        // to be redrawn after the work is on its way rather than before.
        refreshCounts()
    }

    /// Whether anything is being worked out right now — a backend run in flight, or one already
    /// ordered and counting down. What the spinner on a server row is allowed to claim.
    var mcpChecking: Bool { mcpBusy || (recheckTimer?.isValid ?? false) }

    /// A toggle leaves the row spinning, and something has to go and check. Waiting for
    /// the ten-minute timer meant a server switched back on sat unresolved long enough to read as
    /// broken. Debounced, because flipping several servers in a row should cost one check, not one
    /// each — a full check re-runs `claude mcp list` and a tools/list round trip per server.
    /// Claude's check alone: only a Claude switch asks for it, and Codex's servers are not its
    /// business.
    func scheduleRecheck() {
        recheckTimer?.invalidate()
        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.refreshMCP(of: ["claude"])
        }
        // .common, so it fires while the menu is open — which is exactly when toggles happen.
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    /// The rule goes first for an older mcpbar.py, which reads exactly one positional argument;
    /// `--server`/`--tool` is what a current one uses, because only it can turn a display name
    /// into the spelling Claude Code actually uses inside a tool name. Building the rule here was
    /// the bug: for a plugin or a claude.ai connector it produced `mcp__claude.ai Figma__…`,
    /// which matches no tool at all — the switch went off and the tool kept loading.
    func setMCPTool(server: String, tool: String, prefix: String, provider: String = "claude",
                    enabled: Bool) {
        // Local first, then the backend. Rewriting settings.json and re-deriving the whole picture
        // takes long enough that the counts would sit stale until the panel is reopened, which
        // reads as the switch having done nothing. No recheck is scheduled, unlike a server
        // toggle: a tool moving in or out of the context does not change which servers answered.
        model(of: provider).setToolLocally(server: server, tool: tool, enabled: enabled)
        refreshCounts()
        runBackend(.toggleTool(provider: provider, server: server, tool: tool, prefix: prefix,
                               on: enabled))
    }

    @objc func openSettingsJSON() { openConfig(of: "claude") }

    /// The file where THIS agent's servers are configured. The button used to be a fixed path to
    /// settings.json, which for a Codex row opens a file that has nothing to do with it.
    func openConfig(of provider: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath:
            Provider.named(provider).configFile(home: NSHomeDirectory())))
    }

    /// Whether it is worth spawning `codex app-server` to ask which hooks it trusts.
    ///
    /// Yes on the first refresh of a run, yes whenever Codex has rewritten either file the answer
    /// depends on — its hook list, and the config where the approved hashes live — and yes while
    /// our own answer file is missing, so a deleted one is re-made rather than waited for. No the
    /// rest of the time: nothing else can change the answer, and the question costs a process.
    func askCodexAboutHooks() -> Bool {
        guard codexInstalled else { return false }
        let answered = (root as NSString).appendingPathComponent("codex/hooks.json")
        guard FileManager.default.fileExists(atPath: answered) else { return true }
        let stamps = ["hooks.json", "config.toml"].map { name -> String in
            let path = (codexHome as NSString).appendingPathComponent(name)
            let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
                as? Date
            return date.map { String($0.timeIntervalSince1970) } ?? "-"
        }.joined(separator: "|")
        if stamps == codexTrustInputs { return false }
        codexTrustInputs = stamps
        return true
    }
}
