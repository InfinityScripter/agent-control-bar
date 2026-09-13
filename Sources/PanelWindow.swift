import Cocoa
import SwiftUI

// The window the panel lives in.
//
// Not an NSMenu, because a menu cannot be re-laid-out while it is open (Sources/Menu.swift used to
// say so at the top, and docs/motion.md still records what that cost: no accordion, no tab switch,
// no row appearing under a click). Not an NSPopover either — ToolCard.swift already documents why
// that was rejected here: it brings its own light bubble and anchor arrow, foreign against the
// menu material this app is drawn on.
//
// So: the same shape HoverCard already uses — a borderless window at .popUpMenu level over an
// NSVisualEffectView — with the two differences a panel needs and a hover card must not have. It
// takes mouse events, and it can become key, because every control in it is clickable and the
// keyboard shortcuts have to reach somewhere.
final class PanelHostWindow: NSWindow {
    // A borderless window is not key-eligible by default, and without this the switches take
    // clicks but ⌘R, ⌘, and ⌘Q go nowhere and VoiceOver has nothing to focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCancel: (() -> Void)?

    /// Escape, and anything else AppKit routes to cancelOperation. A panel that cannot be
    /// dismissed from the keyboard is a trap for whoever opened it from the keyboard.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

extension StatusController {

    var panelIsOpen: Bool { panelWindow?.isVisible == true }

    /// A click that lands this soon after the panel closed is the tail of the click that closed
    /// it, not a new request to open.
    private static let reopenGuard: TimeInterval = 0.3

    /// The status item's click. A second click closes, the way a menu would.
    ///
    /// The guard is not defensive programming, it is the whole reason a second click works at all.
    /// Clicking the status item makes the menu bar's own window key, so the panel resigns key and
    /// windowDidResignKey closes it — and only THEN does the button's action arrive here, find a
    /// closed panel, and open it straight back. Without the guard the icon could open the panel
    /// but never close it.
    @objc func togglePanel() {
        if panelIsOpen { closePanel(); return }
        guard Date().timeIntervalSince1970 - panelClosedAt > Self.reopenGuard else { return }
        openPanel()
    }

    func openPanel() {
        // Opening the panel is the moment the picture gets looked at, so it is the moment to
        // notice it has gone stale. Not on EVERY open, though: a check costs about 34 seconds and
        // nearly all of it is `claude mcp list` starting every configured server and waiting for
        // each to answer. Two minutes means a burst of opens costs one check.
        if !mcpBusy, Date().timeIntervalSince1970 - mcp.checkedAt > Self.mcpOpenStaleAfter {
            refreshMCP()
        }
        // A sleeping Mac misses timer ticks, so the five-minute cadence can silently become an
        // hour. Opening is the moment the figures get looked at — worth a poll if the reading is
        // older than the timer could explain.
        if Date().timeIntervalSince1970 - (limits?.ts ?? 0) > 600 { pollLimits() }
        checkForUpdate()          // refreshes the update cache for next open (gated to once a day)
        refreshNotificationAuthStatus()
        // Branches otherwise refresh only on hook events, so re-read on open (one tiny file read
        // per session) to catch a checkout made while a session sat idle. On open, not on every
        // 2.5 Hz refresh: this walks directories toward the filesystem root.
        for (id, s) in sessions where !s.cwd.isEmpty {
            if gitHeadCache[s.cwd] == "" { gitHeadCache[s.cwd] = nil }  // may have been git-init'd since
            var u = s; u.branch = branchForCwd(u.cwd); sessions[id] = u
        }

        panelStore.collapseAll()          // every open starts collapsed
        panelStore.refreshUpdateBase()    // the one moment the bundle on disk can have changed
        panelStore.refresh()

        let window = panelWindow ?? makePanelWindow()
        panelWindow = window
        // Inherit the appearance of the menu bar, not of the app: a window of its own resolves
        // labelColor against NSApp.effectiveAppearance, and the menu bar is not obliged to agree
        // with it — a dark wallpaper turns the bar dark while the system stays light.
        if let button = statusItem.button { window.appearance = button.effectiveAppearance }
        positionPanel(window)
        // An accessory app is not active, and a panel opened from an inactive app never takes the
        // keyboard — the switches would work and every shortcut would not.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startPanelDismissWatch()
        if Motion.enabled, let layer = window.contentView?.layer {
            // It comes out of the status item it belongs to: the offset points back up at the
            // menu bar, so the panel grows downward into view.
            Motion.appear(layer, from: CGPoint(x: 0, y: 8))
        }
    }

    func closePanel() {
        stopPanelDismissWatch()
        panelClosedAt = Date().timeIntervalSince1970
        panelWindow?.orderOut(nil)
    }

    /// Where the panel hangs: under the status item, right edge aligned with the button's, pulled
    /// back onto the screen when the item sits near a corner. A crowded menu bar can park the item
    /// off-screen entirely (measured at x ≈ −8650 on this machine), and anchoring to that would
    /// put the panel off-screen with it — so an anchor outside the visible frame falls back to the
    /// top-right of the screen the pointer is on.
    private func positionPanel(_ window: NSWindow) {
        let size = window.frame.size
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var anchor = CGPoint(x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 4)
        if let button = statusItem.button, let host = button.window {
            let frame = host.convertToScreen(button.convert(button.bounds, to: nil))
            if visible.intersects(frame) {
                anchor.x = min(max(frame.maxX - size.width, visible.minX + 8),
                               visible.maxX - size.width - 8)
                anchor.y = frame.minY - size.height - 4
            }
        }
        window.setFrameOrigin(NSPoint(x: anchor.x, y: max(anchor.y, visible.minY + 8)))
    }

    private func makePanelWindow() -> PanelHostWindow {
        let host = NSHostingController(rootView: PanelView(store: panelStore))
        // The panel is the one window in this app whose height is genuinely content-driven: two
        // sessions and twenty servers are different windows. .preferredContentSize hands the size
        // to SwiftUI, and windowDidResize below re-pins the top edge so it grows downward.
        host.sizingOptions = [.preferredContentSize]

        // Built at the width the CONTENT will use, not at a constant beside it: the view frames
        // itself at boxWidth, and a window that started at a different number would sit at the
        // wrong anchor until the first resize moved it.
        let window = PanelHostWindow(
            contentRect: NSRect(x: 0, y: 0, width: boxWidth, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        window.isOpaque = false
        window.backgroundColor = .clear
        // The shadow is computed from the alpha channel, and the rounded material inside the
        // SwiftUI view is what supplies it — so the shadow follows the corners rather than
        // squaring them off. It has to be invalidated whenever the content resizes.
        window.hasShadow = true
        window.level = .popUpMenu       // 101, what NSPopupMenuWindow itself uses
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                                     .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.onCancel = { [weak self] in self?.closePanel() }
        window.delegate = self
        return window
    }

    // MARK: NSWindowDelegate

    /// Switching to another app closes the panel, the way a menu closes. Settings is not an
    /// exception to work around: opening it goes through closePanel() first.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panelWindow else { return }
        closePanel()
    }

    /// SwiftUI resizes the window from the bottom-left, so growing content would push the panel's
    /// top edge up into the menu bar. The top is the edge that must not move: it is pinned to the
    /// status item the panel hangs from.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panelWindow,
              window.isVisible else { return }
        positionPanel(window)
        window.invalidateShadow()
    }

    // MARK: dismissal

    /// Clicking anywhere else closes the panel, which is the one menu behaviour a window of our
    /// own does not inherit. A global monitor is enough on its own: it never fires for events
    /// delivered to our own windows, so clicks inside the panel are not mistaken for clicks past
    /// it. The status item's own click is a different case entirely and is handled in
    /// togglePanel() — it never reaches a monitor at all, because the status bar is ours too.
    private func startPanelDismissWatch() {
        stopPanelDismissWatch()
        panelClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.closePanel()
            }
    }

    private func stopPanelDismissWatch() {
        if let monitor = panelClickMonitor { NSEvent.removeMonitor(monitor) }
        panelClickMonitor = nil
    }

    // MARK: the text dump

    /// What CONTROL_BAR_DUMP_MENU prints. Looking at the real thing is not a reliable check: a
    /// crowded menu bar parks the status item off-screen behind a manager's chevron, so the panel
    /// can be perfectly healthy and completely invisible. This reads the panel that would be drawn
    /// — and, near enough, what VoiceOver would say about it.
    func describePanel() -> String {
        // The banner is cached from the open path, and the dump never opens the panel — without
        // this the one thing someone runs the dump to check ("is it offering the update?") is the
        // one thing it could never print.
        panelStore.refreshUpdateBase()
        panelStore.refresh()
        let snapshot = panelStore.snapshot
        var lines: [String] = []
        if let update = snapshot.update {
            lines.append("[update] \(update.kind) \(update.version)"
                + (update.stage.map { " — \($0)" } ?? ""))
        }
        // The layout the strip is in is printed too: with two providers the dump is the only
        // place to check that the switcher is showing the one it was left on.
        lines.append("Limits — " + snapshot.limitsNote
            + (snapshot.limitGroups.count > 1 ? "  [\(snapshot.limitsLayout.rawValue)]" : ""))
        // The same fallback the strip uses: a remembered pick whose provider has no figures
        // right now shows the first group instead, and the dump has to agree with the window.
        let showing = snapshot.limitGroups.first { $0.provider == snapshot.limitsProvider }?.provider
            ?? snapshot.limitGroups.first?.provider
        for group in snapshot.limitGroups {
            let hidden = snapshot.limitGroups.count > 1
                && snapshot.limitsLayout == .switcher
                && group.provider != showing
            lines.append("  \(group.tip)"
                + (group.resets.map { "  resets in \($0)" } ?? "")
                + (hidden ? "  [behind the switcher]" : ""))
            for limit in group.limits {
                lines.append("    \(limit.title)\(limit.badge.map { " [\($0)]" } ?? "") \(limit.used)%"
                    + (limit.resets.map { "  resets in \($0)" } ?? ""))
            }
        }
        lines.append("Sessions (\(snapshot.sessions.count))")
        for session in snapshot.sessions {
            // session.subtitle, not a second spelling of it: the row draws that exact sentence, and
            // the point of this dump is to say what the row says.
            lines.append("  \(session.name) · \(session.subtitle)"
                + (session.pct.map { "  ctx \(session.assumed ? "~" : "")\($0)%" } ?? "")
                + (session.tag.isEmpty ? "" : "  " + session.tag))
        }
        if snapshot.offerOpenClaude { lines.append("  Open Claude") }
        lines.append("MCP — \(snapshot.mcp.summary) · \(snapshot.mcp.toolsLine)")
        if let change = snapshot.mcp.change { lines.append("  changed: \(change)") }
        for group in snapshot.mcp.groups {
            lines.append("  \(group.title)")
            for server in group.servers {
                lines.append("    \(server.state) \(server.name)  \(server.tail)"
                    + (server.enabled ? "" : "  [off]")
                    + (server.tools.isEmpty ? "" : "  (\(server.tools.count) tools)"))
            }
        }
        if !snapshot.mcp.waitingAuth.isEmpty {
            lines.append("  Waiting for authorisation — run /mcp in a terminal")
            for name in snapshot.mcp.waitingAuth { lines.append("    \(name)") }
        }
        if let error = snapshot.mcp.error { lines.append("  Check failed: \(error)") }
        if snapshot.notificationsDenied { lines.append("Notifications are off") }
        lines.append("Settings…   ⌘,")
        lines.append("Quit   ⌘Q")
        return lines.joined(separator: "\n")
    }
}
