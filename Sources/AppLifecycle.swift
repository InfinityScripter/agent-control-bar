import Cocoa

// Where this copy stands among the others on the machine (predecessors, a second instance) and
// when it quits on its own. Lifted out of main.swift; the stored state these read stays there,
// because an extension cannot declare stored properties.

extension StatusController {
    // A rename leaves the previous copy installed and running: same job, second menu bar icon,
    // two apps writing one state directory. Measured on the development machine mid-merge —
    // MCPStatus and an orphaned MCP Bar.app from an earlier rename were both still on disk.
    //
    // Retired to the Trash, not unlinked: an app the user can drag back is a different promise
    // from one this deleted on its own authority during a routine launch.
    /// True only for a copy living under /Applications or ~/Applications. A build run straight out
    /// of build/ is a development artifact and must keep its hands off the user's machine — it
    /// has no business installing hooks into settings.json or moving installed apps to the Trash
    /// just because someone launched it to look at the menu. (Learned the direct way: a dev run
    /// wrote eight hooks into a live settings.json.)
    ///
    /// Anchored at the front of the path, not searched anywhere inside it: a plain `contains`
    /// promoted `/tmp/Applications/scratch/…` and `~/projects/Applications/demo/…` to installed
    /// copies, which is the exact dev run this guard exists to hold back. A prefix rather than an
    /// exact parent, because organising apps into /Applications/Utilities is normal and a copy
    /// filed away there is installed by any honest reading.
    var isInstalledCopy: Bool {
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath).resolvingSymlinksInPath().path
        // Both sides resolved, or a home directory that is itself a link never matches.
        let personal = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("Applications").path
        return bundle.hasPrefix("/Applications/") || bundle.hasPrefix(personal + "/")
    }

    func retirePredecessors() {
        guard isInstalledCopy else { return }
        let fm = FileManager.default
        for id in legacyBundleIDs where id != Bundle.main.bundleIdentifier {
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == id {
                app.terminate()
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  // Re-read the id off disk: urlForApplication answers from Launch Services'
                  // cache, which keeps pointing at a path long after the bundle moved.
                  let info = NSDictionary(
                    contentsOfFile: url.appendingPathComponent("Contents/Info.plist").path),
                  info["CFBundleIdentifier"] as? String == id,
                  url.path != Bundle.main.bundlePath
            else { continue }
            var trashed: NSURL?
            do { try fm.trashItem(at: url, resultingItemURL: &trashed) } catch {
                NSLog("ClaudeControlBar: could not retire \(url.path): \(error)")
            }
        }
    }

    // Two bundles can carry one id (the plugin builds into ~/Applications, brew installs into
    // /Applications) and macOS will happily run both — one id, two menu bar items, and `open -b`
    // picking between them at random. The copy in /Applications wins because that is the one
    // brew updates; a plugin build stands down rather than fighting it.
    func enforceSingleInstance() {
        // A bare binary — which is how the diagnostic modes and ad-hoc builds run — has no bundle
        // identifier, and `nil == nil` matched every OTHER bundle-less process on the machine. The
        // first one found (universalaccessd, on this Mac) counted as "already running" and every
        // diagnostic run stood down before printing anything.
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = Bundle.main.bundlePath
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == id && $0.processIdentifier != me
        }
        guard !others.isEmpty else { return }
        let systemWide = mine.hasPrefix("/Applications/")
        for other in others {
            let theirs = other.bundleURL?.path ?? ""
            if systemWide && !theirs.hasPrefix("/Applications/") {
                other.terminate()
            } else {
                NSLog("ClaudeControlBar: \(theirs) already running, standing down")
                NSApp.terminate(nil)
                return
            }
        }
    }

    // MARK: self-quit lifecycle

    func claudeDesktopRunningLive() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleID).isEmpty
    }

    func observeDesktopApp() {
        desktopRunning = claudeDesktopRunningLive()
        let nc = NSWorkspace.shared.notificationCenter
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                (NSWorkspace.didTerminateApplicationNotification, false)] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == self.claudeDesktopBundleID else { return }
                self.desktopRunning = running
            }
        }
    }

    // The listing reloadSessions() just made, not a second contentsOfDirectory for the same answer.
    func sessionCount() -> Int { board.fileCount }

    /// Is an agent itself running, whatever it has or has not written to disk?
    ///
    /// Only consulted when everything else says the app is not needed, and the answer is held for
    /// ten seconds — otherwise a session that writes no state file would have this walking the
    /// process table on every tick, forever. Both agents in one probe: a Codex session whose
    /// hooks the user has not trusted yet writes nothing at all, and quitting the app out from
    /// under it is exactly the "only works with the desktop app" bug this probe was added for.
    /// `codex` is the process name whichever way it was installed — the npm wrapper execs the
    /// native binary rather than staying in the picture as `node`.
    func agentRunning() -> Bool {
        let now = Date().timeIntervalSince1970
        if now - claudeProbedAt < 10 { return claudeWasRunning }
        claudeProbedAt = now
        claudeWasRunning = RunningProcesses.existsAny(of: ["claude", "codex"])
        return claudeWasRunning
    }

    // Liveness probe: is this session's `claude` process still alive? kill(pid,0) returns 0 if the
    // process exists; EPERM = exists but not ours (won't happen, same user); ESRCH = gone.
    func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // Stay while Claude desktop is open OR a session is active; otherwise quit after a
    // short debounced grace (warmup-session churn must not kill us). The debounce is IdleQuit's,
    // under the model check; the two slow probes that get the last word run here.
    func checkLifecycle() {
        let inUse = settingsWindow?.isVisible == true || panelIsOpen
        guard idleQuit.step(now: Date(), inUse: inUse, needed: sessionCount() > 0 || desktopRunning)
                == .confirm else { return }
        // The process table gets the last word. A session whose hooks never fired — no node
        // on the PATH, hooks switched off, settings sources that skip the user's file —
        // leaves no state file, and quitting on that evidence killed the app ten seconds
        // after launch with Claude Code running in a terminal the whole time.
        guard !agentRunning() else { return }
        // Notification-fed flag could have missed a launch (e.g. delivered while the run loop
        // was blocked); confirm with LaunchServices before the irreversible step.
        if claudeDesktopRunningLive() { desktopRunning = true; idleQuit.reset(); return }
        NSApp.terminate(nil)
    }
}
