import Cocoa

// Installing the session hooks and keeping an eye on them — at launch, on a retry timer, and from
// the buttons in the panel and Settings. The verdicts and the node search are in
// Sources/Model/HookInstall.swift; this file runs them and keeps the state they report.

extension StatusController {
    // MARK: hooks

    /// Installs the hooks, then makes sure the node they call starts. At launch, again on a timer
    /// while that keeps failing, when the panel opens on an empty Sessions tab, and whenever
    /// someone presses the button in the panel or in Settings.
    ///
    /// The installer runs on every launch, not once per version. It is idempotent — it compares
    /// and writes nothing when nothing differs — and it is also what reclaims the hooks when the
    /// plugin channel goes away, which is not a version change at all. A version gate got this
    /// exactly backwards: remove the hooks by hand (or have another install remove them) and the
    /// app would never put them back, because UserDefaults still said "done".
    ///
    /// And a failure is a state, not a log line. This used to spawn the installer with `try?`,
    /// never read how it ended, and leave the next attempt to the next launch. A node that died in
    /// dyld therefore looked like a finished install, and the Sessions tab said "No session
    /// running" for as long as the app stayed up — hours — with sessions plainly running.
    ///
    /// `thenApproveCodex` is the Settings button and nothing else: a launch or a retry never
    /// approves anything in Codex. It waits for the installer, so what gets approved is the
    /// hooks.json this install left behind rather than the one it was about to replace.
    func checkHooks(thenApproveCodex: Bool = false) {
        // A build run out of build/ keeps its hands off settings.json, as before; it simply has no
        // verdict to show, and Settings says why.
        guard isInstalledCopy, !hookCheckRunning else { return }
        guard let installer = Bundle.main.path(forResource: "install", ofType: "js") else {
            // No retry timer: a file missing from the bundle does not come back by itself.
            hookHealth = .notInstalled(reason: "This copy of the app has no install.js inside it.",
                                       hint: "Reinstall the app.")
            hookCheckedAt = Date().timeIntervalSince1970
            refreshCounts()
            return
        }
        hookCheckRunning = true
        hookRetryTimer?.invalidate()
        hookRetryTimer = nil
        refreshCounts()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (health, trace) = Self.installHooks(installer: installer)
            DispatchQueue.main.async {
                guard let self else { return }
                // Logged when something is wrong and when the verdict moves — a launch that finds
                // everything in place, or an empty-tab look that changes nothing, stays quiet.
                if health.problem != nil || health != self.hookHealth {
                    NSLog("ClaudeControlBar: hooks — \(trace)")
                }
                self.hookCheckRunning = false
                self.hookCheckedAt = Date().timeIntervalSince1970
                self.hookHealth = health
                if health.problem != nil {
                    self.hookFailures += 1
                    self.scheduleHookRetry()
                } else {
                    self.hookFailures = 0
                }
                self.refreshCounts()
                if thenApproveCodex, self.codexInstalled {
                    self.approveCodexHooks()
                }
            }
        }
    }

    /// Looks again after a failure, sooner at first and then every few minutes — so a node
    /// repaired by `brew upgrade` is noticed without a restart, which is the step that never
    /// happened when "next launch" was the only retry.
    func scheduleHookRetry() {
        hookRetryTimer?.invalidate()
        let timer = Timer(timeInterval: HookInstall.retryDelay(afterFailures: hookFailures),
                          repeats: false) { [weak self] _ in self?.checkHooks() }
        // .common, so it fires while the panel is open — which is when someone is watching for it.
        RunLoop.main.add(timer, forMode: .common)
        hookRetryTimer = timer
    }

    /// One look, off the main thread: find a node that starts, run the installer with it, and
    /// check the node the hook commands will call. Returns the verdict and a line for the log.
    static func installHooks(installer: String) -> (HookHealth, String) {
        var (node, rejected) = HookInstall.firstRunning(nodeCandidates())
        if node == nil, let found = shellNode(), !rejected.contains(where: { $0.path == found }) {
            let second = HookInstall.firstRunning([found])
            node = second.node
            rejected += second.rejected
        }
        let dead = rejected.map { "\($0.path) does not start (\(HookInstall.describe($0.run)))" }
        guard let node else {
            let health = HookInstall.health(rejected: rejected, installer: nil, runtime: nil)
            return (health, (["no working node"] + dead).joined(separator: "; "))
        }
        let run = HookInstall.run(node, [installer], timeout: 60)
        let health = HookInstall.health(rejected: rejected, installer: run,
                                        runtime: HookInstall.hookRuntime())
        let said = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let trace = dead + ["install.js via \(node): \(run.end)" + (said.isEmpty ? "" : " — " + said)]
        return (health, trace.joined(separator: "; "))
    }

    /// Where a node may be, in the order they are tried — see HookInstall.nodeCandidates.
    static func nodeCandidates() -> [String] {
        let home = NSHomeDirectory()
        let versions = (try? FileManager.default.contentsOfDirectory(
            atPath: "\(home)/.nvm/versions/node")) ?? []
        return HookInstall.nodeCandidates(home: home, nvmVersions: versions)
    }

    /// The last resort, asked of the user's own shell. `/bin/zsh -lc node` saw only the login PATH,
    /// missing nvm/fnm set in .zshrc — hence the interactive spelling first.
    static func shellNode() -> String? {
        for args in [["-ilc", "command -v node"], ["-lc", "command -v node"]] {
            let result = HookInstall.run("/bin/zsh", args, timeout: 10)
            if let path = HookInstall.shellAnswer(result.output) { return path }
        }
        return nil
    }

    /// Approve this app's own hooks in Codex, then ask Codex again — because the person reading the
    /// panel or Settings has just pressed the button that says so.
    ///
    /// Only ever from a click. Codex asks for approval because hooks run outside its sandbox, and
    /// a launch that approved by itself would be this app deciding that on the user's behalf; the
    /// click is the user deciding it. Codex records the approval itself, with the hash it computed
    /// (see approve_codex_hooks in mcpbar.py), so what is approved is exactly what its own review
    /// screen would have shown. With nothing waiting it writes nothing and only asks again, which
    /// is also how someone who approved inside Codex checks that it took.
    ///
    /// Deliberately past askCodexAboutHooks's mtime gate. That gate exists so a handful of clicks
    /// in the MCP tab cannot spawn a `codex app-server` each, and it answers "nothing changed" for
    /// a Codex that has not written its config back yet. A button that answered "nothing to do"
    /// would read as the click having done nothing.
    func approveCodexHooks() {
        guard !codexHooksChecking else { return }
        codexHooksChecking = true
        refreshCounts()
        runQuietCommand(.codexHooksApprove) { [weak self] in
            guard let self else { return }
            // The next tick re-reads codex/hooks.json through its own mtime gate; clearing the
            // flag here is what turns the button back from "Approving…" to its own name.
            self.codexHooksChecking = false
            self.codexTrustInputs = ""   // the gate has been overtaken, so let it re-measure
            self.refreshCounts()
        }
    }

    /// Open ~/.codex/hooks.json in the Finder, selected: the exact file Codex is asking the user to
    /// approve, to read before pressing Approve rather than after.
    @objc func revealCodexHooks() {
        let path = (codexHome as NSString).appendingPathComponent("hooks.json")
        guard FileManager.default.fileExists(atPath: path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: codexHome))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
