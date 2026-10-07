import Cocoa

// The 0.4 s tick: re-read whatever the hooks and mcpbar.py rewrote, decide, and redraw. Every
// read is behind an mtime gate, so a quiet tick costs a few stat() calls and no parse.

extension StatusController {
    func loadLimits() {
        let path = (root as NSString).appendingPathComponent("limits.json")
        // A stat per tick, not a parse: this runs from tick() at 2.5 Hz for the app's whole
        // lifetime, and the file changes every few minutes at most. Writes are atomic renames,
        // so a changed mtime always means a whole new file. The oauth toggle nils limitsMTime
        // so its source-drop decision below re-runs without waiting for a rewrite.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date
        if let stamp, stamp == limitsMTime { return }
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        limitsMTime = stamp
        // Opting out has to mean the numbers go away, not just that they stop moving. The file
        // survives the switch (the statusLine capture writes the same one), so the source is
        // what decides: figures that came from the API are dropped the moment the API is off,
        // and the section says it has no data — which is what the README promises. Anything
        // captured from statusLine is the user's own second source and stays.
        if !oauthLimits, (root["source"] as? String) == "oauth" {
            limits = nil
            return
        }
        // The parse lives in Sources/Model/Limits.swift so the model check can cover it;
        // a file with no readable window at all reads as "no data", not as zeros.
        limits = Limits(json: root)
    }

    /// Both Codex files are read on the same stat-per-tick gate as the Claude one above; the gate
    /// and what its three answers mean are in Sources/Model/StateFileGate.swift.
    func codexStateFile(at name: String, gate: inout Date?) -> StateFileLook {
        StateFileLook.at((root as NSString).appendingPathComponent(name), gate: &gate)
    }

    /// codex/limits.json.
    ///
    /// Off has to mean the figures go away rather than stop moving, exactly as it does for the
    /// Anthropic poll: the file survives the switch, so the switch is what decides.
    func loadCodexLimits() {
        guard codexLimits else {
            codexWindows = nil
            return
        }
        switch codexStateFile(at: "codex/limits.json", gate: &codexLimitsMTime) {
        case .missing: codexWindows = nil
        case .unchanged: break
        case .changed(let object): codexWindows = LimitsSet(codex: object)
        }
    }

    /// codex/hooks.json — how many of our hooks Codex is skipping for want of trust.
    ///
    /// No file means no answer rather than "all approved": the count is only ever written after
    /// Codex itself has been asked, and a machine where the command has not run yet must not be
    /// told its hooks are fine.
    func loadCodexHooks() {
        switch codexStateFile(at: "codex/hooks.json", gate: &codexHooksMTime) {
        case .missing: codexHooksUntrusted = 0; codexHooksAnswered = false
        case .unchanged: break
        case .changed(let object):
            codexHooksUntrusted = (object["untrusted"] as? NSNumber)?.intValue ?? 0
            codexHooksAnswered = true
        }
    }

    // MARK: state polling

    func tick() {
        // Whether to quit is not a four-times-a-second question — the decision behind it is
        // debounced by IdleQuit.delay anyway, so checking at this rate only bought the app a
        // steady CPU cost for an answer that cannot change meaningfully between looks.
        let now = Date().timeIntervalSince1970
        reloadSessions()
        if now - lastLifecycleCheck >= 2 {
            lastLifecycleCheck = now
            checkLifecycle()   // after the reload: sessionCount() reads the listing it just made
        }
        // Both are mtime checks against a file another process rewrites atomically, so this is
        // a stat() per tick, not a parse — the parse happens only when something actually moved.
        if mcp.reloadIfChanged() { notifyMCPChange() }
        // Codex's file is re-read on the same tick and behind the same mtime gate, but without
        // the change notification: "a server went down" is worth interrupting someone about for
        // the agent they are working in, and a second notification for the other agent's servers
        // — refreshed on our own timer, not by anything they just did — is noise.
        if codexServers { codexMCP.reloadIfChanged() }
        loadLimits()
        pollLimitsIfRolledOver(now: now)
        loadCodexLimits()
        loadCodexHooks()
        evaluate()
        // The panel is a live window, not a menu frozen at open time: the per-session clocks, the
        // limit figures and the server states all move under it. The store publishes only when
        // something actually differs, so a quiet tick costs one comparison and no redraw.
        refreshCounts()
    }

    /// The panel's limits: both agents' figures minus whichever the agent setting leaves out.
    var limitsBoard: LimitsBoard {
        agentDisplay.limits(claude: limits?.set, codex: codexWindows, forBar: false)
    }

    // Where a session's own file lives — see Provider.statePath, so the reap in evaluate()
    // cannot delete out of the wrong agent's directory.
    func statePath(of s: Session) -> String {
        Provider.statePath(provider: s.provider, id: s.id, home: NSHomeDirectory())
    }

    // Refresh `sessions` from the state directories; SessionBoard re-parses only the files whose
    // mtime changed.
    func reloadSessions() {
        let fm = FileManager.default
        let listed = Provider.stateFiles(home: NSHomeDirectory()) { dir in
            (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        }
        let files = listed.compactMap { f -> SessionBoard.File? in
            guard let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date
            else { return nil }
            return SessionBoard.File(key: f.key, path: f.path, provider: f.provider, id: f.id, mtime: m)
        }
        board.reload(files, read: { path in
            fm.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }, branch: freshBranch)
    }

    // The branch for a cwd a hook event just touched; see GitBranches.fresh.
    func freshBranch(_ cwd: String) -> String { git.fresh(cwd) }

    func playNeedsYou() {
        guard !needsYouSound.isEmpty else { return }
        if needsYouPlayer?.name != needsYouSound {
            needsYouPlayer = NSSound(named: NSSound.Name(needsYouSound))
            needsYouPlayer?.volume = NeedsYouSound.volume
        }
        needsYouPlayer?.stop()   // a second cue restarts the clip instead of being dropped
        needsYouPlayer?.play()
    }

    func evaluate() {
        let now = Date().timeIntervalSince1970
        let agents = agentDisplay
        let rules = SessionBoard.Rules(soundThreshold: soundThreshold, stalePruneAge: stalePruneAge,
                                       thinkingWords: thinkingWords, needsYou: !needsYouSound.isEmpty,
                                       leads: agents.barProviders, cues: agents.panelProviders)
        let tick = board.tick(now: now, rules: rules, pidAlive: pidAlive,
                              frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })
        // The one write this app makes into a state directory: the file of a session whose
        // process has died. The path comes from the session's provider — see statePath(of:).
        for s in tick.reaped { try? FileManager.default.removeItem(atPath: statePath(of: s)) }
        // Kept only for directories a live session still points at.
        git.keep(only: Set(sessions.values.map(\.cwd)))
        if tick.chime { completionSound?.play() }
        if tick.needsYou { playNeedsYou() }   // one cue per tick however many sessions asked at once

        renderMenuBar(now: now)
    }
}
