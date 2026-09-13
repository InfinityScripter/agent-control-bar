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
                     termProgram: String, termBundle: String) {
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
