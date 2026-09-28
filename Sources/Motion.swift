import SwiftUI

/// Every moving part of the panel asks this type three questions: whether to move at all, for how
/// long, and on what curve.
///
/// One gate, for one reason. Motion has to be switchable off in a single place — the system's
/// Reduce Motion setting, or the user's own pick in Settings — and durations spread across six
/// files cannot be switched off at all. It is static state rather than a value threaded through
/// every view because the answer is the same for the whole app at any instant, and the window
/// chrome that asks (PanelWindow) is AppKit with nowhere to carry an Environment value.
///
/// The budget every rule here defends: an animation is committed once and then interpolated by the
/// render server, so the process does no work per frame. Nothing in this file may introduce a Timer
/// or a per-frame redraw. That, and not the number of animations, is what would cost a menu bar
/// app its battery.
enum Motion {

    // MARK: level

    enum Level: String, CaseIterable {
        case off, subtle, expressive

        var title: String {
            switch self {
            case .off:        return "Off"
            case .subtle:     return "Subtle"
            case .expressive: return "Expressive"
            }
        }

        /// What the row says under the name, so the choice can be made without trying all three.
        var detail: String {
            switch self {
            case .off:        return "No animation anywhere."
            case .subtle:     return "The panel, its cards and its switches move. Rows appear at once."
            case .expressive: return "Adds a staggered entrance for the rows in a list."
            }
        }
    }

    /// Set at launch from UserDefaults, and again whenever the user picks a level.
    static var level: Level = .subtle

    /// Read live rather than cached: it is a system setting the user can flip while the app runs,
    /// and an accessibility switch that needs a relaunch is not one that works.
    static var systemReducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Anything at all, a plain crossfade included.
    static var enabled: Bool { level != .off }

    /// Movement specifically — scale, slide, spring. Reduce Motion drops these and keeps the
    /// crossfade, which is the rule Apple states for it: replace motion, do not remove the
    /// feedback that something changed.
    static var moves: Bool { enabled && !systemReducesMotion }

    /// Row-by-row entrances. Expressive only, and never under Reduce Motion.
    static var staggers: Bool { level == .expressive && !systemReducesMotion }

    /// How much longer or shorter than the spec every duration runs at the current level. Reduce
    /// Motion shortens what is left rather than removing it; Expressive is a touch slower, because
    /// a longer curve is what makes a flourish readable instead of a flicker.
    static var rate: Double {
        guard enabled else { return 0 }
        if systemReducesMotion { return 0.6 }
        return level == .expressive ? 1.25 : 1
    }

    static func time(_ base: Double) -> Double { base * rate }

    // MARK: builders

    static func fade(from: Float, to: Float, seconds: Double,
                     curve: CAMediaTimingFunctionName = .easeOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = time(seconds)
        a.timingFunction = CAMediaTimingFunction(name: curve)
        return a
    }

    /// The panel arriving as a whole: it grows the last few percent into place rather than
    /// switching on. `origin` is the direction it comes from, in points — the panel uses the menu
    /// bar above it, so it appears to come out of the status item it hangs from.
    ///
    /// Core Animation rather than SwiftUI, because this animates the hosting window's own layer,
    /// which is outside the SwiftUI view it contains.
    static func appear(_ layer: CALayer, from origin: CGPoint, scale: CGFloat = 0.96,
                       seconds: Double = 0.19) {
        layer.removeAnimation(forKey: "hide")
        layer.add(fade(from: 0, to: 1, seconds: seconds), forKey: "appear")
        guard moves else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(origin.x, origin.y, 0)))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = time(seconds)
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "grow")
    }
}

/// A row's entrance when its list first appears. Expressive only.
///
/// Past the cap the rows arrive together: twenty MCP rows staggered at 16ms each would still be
/// arriving a third of a second after the panel was asked for, which is a panel that feels slow,
/// not alive.
struct PanelEntrance: ViewModifier {
    let index: Int
    // Not the State attribute: in the SDK it is a macro whose plugin ships only with Xcode, and
    // the plugin install builds this app with the Command Line Tools alone. CI rejects it here.
    private let _shown = State<Bool>(initialValue: false)
    private var shown: Bool {
        get { _shown.wrappedValue }
        nonmutating set { _shown.wrappedValue = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -5)
            .onAppear {
                guard Motion.staggers else { shown = true; return }
                withAnimation(.easeOut(duration: Motion.time(0.23))
                    .delay(min(Double(index) * 0.016, 0.18))) { shown = true }
            }
    }
}

extension View {
    func panelEntrance(_ index: Int) -> some View { modifier(PanelEntrance(index: index)) }
}
