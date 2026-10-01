import Cocoa

// Every mcpbar.py run, and the switches that cause one. Nothing here parses the script's output:
// it writes its file, and the models re-read it (see .claude/rules/architecture.md).

extension StatusController {
    // MARK: MCP backend

    /// Any mcpbar.py command: off the main queue, UI updated back on it. Nothing here parses the
    /// script's output — the script writes mcp.json and the model re-reads it.
    ///
    /// Serial, on backendQueue (main.swift says why).
    func runBackend(_ command: BackendCommand, then done: (() -> Void)? = nil) {
        guard !backend.script.isEmpty else {
            NSLog("ClaudeControlBar: no mcpbar.py — the bootstrap hook has not run")
            done?()
            return
        }
        backendRunning += 1
        mcpBusy = true
        backendQueue.async { [weak self] in
            guard let self else { return }
            self.spawnBackend(command)
            DispatchQueue.main.async {
                self.backendRunning = max(0, self.backendRunning - 1)
                self.mcpBusy = self.backendRunning > 0
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

    /// Refreshes coalesce: a second full check queued behind one still running buys nothing but
    /// another half-minute of every configured server being started again. It is remembered, not
    /// discarded, and runs once as soon as the current one lands.
    @objc func refreshMCP() {
        guard !refreshQueued else { refreshAgain = true; return }
        refreshQueued = true
        // Codex's list is asked for on the same occasions as Claude's, and coalesces with it for
        // the same reason: this one starts every configured Codex server to ask it for its tools,
        // which is the expensive thing a second queued check would repeat for nothing. Gated on
        // the switch AND on Codex being installed, so a Mac without it spawns nothing.
        if codexServers, codexInstalled {
            runQuietCommand(.mcpRefresh(provider: "codex"))
        }
        // Asked on the same occasions, and not gated on either Codex switch: this one explains an
        // empty Sessions tab, which is not a thing either switch turns off. It is gated on its own
        // INPUT instead, and that gate is not an optimisation: refreshes also run 2.5 s after every
        // server or tool switch, so without it a handful of clicks in the MCP tab would spawn a
        // `codex app-server` each — for an answer that can only change when a human has answered a
        // trust prompt, which is exactly what rewrites one of the two files below.
        if askCodexAboutHooks() { runQuietCommand(.codexHooks) }
        runBackend(.mcpRefresh(provider: "claude")) { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            if self.refreshAgain {
                self.refreshAgain = false
                self.refreshMCP()
            }
        }
    }

    /// One round of limit figures, one provider at a time. For Claude, mcpbar.py asks Anthropic's
    /// usage endpoint — the same one /usage in Claude Code asks — and rewrites limits.json; for
    /// Codex it reads the newest session file Codex left on disk and writes codex/limits.json.
    /// Either way the 0.4s tick picks the file up.
    ///
    /// Each has its own off switch, for different reasons: the Anthropic poll spends the user's
    /// own OAuth token, and the Codex read opens files that belong to another program.
    ///
    /// Opening the panel calls this every time, so Claude is asked only when the last question is
    /// a minute old: a burst of opens costs one request, not one each.
    func pollLimits() {
        let now = Date().timeIntervalSince1970
        if oauthLimits, now - lastLimitsPoll >= 60 { pollClaudeLimits(now: now) }
        // Not gated on the switch above, and deliberately: reading Codex's figures costs no token
        // and no request at all. Codex writes them into its own session file as it goes, and the
        // command only reads the newest one — so the only thing to opt out of is the reading.
        //
        // The stat is worth it: without it a Mac that has never run Codex — most of them — would
        // spawn a process every five minutes to be told there is nothing to read. Asked afresh
        // each poll, so installing Codex later is picked up without a restart.
        if codexLimits, codexHasRun {
            runQuietCommand(.limits(provider: "codex"))
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
    /// Claude only. Codex's figures are lifted out of its session transcript, so asking again
    /// rereads the same file for the same answer — they move when its owner runs Codex, not before.
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
        lastLimitsPoll = now
        limitsTimer?.fireDate = Date(timeIntervalSince1970: now + 300)
        runQuietCommand(.limits(provider: "claude"))
    }

    /// Run one backend command for the file it writes and nothing else. Not routed through runBackend:
    /// that toggles mcpBusy and re-reads mcp.json, and a poll that only rewrites its own file
    /// has nothing to say about either — the tick's mtime gate picks the file up.
    func runQuietCommand(_ command: BackendCommand, then done: (() -> Void)? = nil) {
        guard !backend.script.isEmpty else { done?(); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.spawnBackend(command)
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    /// Run mcpbar.py once and wait for it, off the main queue. Both runBackend and runQuietCommand
    /// come through here, so neither can die unheard: stderr and the exit code used to go to
    /// /dev/null together on the quiet path, and a backend that died on a traceback looked exactly
    /// like one that had nothing to report — every question to Codex once failed that way with a
    /// NameError, unnoticed. Read into a pipe (not inherited: a GUI process's stderr is the
    /// system log, where it is nobody's) and surfaced only on a non-zero exit, so a healthy run
    /// stays quiet.
    func spawnBackend(_ command: BackendCommand) {
        let arguments = command.arguments
        let task = Process()
        // Absolute paths: a GUI process gets a stripped PATH with no pyenv and no nvm in it.
        task.executableURL = URL(fileURLWithPath: backend.python)
        task.arguments = [backend.script] + arguments
        task.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        task.standardError = errors
        do {
            try task.run()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let text = String(data: stderr.suffix(2000), encoding: .utf8) ?? ""
                NSLog("ClaudeControlBar: mcpbar.py \(arguments.joined(separator: " ")) exited"
                      + " \(task.terminationStatus): \(text)")
            }
        } catch {
            NSLog("ClaudeControlBar: \(backend.python) failed: \(error)")
        }
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
        scheduleRecheck()
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
    func scheduleRecheck() {
        recheckTimer?.invalidate()
        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in self?.refreshMCP() }
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
