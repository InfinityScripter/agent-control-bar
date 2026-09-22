import Cocoa

// The update channels: the daily GitHub/Homebrew check, the what's-new window, and the
// build-from-source self-update. Lifted out of main.swift; StatusController's stored state
// stays there (an extension cannot hold it).
extension StatusController {
    // MARK: update check

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    /// The version of the bundle sitting on disk, read fresh from the file rather than from the
    /// Info.plist the process cached at launch.
    ///
    /// A DMG install or `brew upgrade --cask` replaces the bundle under a live process, and macOS
    /// keeps the running executable image alive until the app is restarted. Measured on the
    /// development machine: a 0.5.1 bundle in /Applications and a 0.5.0 process in the menu bar,
    /// for two hours, with nothing anywhere saying so. And it is worse than cosmetic — a process
    /// whose bundle was replaced could no longer write its own preferences at all, so the update
    /// check had nowhere to keep the latest tag and the "Update to X" line could never appear
    /// again either. The one thing that fixes it is a restart, so that is what gets offered.
    var installedVersion: String? { Self.bundleVersion(at: Bundle.main.bundleURL) }
    static func bundleVersion(at bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
    }
    // Homebrew: the cask lags a GitHub release by up to ~a day (autobump), so brew-managed
    // installs gate "update available" on the CASK version, so the copy command always works
    // when offered. Public JSON, nothing sent anywhere (same privacy story as the GitHub check).
    // The trailing `open` matters: brew only copies the app, and the first launch of the new copy
    // is what installs hooks and removes the old-named bundle (0.4.0 rename transition).
    var brewManaged: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/claude-control-bar")
            || FileManager.default.fileExists(atPath: "/usr/local/Caskroom/claude-control-bar")
    }

    // Once/day: cache GitHub's latest release tag in UserDefaults. Nothing sent to us.
    /// `force` is the About page's "Check now": someone who came looking is asking a question the
    /// once-a-day throttle exists to stop us asking on their behalf, and answering "no" to a direct
    /// press would read as the button doing nothing.
    func checkForUpdate(force: Bool = false) {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if !force, now - d.double(forKey: "lastUpdateCheck") < 86400 { return }
        // Stamped here, before the requests, not in the success handler. Written on success only,
        // an unreachable GitHub meant every subsequent menu open fired both requests again — the
        // opposite of the once-a-day check PRIVACY.md promises, and worst exactly when the network
        // is already in trouble. An attempt is what the throttle counts; the outcome is separate.
        d.set(now, forKey: "lastUpdateCheck")
        guard let url = URL(string: releaseAPIURL) else { return }
        hooksWillChange()
        updateCheckRunning = true
        var req = URLRequest(url: url)
        req.setValue("ClaudeControlBar", forHTTPHeaderField: "User-Agent") // GitHub API requires a UA
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard let obj, let tag = obj["tag_name"] as? String else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                self?.updateCheckFinished(problem: UpdateFeed.checkProblem(status: status, answer: obj,
                                                                           error: error))
                return
            }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(ver, forKey: "latestVersion")
            // The release body rides in the same response — the "What's new in X" row shows
            // it before the user decides to update, at no extra request. Written together
            // with latestVersion so the two always describe the same release.
            UserDefaults.standard.set((obj["body"] as? String) ?? "", forKey: "latestReleaseNotes")
            // The DMG the one-click update installs, with the size and digest that prove a
            // download is that file. Removed, not left stale, when the release has none, so
            // the menu falls back to the source build instead of fetching an older DMG.
            if let asset = UpdateFeed.dmgAsset(in: obj) {
                UserDefaults.standard.set(asset.dictionary, forKey: "latestAsset")
            } else {
                UserDefaults.standard.removeObject(forKey: "latestAsset")
            }
            // Once per version, ever: the point is "an update exists, the menu explains it",
            // not a daily drumbeat. The plugin channel gets this too — it will update itself
            // on its own schedule, but a heads-up with readable notes beats a silent swap.
            if let self, Self.versionIsNewer(ver, than: self.currentVersion),
               UserDefaults.standard.string(forKey: "updateNotifiedVersion") != ver {
                UserDefaults.standard.set(ver, forKey: "updateNotifiedVersion")
                self.notify(title: "Claude Control Bar \(ver) is available",
                            body: "The panel has \u{201C}What\u{2019}s new in \(ver)\u{201D} and the update.")
            }
            self?.updateCheckFinished(problem: nil)
        }.resume()
        guard let brewURL = URL(string: brewCaskAPIURL) else { return }
        URLSession.shared.dataTask(with: URLRequest(url: brewURL)) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ver = obj["version"] as? String else { return }
            UserDefaults.standard.set(ver, forKey: "brewCaskVersion")
        }.resume()
    }

    /// The About page reads the check's outcome at draw time, so it has to be told when one ends:
    /// without this, a press that found a new version went on saying "up to date" until something
    /// unrelated redrew the window, and a refused check said nothing at all.
    func updateCheckFinished(problem: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hooksWillChange()
            self.updateCheckRunning = false
            self.updateCheckProblem = problem
            if problem == nil { self.updateCheckedAt = Date() }
        }
    }

    // Numeric component-wise compare so "0.0.10" > "0.0.9".
    /// Static because the Node search needs it too, and that runs before any instance exists.
    /// A leading "v" is tolerated: release tags and nvm directories both carry one.
    ///
    /// Everything from the first non-numeric component on is dropped, so a pre-release compares as
    /// its own base version and never above it. Mapping an unparsable component to 0 instead had
    /// "0.6.0-rc.1" split into 0, 6, "0-rc" -> 0, 1 — one component longer than "0.6.0" and
    /// therefore newer, which is backwards: a release candidate would have been offered as an
    /// update to the release it precedes.
    static func versionIsNewer(_ a: String, than b: String) -> Bool {
        let parts = { (s: String) in
            s.drop(while: { $0 == "v" }).split(separator: ".")
                .prefix(while: { Int($0) != nil }).map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func openLatestRelease() {
        if let url = URL(string: releasePageURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: what's new

    /// The version whose changelog hasn't been opened yet. UserDefaults, not a transient flag:
    /// the plugin channel updates by replacing the bundle and relaunching, so the row has to
    /// survive exactly that restart to ever be seen.
    var whatsNewUnseen: String? {
        get { UserDefaults.standard.string(forKey: "whatsNewUnseen") }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: "whatsNewUnseen") }
            else { UserDefaults.standard.removeObject(forKey: "whatsNewUnseen") }
        }
    }

    /// Both update channels end the same way — a new version starts running — so this one
    /// launch-time check is what makes either of them visible. The plugin channel in
    /// particular rebuilds and swaps the app with no user action at all; without this the
    /// only trace of an update was the version row quietly reading a different number.
    ///
    /// The first launch ever is silent: there is no previous version to have changed from,
    /// and greeting a fresh install with "updated!" would be noise.
    func announceVersionChange() {
        let d = UserDefaults.standard
        let last = d.string(forKey: "lastRunVersion")
        d.set(currentVersion, forKey: "lastRunVersion")
        // Strictly newer, not merely different: a rollback (a dev branch, an older DMG put
        // back on purpose) announcing "Updated from 0.7.4" would be reporting the opposite
        // of what happened.
        guard let last, Self.versionIsNewer(currentVersion, than: last) else { return }
        whatsNewUnseen = currentVersion
        notify(title: "Claude Control Bar \(currentVersion)",
               body: "Updated from \(last). \u{201C}What\u{2019}s new\u{201D} in the menu has the changes.")
    }

    /// The changes of the copy that is running: the CHANGELOG.md the build shipped alongside
    /// the binary, so the answer matches this exact version and works offline.
    @objc func showWhatsNewCurrent() {
        whatsNewUnseen = nil
        let bundled = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let md = bundled, let text = Changelog.section(for: currentVersion, in: md) {
            showWhatsNewWindow(version: currentVersion, markdown: text,
                               date: Changelog.date(for: currentVersion, in: md))
        } else if let url = URL(string:
            "https://github.com/InfinityScripter/claude-control-bar/releases/tag/v\(currentVersion)") {
            // A bundle built before the changelog shipped as a resource: the release page has it.
            NSWorkspace.shared.open(url)
        }
    }

    /// The changes of the version that is only available yet — the release body the daily
    /// update check already fetched (`releases/latest` carries it; no extra request).
    @objc func showWhatsNewLatest() {
        let d = UserDefaults.standard
        if let latest = d.string(forKey: "latestVersion"),
           let notes = d.string(forKey: "latestReleaseNotes"), !notes.isEmpty {
            // The button belongs to the DMG and source channels only: a brew-managed bundle is
            // brew's to replace, and the menu's copyable command is the way there.
            showWhatsNewWindow(version: latest, markdown: notes, date: nil,
                               install: brewManaged ? nil : (self, #selector(installLatestUpdate)))
        } else {
            openLatestRelease()
        }
    }

    func showWhatsNewWindow(version: String, markdown: String, date: String?,
                            install: (target: AnyObject, action: Selector)? = nil) {
        let (container, button) = WhatsNewPanel.contentView(version: version, markdown: markdown,
                                                            date: date, icon: NSApp.applicationIconImage,
                                                            install: install)
        whatsNewInstallButton = button
        setUpdateStage(updateStage)
        // One window, reused: a second click brings the same panel forward instead of
        // stacking copies. Closing releases the content, not the app (isReleasedWhenClosed
        // stays false because the controller keeps the reference).
        let win = whatsNewWindow ?? {
            let w = NSWindow(contentRect: container.frame,
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            // The header inside the content is the title; the system bar above it would say
            // the same thing twice. The window name stays set for Mission Control and VoiceOver.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.center()
            whatsNewWindow = w
            return w
        }()
        win.title = "What\u{2019}s new in \(version)"
        win.contentView = container
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Quit, then come back as the copy on disk.
    ///
    /// The relaunch waits for this process to be gone rather than firing alongside it: two copies
    /// of the SAME bundle path coexist happily — enforceSingleInstance only stands one down when
    /// the paths differ — so an overlap means two menu bar icons and two backends writing one
    /// state directory. The quit marker is written for the same reason the Quit item writes it:
    /// a hook firing in the gap would otherwise race the app back up before `open` runs. The new
    /// process clears the marker as it starts.
    @objc func restartIntoInstalledCopy() {
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/quit-intent")
        FileManager.default.createFile(atPath: marker, contents: nil)
        let quoted = "'" + Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null;"
                          + " do sleep 0.2; done; exec /usr/bin/open \(quoted)"]
        do { try task.run() } catch {
            // Quitting with no relauncher running would just make the app vanish. Staying alive
            // is strictly better: the copy on disk is already the new one, so the menu's
            // "Restart to finish updating" row appears on the next open and offers this again.
            logProblem("relaunch spawn failed: \(error)")
            selfUpdating = false
            setUpdateStage(nil)
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: the update itself

    /// The DMG of the release the daily check last saw, if it shipped one.
    var latestAsset: UpdateFeed.ReleaseAsset? {
        (UserDefaults.standard.dictionary(forKey: "latestAsset")).flatMap(UpdateFeed.ReleaseAsset.init)
    }

    /// What one click on "Update" does, whichever channel this copy has. The prebuilt DMG is the
    /// normal path; the source build covers a release that shipped without one; and with neither
    /// on offer the release page is where the file is.
    ///
    /// Strictly newer, checked here and not only where the menu decides to offer it: a
    /// restarted copy inherits this process's environment, and in the CONTROL_BAR_UPDATE_NOW
    /// mode it reinstalled the version it had just become and restarted once more.
    @objc func installLatestUpdate() {
        guard !selfUpdating, let latest = UserDefaults.standard.string(forKey: "latestVersion"),
              Self.versionIsNewer(latest, than: currentVersion) else { return }
        if let asset = latestAsset { installLatestDMG(latest: latest, asset: asset) }
        else if canBuildFromSource { selfUpdate(latest: latest) }
        else { openLatestRelease() }
    }

    /// Both channels end a failed attempt the same way: a line in problems.log, the banner back
    /// to "Update available", and a notification — the menu is closed by then, so nothing else
    /// would tell the user the click came to nothing.
    func updateFailed(latest: String, reason: String, body: String) {
        logProblem("update to \(latest) failed: \(reason)")
        setUpdateStage(nil)
        DispatchQueue.main.async { [weak self] in
            self?.selfUpdating = false
            self?.updateDownload = nil
            self?.notify(title: "Update to \(latest) failed",
                         body: body + " Details are in ~/.claude/control-bar/problems.log.")
        }
    }

    /// The progress text the banner and the "What's new" button show while an update runs.
    /// Set from any thread; the views are touched on main only.
    func setUpdateStage(_ stage: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateStage = stage
            // The banner is part of the panel's picture now, not a view held by reference: the
            // store re-reads updateStage and republishes, so the progress lands in an open panel
            // without the download knowing anything about which view is drawing it.
            self.refreshCounts()
            if let b = self.whatsNewInstallButton {
                b.title = stage ?? "Download and install"
                b.isEnabled = stage == nil
            }
        }
    }

    /// Download the release's DMG, verify it, mount it, stage its bundle beside the temp files,
    /// swap it into this bundle's place and restart. The same bundle swap build.sh does, minus
    /// the minute of compiling and the toolchain it needs.
    ///
    /// No signature is involved: releases are ad-hoc signed, so there is no identity to require.
    /// What stands in are the size and sha256 the releases API advertises (UpdateFeed.verify)
    /// and the bundle's own version, which must be the one the menu offered. The download
    /// carries no quarantine — URLSession only sets it for apps that opt in — and the staged
    /// bundle is cleared of attributes anyway, so Gatekeeper never sees a "downloaded" app.
    func installLatestDMG(latest: String, asset: UpdateFeed.ReleaseAsset) {
        selfUpdating = true
        setUpdateStage("Downloading…")
        let target = Bundle.main.bundlePath
        let fail: (String) -> Void = { [weak self] reason in
            self?.updateFailed(latest: latest, reason: reason, body: "Nothing was changed.")
        }
        let dmg = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccb-update-\(latest).dmg")
        let progress = DownloadProgress()
        progress.onProgress = { [weak self] percent in self?.setUpdateStage("Downloading… \(percent)%") }
        progress.onFinish = { [weak self] file, error in
            // Quit cancels the task; the app is on its way out, and that is not a failed update.
            if (error as? URLError)?.code == .cancelled { return }
            // URLSession's file dies with this callback: move it out before anything slow.
            guard let file else { return fail(error.map(String.init(describing:)) ?? "empty download") }
            try? FileManager.default.removeItem(at: dmg)
            do { try FileManager.default.moveItem(at: file, to: dmg) } catch { return fail("move: \(error)") }
            DispatchQueue.global(qos: .utility).async {
                self?.mountAndSwap(dmg: dmg, asset: asset, target: target, latest: latest, fail: fail)
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: progress, delegateQueue: nil)
        let task = session.downloadTask(with: asset.url)
        updateDownload = task
        task.resume()
        session.finishTasksAndInvalidate()
    }

    private func mountAndSwap(dmg: URL, asset: UpdateFeed.ReleaseAsset, target: String,
                              latest: String, fail: (String) -> Void) {
        setUpdateStage("Installing…")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccb-update-\(ProcessInfo.processInfo.processIdentifier)")
        let mount = tmp.appendingPathComponent("dmg")
        let stage = tmp.appendingPathComponent((target as NSString).lastPathComponent)
        var mounted = false
        defer {
            if mounted { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: dmg)
        }
        if let why = UpdateFeed.verify(file: dmg, against: asset) { return fail(why) }
        do { try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true) }
        catch { return fail("mkdir: \(error)") }
        if let why = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly",
                                              "-quiet", "-mountpoint", mount.path]) { return fail("attach: \(why)") }
        mounted = true
        // Located by its shape, not its name: the image carries the app and an Applications
        // symlink, and a renamed product must still be found.
        guard let app = (try? FileManager.default.contentsOfDirectory(atPath: mount.path))?
                .first(where: { $0.hasSuffix(".app") }).map({ mount.appendingPathComponent($0) })
        else { return fail("no .app in the image") }
        if let why = run("/usr/bin/ditto", [app.path, stage.path]) { return fail("ditto: \(why)") }
        if let why = run("/usr/bin/xattr", ["-cr", stage.path]) { return fail("xattr: \(why)") }
        let staged = Self.bundleVersion(at: stage)
        guard staged == latest else { return fail("the image carries \(staged ?? "no version"), not \(latest)") }
        // Rename aside, move in, then delete — not build.sh's rm-then-mv. That runs at a
        // developer's desk with the checkout intact; this runs unattended on a user's machine,
        // where a move that fails after the delete (full disk, a scanner holding the bundle)
        // would leave no app on disk and a notification claiming nothing changed. The running
        // process keeps its executable image either way; restartIntoInstalledCopy brings up
        // whatever sits at the path.
        let aside = target + ".replaced-\(ProcessInfo.processInfo.processIdentifier)"
        do { try FileManager.default.moveItem(atPath: target, toPath: aside) }
        catch { return fail("move aside: \(error)") }
        do { try FileManager.default.moveItem(atPath: stage.path, toPath: target) } catch {
            try? FileManager.default.moveItem(atPath: aside, toPath: target)
            return fail("swap: \(error)")
        }
        try? FileManager.default.removeItem(atPath: aside)
        DispatchQueue.main.async { [weak self] in self?.restartIntoInstalledCopy() }
    }

    /// nil on success; otherwise the exit status and the tail of stderr.
    private func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return "launch: \(error)" }
        let tail = err.fileHandleForReading.readDataToEndOfFile().suffix(500)
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        return "exit \(p.terminationStatus): \(String(decoding: tail, as: UTF8.self))"
    }

    // MARK: self-update (build from source)

    /// Best-effort breadcrumb for the failures a menu bar app has nowhere to show live.
    func logProblem(_ text: String) {
        NSLog("ClaudeControlBar: %@", text)
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/problems.log"
        // Appended, not read-and-rewritten: the app runs for days, and a self-update stuck in a
        // retry loop once rewrote the whole file on every failure.
        if !FileManager.default.fileExists(atPath: log) {
            FileManager.default.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let h = FileHandle(forWritingAtPath: log), let data = (text + "\n").data(using: .utf8) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        }
    }

    /// The DMG channel's automatic update: download the release source, build it with the same
    /// script every channel uses, let its staging swap replace this bundle, restart into it.
    ///
    /// No signature is involved anywhere — the binary is compiled on this machine, and
    /// Gatekeeper's quarantine applies to downloaded executables, not locally built ones. This
    /// is the plugin channel's own mechanism; since releases ship a DMG it is the fallback for a
    /// release that has none, and it needs a Swift toolchain on the machine.
    func selfUpdate(latest: String) {
        guard let url = URL(string:
                "https://github.com/InfinityScripter/claude-control-bar/archive/refs/tags/v\(latest).tar.gz")
        else { return }
        selfUpdating = true
        setUpdateStage("Downloading source…")
        let target = Bundle.main.bundlePath
        let fail: (String) -> Void = { [weak self] reason in
            self?.updateFailed(latest: latest, reason: reason, body: "The build did not finish.")
        }
        URLSession.shared.downloadTask(with: url) { [weak self] file, _, error in
            // The download lands in URLSession's temporary file, which dies with this callback —
            // move it out synchronously, then leave the session's queue before the slow part:
            // a build takes a minute, and this queue also serves the daily update check.
            let tar = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ccb-update-\(latest).tar.gz")
            guard let file else { return fail(error.map(String.init(describing:)) ?? "empty download") }
            try? FileManager.default.removeItem(at: tar)
            do { try FileManager.default.moveItem(at: file, to: tar) } catch { return fail("move: \(error)") }
            DispatchQueue.global(qos: .utility).async {
                self?.buildAndSwap(tar: tar, target: target, latest: latest, fail: fail)
            }
        }.resume()
    }

    private func buildAndSwap(tar: URL, target: String, latest: String, fail: (String) -> Void) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccb-update-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: tar) }
        do { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
        catch { return fail("mkdir: \(error)") }

        if let why = run("/usr/bin/tar", ["-xzf", tar.path, "-C", tmp.path]) { return fail("tar: \(why)") }

        // GitHub archives unpack into <repo>-<version>/ — located by its build.sh, not by name,
        // so a fork or a renamed tag cannot break the path.
        guard let src = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?
                .map({ tmp.appendingPathComponent($0) })
                .first(where: { FileManager.default.isReadableFile(atPath: $0.appendingPathComponent("build.sh").path) })
        else { return fail("no build.sh in the archive") }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = [src.appendingPathComponent("build.sh").path]
        build.currentDirectoryURL = src
        var env = ProcessInfo.processInfo.environment
        env["CONTROL_BAR_APP"] = target
        build.environment = env
        // stdout to the bit bucket; stderr drained by a handler, not a blocking
        // readDataToEndOfFile — that read returns only when every holder of the write end closes
        // it, so a compiler child outliving bash would pin this thread forever. The watchdog
        // bounds the build for the same reason: a hang here would otherwise leave
        // selfUpdating=true (a banner stuck on "Building…", no retry) for the process's lifetime.
        build.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        build.standardError = errPipe
        // Appends serialized on their own queue: the readability handler runs on FileHandle's
        // private queue while this thread reads the tail after waitUntilExit — and nilling the
        // handler does not wait out an in-flight invocation, so the plain shared `var` was an
        // unsynchronized cross-thread mutation on exactly the failure path where the tail
        // matters. The empty-read check also stops the EOF spin (the handler is re-invoked
        // with empty data until removed).
        let stderrQueue = DispatchQueue(
            label: "io.github.infinityscripter.claude-control-bar.update-stderr")
        var stderrData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            stderrQueue.async { stderrData.append(chunk) }
        }
        setUpdateStage("Building… (about a minute)")
        do { try build.run() } catch { return fail("build launch: \(error)") }
        DispatchQueue.main.async { [weak self] in self?.updateBuild = build }
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) { [weak build] in
            if let build, build.isRunning { build.terminate() }
        }
        build.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async { [weak self] in self?.updateBuild = nil }
        guard build.terminationStatus == 0 else {
            let tail = stderrQueue.sync { String(decoding: stderrData.suffix(2000), as: UTF8.self) }
            return fail("build exited \(build.terminationStatus):\n\(tail)")
        }
        // The bundle at `target` is already the new version (build.sh swaps only a verified
        // staging copy). restartIntoInstalledCopy quits us and opens whatever is on disk.
        DispatchQueue.main.async { [weak self] in self?.restartIntoInstalledCopy() }
    }
}

/// Progress and completion of one DMG download. A delegate rather than a completion handler
/// because only the delegate form reports bytes as they arrive, and a download the menu shows
/// no movement on reads as a hang.
final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    /// Whole percents only: every received chunk reports, and the banner would be redrawn
    /// dozens of times with the same text otherwise.
    var onProgress: ((Int) -> Void)?
    var onFinish: ((URL?, Error?) -> Void)?
    private var lastPercent = -1

    private func finish(_ file: URL?, _ error: Error?) {
        onFinish?(file, error)
        onFinish = nil
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        if percent != lastPercent { lastPercent = percent; onProgress?(percent) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // A server error page downloads just fine; only a 200 is the asset.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            return finish(nil, URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]))
        }
        finish(location, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(nil, error) }
    }
}
