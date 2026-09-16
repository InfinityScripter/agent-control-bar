import Cocoa

// What the panel's controls actually do: opening a session's window, the two System Settings
// panes this app deep-links into, and quitting.
//
// These were the menu's @objc handlers. The menu is gone (see PanelWindow.swift), the handlers are
// not: the rules in openSession below are the product of a long line of "the click did nothing"
// reports, and none of them had anything to do with how the row was drawn.
extension StatusController {

    // Files & Folders — the pane holding the per-app network-volumes switch. Same undocumented
    // scheme as the notifications pane below; the bare Privacy pane is the fallback.
    @objc func openFilesPrivacySettings() {
        for link in ["x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
                     "x-apple.systempreferences:com.apple.preference.security"] {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
        NSLog("ClaudeControlBar: privacy settings pane did not open")
    }

    // Deep link into this app's own Notifications pane. URL(string:) only checks syntax; whether
    // the pane id still resolves is decided by System Settings at open() — the scheme is
    // undocumented and has shifted between macOS releases — so a failed open falls back to
    // Settings' root: a landing page and a Console trace instead of a click that does nothing.
    @objc func openNotificationSettings() {
        var link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let id = Bundle.main.bundleIdentifier { link += "?id=" + id }
        if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        NSLog("ClaudeControlBar: notification settings pane did not open")
        if let root = URL(string: "x-apple.systempreferences:com.apple.systempreferences") {
            NSWorkspace.shared.open(root)
        }
    }



    @objc func quit() {
        // NSApp.terminate tears down our threads but NOT the spawned build — bash and its
        // compilers would be orphaned, finish minutes later and swap the bundle with nobody
        // left to restart into it. Ending the child turns that into an ordinary failed build.
        updateBuild?.terminate()
        updateDownload?.cancel()
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/quit-intent")
        FileManager.default.createFile(atPath: marker, contents: nil)
        NSApp.terminate(nil)
    }

    @objc func openClaude() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Row click. Desktop session: switch the app to THAT conversation (see DesktopSessions).
    // Merely focusing the app was the bug — it is normally frontmost already, so every row did
    // nothing visible and all of them did the same nothing. Focusing the app is still the
    // fallback for a conversation this machine has no record of.
    // CLI session: bring its terminal APP to the front (zero permission). Targeting the exact
    // window/tab needs a one-time Automation grant, deferred to the opt-in build (issue #19).
    func openSession(_ id: String, threadURL: URL?, entrypoint: String,
                     termProgram: String, termBundle: String, tty: String) {
        // Codex's own deep link, when the model half decided this session is one to follow there
        // (SessionFormat.codexThreadURL says which). `open -b` pins the receiving app rather than
        // letting LaunchServices pick among whatever else claims `codex://` — the same precaution
        // the editor branch below takes, and for the same reason.
        //
        // The app has to actually be installed, checked here rather than left to `open` — a
        // failed `open` reports into a stderr nobody reads, and because this branch returns, a
        // click that quietly went nowhere would have replaced one that used to raise a terminal.
        if let threadURL, NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: Self.codexBundleID) != nil {
            openTool(["-b", Self.codexBundleID, threadURL.absoluteString])
            return
        }
        if entrypoint == "claude-desktop" {
            guard let local = DesktopSessions.sessionID(forCLI: id),
                  let url = DesktopSessions.focusURL(sessionID: local)
            else { openClaude(); return }
            NSWorkspace.shared.open(url)
            return
        }
        // Extension-panel session: jump to the CONVERSATION, not just the editor. The Claude
        // Code extension registers a URI handler (read out of its extension.js):
        // <scheme>://anthropic.claude-code/open?session=<id> resumes exactly this session in
        // the panel. The scheme comes from the editor's own Info.plist — Cursor says "cursor",
        // VS Code "vscode" — so no fork catalog; `open -b` pins the receiving app in case two
        // forks claim one scheme. An editor without the handler still comes to the front.
        if entrypoint == "claude-vscode", !termBundle.isEmpty, let scheme = urlScheme(ofBundle: termBundle) {
            openTool(["-b", termBundle, "\(scheme)://anthropic.claude-code/open?session=\(id)"])
            return
        }
        // Everything past here is a session living in a terminal, and the two steps are "which
        // window and tab" then "failing that, which app". The exact step is tried first and only
        // when the user has asked for it: it sends an Apple Event, which costs a one-time macOS
        // Automation grant, and nobody should be made to answer that prompt for a click they
        // expected to be free.
        if exactTerminalFocus, !tty.isEmpty {
            switch focusTerminalTab(termProgram: termProgram, tty: tty) {
            case .focused:
                return
            case .denied:
                // The grant was refused. Switch the feature back off rather than leaving a toggle
                // on that silently does nothing, and clear the explanation's seen-flag so turning
                // it on again explains itself again. The reset is what makes that re-enable able
                // to work at all: macOS remembers a denial and never asks a second time.
                applyExactTerminalFocus(false)
                UserDefaults.standard.set(false, forKey: "exactFocusExplained")
                resetAutomationGrant()
            case .unsupported:
                break
            }
        }
        // The hooks record __CFBundleIdentifier, which names the exact hosting app — the
        // TERM_PROGRAM map below cannot: Cursor, Windsurf and VS Code all report "vscode"
        // (so the click opened the wrong editor), and the IDE extension panel sets no
        // TERM_PROGRAM at all (so the click did nothing). `open -b` takes the id verbatim.
        if !termBundle.isEmpty {
            openTool(["-b", termBundle])
            return
        }
        // Map TERM_PROGRAM to a name `open -a` understands; most terminals match verbatim.
        let app: String
        switch termProgram {
        case "Apple_Terminal": app = "Terminal"
        case "iTerm.app":      app = "iTerm"
        case "vscode":         app = "Visual Studio Code"
        case "WarpTerminal":   app = "Warp"
        case "":               return  // unknown surface, nothing to focus
        default:               app = termProgram  // Ghostty, WezTerm, Tabby, Hyper, kitty, …
        }
        openTool(["-a", app])
    }

    /// The bundle id of Codex's desktop app, which is what registers the `codex://` scheme.
    static let codexBundleID = "com.openai.codex"

    /// What came of trying to focus one exact tab. Three outcomes and not a Bool, because the
    /// caller does something different with each: a refusal switches the feature off, a terminal
    /// that cannot be asked just falls through quietly, and only a refusal is the user's business.
    enum FocusOutcome { case focused, denied, unsupported }

    /// Focus the window and tab whose controlling terminal is `tty`, through AppleScript.
    ///
    /// Terminal and iTerm are the two that can be asked: both publish a tab's `tty` in their
    /// scripting dictionary, which is the only property that identifies a tab from the outside —
    /// a title can be rewritten by the shell and a window index moves the moment anything is
    /// dragged. Ghostty, WezTerm, kitty and Warp publish no such thing, so they are `.unsupported`
    /// and keep the old behaviour rather than getting a worse guess.
    ///
    /// The first call raises the macOS "…wants to control Terminal" prompt. It needs the
    /// apple-events entitlement to get that far at all — without it a hardened-runtime build has
    /// the event blocked before macOS can ask, which looks exactly like a click that did nothing
    /// (see build.sh, where the entitlement is signed in).
    func focusTerminalTab(termProgram: String, tty: String) -> FocusOutcome {
        // Normalised and vetted in the model half, where the check is pinned by a test: this
        // string is interpolated into an AppleScript literal, so what it may contain is a rule
        // about a session rather than a detail of this function.
        guard let dev = SessionFormat.ttyDevice(tty) else { return .unsupported }
        let script: String
        switch termProgram {
        case "Apple_Terminal":
            script = """
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(dev)" then
                    set selected of t to true
                    set frontmost of w to true
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        case "iTerm.app":
            script = """
            tell application "iTerm"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(dev)" then
                      select s
                      select t
                      tell w to select
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        default:
            return .unsupported
        }
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        guard let err else { return .focused }
        // -1743 is errAEEventNotPermitted: the grant was refused, or was never given. Every other
        // error — the app is not running, the tab is gone, the dictionary changed — is a fallback,
        // because none of them is the user having said no to something.
        let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
        return code == -1743 ? .denied : .unsupported
    }

    /// Clear this app's Apple Events decisions so the next attempt can ask again.
    ///
    /// macOS records a refusal and never re-prompts, so without this, turning the feature back on
    /// after a refusal would produce a toggle that is on and a click that does nothing — the worst
    /// of the three possible states. `tccutil reset` edits the user's own TCC database and needs no
    /// privilege; it touches this app's entry and nothing else.
    func resetAutomationGrant() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "AppleEvents", id]
        try? p.run()
    }

    /// One spelling of "hand this to /usr/bin/open" for the four branches above. They differed
    /// only in their arguments, and four copies of a five-line launch is four places to forget
    /// when the launch itself ever needs to change.
    private func openTool(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = arguments
        try? p.run()
    }


    // First CFBundleURLTypes scheme of the app carrying this bundle id; nil when the app is
    // gone or registers no URL scheme at all.
    func urlScheme(ofBundle bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let types = Bundle(url: appURL)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        else { return nil }
        return types.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
    }
}
