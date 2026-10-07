import Cocoa
import UserNotifications

// Banners for the MCP picture, and the one macOS permission this app asks for.

extension StatusController {
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
        for banner in change.notifications { notify(title: banner.title, body: banner.body) }
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
}
