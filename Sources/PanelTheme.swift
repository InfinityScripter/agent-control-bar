import SwiftUI

// The panel's look in one place: sizes, the card surface, the section title, the state colours.
//
// Every surface branches on the colour scheme rather than leaning on one translucent black.
// An opacity that reads as a card against white reads as nothing at all against the near-black
// the menu material becomes in dark mode, and the panel is drawn on that material, not on a
// window background of its own.
enum PanelTheme {
    /// The panel is the width the menu was, so a user upgrading does not have to re-find anything
    /// in the menu bar. This is the default of the one knob that sets it — `boxWidth` in
    /// uiconfig.json — and the only place the number is written: the window is built from
    /// `boxWidth` too, or the window and the view it hosts disagree about how wide the panel is
    /// until the first resize catches up.
    static let width: CGFloat = 300
    static let pad: CGFloat = 9
    static let corner: CGFloat = 13
    static let cardCorner: CGFloat = 10
    /// The floor under the measured cap. The real ceiling comes from the screen the panel opens
    /// on (`StatusController.panelContentCap`) — a hand-computed constant here would be a guess
    /// about a screen this code can simply measure, and when the guess ran long the panel's top
    /// edge was quietly pushed up off its status item to make room.
    static let minContentHeight: CGFloat = 160

    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.028)
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        // The one setting that asks for a visible edge asks for it here: at a tenth of an opacity
        // a hairline is exactly what someone who turned that setting on cannot see.
        let raised = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return scheme == .dark
            ? Color.white.opacity(raised ? 0.26 : 0.085)
            : Color.black.opacity(raised ? 0.24 : 0.070)
    }

    /// A control or figure sitting inside a card — the limit tiles, the tab strip's trough.
    static func wellFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.035)
    }

    /// The selected tab: lighter than its trough in both modes, which is what makes it read as
    /// raised rather than merely tinted.
    static func raisedFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.92)
    }

    static func track(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.12)
    }

    /// The one meaning of "nearly out" in this app, borrowed rather than restated. This used to
    /// pick `.systemRed` / `.systemOrange` under a comment claiming it matched the menu bar gauge,
    /// which it did not: `Gauge.level` returns hand-picked sRGB values, so a 94% bar in the panel
    /// and the 94% strip beside the icon were two different reds.
    static func level(_ fraction: Double) -> Color? {
        Gauge.level(fraction).map(Color.init(nsColor:))
    }

    /// Fable's own hue: systemIndigo is tuned by the system for both appearances and for the
    /// increased-contrast setting, and it is the one accent the account windows never use, so the
    /// row cannot be mistaken for a third account window.
    static let fable = Color(nsColor: .systemIndigo)

    static func serverTint(_ state: String) -> Color {
        Color(nsColor: mcpTint(state))
    }
}

/// The surface the panel is drawn on.
///
/// SwiftUI's own `.regularMaterial` is a within-window blur: in a window whose background is clear
/// it samples nothing and the panel comes out transparent. An NSVisualEffectView in
/// `.behindWindow` mode is the one that samples the desktop, and `.menu` is the exact material the
/// dropdown this panel replaced was drawn on — so the panel does not read as some other app's
/// window that happened to open under the menu bar.
struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - building blocks

/// The rounded card every section is drawn on.
struct PanelCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PanelTheme.cardCorner, style: .continuous)
                    .fill(PanelTheme.cardFill(scheme)))
            .overlay(
                RoundedRectangle(cornerRadius: PanelTheme.cardCorner, style: .continuous)
                    .strokeBorder(PanelTheme.cardBorder(scheme), lineWidth: 0.7))
    }
}

/// The amber notice: something outside this app is holding a feature back, and the line
/// says which. One shape for both of them, because two hand-built copies of the same amber pill
/// drift apart at the first change of radius or tint — and an inconsistent warning reads as a
/// different KIND of warning. Whether the line is clickable is the caller's business: one opens
/// System Settings, the other has nowhere to go, since Codex asks for hook trust on its own screen.
/// A short title stays on one line; a longer message wraps, because the half that got cut off at
/// 300pt was the half saying what to do ("…The session is still shown. Try again.").
struct PanelNotice: View {
    let glyph: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: glyph).font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(nsColor: .systemOrange))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .systemOrange).opacity(0.12)))
    }
}

/// The small uppercase caption above a card. Trailing content is the right-hand accessory —
/// a count, a timestamp, the two icon buttons over the MCP list.
struct PanelSectionTitle<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.top, 11)
        .padding(.bottom, 5)
    }
}

/// The capsule bar under a limit figure and inside a context row.
struct PanelBar: View {
    @Environment(\.colorScheme) private var scheme
    /// The pixels-per-point of the screen this is drawn on, so the one-device-pixel floor below is
    /// one device pixel on a Retina display and on an external 1x monitor alike.
    @Environment(\.displayScale) private var displayScale
    let value: Double
    var fill: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PanelTheme.track(scheme))
                // Gauge.fillWidth, not a formula of our own: it rounds to the device pixel grid
                // and floors anything above zero at ONE device pixel. Hand-rolled here, the floor
                // was 1 point — two pixels on every Mac this runs on — so the panel's bar and the
                // strip beside the menu bar icon disagreed about what a nearly-empty window looks
                // like, which is the one thing they exist to agree about.
                Capsule().fill(fill)
                    .frame(width: Gauge.fillWidth(value, trackWidth: geo.size.width,
                                                  scale: displayScale))
            }
        }
        .frame(height: height)
    }
}

/// A limit window's bar, drawn the way T3 Code draws it, so one account reads the same in both.
/// The solid part is what is left. The hatched part is what has been spent and comes back at the
/// reset. The line is where the solid part would end by now under even spending: solid running
/// past the line is headroom, solid stopping short of it is a window that runs out early.
struct PanelLimitBar: View {
    @Environment(\.colorScheme) private var scheme
    /// The pixels-per-point of the screen this is drawn on, for the same reason PanelBar asks.
    @Environment(\.displayScale) private var displayScale
    /// How much of the window is left, 0…1.
    let left: Double
    var fill: Color
    /// Whether the spent part is hatched. Hatching says "this comes back", so a window that does
    /// not say when it resets gets a plain track instead.
    var refills: Bool
    /// How much of the window's time is left, 0…1, or nil when the window has no clock.
    var mark: Double?

    /// Twice PanelBar's hairline: a hatch needs a few points of height to read as one.
    static let height: CGFloat = 8
    /// Half the slot cut for the line, and how far the line stands clear of either end.
    private static let slot: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let solid = Gauge.fillWidth(left, trackWidth: width, scale: displayScale)
            let at = markOffset(in: width, solid: solid)
            ZStack(alignment: .leading) {
                PanelTheme.track(scheme)
                if refills {
                    PanelHatch().stroke(fill.opacity(0.55), lineWidth: 1)
                        .frame(width: max(0, width - solid))
                        .clipped()
                        .offset(x: solid)
                }
                fill.frame(width: solid)
            }
            // The line sits in a slot cut out of the bar, so it reads against the solid part,
            // the hatch and the bare track alike.
            .mask(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle().frame(width: at.map { $0 - Self.slot })
                    Color.clear.frame(width: at == nil ? 0 : Self.slot * 2)
                    Rectangle()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            .overlay(alignment: .leading) {
                if let at {
                    Capsule().fill(Color.primary)
                        .frame(width: 1.5, height: Self.height)
                        .offset(x: at - 0.75)
                }
            }
        }
        .frame(height: Self.height)
    }

    /// The line's place along the bar, on the device pixel grid. Gauge.markPosition decides it,
    /// as it does for the menu bar's bars: clear of both ends, and never over the whole of a
    /// small remainder. Nil when there is no clock, or no room for a slot.
    private func markOffset(in width: CGFloat, solid: CGFloat) -> CGFloat? {
        guard let mark, width >= Self.slot * 4 else { return nil }
        let at = Gauge.markPosition(mark, width: width, solid: solid, slot: Self.slot)
        return (at * displayScale).rounded() / displayScale
    }
}

/// Thin diagonal lines across a rectangle, leaning the way T3 Code's hatch leans.
struct PanelHatch: Shape {
    /// How far apart the lines start along the bottom edge.
    var spacing: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Each line climbs one bar-height to the right, so the first has to start a bar-height
        // before the left edge for the corner to be covered.
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

/// A row's trailing chevron, rotated when its detail is open.
struct PanelDisclosure: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(open ? 90 : 0))
    }
}

/// The three-letter surface badge on a session row: APP, IDE or CLI.
struct PanelTag: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(PanelTheme.wellFill(scheme)))
    }
}

/// The system's own indeterminate spinner at row size. Two callers — a working session and a
/// server being checked — and AppKit animates it, so it costs this process nothing per frame.
struct PanelSpinner: View {
    var body: some View {
        ProgressView().controlSize(.mini).scaleEffect(0.62).frame(width: 8, height: 8)
    }
}

/// A footer or section-header button: no border, a well behind it, and the whole thing is the
/// hit target rather than the glyph alone.
struct PanelButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, filled ? 9 : 4)
            .padding(.vertical, filled ? 5 : 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? PanelTheme.wellFill(scheme) : .clear)
                    .opacity(configuration.isPressed ? 0.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
