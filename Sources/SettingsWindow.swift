import Cocoa
import SwiftUI

// The Settings window: an ordinary titled window hosting the SwiftUI pages, plus the three things
// an LSUIElement app has to do by hand before one of those is actually usable.
extension StatusController {

    /// The app's own name, read rather than written: identity lives in identity.env and reaches
    /// the binary only through Info.plist, so spelling it here would be a second copy to keep in
    /// step. The fallback is the executable's name, which is that same value by another route.
    var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    @objc func openSettingsWindow() {
        // The pets folder is somebody else's — Codex and its galleries write into it while this
        // app runs — and this is the one screen that lists it, so it is re-read here rather than
        // on a timer or once at launch.
        reloadPetLibrary()
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        if window.contentViewController == nil { installSettingsPages(in: window) }
        // An accessory app has no Dock tile and cannot be brought to the front the ordinary way:
        // its window opens behind whatever the user was looking at and never becomes key, so the
        // controls in it do not take the keyboard. Becoming .regular for as long as Settings is
        // open is what makes it an ordinary window — and windowWillClose puts it back, or the app
        // keeps a Dock icon it has never had.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        installMainMenuIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        // .miniaturizable so the Window menu's Minimize is not a dead row.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "Settings"
        window.contentMinSize = NSSize(width: 620, height: 420)
        // Kept and reopened rather than rebuilt: without this the window is deallocated on close
        // and the next open lands on a dangling reference.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
        return window
    }

    /// The pages, built for each opening: windowWillClose takes them out again, and says why.
    private func installSettingsPages(in window: NSWindow) {
        let host = NSHostingController(rootView: SettingsView(store: settingsStore))
        // Empty on purpose. Every automatic option here (.intrinsicContentSize, .preferredContentSize)
        // hands the window's size to the SwiftUI content, and these pages differ enough in
        // height that the window would resize itself on every sidebar click.
        host.sizingOptions = []
        // A window resizes itself to the controller it is handed. The frame is the user's — where
        // they left the window and how large — so it is put back.
        let frame = window.frame
        window.contentViewController = host
        window.setFrame(frame, display: false)
    }

    /// A menu bar for the window to live under.
    ///
    /// An accessory app has no main menu, and going .regular without one leaves the bar empty
    /// except for the Apple menu — which reads as a broken app rather than a deliberate one. It
    /// also gives the window the two shortcuts anyone will try on it: ⌘W and ⌘M.
    /// Not private: the Usage window is the second window that needs it.
    func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsWindow),
                                       keyEquivalent: ",")
        settings.target = self
        let usageItem = appMenu.addItem(withTitle: "Usage…", action: #selector(openUsageWindow),
                                        keyEquivalent: "u")
        usageItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let quitItem = appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(quit),
                                       keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    // Becoming key covers both moments the stored answer is worth re-reading: the window opening,
    // and the user coming back from System Settings having just changed it.
    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        refreshNotificationAuthStatus()
    }

    // Back to an accessory the moment the last ordinary window goes away. The .regular policy
    // above is what puts this app in the Dock and in Cmd-Tab, and it has no business being in
    // either once the windows it was raised for are gone. Two windows raise it now — Settings and
    // Usage — so closing one must not take the Dock icon from under the other. A minimised window
    // still counts: it is in the Dock, and an accessory app has no Dock to keep it in.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              closing === settingsWindow || closing === usageWindow else { return }
        let other = closing === settingsWindow ? usageWindow : settingsWindow
        if other?.isVisible != true && other?.isMiniaturized != true {
            NSApp.setActivationPolicy(.accessory)
        }
        if closing === settingsWindow {
            // The pet picker draws every pet, so it holds every pet's frames. The panel needs one.
            // Emptying the caches is half of giving them back: the pickers hold what they were last
            // handed, a closed window never asks again, and so the pages went on keeping a decoded
            // sheet for every pet in the library. Only the pages going away lets go of those — the
            // window stays, with its place on screen, and opens on General again next time.
            releasePetPreviews()
            settingsWindow?.contentViewController = nil
        } else {
            usageWindowClosed()
        }
    }
}
