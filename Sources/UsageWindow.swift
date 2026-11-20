import Cocoa
import SwiftUI

// The Usage window: an ordinary resizable window like Settings, the commands it runs and when it
// runs them. What it draws is built in UsageData.swift; nothing here parses a command's output —
// each one rewrites its files and the loaders re-read them.

/// What the window's glue remembers between ticks. One value in main.swift rather than a dozen
/// properties: all of it is about a window most runs never open.
struct UsageRuntime {
    var files = UsageFiles()
    /// The frozen clock of the picture; see `UsageSnapshot.now`.
    var now: Double = 0
    /// When the window was last opened: a reset result older than this is not announced.
    var openedAt = Double.infinity
    /// The `usage` command is in flight. One at a time — a second one would only be refused by
    /// the script's own lock, with exit 1 and a log line.
    var scanRunning = false
    /// A scan was asked for while one ran, for a reason the running one cannot have seen (new
    /// prices, a pressed refresh): run once more when it lands. Holds the `refresh` flag to use.
    var scanAgain: Bool?
    var scanFailed = false
    var resetBusy: Set<String> = []
    /// Providers whose last redemption command ended without writing a result.
    var resetUnanswered: Set<String> = []
    var resetDismissed: [String: Double] = [:]
}

extension StatusController {
    var usageWindowVisible: Bool { usageWindow?.isVisible == true }

    // MARK: window

    @objc func openUsageWindow() {
        let window = usageWindow ?? makeUsageWindow()
        usageWindow = window
        let wall = Date().timeIntervalSince1970
        // Not while a redemption is running: its result is news for whoever started it, and a
        // window closed and reopened meanwhile would otherwise file it under history.
        if !window.isVisible, usage.resetBusy.isEmpty {
            usage.openedAt = wall
            usage.resetDismissed = [:]
            usage.resetUnanswered = []
        }
        usage.now = wall
        loadUsageFiles()
        // Opening is the moment the figures get looked at, so both halves are asked for afresh:
        // the limits through the panel's own debounced path, the summary when it has aged.
        pollLimits()
        scanUsageIfStale()
        usageStore.refresh()
        // The same three things Settings does to become a usable window; see openSettingsWindow.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        installMainMenuIfNeeded()
        installUsageKeys()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeUsageWindow() { usageWindow?.performClose(nil) }

    private func makeUsageWindow() -> NSWindow {
        let host = NSHostingController(rootView: UsageView(store: usageStore))
        // Empty for the reason Settings gives: the three tabs differ in height, and a window that
        // resized itself on every tab switch would not stay where it was put.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        UsageWindowLook.apply(to: window)
        window.setContentSize(UsageWindowLook.size)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        return window
    }

    /// Called by windowWillClose. Nothing is torn down: the window is kept, and a command still
    /// running finishes into the files whether or not anyone is looking.
    func usageWindowClosed() {
        if let monitor = usageKeyMonitor { NSEvent.removeMonitor(monitor) }
        usageKeyMonitor = nil
        usageStore.closeSurface()
        usageStore.hidePopover()
    }

    // MARK: keys

    /// The window's shortcuts, read off the physical key so they survive a keyboard layout that
    /// types another letter there — which SwiftUI's own key equivalents do not for a bare C, T or
    /// L. Installed only while the window is open.
    private func installUsageKeys() {
        guard usageKeyMonitor == nil else { return }
        usageKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.usageKey(event) == true ? nil : event
        }
    }

    /// True when the key was one of the window's and has been acted on.
    private func usageKey(_ event: NSEvent) -> Bool {
        guard let window = usageWindow, event.window === window,
              let shortcut = UsageShortcut.match(keyCode: event.keyCode, modifiers: event.modifierFlags)
        else { return false }
        // Typing wins: a C in a price cell is a C. Esc still closes the dialog the field is in —
        // unless an input method is mid-composition, where Esc belongs to it.
        if let text = window.firstResponder as? NSTextView {
            guard shortcut == .dismiss, !text.hasMarkedText() else { return false }
        }
        // A held key is one press. Its repeats are still swallowed: passed on, each would reach
        // a window with nothing to type into and be answered with the system beep.
        if !event.isARepeat { usageStore.perform(shortcut) }
        return true
    }

    // MARK: refresh policy

    /// The tick's share while the window is visible: pick up rewritten files and move the frozen
    /// clock into the new minute. Returns nothing — refreshCounts republishes right after.
    func tickUsageWindow(wall: Double) {
        loadUsageFiles()
        if UsageClock.minuteChanged(frozen: usage.now, wall: wall) { usage.now = wall }
    }

    /// The tab or the period was switched: the moment the figures get looked at again, so the
    /// clock moves and whatever that tab shows is asked for afresh if it has aged. T3 re-reads
    /// its summary on a period switch too; here all four periods arrive in one scan.
    func usageSelectionChanged(tab: UsageTab) {
        usage.now = Date().timeIntervalSince1970
        if tab == .limits { pollLimits() } else { scanUsageIfStale() }
        usageStore.refresh()
    }

    /// The header's refresh button.
    func refreshUsage(tab: UsageTab) {
        if tab == .limits { refreshUsageLimits() } else { scanUsage(refresh: true) }
    }

    private func scanUsageIfStale() {
        let wall = Date().timeIntervalSince1970
        guard UsageClock.summaryIsStale(readAt: usage.files.summary?.summary.readAt, now: wall) else { return }
        scanUsage(refresh: false)
    }

    /// Run `mcpbar.py usage`. `rerun` says the caller needs a scan that starts after this moment
    /// even if one is already running — the user pressed refresh, or the prices just changed.
    func scanUsage(refresh: Bool, rerun: Bool = false) {
        if usage.scanRunning {
            if rerun { usage.scanAgain = (usage.scanAgain ?? false) || refresh }
            return
        }
        usage.scanRunning = true
        // The store directly, not refreshCounts: what a command of the window's did is published
        // whether or not the window is still visible, so no spinner outlives its command.
        usageStore.refresh()
        runQuietCommand(.usage(refresh: refresh)) { [weak self] succeeded in
            guard let self else { return }
            self.usage.scanRunning = false
            self.usage.scanFailed = !succeeded
            self.loadUsageFiles()
            self.usage.now = Date().timeIntervalSince1970
            if let again = self.usage.scanAgain {
                self.usage.scanAgain = nil
                self.scanUsage(refresh: again)
            }
            self.usageStore.refresh()
        }
    }

    /// Ask both providers for limits now. The panel's polls are debounced because opening it
    /// twice in a minute is not a request; a pressed refresh button is one. Still one flight per
    /// provider: a poll already on its way — the window's own opening poll, usually — is the
    /// answer, not a reason for a second. Both go through the panel's own poll functions, so
    /// the timers and the debounces are re-armed exactly as after any other poll.
    private func refreshUsageLimits() {
        let wall = Date().timeIntervalSince1970
        pollClaudeLimits(now: wall, force: true)
        pollCodexLimits(now: wall, force: true)
        usage.now = wall
        usageStore.refresh()
    }

    /// A limits poll is on its way, whoever asked for it: the refresh button spins and stands
    /// back for the timer's poll and the opening one as much as for its own.
    var usageLimitsRefreshing: Bool {
        codexLimitsPoll.inFlight || ClaudeLimitsPoll.inFlight(
            now: Date().timeIntervalSince1970, lastStart: lastLimitsPoll, running: claudeLimitsRunning)
    }

    /// A limits poll came back, whoever asked for it. With the window on screen its files are
    /// read now rather than at the next tick, so the bars and the plan line change together,
    /// and the frozen clock moves as T3's does after every refresh that settles. With the window
    /// closed only the store is told, so no spinner outlives its poll.
    func usageLimitsLanded() {
        guard usageWindow != nil else { return }
        guard usageWindowVisible else {
            usageStore.refresh()
            return
        }
        loadLimits()
        loadLimitsStatus()
        loadCodexLimits()
        loadCodexLimitsStatus()
        loadUsageFiles()
        usage.now = Date().timeIntervalSince1970
        refreshCounts()
    }

    // MARK: prices

    var usagePricesPath: String { (root as NSString).appendingPathComponent(UsageFiles.pricesName) }

    /// Write the editor's plan through the model's own save. A rescan follows only when the
    /// settings changed: prices and mappings are applied by the scan, and the summary on screen
    /// was counted with the old ones.
    func saveUsagePrices(_ editor: inout UsagePriceEditor) -> Bool {
        guard editor.canSave else { return false }
        let before = editor.saved
        do {
            try editor.save(at: usagePricesPath)
        } catch {
            NSLog("ClaudeControlBar: could not save usage prices: \(error)")
            return false
        }
        usage.files.saved(editor.saved)
        if editor.saved != before { scanUsage(refresh: false, rerun: true) }
        usageStore.refresh()
        return true
    }

    // MARK: reset credits

    /// Spend one banked reset credit. Only ever from the confirmation the user just accepted —
    /// it cannot be undone. The script holds its own lock and idempotency key; the flag here is
    /// what keeps a second click from starting a second process at all (the approveCodexHooks
    /// pattern). Its answer is the result file, never the exit code alone.
    ///
    /// The model's rule is asked here again, of the state as it is now and not as the window last
    /// drew it: after an attempt that ended unknown only its own retry may be sent, whatever a
    /// button still on screen says (UsageProviderState.mayRedeem).
    func redeemUsageReset(provider: String, creditId: String?) {
        guard usageSnapshot().limits.first(where: { $0.provider == provider })?
            .mayRedeem(creditId: creditId) == true else { return }
        usage.resetBusy.insert(provider)
        usage.resetDismissed[provider] = nil
        usage.resetUnanswered.remove(provider)
        let asked = Date().timeIntervalSince1970
        usageStore.refresh()
        runQuietCommand(.resetCredit(provider: provider, creditId: creditId)) { [weak self] _ in
            guard let self else { return }
            self.usage.resetBusy.remove(provider)
            // The command re-polled limits itself after an answer, so every file it touches is
            // re-read now rather than at the next tick: the bars and the line change together.
            self.loadLimits()
            self.loadLimitsStatus()
            self.loadCodexLimits()
            self.loadCodexLimitsStatus()
            self.loadUsageFiles()
            // The script writes its result on every run. A run that left none — it never
            // started, died first, or sent nothing and left the record of an open attempt
            // standing — still has to end in a sentence: with no line at all,
            // someone who just pressed "Use credit" cannot tell a refusal from silence. The
            // result's stamp is in whole seconds, hence the rounding.
            if (self.usage.files.resetResults[provider]?.ts ?? 0) < asked.rounded(.down) {
                self.usage.resetUnanswered.insert(provider)
            }
            self.usage.now = Date().timeIntervalSince1970
            self.refreshCounts()
            self.usageStore.refresh()
        }
    }

    func dismissUsageResetStatus(provider: String) {
        usage.resetDismissed[provider] = usage.files.resetResults[provider]?.ts
        usage.resetUnanswered.remove(provider)
        usageStore.refresh()
    }
}

/// How the window looks as a window, in one place because the render mode builds the same one
/// off screen: the title bar is transparent and shows the page's own background, so the page
/// reads as one T3-style sheet with the traffic lights on it instead of a grey bar above it.
enum UsageWindowLook {
    static let size = NSSize(width: 980, height: 720)
    static let minimumSize = NSSize(width: 760, height: 520)

    static func apply(to window: NSWindow) {
        // The title is kept for the Window menu and Mission Control; the page prints its own.
        window.title = "Usage"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // .miniaturizable so the Window menu's Minimize is not a dead row.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.contentMinSize = minimumSize
        // Under the transparent title bar before SwiftUI has drawn, and around it while resizing.
        window.backgroundColor = NSColor(UsageTheme.background)
    }
}
