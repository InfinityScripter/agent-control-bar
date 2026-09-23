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
    var frameIdx = 0

    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
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
    var gitHeadCache: [String: String] = [:]  // cwd -> resolved HEAD path ("" = confirmed non-git)
    var uiConfigCache: (mtime: Date?, values: [String: Double])?
    // Stored state used by the extensions in Updates.swift, SessionRows.swift and
    // IconRender.swift — an extension cannot declare stored properties, so they live here.
    let releaseAPIURL = "https://api.github.com/repos/InfinityScripter/claude-control-bar/releases/latest"
    let releasePageURL = "https://github.com/InfinityScripter/claude-control-bar/releases/latest"
    let brewCaskAPIURL = "https://formulae.brew.sh/api/cask/claude-control-bar.json"
    let brewUpgradeCommand = "brew upgrade --cask claude-control-bar"
    let brewInstallCommand = "brew install --cask claude-control-bar && open -a \"Claude Control Bar\""
    var whatsNewWindow: NSWindow?
    let logoSet: [NSImage] = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    var activeBase = ""        // label without the elapsed clock
    var renderedTitle: String? // what the status item is actually showing, to skip identical redraws
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
    var iconCache: [Int: NSImage] = [:]  // composed menu bar frames, rebuilt only when the look changes
    var iconCacheKey = ""
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil
    var activeBadge = false

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
    /// What a Mac with the ChatGPT app calls the Codex mascot. Only a default: with that app
    /// absent the id resolves to nothing in particular and the usual fallback picks a pet.
    static let codexDefaultPet = "codex"
    private var petLibraryCache: [Pet]?
    private var petAtlasCache: [String: PetAtlas?] = [:]
    private var petPreviewCache: [(pet: Pet, atlas: PetAtlas?)] = []
    private var iconPreviewCache: [(icon: MenuBarIcon, name: String, frames: [NSImage])] = []
    private var petIconCache: PetIconFrames?
    private var petIconID: String?
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
    var crabMood: CrabMood = .sleeping
    var crabWorking = 0   // sessions working right now; sets the tempo inside a mood
    var fps: Double {
        if petIconTicks != nil { return PetIconFrames.fps }
        switch drawnIcon {
        case .web: return spriteFPS
        case .code: return Double(codeGlyphs.count * codeSub) / codeCycle
        case .crab, .pet: return crabMood.framesPerSecond(working: crabWorking)
        }
    }
    var frameCount: Int {
        if let ticks = petIconTicks { return ticks.count }
        switch drawnIcon {
        case .web: return max(1, frames.count)
        case .code: return codeGlyphs.count * codeSub
        case .crab, .pet: return max(1, crabFrameSet.frames(for: crabMood).count)
        }
    }

    /// The icon actually on screen. A pet whose pictures are gone — the app that carried it was
    /// uninstalled, the folder was deleted — falls back to the crab, and every question about the
    /// icon has to be answered about the thing being drawn rather than about the saved choice.
    /// The choice itself is left alone, so the pet comes back if its app does.
    var drawnIcon: MenuBarIcon { animStyle.isPet && petIconTicks == nil ? .crab : animStyle }

    /// The menu bar pet's pictures for the state showing now, or nil when the bar is not drawing
    /// a pet at all. One picture per tick, so stepping through them needs no durations.
    var petIconTicks: [NSImage]? {
        guard animStyle.isPet, let built = petIconFrames() else { return nil }
        let ticks = built.frames(for: crabMood.petRow)
        return ticks.isEmpty ? nil : ticks
    }

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
        render(label: "", color: iconColor, animate: false, startedAt: 0)
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
                let gauge = self.currentGauge()
                print("gauge 5h=\(gauge.fiveHour as Any) 7d=\(gauge.sevenDay as Any)")
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
            } else if !systemWide {
                NSLog("ClaudeControlBar: \(theirs) already running, standing down")
                NSApp.terminate(nil)
                return
            }
        }
    }

    // MARK: hooks

    /// What the last look at the hooks found. The panel and Settings both show it, and neither
    /// asks for it: the look runs on its own schedule (see checkHooks) and republishes when done.
    var hookHealth: HookHealth = .unchecked
    var hookCheckRunning = false
    var hookCheckedAt: Double = 0
    /// Failed looks in a row, which is what spaces the retries out.
    var hookFailures = 0
    var hookRetryTimer: Timer?

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

    /// Where a node may be, in the order they are tried. The two the hook commands put in front of
    /// PATH come first, so whether the hooks' own node starts is always part of the answer.
    static func nodeCandidates() -> [String] {
        let home = NSHomeDirectory()
        var candidates = HookInstall.hookPathPrefix.map { $0 + "/node" } + [
            "/usr/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            // Component-wise, not alphabetical: as text "v9.11.2" sorts above "v20.19.0", so the
            // newest-first intent picked the oldest Node on the machine — and the installer this
            // runs uses APIs a Node that old does not have.
            for v in versions.sorted(by: { versionIsNewer($0, than: $1) }) {
                candidates.append("\(nvmDir)/\(v)/bin/node")
            }
        }
        return candidates
    }

    /// The last resort, asked of the user's own shell. `/bin/zsh -lc node` saw only the login PATH,
    /// missing nvm/fnm set in .zshrc — hence the interactive spelling first.
    static func shellNode() -> String? {
        for args in [["-ilc", "command -v node"], ["-lc", "command -v node"]] {
            let result = HookInstall.run("/bin/zsh", args, timeout: 10)
            // The last line naming a node, not simply the last line: stdout and stderr share one
            // file here, and a .zshrc or .zlogout can print after the answer.
            let path = result.output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") && $0.hasSuffix("/node")
                    && FileManager.default.isExecutableFile(atPath: $0) }
            if let path { return path }
        }
        return nil
    }

    // MARK: MCP backend

    /// Any mcpbar.py command: off the main queue, UI updated back on it. Nothing here parses the
    /// script's output — the script writes mcp.json and the model re-reads it.
    ///
    /// Serial, deliberately. A full check starts every configured MCP server and takes about
    /// half a minute; on a concurrent queue a toggle during one of those launched a second
    /// backend over the same servers and the same cache files, and whichever finished first
    /// cleared mcpBusy while the rest were still running — the menu said "done" mid-flight.
    let backendQueue = DispatchQueue(
        label: "io.github.infinityscripter.claude-control-bar.backend")
    /// Operations handed to the queue and not yet finished. A plain Bool could not survive two
    /// of them: the first to return cleared it.
    var backendRunning = 0

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

    /// True from the moment a full check is asked for until it has finished.
    var refreshQueued = false
    /// A check asked for while one was already running. Dropping it outright was wrong: the run
    /// in flight started BEFORE the toggle and cannot know about it, so a server switched off
    /// mid-check kept its old row until the ten-minute timer came round — a stale answer that
    /// reads as the click having done nothing.
    var refreshAgain = false

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

    /// Re-publish the panel's picture if it is on screen. The menu needed a list of closures for
    /// this, because NSMenu would not let rows be added or removed while it tracked and the only
    /// thing that could move was the text already in them. A window has no such rule: the store
    /// re-reads, and only a real difference redraws anything.
    func refreshCounts() {
        if panelIsOpen { panelStore.refresh() }
        if settingsWindow?.isVisible == true { settingsStore.refresh() }
    }

    // MARK: pets
    //
    // Both folders are read here rather than in the panel, for the reason every other path is:
    // main.swift owns where things live, models parse what it hands them, and the views draw the
    // result. The pets folder sits beside codexHome so a Codex that moves takes its pets with it.

    /// The pets on offer. Cached because the panel asks on every refresh; dropped when the
    /// Settings window opens, which is the only place the whole list is shown and therefore the
    /// only moment a pet installed while the app was running needs to appear.
    func petLibrary() -> [Pet] {
        if let cached = petLibraryCache { return cached }
        let library = Pet.library(
            bundled: Bundle.main.resourceURL?.appendingPathComponent("pets").path,
            codex: (codexHome as NSString).appendingPathComponent("pets"),
            archive: codexAppArchive)
        petLibraryCache = library
        return library
    }

    /// Which pet a provider's rows draw.
    func petID(of provider: String) -> String { provider == "codex" ? codexPetID : petID }

    /// A chosen pet's atlas, decoded on first use and kept until the choice changes. Only the
    /// chosen ones are ever decoded: an atlas is a megabyte-scale picture, and a folder of gallery
    /// pets would otherwise all sit in memory for the sake of the one or two being drawn. Keyed by
    /// id rather than by provider, so the common case — both agents showing the same pet — decodes
    /// it once and both lists of rows draw the same pictures.
    ///
    /// The dictionary holds an optional: "we looked and there is nothing" has to be told apart
    /// from "we have not looked", or a pet whose art will not decode is decoded again on every
    /// refresh of a panel that asks 2.5 times a second.
    func petAtlas(of provider: String) -> PetAtlas? {
        let id = petID(of: provider)
        if let cached = petAtlasCache[id] { return cached }
        // Only the ids in use are kept. Clicking down a picker of twenty pets changes the setting
        // twenty times, and each one asked for its sheet; without this the last nineteen stay.
        petAtlasCache = petAtlasCache.filter { $0.key == petID || $0.key == codexPetID }
        let atlas = Pet.chosen(id, from: petLibrary()).flatMap(PetAtlas.init)
        petAtlasCache[id] = atlas
        return atlas
    }

    /// The menu bar pet, cut down to the bar's own size. Built once per pick and kept: it is a
    /// couple of dozen pictures 18 points tall, and building it costs a decode of the whole sheet.
    func petIconFrames() -> PetIconFrames? {
        guard case .pet(let id) = animStyle else { return nil }
        if petIconID == id { return petIconCache }
        petIconID = id
        petIconCache = Pet.chosen(id, from: petLibrary()).flatMap { PetIconFrames($0) }
        return petIconCache
    }

    func reloadPetLibrary() {
        petLibraryCache = nil
        petAtlasCache = [:]
        petIconID = nil
    }

    /// The archive of the desktop app that carries the Codex companions, when it is installed.
    ///
    /// Known locations rather than a Launch Services lookup, the same list `mcpbar.py` keeps for
    /// finding `codex` itself: that lookup answers from a cache which goes on naming a path long
    /// after the bundle moved. Nothing here is copied — the pets are read out of the app in place,
    /// and on a Mac without it there are simply fewer of them.
    var codexAppArchive: String? {
        let personal = NSHomeDirectory() + "/Applications"
        return ["/Applications/ChatGPT.app", "/Applications/Codex.app",
                personal + "/ChatGPT.app", personal + "/Codex.app"]
            .map { $0 + "/Contents/Resources/app.asar" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every pet with its frames, for the picker that shows them rather than naming them.
    ///
    /// This is the one place that decodes more than the chosen pet, because showing the choice is
    /// the whole point of it — so it is also the one place that has to give the memory back. The
    /// pictures live exactly as long as the Settings window: `releasePetPreviews()` runs when that
    /// window closes, leaving only the atlas the panel is drawing.
    func petPreviews() -> [(pet: Pet, atlas: PetAtlas?)] {
        if petPreviewCache.isEmpty {
            petPreviewCache = petLibrary().map { ($0, PetAtlas($0)) }
        }
        return petPreviewCache
    }

    /// Every menu bar choice with the pictures it would put in the bar, at the size the bar draws
    /// them and one picture per tick of the bar's own clock.
    ///
    /// The picker animates all of them for the same reason the pet picker does: a pet's name comes
    /// out of somebody else's manifest and says nothing about what will appear up there. The two
    /// tempos below are approximate — the spark runs at nine frames a second and the glyphs tween
    /// their size — because the picker has to answer "which one is this", not reproduce the bar.
    func iconChoicePreviews() -> [(icon: MenuBarIcon, name: String, frames: [NSImage])] {
        if iconPreviewCache.isEmpty {
            let colour = iconColor
            iconPreviewCache = [
                (.web, MenuBarIcon.web.title,
                 frames.indices.map { tint(frames, color: colour, frame: $0) }),
                (.code, MenuBarIcon.code.title,
                 (0..<codeGlyphs.count).flatMap {
                     repeatElement(codeIcon(color: colour, glyph: $0, scale: 1), count: 8) }),
                (.crab, MenuBarIcon.crab.title,
                 crabFrameSet.frames(for: .walking).indices.map {
                     crabIcon(color: colour, frame: $0, mood: .walking) }),
            ]
            iconPreviewCache += petLibrary().compactMap { pet in
                PetIconFrames(pet).map { (.pet(pet.id), pet.displayName, $0.frames(for: .idle)) }
            }
        }
        return iconPreviewCache
    }

    func releasePetPreviews() {
        petPreviewCache = []
        iconPreviewCache = []
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

    /// What a look at one of the codex/*.json state files found. Three outcomes, because the
    /// three mean three different things to a reader: no file at all is an answer (the figures
    /// go, rather than standing until a restart), an unchanged mtime is a stat and no parse, and
    /// a file that is there but unreadable is a half-written rewrite — for the few milliseconds
    /// that lasts, the previous parse is the better of the two things to show, so it reads as
    /// unchanged rather than as missing.
    enum CodexStateFile {
        case missing
        case unchanged
        case changed([String: Any])
    }

    /// Both Codex files are read on the same stat-per-tick gate as the Claude one above: at 2.5 Hz
    /// for the app's whole life, against files another process rewrites every few minutes. Writes
    /// are atomic renames, so a changed mtime always means a whole new file.
    func codexStateFile(at name: String, gate: inout Date?) -> CodexStateFile {
        let path = (root as NSString).appendingPathComponent(name)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date
        guard let stamp else {
            gate = nil
            return .missing
        }
        if stamp == gate { return .unchanged }
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unchanged }
        gate = stamp
        return .changed(object)
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

    /// A server falling over is worth interrupting for; a tool count moving is not — that is
    /// usually the user, one click ago, in this very menu.
    func notifyMCPChange() {
        // Keyed on the change's own timestamp: freshChange() keeps answering with the same
        // change for its whole 45 s window, and this runs from every runBackend completion AND
        // the mtime tick — without the key, a toggle seconds after "server went down" posted
        // the same banner a second time.
        guard let change = mcp.freshChange(), change.deservesNotification,
              change.at != lastNotifiedChangeAt else { return }
        lastNotifiedChangeAt = change.at
        if !change.down.isEmpty {
            notify(title: change.down.count == 1
                    ? "MCP: \(mcpShortName(change.down[0])) went down"
                    : "MCP: \(change.down.count) servers went down",
                   body: change.down.map(mcpShortName).joined(separator: ", "))
        }
        if !change.up.isEmpty {
            notify(title: change.up.count == 1
                    ? "MCP: \(mcpShortName(change.up[0])) is back"
                    : "MCP: \(change.up.count) servers are back",
                   body: change.up.map(mcpShortName).joined(separator: ", "))
        }
    }

    /// Notifications were posted without permission ever being asked for — `requestAuthorization`
    /// appears nowhere in this project's history — so macOS declined every one of them: an app
    /// sitting at `.notDetermined` is not prompted on delivery, the request simply fails, and the
    /// only trace was an NSLog nobody reads. Asked here rather than
    /// at launch, so the prompt arrives attached to a real event — a server that just fell over —
    /// instead of ambushing the first launch.
    ///
    /// A refusal is remembered, not retried: macOS shows the system dialog once per app, ever —
    /// no later version, reinstall or second `requestAuthorization` brings it back, only the user
    /// in System Settings. So a denial used to be swallowed whole, and someone who declined a year
    /// ago could never learn why alerts stopped. It now sets `notificationsDenied`, which the menu
    /// answers with a row that opens the right Settings pane.
    func notify(title: String, body: String) {
        // UNUserNotificationCenter.current() traps (NSInternalInconsistencyException,
        // "bundleProxyForCurrentProcess is nil") when the process runs outside an .app bundle —
        // which is exactly how the diagnostic modes (CONTROL_BAR_DUMP_MENU/DIAGNOSE) and ad-hoc
        // builds run the bare binary. No bundle, no notification delivery anyway.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        let deliver = {
            center.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            ) { error in if let error { NSLog("ClaudeControlBar: notification failed: \(error)") } }
        }
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error { NSLog("ClaudeControlBar: notification permission: \(error)") }
                    // The system now holds the stored answer; the one canonical mapping reads it
                    // back, rather than a second spelling (!granted) drifting beside it.
                    self?.refreshNotificationAuthStatus()
                    if granted { deliver() }
                }
                return
            }
            let denied = settings.authorizationStatus == .denied
            // Written on the allowed path too: flipping the switch back on in System Settings
            // must clear the menu row on the next event, not only on the next menu open.
            DispatchQueue.main.async { self?.notificationsDenied = denied }
            if !denied { deliver() }
        }
    }

    /// The stored answer, refreshed at launch and on every menu open: flipping the switch in
    /// System Settings must clear the menu row without a restart.
    func refreshNotificationAuthStatus() {
        guard Bundle.main.bundleIdentifier != nil else { return }  // see notify(): traps bundle-less
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationsDenied = settings.authorizationStatus == .denied
            }
        }
    }

    // MARK: state polling

    func tick() {
        // Whether to quit is not a four-times-a-second question — the decision behind it is
        // debounced by idleQuitDelay anyway, so checking at this rate only bought the app a
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

    /// Bars ride in the same status item as the icon. A second status item would be cleaner to
    /// build and cost another ~33pt of a menu bar that, on this machine, is already ~220pt past
    /// what fits beside the notch — and overflow there does not clip, it disappears.
    func decorate(_ icon: NSImage?) -> NSImage? {
        let gauge = currentGauge()
        guard !gauge.isEmpty else { return icon }
        return gauge.image(icon: icon)
    }

    func currentGauge() -> Gauge { limitsBoard.gauge(at: Date().timeIntervalSince1970) }

    var limitsBoard: LimitsBoard { LimitsBoard(claude: limits?.set, codex: codexWindows) }

    // The session files currently on disk, both agents' (ignores the .tmp files mid-write).
    // Keyed "<provider>:<id>", because the two agents mint their ids independently and the
    // dictionaries below must not be able to mix them up.
    func stateFiles() -> [(key: String, path: String, provider: String, id: String)] {
        Provider.all.flatMap { agent in
            let provider = agent.id, dir = agent.stateDir(home: NSHomeDirectory())
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".json") }
                .map { name in
                    let id = (name as NSString).deletingPathExtension
                    return (key: provider + ":" + id,
                            path: (dir as NSString).appendingPathComponent(name),
                            provider: provider, id: id)
                }
        }
    }

    // Where a session's own file lives — the one place that turns a session back into a path,
    // so the reap in evaluate() cannot delete out of the wrong agent's directory.
    func statePath(of s: Session) -> String {
        let dir = Provider.named(s.provider).stateDir(home: NSHomeDirectory())
        return (dir as NSString).appendingPathComponent(s.id + ".json")
    }

    // Refresh `sessions` from the state directories; SessionBoard re-parses only the files whose
    // mtime changed.
    func reloadSessions() {
        let fm = FileManager.default
        let files = stateFiles().compactMap { f -> SessionBoard.File? in
            guard let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date
            else { return nil }
            return SessionBoard.File(key: f.key, path: f.path, provider: f.provider, id: f.id, mtime: m)
        }
        board.reload(files, read: { path in
            fm.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }, branch: freshBranch)
    }

    // A hook event means activity in that cwd, which may have JUST become a repo (git init or a
    // first branch mid-session) — a cached "" (non-git) would otherwise stick until app restart.
    func freshBranch(_ cwd: String) -> String {
        if gitHeadCache[cwd] == "" { gitHeadCache[cwd] = nil }
        return branchForCwd(cwd)
    }

    // MARK: git branch (no `git` spawn — .git/HEAD is a tiny text file)

    // Resolve <cwd>'s HEAD path by walking toward /. A worktree/submodule has .git as a FILE
    // containing "gitdir: <path>". Resolution walks directories, so cache it per cwd; a cached
    // "" means confirmed non-git. Dropped by branchForCwd if the HEAD read later fails.
    func gitHeadPath(_ cwd: String) -> String? {
        if let hit = gitHeadCache[cwd] { return hit.isEmpty ? nil : hit }
        let fm = FileManager.default
        var dir = cwd, isDir: ObjCBool = false
        for _ in 0..<40 {
            let g = (dir as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: g, isDirectory: &isDir) {
                var head: String? = nil
                if isDir.boolValue {
                    head = (g as NSString).appendingPathComponent("HEAD")
                } else if let d = fm.contents(atPath: g), d.count <= 4096,
                          let s = String(data: d, encoding: .utf8),
                          let line = s.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
                    var gd = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    if !gd.hasPrefix("/") { gd = ((dir as NSString).appendingPathComponent(gd) as NSString).standardizingPath }
                    head = (gd as NSString).appendingPathComponent("HEAD")
                }
                gitHeadCache[cwd] = head ?? ""
                return head
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        gitHeadCache[cwd] = ""
        return nil
    }

    // HEAD is "ref: refs/heads/<branch>" on a branch, a bare commit hash when detached.
    // nil (no branch text, no error) for non-git dirs and anything unrecognized.
    func branchForCwd(_ cwd: String) -> String {
        guard !cwd.isEmpty, let headPath = gitHeadPath(cwd) else { return "" }
        guard let d = FileManager.default.contents(atPath: headPath), d.count <= 1024,
              let s = String(data: d, encoding: .utf8) else {
            gitHeadCache[cwd] = nil   // stale resolution (repo moved/deleted) — retry next time
            return ""
        }
        let head = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst(16)) }
        if head.hasPrefix("ref: ") { return ((head as NSString).lastPathComponent) }
        if (40...64).contains(head.count), head.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return String(head.prefix(7))   // detached HEAD -> short SHA
        }
        return ""
    }

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
        let rules = SessionBoard.Rules(soundThreshold: soundThreshold, stalePruneAge: stalePruneAge,
                                       thinkingWords: thinkingWords, needsYou: !needsYouSound.isEmpty)
        let tick = board.tick(now: now, rules: rules, pidAlive: pidAlive,
                              frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })
        // The one write this app makes into a state directory: the file of a session whose
        // process has died. The path comes from the session's provider — see statePath(of:).
        for s in tick.reaped { try? FileManager.default.removeItem(atPath: statePath(of: s)) }
        // Keyed by cwd, so it outlived the sessions above: an entry per directory ever seen, for
        // the app's lifetime. Kept only for directories a live session still points at.
        let liveCwds = Set(sessions.values.map(\.cwd))
        gitHeadCache = gitHeadCache.filter { liveCwds.contains($0.key) }
        if tick.chime { completionSound?.play() }
        if tick.needsYou { playNeedsYou() }   // one cue per tick however many sessions asked at once

        let lead = tick.lead
        setCrabMood(CrabMood.display(forEffectiveStates: sessions.values.map(\.eff), leadState: lead?.eff),
                    working: sessions.values.filter { isWorkingState($0.eff) }.count)
        statusItem.button?.toolTip = lead.map(sessionMenuLine)  // repo · branch [· elapsed] on hover

        guard let lead = lead else { renderResting(); return }
        switch lead.eff {
        case "permission":
            render(label: statusText(lead, eff: lead.eff), color: crabRenderColor,
                   animate: drawnIcon.restsInMotion || crabMood != .sleeping,
                   startedAt: 0, badge: true)
        case "thinking", "tool":
            render(label: statusText(lead, eff: lead.eff), color: crabRenderColor, animate: true, startedAt: lead.startedAt)
        default:
            renderResting()
        }
    }

    var crabRenderColor: NSColor? {
        drawnIcon == .crab && crabMood.keepsColorInSystem ? brand : iconColor
    }

    func setCrabMood(_ mood: CrabMood, working: Int) {
        let tempoChanged = mood.framesPerSecond(working: working) != crabMood.framesPerSecond(working: crabWorking)
        crabWorking = working
        guard mood != crabMood || tempoChanged else { return }
        let previous = crabMood
        crabMood = mood
        switch drawnIcon {
        case .web, .code:
            return                                     // one picture, nothing to restart
        case .crab:
            animTimer?.invalidate(); animTimer = nil   // recreated at the new tempo by render()
            guard mood != previous else { return }
        case .pet:
            // A pet runs every animation at the same tick, so the timer can keep going. But four
            // of the six moods draw the same one, and restarting a walk that was already walking
            // is a visible stutter standing for no change at all.
            guard mood.petRow != previous.petRow else { return }
        }
        frameIdx = 0
        iconCacheKey = ""
        iconCache.removeAll()
        statusItem.button?.image = nil
    }

    func renderResting() {
        render(label: "", color: crabRenderColor, animate: drawnIcon.restsInMotion, startedAt: 0)
    }



    // MARK: self-quit lifecycle

    // Asking LaunchServices about the desktop app on a timer is a synchronous XPC round-trip;
    // workspace launch/terminate notifications keep this flag instead. The authoritative query
    // runs only at the quit decision, so a missed notification can delay a quit by one debounce
    // but can never quit under a live app.
    var desktopRunning = false

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

    var claudeProbedAt: Double = 0
    var claudeWasRunning = false

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
    // short debounced grace (warmup-session churn must not kill us).
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        // An open Settings window or panel is someone using the app right now. Without this the
        // idle quit fires three seconds after the last session ends and closes what they are
        // looking at under their hands — which the panel made reachable in a way the menu did not:
        // a menu ran a modal tracking loop that the timer could not interrupt, a window does not.
        if settingsWindow?.isVisible == true || panelIsOpen {
            notNeededSince = nil
            return
        }
        if sessionCount() > 0 || desktopRunning {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            // The process table gets the last word. A session whose hooks never fired — no node
            // on the PATH, hooks switched off, settings sources that skip the user's file —
            // leaves no state file, and quitting on that evidence killed the app ten seconds
            // after launch with Claude Code running in a terminal the whole time.
            guard now.timeIntervalSince(since) >= idleQuitDelay, !agentRunning() else { return }
            // Notification-fed flag could have missed a launch (e.g. delivered while the run loop
            // was blocked); confirm with LaunchServices before the irreversible step.
            if claudeDesktopRunningLive() { desktopRunning = true; notNeededSince = nil; return }
            NSApp.terminate(nil)
        } else {
            notNeededSince = now
        }
    }


}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
