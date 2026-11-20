import Cocoa
import SwiftUI

// The Usage window, drawn into PNG files without running the app.
//
//   CONTROL_BAR_RENDER_USAGE=<output dir>         switches the mode on (main.swift, first thing)
//   CONTROL_BAR_RENDER_FIXTURES=<state dir>       a directory shaped like ~/.claude/control-bar
//   CONTROL_BAR_RENDER_NOW=<epoch seconds>        the picture's frozen "now" (default: the clock)
//   CONTROL_BAR_RENDER_PERIOD=1|7|30|90           default 30
//   CONTROL_BAR_RENDER_SIZE=<W>x<H>               default 980x720
//   CONTROL_BAR_RENDER_PROVIDERS=claude,codex     which agents the app shows (default both)
//   CONTROL_BAR_RENDER_SCROLL=<points>            scroll the Limits page this far before its
//                                                 popover is opened (popover-window image only)
//
// Why it exists: this app's window cannot be looked at in a test run — the real one needs the
// user's menu bar, their state directory and their accounts. Here nothing is live: the files come
// from the fixture directory, no controller is created (so no status item, timers, hooks check or
// backend), and the store has nobody to send an action to. The snapshot is built by the same
// builder the app uses (UsageSnapshot(_:) in UsageData.swift) and drawn by the same views.
//
// Written: usage-{cost,tokens,limits}-{light,dark}.png, the dialogs as the window with the dialog
// over it (usage-model-*, usage-prices-*, usage-limits-confirm-*), the account popover's content
// alone (usage-limits-popover-*) and the Limits tab with `store.popover` set to that same window
// (usage-limits-popover-window-*), panel-footer-*.png for the panel's entry-point button, and
// usage-snapshot.txt with the figures behind the pictures.
enum UsageRender {
    static func run(output: String, environment: [String: String]) -> Int32 {
        let fixtures = environment["CONTROL_BAR_RENDER_FIXTURES"] ?? ""
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fixtures, isDirectory: &isDirectory), isDirectory.boolValue else {
            FileHandle.standardError.write(Data("CONTROL_BAR_RENDER_FIXTURES is not a directory: \(fixtures)\n".utf8))
            return 2
        }
        do {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(output): \(error.localizedDescription)\n".utf8))
            return 2
        }
        let now = environment["CONTROL_BAR_RENDER_NOW"].flatMap(Double.init) ?? Date().timeIntervalSince1970
        let days = environment["CONTROL_BAR_RENDER_PERIOD"].flatMap(Int.init)
            .flatMap { UsageSummary.periodDays.contains($0) ? $0 : nil } ?? 30
        let size = environment["CONTROL_BAR_RENDER_SIZE"].flatMap(Self.size) ?? UsageWindowLook.size
        let shown = environment["CONTROL_BAR_RENDER_PROVIDERS"].map { list in
            Provider.all.map(\.id).filter { list.split(separator: ",").map(String.init).contains($0) }
        } ?? Provider.all.map(\.id)
        let scroll = environment["CONTROL_BAR_RENDER_SCROLL"].flatMap(Double.init).map { CGFloat(max(0, $0)) } ?? 0

        // Needed to make windows at all; .prohibited keeps the process out of the Dock and from
        // ever coming to the front. No window here is put on screen.
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Still pictures of a settled window. With motion on, the popover and the dialogs fade
        // in, and a picture taken mid-fade shows them translucent — or not, depending on how
        // busy this Mac is. Only this process is told; nobody's preference is written.
        Motion.level = .off

        let store = UsageStore(controller: nil, defaults: nil)
        store.publish(snapshot(fixtures: fixtures, now: now, providers: shown))

        var written: [String] = []
        var skipped: [String] = []
        var failed = false
        let save = { (name: String, image: NSBitmapImageRep?) in
            let path = (output as NSString).appendingPathComponent(name)
            if let data = image?.representation(using: .png, properties: [:]),
               (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                written.append(path)
            } else {
                failed = true
                FileHandle.standardError.write(Data("could not write \(path)\n".utf8))
            }
        }

        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: name) else { continue }
            let window = { (tab: UsageTab, surface: UsageSurface?) -> NSBitmapImageRep? in
                store.preview(tab: tab, days: days, surface: surface)
                return windowImage(UsageView(store: store), size: size, appearance: appearance)
            }
            for tab in UsageTab.allCases {
                save("usage-\(tab.rawValue)-\(suffix).png", window(tab, nil))
            }

            store.preview(tab: .cost, days: days)
            if let model = store.previewModel {
                save("usage-model-\(suffix).png", window(.cost, .model(model.id)))
            } else {
                skipped.append("usage-model-\(suffix).png (no model in this fixture)")
            }
            save("usage-prices-\(suffix).png", window(.cost, .prices(model: nil)))
            // The editor as "Set price" opens it: a row for the first model without a price.
            store.preview(tab: .cost, days: days)
            if let unpriced = store.totals.models.first(where: \.isCostUnknown) {
                save("usage-prices-set-\(suffix).png", window(.cost, .prices(model: unpriced.model)))
            } else {
                skipped.append("usage-prices-set-\(suffix).png (no unpriced model in this fixture)")
            }

            store.preview(tab: .limits, days: days)
            if let request = store.previewReset {
                save("usage-limits-confirm-\(suffix).png", window(.limits, .resetConfirm(request)))
            } else {
                skipped.append("usage-limits-confirm-\(suffix).png (no credit to redeem in this fixture)")
            }
            store.preview(tab: .limits, days: days)
            if let pick = store.previewPopover {
                let popover = UsageAccountPopover(store: store, state: pick.state, row: pick.row)
                    .foregroundStyle(UsageTheme.foreground)
                    .padding(24)
                    .background(UsageTheme.background)
                save("usage-limits-popover-\(suffix).png", fittedImage(popover, appearance: appearance))
                // The same popover where the tab puts it, for a tab that draws it from
                // `store.popover`; a tab that does not shows its plain self here.
                // Opened after the scroll, as a click would: scrolling puts an open one away.
                let target = UsagePopoverTarget(provider: pick.state.provider, row: pick.row.id)
                save("usage-limits-popover-window-\(suffix).png",
                     windowImage(UsageView(store: store), size: size, appearance: appearance, scroll: scroll) {
                         store.preview(tab: .limits, days: days, popover: target)
                     })
            } else {
                skipped.append("usage-limits-popover-\(suffix).png (no limit window in this fixture)")
            }
            save("panel-footer-\(suffix).png", fittedImage(PanelFooterProbe(), appearance: appearance))
        }

        store.preview(tab: .limits, days: days)
        let dump = (output as NSString).appendingPathComponent("usage-snapshot.txt")
        if (try? describe(store, days: days).write(toFile: dump, atomically: true, encoding: .utf8)) != nil {
            written.append(dump)
        } else {
            failed = true
        }
        print(written.joined(separator: "\n"))
        if !skipped.isEmpty { print("skipped:\n" + skipped.map { "  " + $0 }.joined(separator: "\n")) }
        return failed ? 1 : 0
    }

    // MARK: the picture

    /// The fixture directory read the way the app reads the real one. The limits files go through
    /// the same parsers the panel's loaders use; the rest through UsageFiles itself.
    static func snapshot(fixtures: String, now: Double, providers: [String]) -> UsageSnapshot {
        let object = { (name: String) -> [String: Any]? in
            FileManager.default.contents(atPath: (fixtures as NSString).appendingPathComponent(name))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        var files = UsageFiles()
        files.reload(root: fixtures)
        var inputs = UsageInputs(now: now, providers: providers)
        inputs.limits = [
            Provider.claude.id: UsageLimitsInput(set: object("limits.json").flatMap(Limits.init(json:))?.set,
                                                 status: object("limits-status.json").flatMap(LimitsStatus.init(json:))),
            Provider.codex.id: UsageLimitsInput(set: object("codex/limits.json").flatMap(LimitsSet.init(codex:)),
                                                status: object("codex/limits-status.json").flatMap(LimitsStatus.init(json:))),
        ]
        inputs.files = files
        // The picture of a window opened ten minutes before "now": a reset that ended since then
        // is announced under its bars, an older one is history.
        inputs.resetNewsSince = now - 600
        // Opening the window starts a scan when there is no summary, so that moment looks like
        // the skeleton — unless the fixture says the scan has just failed.
        inputs.usageRunning = files.summary == nil && files.scan?.state != "failed"
        inputs.hour12 = UsageFormat.uses12HourClock(.current)
        return UsageSnapshot(inputs)
    }

    // MARK: drawing

    /// The whole window, title bar included, as the app builds it — but never ordered on screen.
    /// cacheDisplay rather than ImageRenderer: the header's menus are AppKit controls, and
    /// ImageRenderer draws those as a yellow "not supported" box.
    /// `scroll` moves the page first; `then` runs after that and before the picture is taken.
    private static func windowImage<Content: View>(_ view: Content, size: NSSize, appearance: NSAppearance,
                                                    scroll: CGFloat = 0, then: () -> Void = {}) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        UsageWindowLook.apply(to: window)
        window.appearance = appearance
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        settle(window)
        if scroll > 0, let page = window.contentView.flatMap(scrollView(in:)) {
            page.contentView.scroll(to: NSPoint(x: 0, y: scroll))
            page.reflectScrolledClipView(page.contentView)
            settle(window)
        }
        then()
        settle(window)
        // The frame view, so the picture has the traffic lights the page is laid out around.
        return (window.contentView?.superview ?? window.contentView).flatMap { bitmap(of: $0, appearance: appearance) }
    }

    /// The page's scroll view: the first one under the hosting view.
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let found = view as? NSScrollView { return found }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    /// A view at the size it asks for, on nothing.
    private static func fittedImage<Content: View>(_ view: Content, appearance: NSAppearance) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        settle(window)
        return bitmap(of: host, appearance: appearance)
    }

    /// SwiftUI commits its first layout and its onAppear work on the run loop, not in the call
    /// that installed the view.
    private static func settle(_ window: NSWindow) {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// Always 2x, whatever display this Mac has: twice the pixels of the view's size in points.
    private static func bitmap(of view: NSView, appearance: NSAppearance) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let blank = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Double(bounds.width * 2).clampedInt,
                                           pixelsHigh: Double(bounds.height * 2).clampedInt, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              // Tagged sRGB before anything is drawn, so the theme's sRGB values land in the file
              // as written rather than converted for whatever display is attached.
              let rep = blank.retagging(with: .sRGB)
        else { return nil }
        rep.size = bounds.size
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: rep) }
        return rep
    }

    private static func size(_ text: String) -> NSSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 200, parts[1] >= 200, parts[0] <= 4000, parts[1] <= 4000 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }

    // MARK: the figures as text

    /// What the pictures were drawn from, so a number in a PNG can be checked without reading it
    /// off the pixels.
    static func describe(_ store: UsageStore, days: Int) -> String {
        let snapshot = store.snapshot
        var lines = ["now \(snapshot.now.clampedInt)  providers \(snapshot.providers.joined(separator: ","))"
                        + "  hour12 \(snapshot.hour12)"]
        lines.append("Limits")
        for state in snapshot.limits {
            let limits = state.limits
            lines.append("  \(limits.title) — plan \(limits.plan ?? "-") · email \(limits.email ?? "-")"
                + " · poll \(state.status?.state ?? "-") · tickets \(limits.ticketCount)")
            for row in limits.rows {
                let reset = UsageLimitText.resetsIn(row.resetsAt, now: snapshot.now, style: .refill) ?? "no reset"
                lines.append("    \(row.label) [\(row.id)] \(row.remainingPercent)% left · used \(row.usedPercent)%"
                    + " · \(reset) · pace \(row.pace ?? "-") · even \(row.evenPacePercent.map { "\($0)%" } ?? "-")"
                    + " · hatch \(row.hatchPercent)% · restores \(row.restoresPercent.map { "+\($0)%" } ?? "-")")
            }
            for choice in limits.resetChoices(now: snapshot.now) {
                lines.append("    [reset] \(choice.summary) — \(choice.actionLabel)"
                    + (choice.redeemable ? "" : "  (not redeemable)"))
            }
            if let status = state.resetStatus { lines.append("    [status] \(limits.title) \(status)") }
            if state.resetNeedsRefresh { lines.append("    [status] refresh limits before the next reset") }
            if let notice = state.notice { lines.append("    [notice] \(notice)") }
        }
        lines.append("Usage — phase \(snapshot.usagePhase) · pricing \(snapshot.pricing?.status ?? "-")"
            + " · error \(snapshot.usageError ?? "-")")
        for tab in [UsageTab.cost, .tokens] {
            store.preview(tab: tab, days: days)
            lines.append("  header (\(tab.title)): \(store.statusLine)")
        }
        if let summary = snapshot.summary?.summary {
            for period in UsageSummary.periodDays {
                let totals = UsageTotals(period: summary.period(period), provider: store.usageProvider)
                lines.append("  \(period)d: \(UsageFormat.usd(totals.costUsd)) · \(UsageFormat.tokens(totals.totalTokens)) tokens"
                    + " · \(UsageFormat.count(totals.sessions)) sessions · \(totals.models.count) models"
                    + " · unpriced \(UsageFormat.percent(totals.costQuality.unpricedShare))")
                for provider in totals.providers {
                    lines.append("    \(UsageCopy.providerName(provider.provider)): \(UsageFormat.usd(provider.costUsd))"
                        + " · \(UsageFormat.tokens(provider.totalTokens)) tokens")
                }
                for warning in summary.period(period).warnings(provider: store.usageProvider) {
                    lines.append("    [warning] \(warning)")
                }
            }
        }
        lines.append("Prices — \(snapshot.prices.customModels.joined(separator: ", "))")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The panel's footer at the panel's own width, in its three situations: no limits note, a
/// one-provider note beside the buttons, and two providers' note on a row of its own. The buttons
/// are the real ones (PanelFooterButtons); only the row around them is repeated from PanelView.
private struct PanelFooterProbe: View {
    private static let width: CGFloat = PanelTheme.width - 2 * PanelTheme.pad

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            footer(note: "", stacked: false)
            footer(note: "Limits · 59 min ago", stacked: false)
            footer(note: "Claude 1d ago · Codex just now", stacked: true)
        }
        .padding(PanelTheme.pad)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func footer(note: String, stacked: Bool) -> some View {
        let line = Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        return VStack(alignment: .leading, spacing: 5) {
            if stacked { line }
            HStack(spacing: 8) {
                if !stacked { line.fixedSize() }
                PanelFooterButtons(usage: {}, settings: {}, quit: {})
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 3)
        .frame(width: Self.width)
        .border(Color.red.opacity(0.25), width: 0.5)
    }
}
