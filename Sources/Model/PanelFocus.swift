import Foundation

/// Whether closing the panel gives the keyboard back to the app it was opened over.
///
/// Opening makes this app active, because a panel in an inactive app never takes the keyboard.
/// An accessory app has no window of its own to fall back to once the panel is gone, so after
/// Esc the keys went nowhere until the person clicked their editor again.
///
/// Asked only where the panel closes without another app being chosen: Esc and a second click on
/// the icon. A click past the panel or on a session row has already said where the focus goes.
enum PanelFocus {
    static func handsBack(appActive: Bool, previousRunning: Bool, settingsVisible: Bool) -> Bool {
        // Not active means the person has switched somewhere already, and activating the old app
        // would pull the focus off the one they just chose. A visible Settings window is this
        // app's own, and the keyboard belongs to it.
        appActive && previousRunning && !settingsVisible
    }
}
