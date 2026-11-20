import SwiftUI

// The Usage window's look in one place. Unlike the panel, which is drawn on the menu material in
// adaptive system colours, this window copies T3 Code's Usage page: its fixed palette, radii and
// control shapes (its index.css tokens, resolved for the default light and dark themes). The rest
// of the app keeps its own look — nothing outside the Usage* files may use these.
//
// Every colour is dynamic: it picks its light or dark value from the appearance it is drawn in,
// so a view never has to read the colour scheme to use a token.
enum UsageTheme {

    // MARK: tokens

    /// The page itself, and the selected segment in light mode.
    static let background = token(light: 0xfcfcfc, dark: 0x000000)
    static let foreground = token(light: 0x18181b, dark: 0xf5f5f5)
    /// Bar tracks and quiet strips.
    static let muted = token(light: 0xfafafa, dark: 0xffffff, darkAlpha: 0.03)
    /// Secondary text and glyphs.
    static let mutedForeground = token(light: 0x71717b, dark: 0xa1a1a1)
    /// Raised surfaces: dialogs, popovers, outline buttons.
    static let card = token(light: 0xffffff, dark: 0x111111)
    static let border = token(light: 0xe4e4e7, dark: 0xffffff, darkAlpha: 0.08)
    /// T3's `border/60`: cards and the dividers inside them.
    static let borderSoft = token(light: 0xe4e4e7, dark: 0xffffff, lightAlpha: 0.6, darkAlpha: 0.048)
    /// Control outlines, and the base of the segmented trough.
    static let input = token(light: 0xd4d4d8, dark: 0xffffff, darkAlpha: 0.11)
    /// Hover and pressed backgrounds.
    static let accent = token(light: 0xf4f4f5, dark: 0xffffff, darkAlpha: 0.04)
    /// The one filled button (a confirmation) and focus rings.
    static let primary = token(light: 0x1b4ed8, dark: 0x346bf1)
    static let primaryForeground = Color.white
    static let warning = token(light: 0xfe9a00, dark: 0xfe9a00)
    static let warningForeground = token(light: 0xbb4d00, dark: 0xffb900)
    static let warningSurface = token(light: 0xfe9a00, dark: 0xfe9a00, lightAlpha: 0.08, darkAlpha: 0.16)
    static let warningBorder = token(light: 0xfe9a00, dark: 0xfe9a00, lightAlpha: 0.32, darkAlpha: 0.32)
    static let destructive = token(light: 0xfb2c36, dark: 0xfb414a)
    static let destructiveForeground = token(light: 0xc10007, dark: 0xff6467)
    /// What a dialog dims the page with.
    static let scrim = token(light: 0xfcfcfc, dark: 0x000000, lightAlpha: 0.6, darkAlpha: 0.64)
    /// Placeholder blocks while the first figures load.
    static let skeleton = token(light: 0x71717b, dark: 0xa1a1a1, lightAlpha: 0.15, darkAlpha: 0.15)

    // The segmented control's three surfaces are mixes of the tokens above that differ per
    // appearance (`bg-input/40`; selected `bg-background` or, dark, `bg-input/72`).
    static let segmentTrough = token(light: 0xd4d4d8, dark: 0xffffff, lightAlpha: 0.4, darkAlpha: 0.044)
    static let segmentSelected = token(light: 0xfcfcfc, dark: 0xffffff, darkAlpha: 0.0792)
    static let segmentHover = token(light: 0xfcfcfc, dark: 0xffffff, lightAlpha: 0.55, darkAlpha: 0.0352)

    /// A provider's series, dot and bar: Claude's orange, Codex in the foreground colour.
    static func provider(_ id: String) -> Color { color(UsagePalette.provider(id)) }

    /// A colour the models hand over as two hex numbers (share-bar segments, provider inks).
    static func color(_ ink: UsageInk) -> Color { token(light: ink.light, dark: ink.dark) }

    // MARK: shape and type

    /// T3's radius scale: sm 4, md 6, lg 8, xl 12, 2xl 16.
    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 16
    }

    /// The widest the page's content gets (`max-w-5xl`), and the dialogs' own limits.
    static let pageWidth: CGFloat = 1024
    /// T3's header is 48 tall (`min-h-12`): one row, or the title with a 12pt line under it.
    static let headerHeight: CGFloat = 48

    /// The system font at T3's sizes: 10, 11, 12, 14, 16, 20, 24, 30, 36.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: -

    private static func token(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

// MARK: - shared pieces

/// Tells its content whether the pointer is over it. One wrapper for every hover surface of the
/// window, because each of them would otherwise carry the same three lines of state.
struct UsageHover<Content: View>: View {
    // Not the State attribute: its macro plugin ships only with Xcode (see Motion.swift).
    private let hovered = State(initialValue: false)
    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) { self.content = content }

    var body: some View {
        content(hovered.wrappedValue).onHover { hovered.wrappedValue = $0 }
    }
}

/// A provider's mark at the size a caller needs: the same glyph the panel tells the agents apart
/// by, in the provider's Usage colour.
struct UsageProviderMark: View {
    let provider: String
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: Provider.named(provider).glyph)
            .font(.system(size: size * 0.72, weight: .medium))
            .foregroundStyle(UsageTheme.provider(provider))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// One choice of a segmented control.
struct UsageSegment<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    /// The tooltip, e.g. "Cost (C)".
    var help: String = ""

    var id: Value { value }
}

/// T3's segmented control (its period and metric switches): a trough with one raised segment.
/// Pressing the selected segment does nothing, as there.
struct UsageSegmented<Value: Hashable>: View {
    let label: String
    let segments: [UsageSegment<Value>]
    let selection: Value
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                UsageHover { hovered in cell(segment, hovered: hovered) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: UsageTheme.Radius.lg, style: .continuous)
            .fill(UsageTheme.segmentTrough))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    // The colours are worked out as typed values first: left inline, each of these choices is
    // one more thing Swift 6.0 has to solve together with the whole modifier chain.
    private func cell(_ segment: UsageSegment<Value>, hovered: Bool) -> some View {
        let selected = segment.value == selection
        let text: Color = selected || hovered ? UsageTheme.foreground : UsageTheme.mutedForeground
        let fill: Color = selected ? UsageTheme.segmentSelected : (hovered ? UsageTheme.segmentHover : .clear)
        let shadow: Color = .black.opacity(selected ? 0.1 : 0)
        let traits: AccessibilityTraits = selected ? .isSelected : []
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.md, style: .continuous)
        return Button { if !selected { select(segment.value) } } label: {
            Text(segment.label)
                .font(UsageTheme.font(12, .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(text)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(shape.fill(fill).shadow(color: shadow, radius: 1, y: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(segment.help.isEmpty ? segment.label : segment.help)
        .accessibilityAddTraits(traits)
    }
}

/// T3's ghost icon button: a 28pt square that only shows a surface under the pointer. While
/// `busy` it is disabled and the glyph gives way to the system's own spinner — the one moving
/// part docs/motion.md allows to run for as long as something takes.
struct UsageIconButton: View {
    let symbol: String
    let label: String
    var symbolSize: CGFloat = 14
    var side: CGFloat = 28
    var busy = false
    let action: () -> Void

    var body: some View {
        UsageHover { hovered in
            Button(action: action) { face(hovered: hovered) }
                .buttonStyle(UsagePressStyle())
                .disabled(busy)
                .help(label)
                .accessibilityLabel(label)
        }
    }

    private func face(hovered: Bool) -> some View {
        let fill: Color = hovered && !busy ? UsageTheme.accent : .clear
        return ZStack {
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Image(systemName: symbol).font(.system(size: symbolSize))
            }
        }
        .foregroundStyle(UsageTheme.mutedForeground)
        .frame(width: side, height: side)
        .background(RoundedRectangle(cornerRadius: UsageTheme.Radius.lg, style: .continuous).fill(fill))
        .contentShape(Rectangle())
    }
}

/// The press feedback every T3 button shares: a 3% shrink, and 64% opacity while disabled.
struct UsagePressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && Motion.moves ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.64)
    }
}

/// T3's text buttons. `outline` is the everyday one ("Cancel", "Use reset", "Set price"),
/// `primary` the single confirming action of a dialog, `ghost` a quiet one ("Discard changes").
struct UsageButtonStyle: ButtonStyle {
    enum Variant { case outline, primary, ghost }
    /// xs is 24pt tall with 12pt text (inside popovers and tables), regular is 32pt with 14pt.
    enum Size { case xs, regular }

    var variant: Variant = .outline
    var size: Size = .regular
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let small = size == .xs
        let text: Color = variant == .primary ? UsageTheme.primaryForeground : UsageTheme.foreground
        let pressed = configuration.isPressed
        let scale: CGFloat = pressed && Motion.moves ? 0.97 : 1
        return UsageHover { hovered in
            configuration.label
                .font(UsageTheme.font(small ? 12 : 14, .medium))
                .lineLimit(1)
                .foregroundStyle(text)
                .padding(.horizontal, small ? 7 : 11)
                .frame(height: small ? 24 : 32)
                .background(surface(hovered: hovered || pressed))
                .contentShape(Rectangle())
                .scaleEffect(scale)
                .opacity(enabled ? 1 : 0.64)
        }
    }

    @ViewBuilder
    private func surface(hovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.lg, style: .continuous)
        switch variant {
        case .outline:
            shape.fill(UsageTheme.card)
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                .overlay(shape.fill(UsageTheme.accent).opacity(hovered ? 1 : 0))
                .overlay(shape.strokeBorder(UsageTheme.input, lineWidth: 1))
        case .primary:
            shape.fill(UsageTheme.primary).opacity(hovered ? 0.9 : 1)
        case .ghost:
            shape.fill(UsageTheme.accent).opacity(hovered ? 1 : 0)
        }
    }
}

/// The surface of a dialog: T3's popup with a 16pt radius, a hairline and a deep shadow. The
/// root view puts the tabs' dialog contents inside it; a tab never builds this itself.
struct UsageDialogSurface<Content: View>: View {
    /// Nil for a confirmation, which has its own two buttons and no ✕.
    let close: (() -> Void)?
    let content: Content

    init(close: (() -> Void)?, @ViewBuilder content: () -> Content) {
        self.close = close
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.xxl, style: .continuous)
        content
            .overlay(alignment: .topTrailing) {
                if let close {
                    UsageIconButton(symbol: "xmark", label: "Close (Esc)", symbolSize: 13, side: 32, action: close)
                        .padding(8)
                }
            }
            .clipShape(shape)
            // The shadow is the plain shape's, not the content's: a shadow on the whole dialog
            // would have every redraw of a chart inside it rasterised a second time.
            .background(shape.fill(UsageTheme.card).shadow(color: .black.opacity(0.3), radius: 32, y: 24))
            .overlay(shape.strokeBorder(UsageTheme.border, lineWidth: 1))
    }
}
