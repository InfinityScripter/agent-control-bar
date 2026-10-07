import Cocoa
import UserNotifications

final class StatusController: NSObject, NSWindowDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar")
    let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    // MARK: MCP + limits
    lazy var mcp = MCPModel(
        path: (root as NSString).appendingPathComponent("mcp.json"))
    /// Codex's servers, written by `mcpbar.py codex-mcp refresh` in exactly mcp.json's shape so
    /// one parser reads both. A second model rather than a merged file: the two are rewritten by
    /// two different commands on their own schedules, and a single file would need one writer to
    /// hold the other's data intact through every refresh.
    lazy var codexMCP = MCPModel(
        path: (root as NSString).appendingPathComponent("codex/mcp.json"))
    var limits: Limits?
    /// Codex's own windows, read from codex/limits.json — the snapshot scripts/mcpbar.py lifts
    /// out of the newest rollout file that Codex itself wrote. Its own mtime gate below, because
    /// the two files are rewritten by two separate commands on the same timer.
    var codexWindows: LimitsSet?
    /// How many of this app's own hooks Codex has not been told to trust, read from
    /// codex/hooks.json. An untrusted hook is one Codex skips, and every one of ours writes the
    /// session file — so a count above zero means Codex is writing down less than it would, and
    /// with the whole set unapproved it writes down nothing at all.
    var codexHooksUntrusted = 0
    /// True while an Approve click is in flight, so the button can say so. Not a general busy
    /// flag: the periodic ask is invisible on purpose and must not flicker a button.
    var codexHooksChecking = false
    /// Whether Codex has ever answered about the hooks on this run. Separate from the count above
    /// because zero has two meanings otherwise — "all approved" and "never asked" — and Settings
    /// must not report the first when it means the second.
    var codexHooksAnswered = false
    var mcpBusy = false
    var recheckTimer: Timer?
    /// How often the MCP picture is rebuilt from scratch in the background. Measured at ~34s a
    /// run, essentially all of it `claude mcp list` starting every configured server and waiting
    /// — which is why it is not on the render path. Without it the picture never updates at all,
    /// which is how a server that had reconnected went on showing a red cross indefinitely.
    static let mcpRefreshInterval: TimeInterval = 600
    /// Opening the menu rebuilds the picture if it is older than this. Short enough that what is
    /// on screen is worth trusting, long enough that opening the menu repeatedly is free.
    static let mcpOpenStaleAfter: TimeInterval = 120
    /// Everything the MCP half needs to run: the interpreter and the script. Written by the
    /// plugin's bootstrap hook so the app survives the plugin moving between versions; falls
    /// back to the copy inside the app bundle, which is what the brew/DMG channel has.
    lazy var backend: (python: String, script: String) = {
        let paths = (root as NSString).appendingPathComponent("paths.json")
        if let data = FileManager.default.contents(atPath: paths),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let script = root["script"] as? String, FileManager.default.fileExists(atPath: script) {
            return (root["python"] as? String ?? "/usr/bin/python3", script)
        }
        let bundled = Bundle.main.path(forResource: "mcpbar", ofType: "py", inDirectory: "scripts")
        return ("/usr/bin/python3", bundled ?? "")
    }()

    var pollTimer: Timer?
    var animTimer: Timer?
    /// Kept between opens rather than rebuilt: it holds the sidebar's selection and whatever size
    /// the window was dragged to.
    var settingsWindow: NSWindow?
    /// Built on the first open. It stores nothing itself — only bindings back to this object.
    lazy var settingsStore = SettingsStore(controller: self)
    /// The dropdown. Kept between opens so the chosen tab survives closing it.
    var panelWindow: PanelHostWindow?
    /// Watches for a click outside the panel, which is how a window of our own gets the one menu
    /// behaviour it does not inherit. Alive only while the panel is open.
    var panelClickMonitor: Any?
    /// When the panel last closed, so the click that closed it cannot also reopen it. See
    /// togglePanel().
    var panelClosedAt: Double = 0
    lazy var panelStore = PanelStore(controller: self)
    struct BarRender {
        var agent: MenuBarAgent
        var icon: MenuBarIcon? = nil
        var ticks: [NSImage]? = nil
        var color: NSColor? = nil
        var animate = false
        var fps: Double = 1
        var frameCount = 1
        var motion = MenuBarMotion()
        var label = ""
        var cacheKey = ""
        var frames: [Int: NSImage] = [:]
    }
    var barRenders: [String: BarRender] = [:]
    var barOrder: [String] = []
    var barTimerFPS: Double = 0
    var barCompositeKey = ""
    var barCompositeFrames: [String: NSImage] = [:]
    var barImageKey = ""

    /// Whether the app may quit on its own yet; see checkLifecycle().
    var idleQuit = IdleQuit(launchedAt: Date())
    // "Hide idle after" setting (seconds): hide a resting session's ROW once it's been quiet this long.
    // Render-only — it never deletes the file or affects liveness (that's pid-driven now), and the
    // most-recent session is always kept visible (floor at one). 0 = Never. Defaults to 15 min.
    // No UI writes it: it is a `defaults write` knob for someone who wants a different number.
    var stalePruneAge: TimeInterval { UserDefaults.standard.object(forKey: "hideIdleAfter") as? Double ?? 900 }

    // Every live session and the decisions about them live in SessionBoard (Sources/Model),
    // under the model check; this class only reads the files and acts on what it returns.
    let board = SessionBoard(engine: SessionEngine())
    var engine: SessionEngine { board.engine }
    var sessions: [String: Session] { board.sessions }  // "<provider>:<id>" -> latest parsed state
    let git = GitBranches()  // cwd -> branch, read out of .git/HEAD (Sources/Model)
    var uiConfigCache: (mtime: Date?, values: [String: Double])?
    // Stored state used by the extensions in Updates.swift, SessionRows.swift and
    // IconRender.swift — an extension cannot declare stored properties, so they live here.
    let releaseAPIURL = "https://api.github.com/repos/InfinityScripter/agent-control-bar/releases/latest"
    let releasePageURL = "https://github.com/InfinityScripter/agent-control-bar/releases/latest"
    let brewCaskAPIURL = "https://formulae.brew.sh/api/cask/claude-control-bar.json"
    let brewUpgradeCommand = "brew upgrade --cask claude-control-bar"
    let brewInstallCommand = "brew install --cask claude-control-bar && open -a \"Claude Control Bar\""
    var whatsNewWindow: NSWindow?
    let logoSet: [NSImage] = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    var lastLifecycleCheck: Double = 0  // the quit decision is sampled far slower than the UI
    var notificationsDenied = false     // the one macOS permission this app has; see notify()
    var lastNotifiedChangeAt: Date?     // dedupe: notifyMCPChange runs on every reload, the change lives 45 s
    var limitsMTime: Date?              // limits.json parse gate; nil forces a re-read (see loadLimits)
    var lastLimitsPoll: Double = 0      // so a rollover cannot bring the next poll forward into a loop
    var limitsTimer: Timer?             // the five-minute poll; each Claude request pushes it back
    var rolledOverHandled: Double = 0   // the reset stamp that already brought one poll forward
    var codexLimitsMTime: Date?         // the same gate for codex/limits.json
    var codexHooksMTime: Date?          // and for codex/hooks.json
    /// The mtimes the last hook-trust question was asked against; see askCodexAboutHooks().
    var codexTrustInputs: String?
    /// Where Codex keeps the session files its limit figures are read out of. Owned by Codex,
    /// never written here.
    let codexSessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    /// Codex's own directory. Its presence is the whole test for "is Codex installed here" —
    /// asked afresh rather than cached, so installing Codex later needs no restart.
    let codexHome = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    /// Codex is installed: its servers and hooks can be asked about.
    var codexInstalled: Bool { FileManager.default.fileExists(atPath: codexHome) }
    /// Codex has run at least once: only then is there a session file to read limits out of. A
    /// separate gate from codexInstalled, because an install that never ran has none.
    var codexHasRun: Bool { FileManager.default.fileExists(atPath: codexSessionsDir) }
    var selfUpdating = false            // one update at a time (DMG install or source build)
    var updateBuild: Process?           // the in-flight source build; Quit terminates it (see quit())
    var updateDownload: URLSessionDownloadTask?  // the in-flight DMG download; Quit cancels it
    var updateStage: String?            // "Downloading… 43%" / "Installing…" while selfUpdating; nil otherwise
    var updateCheckRunning = false      // About's "Check now" reads "Checking…" and waits meanwhile
    var updateCheckedAt: Date?          // the last check GitHub answered with a release, this run
    var updateCheckProblem: String?     // why the last check found no release; nil once one did
    weak var whatsNewInstallButton: NSButton?     // the open "What's new" window's button, same reason
    // Never `xcrun --find`: querying xcrun with no developer tools installed pops the system's
    // "install the command line developer tools?" dialog — from a menu bar app, out of nowhere.
    // A missing toolchain must read as "not available", never as a prompt. The fixed paths cover
    // the stock installs; `xcode-select -p` (prompt-free) covers one moved with --switch.
    //
    // Warmed ONCE on a background queue at launch. This used to be a lazy var, and its first
    // touch — inside menuNeedsUpdate, on the main thread — spawned xcode-select synchronously
    // while the user was opening the menu. Until the warm-up lands (sub-second) the update row
    // takes its no-toolchain shape, which is merely the release-page fallback.
    var canBuildFromSource = false
    func warmCanBuildFromSource() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let answer = Self.probeToolchain()
            DispatchQueue.main.async { self?.canBuildFromSource = answer }
        }
    }
    static func probeToolchain() -> Bool {
        let stock = ["/Library/Developer/CommandLineTools/usr/bin/swiftc",
                     "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"]
        if stock.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        probe.arguments = ["-p"]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0,
              let root = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { return false }
        return [root + "/usr/bin/swiftc",
                root + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
    let brand = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #d97757, Anthropic's official "Orange" accent
    /// Static because the panel needs it too, and a SwiftUI view has no controller to ask.
    static let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "Needs you" badge
    let frames: [NSImage] = StatusController.loadFrames()
    let spriteFPS: Double = 9 // tune: 8 frames per loop -> ~0.9s/cycle

    /// What the menu bar is drawing: one of the three styles we draw ourselves, or a pet. The type
    /// is in Sources/Model/PetIcon.swift, with the rules about what an unreadable setting means.
    var animStyle: MenuBarIcon = .crab
    /// Which pet the session rows draw, by pet id, or "" for none. A plain string and not an enum
    /// because most of the ids come from ~/.codex/pets, which the user fills in themselves.
    var petID = "clawd"
    /// The same, for rows belonging to Codex. Two settings and not one: the companions are the
    /// other agent's own, and somebody running both wants to tell the two apart in the list at a
    /// glance — which is exactly what one pet for both would take away.
    var codexPetID = StatusController.codexDefaultPet
    /// The Codex mascot where the desktop app is installed; missing art keeps its provider glyph.
    static let codexDefaultPet = "codex"
    var petLibraryCache: [Pet]?
    var petAtlasCache: [String: PetAtlas?] = [:]
    var petPreviewCache: [(pet: Pet, atlas: PetAtlas?)] = []
    var iconPreviewCache: [(icon: MenuBarIcon, name: String, frames: [NSImage])] = []
    var petIconCache: [String: PetIconFrames?] = [:]
    var showTimer = false
    var iconSystem = false // false = brand Orange; true = adaptive black/white (template image)
    var useThinkingWords = true     // rotate a playful verb ("Manifesting…") in place of "Thinking…"
    var oauthLimits = true          // poll Anthropic's usage endpoint for the 5h/7d/Fable limits
    var codexLimits = true          // read Codex's own limit snapshot out of ~/.codex/sessions
    /// Whether Codex's MCP servers are listed and switchable. On by default like the limits, and
    /// for the same reason — a machine without Codex sees nothing either way — but its own
    /// switch, because this one is the half that starts every configured server to ask it for its
    /// tools, and someone with a slow one may not want that on a ten-minute timer.
    var codexServers = true
    /// Whether a click on a CLI session focuses its exact window and tab, or only raises its
    /// terminal app. Off by default, and the ONLY setting in this app that is: it is the one that
    /// buys its behaviour with a macOS permission prompt, and a permission nobody asked for is a
    /// worse default than a click that lands one tab off.
    var exactTerminalFocus = false
    var limitsLayout = PanelLimitsLayout.rows   // how the strip shows two providers at once
    /// Which provider the switcher layout is showing. Remembered across opens: someone who
    /// switched to Codex was answering "how much Codex have I got left", not this once.
    var limitsProvider = "claude"
    /// Which agents the bar and the panel show, as saved, or nil when nobody has picked: the
    /// default then follows whether Codex is installed — see AgentDisplay.resolve.
    var agentChoice: String?
    var agentDisplay: AgentDisplay {
        AgentDisplay.resolve(saved: agentChoice, codexInstalled: codexInstalled)
    }
    var analytics = true            // the anonymous daily ping (Sources/Analytics.swift); env var and endpoint also gate it
    var soundThreshold: Double = 0  // 0 = off; else the min turn length (seconds) that chimes on completion
    var needsYouSound = NeedsYouSound.defaultChoice  // system sound name; "" = off
    var needsYouPlayer: NSSound?  // the loaded pick, replaced when the pick changes
    lazy var completionSound: NSSound? = {
        guard let p = Bundle.main.path(forResource: "completion", ofType: "mp3"),
              let s = NSSound(contentsOfFile: p, byReference: true) else { return nil }
        s.volume = 0.7 // the clip is loud at full system volume; play it a bit softer
        return s
    }()
    // Claude Code's SPINNER_VERBS, minus the hyphenated/tongue-twister ones. Longest kept is ~14 chars
    // ("Hullaballooing"/"Metamorphosing"); with the timer showing they can get wide in a crowded menu bar.
    let thinkingWords = [
        "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'",
        "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping",
        "Bootstrapping", "Brewing", "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing",
        "Cascading", "Catapulting", "Cerebrating", "Channeling", "Channelling", "Churning", "Clauding",
        "Coalescing", "Cogitating", "Combobulating", "Composing", "Computing", "Concocting", "Considering",
        "Contemplating", "Cooking", "Crafting", "Creating", "Crunching", "Crystallizing", "Cultivating",
        "Deciphering", "Deliberating", "Determining", "Doing", "Doodling", "Drizzling", "Ebbing",
        "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning", "Evaporating", "Fermenting",
        "Finagling", "Flambéing", "Flowing", "Flummoxing", "Fluttering", "Forging", "Forming", "Frolicking",
        "Gallivanting", "Galloping", "Garnishing", "Generating", "Gesticulating", "Germinating", "Gitifying",
        "Grooving", "Gusting", "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing",
        "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring", "Infusing",
        "Ionizing", "Jitterbugging", "Julienning", "Kneading", "Leavening", "Levitating", "Lollygagging",
        "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting", "Moonwalking", "Moseying",
        "Mulling", "Mustering", "Musing", "Nebulizing", "Nesting", "Noodling", "Nucleating", "Orbiting",
        "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing", "Pollinating", "Pondering",
        "Pontificating", "Pouncing", "Precipitating", "Processing", "Proofing", "Propagating", "Puttering",
        "Puzzling", "Quantumizing", "Razzmatazzing", "Reticulating", "Roosting", "Ruminating", "Sautéing",
        "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying", "Simmering",
        "Skedaddling", "Sketching", "Slithering", "Smooshing", "Spelunking", "Spinning", "Sprouting",
        "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing", "Tempering",
        "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Transfiguring", "Transmuting", "Twisting",
        "Undulating", "Unfurling", "Unravelling", "Vibing", "Waddling", "Wandering", "Warping",
        "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling", "Zesting", "Zigzagging"]
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    let codeGlyphs = ["✻", "✽", "✶", "✳", "✢"]
    let codePeaks: [CGFloat] = [1.0, 1.0, 1.0, 1.0, 1.0]
    let codeDip: CGFloat = 0.14 // glyph shrinks to this at each swap
    let codeSub = 18            // sub-frames per glyph (tween smoothness)
    let codeCycle: Double = 3.8 // seconds for the full loop (lower = faster)
    lazy var codeGlyphMasks: [NSImage] = codeGlyphs.map { StatusController.glyphMask($0) }
    lazy var crabFrames: [NSImage] = StatusController.decodePNGs(clawdCrabFramePNGs)
    lazy var crabFrameSet = CrabFrameSet(walking: crabFrames)
    // Template frames: bright pixels (white eyes) become transparent holes so they're
    // visible as negative space against the menu bar in System color mode.
    lazy var crabTemplateFrames: [CrabMood: [NSImage]] = Dictionary(uniqueKeysWithValues:
        CrabMood.allCases.map { mood in
            (mood, crabFrameSet.frames(for: mood).map(adaptiveCrabFrame))
        })
    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if d.object(forKey: "thinkingWords") != nil { useThinkingWords = d.bool(forKey: "thinkingWords") }
        if d.object(forKey: "oauthLimits") != nil { oauthLimits = d.bool(forKey: "oauthLimits") }
        if d.object(forKey: "codexLimits") != nil { codexLimits = d.bool(forKey: "codexLimits") }
        if d.object(forKey: "codexServers") != nil { codexServers = d.bool(forKey: "codexServers") }
        exactTerminalFocus = d.bool(forKey: "exactTerminalFocus")   // absent = off, which is the default
        if let s = d.string(forKey: "limitsLayout"), let l = PanelLimitsLayout(rawValue: s) { limitsLayout = l }
        if let s = d.string(forKey: "limitsProvider") { limitsProvider = s }
        agentChoice = d.string(forKey: "agentDisplay")
        if d.object(forKey: "analytics") != nil { analytics = d.bool(forKey: "analytics") }
        if d.object(forKey: "soundThreshold") != nil { soundThreshold = d.double(forKey: "soundThreshold") }
        if let s = d.string(forKey: "needsYouSound") { needsYouSound = s }
        if let s = d.string(forKey: "animStyle") { animStyle = MenuBarIcon(raw: s) }
        if let s = d.string(forKey: "petID") { petID = s }   // "" is a real value here: pets off
        // Never chosen: a Mac that has been showing pets gets the Codex mascot for Codex rows,
        // and one where they were switched off keeps them off. Turning a setting off and finding
        // half of it back on after an update is the one outcome this must not produce.
        codexPetID = d.string(forKey: "codexPetID") ?? (petID.isEmpty ? "" : Self.codexDefaultPet)
        if let s = d.string(forKey: "motionLevel"), let m = Motion.Level(rawValue: s) { Motion.level = m }
        // No `statusItem.menu`: with one set, AppKit swallows the click to open the menu and the
        // button's own action never fires. The panel is a window of ours, so the click has to
        // reach us — see PanelWindow.swift for why it is not an NSMenu any more.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        renderMenuBar(now: Date().timeIntervalSince1970)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        observeDesktopApp()
        // Rebuilding the MCP picture is expensive (`claude mcp list` plus a tools/list round trip
        // per server) so it gets its own slow timer rather than riding the 0.4s render tick.
        Timer.scheduledTimer(withTimeInterval: Self.mcpRefreshInterval, repeats: true) {
            [weak self] _ in self?.refreshMCP()
        }
        refreshMCP()
        // Limits come from the same endpoint /usage reads, on their own cadence: the statusLine
        // capture only fires while a terminal CLI is redrawing its TUI, so for someone working in
        // the desktop app it never fires at all — which left the bars frozen on whatever they
        // last showed. Five minutes is well clear of the endpoint's rate limiting (community
        // consensus puts the floor at three).
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) {
            [weak self] _ in self?.pollLimits()
        }
        pollLimits()
        refreshNotificationAuthStatus()
        tick()
        try? FileManager.default.removeItem(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/quit-intent"))
        // CONTROL_BAR_DUMP_MENU=1 builds the dropdown once, prints it and quits. Looking at the
        // real thing is not a reliable check: a crowded menu bar parks items off-screen behind a
        // manager's chevron (measured at x ≈ −8650 on this machine), so they are invisible while
        // perfectly healthy. This reads the menu that would be drawn.
        // CONTROL_BAR_DIAGNOSE=1 answers the single most common report — "the icon is gone" —
        // with measurements instead of guesses. A status item that does not fit beside the notch
        // is not clipped: macOS parks it off-screen behind the overflow chevron, and from the
        // outside that is indistinguishable from an app that failed to start.
        // CONTROL_BAR_DIAGNOSE=menu opens the dropdown by itself, so it can be screenshotted.
        // There is no other way to look at it: the menu closes the moment anything else takes
        // over, and a crowded menu bar can hide the item that opens it.
        if ProcessInfo.processInfo.environment["CONTROL_BAR_DIAGNOSE"] == "menu" {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                // An accessory app is not active, and performClick on an inactive app's status
                // button does nothing at all.
                NSApp.activate(ignoringOtherApps: true)
                self?.statusItem.button?.performClick(nil)
            }
        // CONTROL_BAR_DIAGNOSE=settings opens the Settings window by itself, for the same reason
        // `menu` opens the panel: neither can be reached from outside the app. The window is only
        // ever raised from the panel's own button, so a change to a settings screen could not be
        // looked at without a person sitting at the machine to click it.
        } else if ProcessInfo.processInfo.environment["CONTROL_BAR_DIAGNOSE"] == "settings" {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                self?.openSettingsWindow()
            }
        // CONTROL_BAR_DIAGNOSE=toggle answers "does clicking the icon close the panel?" without
        // clicking it — which is the only way to ask, for the same reason CONTROL_BAR_UPDATE_NOW
        // exists: a crowded menu bar parks the status item off-screen, where neither a person nor
        // Accessibility can reach it, and that is exactly the machine this bug hid on. It replays
        // the order AppKit produces for that click and prints what the panel did.
        } else if ProcessInfo.processInfo.environment["CONTROL_BAR_DIAGNOSE"] == "toggle" {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.openPanel()
                print("after open:        \(self.panelIsOpen ? "OPEN" : "closed  <-- the panel did not open")")
                // The menu bar takes key status first, which closes the panel; the button's own
                // action arrives after it. Without a guard the action finds a closed panel and
                // opens it straight back, so the icon can open the panel but never close it.
                self.closePanel()
                self.togglePanel()
                print("after icon click:  \(self.panelIsOpen ? "OPEN  <-- it reopened itself" : "closed")")
                Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                    self.togglePanel()
                    print("after later click: \(self.panelIsOpen ? "OPEN" : "closed  <-- the guard is too wide")")
                    NSApp.terminate(nil)
                }
            }
        } else if ProcessInfo.processInfo.environment["CONTROL_BAR_DIAGNOSE"] != nil {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                guard let self else { return }
                for provider in self.barOrder {
                    guard let gauge = self.barRenders[provider]?.agent.gauge else { continue }
                    print("\(provider) gauge \(gauge.signature)")
                }
                print("sessions=\(self.sessions.count) mcp servers=\(self.mcp.servers.count)")
                guard let button = self.statusItem.button else {
                    print("no status item button at all"); NSApp.terminate(nil); return
                }
                print("image=\(button.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")"
                    + " template=\(button.image?.isTemplate as Any) length=\(self.statusItem.length)")
                if let window = button.window {
                    let screen = NSScreen.main?.frame ?? .zero
                    print("item window=\(window.frame) visible=\(window.isVisible) screen=\(screen)")
                    print(window.frame.maxX > screen.maxX || window.frame.minX < 0
                          ? "VERDICT: parked off-screen — the menu bar is full, it is behind the › chevron"
                          : "VERDICT: on screen at x=\(Int(window.frame.minX))")
                } else {
                    print("button has no window yet")
                }
                NSApp.terminate(nil)
            }
        }
        // CONTROL_BAR_UPDATE_NOW=1 runs the one-click update at launch, without the menu: the
        // menu of a parked status item cannot be clicked — by a person or by Accessibility —
        // so this is how the download-verify-swap-restart path is exercised end to end
        // (against a local HTTP server and a seeded latestAsset, see TROUBLESHOOTING).
        if ProcessInfo.processInfo.environment["CONTROL_BAR_UPDATE_NOW"] != nil {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.installLatestUpdate()
            }
        }
        if ProcessInfo.processInfo.environment["CONTROL_BAR_DUMP_MENU"] != nil {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                print(self.describePanel())
                NSApp.terminate(nil)
            }
        }
        enforceSingleInstance()
        retirePredecessors()
        checkHooks()
        checkForUpdate()
        announceVersionChange()
        warmCanBuildFromSource()
        // Hourly, not daily: the app runs for weeks, and a 24h timer that fires while the Mac is
        // asleep is simply late. The throttle inside decides whether a tick sends anything.
        sendAnalyticsPingIfDue()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.sendAnalyticsPingIfDue()
        }
    }

    // Bundles this project shipped under earlier names. See identity.env: upstream's
    // com.local.claudestatusbar is deliberately absent — claude-status-bar is a separate
    // product the user may want, and a fork that deletes the app it forked from is a bug with
    // a very bad blast radius. The inherited routine did exactly that, by id.
    let legacyBundleIDs = ["com.local.mcpstatus", "com.local.mcpbar"]

    // MARK: hooks — the look itself is in HookSetup.swift

    /// What the last look at the hooks found. The panel and Settings both show it, and neither
    /// asks for it: the look runs on its own schedule (see checkHooks) and republishes when done.
    var hookHealth: HookHealth = .unchecked
    var hookCheckRunning = false
    var hookCheckedAt: Double = 0
    /// Failed looks in a row, which is what spaces the retries out.
    var hookFailures = 0
    var hookRetryTimer: Timer?

    // MARK: MCP backend — the runs themselves are in Backend.swift

    /// Serial, deliberately. A full check starts every configured MCP server and takes about
    /// half a minute; on a concurrent queue a toggle during one of those launched a second
    /// backend over the same servers and the same cache files, and whichever finished first
    /// cleared mcpBusy while the rest were still running — the menu said "done" mid-flight.
    let backendQueue = DispatchQueue(
        label: "io.github.infinityscripter.claude-control-bar.backend")
    /// Operations handed to the queue and not yet finished. A plain Bool could not survive two
    /// of them: the first to return cleared it.
    var backendRunning = 0

    /// True from the moment a full check is asked for until it has finished.
    var refreshQueued = false
    /// A check asked for while one was already running. Dropping it outright was wrong: the run
    /// in flight started BEFORE the toggle and cannot know about it, so a server switched off
    /// mid-check kept its old row until the ten-minute timer came round — a stale answer that
    /// reads as the click having done nothing.
    var refreshAgain = false

    // MARK: self-quit lifecycle — the decision is in AppLifecycle.swift

    // Asking LaunchServices about the desktop app on a timer is a synchronous XPC round-trip;
    // workspace launch/terminate notifications keep this flag instead. The authoritative query
    // runs only at the quit decision, so a missed notification can delay a quit by one debounce
    // but can never quit under a live app.
    var desktopRunning = false

    var claudeProbedAt: Double = 0
    var claudeWasRunning = false
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
