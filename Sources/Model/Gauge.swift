import Cocoa

/// The two numbers worth a glance without opening anything: how much of the 5-hour limit is gone,
/// and how much of the weekly one. Each bar is labelled, because an unlabelled pair of bars only
/// says "something is filling up".
///
/// Context deliberately does NOT appear here. It is per session, and someone can have ten
/// sessions open — there is no single honest number to draw, and picking the busiest one would
/// be a figure that jumps between projects for no visible reason. Context lives in the menu,
/// on the row of the session it belongs to. Limits are per account, so one bar is the truth.
struct Gauge {
    var fiveHour: Double?
    var sevenDay: Double?
    /// What the two bars are called. Claude's pair is fixed, so it is the default; Codex reports
    /// the length of its own windows and a plan can carry a pair that is neither 5 hours nor a
    /// week, which is why the labels are passed in rather than spelled here.
    var labels: (String, String) = ("5h", "7d")

    /// Everything that changes what the bars look like, in one string — the part of the cache key
    /// for a composed menu bar icon that this type owns.
    var signature: String {
        rows.map { "\($0.0)\(($0.1 * 100).rounded().clampedInt)" }.joined(separator: ",")
    }

    var rows: [(String, Double)] {
        [(labels.0, fiveHour), (labels.1, sevenDay)].compactMap { label, value in
            value.map { (label, $0) }
        }
    }
    var isEmpty: Bool { rows.isEmpty }

    // Geometry is the width budget, so it lives in one place. The menu bar is not elastic: an
    // item that does not fit is not clipped, it is parked off-screen behind the overflow
    // chevron. Labelled bars cost about 45pt beside the icon.
    static let barW: CGFloat = 20, barH: CGFloat = 3
    static let labelW: CGFloat = 15, labelGap: CGFloat = 3
    static let rowH: CGFloat = 9, rowGap: CGFloat = 2
    static let sideInset: CGFloat = 3, iconGap: CGFloat = 5
    /// Ceiling, not a fixed size: the crab frames are wider than tall and must keep their shape.
    static let iconMaxW: CGFloat = 28

    /// Honest fill width: round(percent × track width) in device pixels, nothing else. The old
    /// formula floored the fill at barH (3pt of a 20pt track), so every value from 0 to 15%
    /// drew the same stub and 18% read as "almost empty". A wrong small number must still be
    /// a small number, not a lie in either direction.
    static func fillWidth(_ value: Double, trackWidth: CGFloat = barW, scale: CGFloat = 2) -> CGFloat {
        let pct = min(max(value, 0), 1)
        let honest = (trackWidth * pct * scale).rounded() / scale
        // One device pixel is the floor for anything above zero — the battery gauge makes the
        // same promise, so "critically low" and "empty" stay distinguishable.
        return pct > 0 ? max(honest, 1 / scale) : 0
    }

    /// The label as VoiceOver should read it. "5h" out loud is "five aitch", which is not what a
    /// screen reader should say about a five-hour window; anything the app has no word for is
    /// read as it is rather than mislabelled as one of the two it knows.
    static func spoken(_ label: String) -> String {
        guard let unit = label.last, let count = Int(label.dropLast()) else { return label }
        let word: String
        switch unit {
        case "h": word = "hour"
        case "d": word = "day"
        case "m": word = "minute"
        default: return label
        }
        return "\(count) \(word)"
    }

    static func level(_ value: Double) -> NSColor? {
        // nil means "neutral": nothing alarming, so the whole image can stay a template and
        // behave like every other menu bar icon — light on a dark bar, dark on a light one.
        if value >= 0.90 { return NSColor(srgbRed: 0.90, green: 0.25, blue: 0.20, alpha: 1) }
        if value >= 0.75 { return NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 1) }
        return nil
    }

    /// `icon` is the icon the app was about to show anyway — a spark frame, a crab frame, or the
    /// amber "Needs you" badge. Template icons use their alpha as ink; full-colour icons
    /// keep their own pixels so semantic red/fire and the Orange crab survive the composite.
    ///
    /// Neutral parts are painted with NSColor.labelColor rather than a hand-picked black or
    /// white, and that is the whole trick. There is no reliable way to ask "is the menu bar
    /// dark": the bar is translucent over the wallpaper, and two independent measurements of
    /// statusItem.button.effectiveAppearance on the same dark bar disagreed — one read
    /// VibrantLight, and it flips to VibrantDark merely because the menu is open and the item is
    /// highlighted. A dynamic colour dodges the question: it resolves at draw time, against
    /// whatever appearance the menu bar is actually drawing in.
    func image(icon: NSImage?) -> NSImage {
        let shown = rows
        let h = NSStatusBar.system.thickness
        // The icon keeps its own aspect: crab frames are 25.5x18, and forcing them into an 18pt
        // square squeezes them by 29%.
        let iconSize = icon.map { NSSize(width: min($0.size.width, Gauge.iconMaxW),
                                         height: min($0.size.height, h)) } ?? .zero
        let strip = Gauge.labelW + Gauge.labelGap + Gauge.barW
        let w = Gauge.sideInset * 2 + (icon != nil ? iconSize.width + Gauge.iconGap : 0) + strip
        // One coloured bar makes the whole image non-template: the system tints a template by
        // alpha alone, so a hue cannot survive in one.
        let template = shown.allSatisfy { Gauge.level($0.1) == nil } && (icon?.isTemplate ?? true)
        let blockH = CGFloat(shown.count) * Gauge.rowH
            + CGFloat(max(shown.count - 1, 0)) * Gauge.rowGap
        let y0 = ((h - blockH) / 2).rounded()   // whole points: crisp at 1x, 2x and 3x alike
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)

        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            var x = Gauge.sideInset
            if let icon {
                let box = NSRect(x: x, y: ((h - iconSize.height) / 2).rounded(),
                                 width: iconSize.width, height: iconSize.height)
                if !icon.isTemplate {
                    icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                } else if template {
                    // Alpha is all the system will read, so draw the frame as-is and let it ink.
                    icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                } else {
                    NSColor.labelColor.setFill()
                    box.fill()
                    icon.draw(in: box, from: .zero, operation: .destinationIn, fraction: 1)
                }
                x += iconSize.width + Gauge.iconGap
            }
            // Top row first: 5h above 7d, the same order the menu lists them in.
            for (i, row) in shown.enumerated() {
                let y = y0 + CGFloat(shown.count - 1 - i) * (Gauge.rowH + Gauge.rowGap)
                let colour = Gauge.level(row.1)
                NSAttributedString(string: row.0, attributes: [
                    .font: font,
                    .foregroundColor: colour ?? NSColor.labelColor.withAlphaComponent(0.65),
                ]).draw(at: NSPoint(x: x, y: y))

                let barX = x + Gauge.labelW + Gauge.labelGap
                let barY = y + ((Gauge.rowH - Gauge.barH) / 2).rounded()
                let radius = Gauge.barH / 2
                let track = NSBezierPath(roundedRect: NSRect(x: barX, y: barY,
                                                             width: Gauge.barW,
                                                             height: Gauge.barH),
                                         xRadius: radius, yRadius: radius)
                NSColor.labelColor.withAlphaComponent(0.30).setFill()
                track.fill()
                // The fill is a straight-edged rect clipped by the track capsule — the way the
                // system battery gauge draws its charge. A rounded fill of its own eats the
                // width of small values: at 18% a 3.6pt capsule with 1.5pt corners reads as a
                // dot, and the honest number looks like 5%.
                let filled = Gauge.fillWidth(row.1)
                if filled > 0 {
                    NSGraphicsContext.current?.saveGraphicsState()
                    track.setClip()
                    (colour ?? NSColor.labelColor).setFill()
                    NSRect(x: barX, y: barY, width: filled, height: Gauge.barH).fill()
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
            return true
        }
        image.isTemplate = template
        // Drawn bars carry no text the system can read, so without this the item is silent to
        // VoiceOver — a regression against the plain label it replaces.
        image.accessibilityDescription = shown
            .map { "\(Gauge.spoken($0.0)) limit \(($0.1 * 100).rounded().clampedInt)%" }
            .joined(separator: ", ")
        return image
    }
}
