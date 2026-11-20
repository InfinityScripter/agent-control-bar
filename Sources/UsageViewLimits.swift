import SwiftUI

// The Limits tab of the Usage window: T3 Code's pooled limits page for one account per provider.
// A section per provider, a card per limit window, and on each card the bar T3 draws — what is
// left as a fill, what the next reset gives back as a hatch, and a tick where an even spender
// would stand. Clicking a bar opens the account popover over the page; "Use reset" in it asks
// for a confirmation, and the result of the redemption is a line under the provider's cards.
//
// Every figure and sentence comes from UsageLimitsModel.swift; this file only places them. The
// sizes are T3's (its UsageLimitsPooled.tsx), in points for its CSS pixels.
//
// Four types are built by other files and keep their names and initialisers:
//   UsageLimitsTab(store:)                   the tab body
//   UsagePopoverLayer(store:anchors:)        the open popover, placed over the whole window
//   UsageAccountPopover(store:state:row:)    the popover, surface included
//   UsageResetConfirm(store:request:)        the content of "Use a reset credit?"

// MARK: - the tab

struct UsageLimitsTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if store.limits.isEmpty {
                UsageLimitsQuietLine(text: Self.noProviders)
            }
            ForEach(sections) { state in
                UsageLimitsSection(store: store, state: state)
            }
            if !store.limitNotices.isEmpty {
                UsageLimitNotices(notices: store.limitNotices)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// A provider without a window to draw is left out when the notices box already says why
    /// (a failed poll, a signed-out agent), as in T3; otherwise its section says what is missing.
    private var sections: [UsageProviderState] {
        store.limits.filter { !$0.limits.rows.isEmpty || $0.notice == nil || $0.resetStatus != nil }
    }

    private static let noProviders: String = "No agent is shown. Turn Claude or Codex on in"
        + " Settings to see its limits."
}

extension UsageStore {
    /// A click on a bar: open its popover, move the popover there, or close the one it has.
    func togglePopover(provider: String, row: String) {
        if popover == UsagePopoverTarget(provider: provider, row: row) {
            hidePopover()
        } else {
            showPopover(provider: provider, row: row)
        }
    }
}

/// Where a bar is, under the target that opens its popover.
struct UsageBarAnchor {
    let target: UsagePopoverTarget
    let bounds: Anchor<CGRect>
}

/// Every bar on the page reports itself, so the one popover can be hung on any of them.
struct UsageBarAnchors: PreferenceKey {
    static let defaultValue: [UsageBarAnchor] = []

    static func reduce(value: inout [UsageBarAnchor], nextValue: () -> [UsageBarAnchor]) {
        value += nextValue()
    }
}

/// The open account popover, over the whole window. The root view lays this over the header and
/// the page rather than the tab drawing it inside the page: in there the scroll view clipped it —
/// a popover under the last bar of a short window lost its buttons below the edge, with nothing
/// to scroll — and it could not lie over the header as T3's does.
///
/// The anchors move with the page, so the popover follows its bar as the page scrolls. Once the
/// bar has left the page altogether there is nothing to point at, and the popover is not drawn
/// until the bar comes back.
struct UsagePopoverLayer: View {
    @ObservedObject var store: UsageStore
    let anchors: [UsageBarAnchor]

    var body: some View {
        GeometryReader { proxy in
            if let target = store.popover, let pick = store.popoverRow,
               let anchor = anchors.last(where: { $0.target == target }),
               proxy[anchor.bounds].maxY > UsageTheme.headerHeight, proxy[anchor.bounds].minY < proxy.size.height {
                UsagePopoverPlacement(bar: proxy[anchor.bounds]) {
                    UsageAccountPopover(store: store, state: pick.state, row: pick.row)
                        // A popover moved to another window starts with the e-mail hidden again.
                        .id(target.provider + "/" + target.row)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.enabled ? .easeOut(duration: Motion.time(0.15)) : nil, value: store.popover)
    }
}

/// Puts the popover where T3 does — centred over its bar, 6pt above it — and under the bar when
/// there is no room above. Whatever the bar's place, the popover stays whole inside the window,
/// 8pt from its edges: in a window too short for either side it lies over its own bar rather
/// than lose the buttons at its bottom.
private struct UsagePopoverPlacement: Layout {
    let bar: CGRect

    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let popover = subviews.first else { return }
        let size = popover.sizeThatFits(.unspecified)
        let above = bar.minY - Self.gap - size.height
        let preferred = above >= Self.margin ? above : bar.maxY + Self.gap
        let y = max(Self.margin, min(preferred, bounds.height - Self.margin - size.height))
        let x = max(Self.margin, min(bar.midX - size.width / 2, bounds.width - Self.margin - size.width))
        popover.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading,
                      proposal: ProposedViewSize(size))
    }
}

// MARK: - a provider's section

private struct UsageLimitsSection: View {
    // Observed, like every view below that reads the store's published state: a plain reference
    // looks unchanged to SwiftUI across a publish, and the body that reads it would not rerun.
    @ObservedObject var store: UsageStore
    let state: UsageProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                UsageProviderLogo(provider: state.provider)
                Text(state.limits.title).font(UsageTheme.font(14, .medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(state.limits.rows, id: \.id) { row in
                UsageLimitCard(store: store, state: state, row: row)
            }
            if state.limits.rows.isEmpty {
                UsageLimitsQuietLine(text: emptyText)
            }
            if let status = state.resetStatus {
                UsageResetStatusLine(store: store, state: state, status: status)
            }
        }
    }

    /// Why there is no card. A failed poll and a signed-out agent are not here: those are the
    /// notices box's to explain, and such a provider has no section at all.
    private var emptyText: String {
        if !state.pollEnabled { return "Limits are switched off in Settings." }
        return store.snapshot.limitsRefreshing ? "Reading limits…" : "No limits yet."
    }
}

/// A muted sentence where cards would be.
private struct UsageLimitsQuietLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(UsageTheme.font(14))
            .foregroundStyle(UsageTheme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The provider's logo in T3's 20pt box: the same two images the panel's strip is headed with.
private struct UsageProviderLogo: View {
    let provider: String

    private static let claude = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:))
    private static let codex = Data(base64Encoded: codexLogoPNG).flatMap(NSImage.init(data:))

    var body: some View {
        Group {
            if provider == Provider.codex.id, let image = Self.codex {
                Image(nsImage: image).renderingMode(.original).resizable().scaledToFit()
            } else if provider == Provider.claude.id, let image = Self.claude {
                // A black silhouette: drawn in the text colour, as T3 draws its provider glyphs.
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(UsageTheme.foreground.opacity(0.8))
            } else {
                UsageProviderMark(provider: provider, size: 16)
            }
        }
        .frame(width: 16, height: 16)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

// MARK: - a window card

private struct UsageLimitCard: View {
    let store: UsageStore
    let state: UsageProviderState
    let row: UsageLimitRow

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            summary.frame(width: 176, alignment: .leading)
            // T3's two bar sizes, picked by the width the bar gets: from 672pt up the countdown
            // sits inside a 32pt bar, under that the bar is 20pt and the countdown has a row
            // of its own below.
            ViewThatFits(in: .horizontal) {
                UsageLimitBar(store: store, state: state, row: row, wide: true)
                    .frame(minWidth: 672)
                VStack(spacing: 4) {
                    UsageLimitBar(store: store, state: state, row: row, wide: false)
                    UsageLimitLegend(store: store, state: state, row: row)
                }
            }
        }
        // 16 inside a 1pt border that T3 counts on top of the padding.
        .padding(17)
        .overlay(RoundedRectangle(cornerRadius: UsageTheme.Radius.lg)
            .strokeBorder(UsageTheme.borderSoft, lineWidth: 1))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label)
                .font(UsageTheme.font(14, .medium))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(row.remainingPercent)%")
                    .font(UsageTheme.font(30, .semibold))
                    .monospacedDigit()
                Text("left")
                    .font(UsageTheme.font(14))
                    .foregroundStyle(UsageTheme.mutedForeground)
                if let pace = row.pace {
                    UsagePaceIcon(pace: pace)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// T3's three pace glyphs (lucide's trending-up, gauge, trending-down), drawn on their 24-unit
/// grid: SF Symbols has no plain trend arrow, and the nearest ones carry a chart's axes.
private struct UsagePaceIcon: View {
    let pace: String

    var body: some View {
        let label = UsageLimitText.paceLabel(pace)
        UsagePaceGlyph(pace: pace)
            .stroke(UsageTheme.mutedForeground,
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            .frame(width: 14, height: 14)
            // Sits on the text's baseline like the glyph of a font would.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            .contentShape(Rectangle())
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
    }
}

private struct UsagePaceGlyph: Shape {
    let pace: String

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let point = { (x: Double, y: Double) in CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        switch pace {
        case "ahead":
            path.addLines([point(22, 7), point(13.5, 15.5), point(8.5, 10.5), point(2, 17)])
            path.addLines([point(16, 7), point(22, 7), point(22, 13)])
        case "under":
            path.addLines([point(22, 17), point(13.5, 8.5), point(8.5, 13.5), point(2, 7)])
            path.addLines([point(16, 17), point(22, 17), point(22, 11)])
        default:
            // The dial: 240 degrees of a circle around (12, 14), open at the bottom, and a needle.
            let arc = stride(from: 150.0, through: 390.0, by: 10).map { degrees -> CGPoint in
                let angle = degrees * .pi / 180
                return point(12 + 10 * cos(angle), 14 + 10 * sin(angle))
            }
            path.addLines(arc)
            path.addLines([point(12, 14), point(16, 10)])
        }
        return path
    }
}

// MARK: - the bar

/// The bar of one window: a button that opens the account popover, T3's "segment".
private struct UsageLimitBar: View {
    @ObservedObject var store: UsageStore
    let state: UsageProviderState
    let row: UsageLimitRow
    let wide: Bool

    var body: some View {
        let target = UsagePopoverTarget(provider: state.provider, row: row.id)
        let open = store.popover == target
        let label = row.accessibilityLabel(name: state.limits.title, credits: state.limits.ticketCount,
                                           now: store.snapshot.now)
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.md)
        return Button { store.togglePopover(provider: target.provider, row: target.row) } label: {
            UsageLimitBarTrack(row: row, color: UsageTheme.provider(state.provider))
                .frame(height: wide ? 32 : 20)
                .overlay(alignment: .trailing) {
                    if wide { UsageResetChip(state: state, row: row, now: store.snapshot.now).padding(.horizontal, 8) }
                }
                // T3 rings the bar its popup is open on.
                .overlay(shape.strokeBorder(UsageTheme.border, lineWidth: 1).opacity(open ? 1 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .anchorPreference(key: UsageBarAnchors.self, value: .bounds) { [UsageBarAnchor(target: target, bounds: $0)] }
    }
}

/// What the bar draws under its countdown: the track, the fill for what is left, the hatch for
/// what the next reset gives back, and the pace tick in a slot cut through all three.
///
/// One Canvas rather than stacked shapes, because the slot has to be cut out of the track, the
/// fill and the hatch alike, and the hatch is a pattern no shape has. Nothing here animates: a
/// bar must never be seen passing through a value it does not have (docs/motion.md).
private struct UsageLimitBarTrack: View {
    let row: UsageLimitRow
    let color: Color

    var body: some View {
        Canvas { context, size in
            let bar = CGRect(origin: .zero, size: size)
            let tick = UsageLimitMath.tickX(percent: row.evenPacePercent, width: size.width)
            var layer = context
            layer.clip(to: Path(roundedRect: bar, cornerRadius: UsageTheme.Radius.md))
            if let tick {
                layer.clip(to: Path(CGRect(x: tick - 3, y: 0, width: 6, height: size.height)), options: .inverse)
            }
            layer.fill(Path(bar), with: .color(UsageTheme.muted))

            let left = CGRect(x: 0, y: 0, width: size.width * Double(row.remainingPercent) / 100, height: size.height)
            if left.width > 0 {
                layer.fill(Path(roundedRect: left, cornerRadius: UsageTheme.Radius.md), with: .color(color.opacity(0.35)))
            }
            let restored = size.width * row.hatchPercent / 100
            if restored > 0 {
                let area = CGRect(x: size.width - restored, y: 0, width: restored, height: size.height)
                var hatch = layer
                hatch.clip(to: Path(area))
                hatch.stroke(Self.hatch(in: area), with: .color(color.opacity(0.2)), lineWidth: 1)
            }
            if let tick {
                let mark = CGRect(x: tick - 1, y: 2, width: 2, height: size.height - 4)
                context.fill(Path(roundedRect: mark, cornerRadius: 1), with: .color(UsageTheme.foreground))
            }
        }
        .accessibilityHidden(true)
    }

    /// T3's `repeating-linear-gradient(135deg, colour 0 1px, transparent 1px 5px)` as lines: one
    /// 1pt stripe every 5pt measured across the stripes, rising to the right, the first of them
    /// through the area's top-left corner.
    private static func hatch(in area: CGRect) -> Path {
        var path = Path()
        let step = 5 * 2.0.squareRoot()
        var offset = 0.5 * 2.0.squareRoot()
        while offset < area.width + area.height {
            path.move(to: CGPoint(x: area.minX + offset, y: area.minY))
            path.addLine(to: CGPoint(x: area.minX + offset - area.height, y: area.maxY))
            offset += step
        }
        return path
    }
}

/// "↻ 3d 19h" and, with credits banked, the ticket and their count: the chip at the right end of
/// a wide bar, and the right-hand end of the row under a narrow one.
private struct UsageResetCountdown: View {
    let state: UsageProviderState
    let row: UsageLimitRow
    let now: Double

    var body: some View {
        let countdown = UsageLimitText.resetsIn(row.resetsAt, now: now, style: .refill)
        let credits = state.limits.ticketCount
        HStack(spacing: 6) {
            if let countdown { Text(countdown) }
            if credits > 0 {
                if countdown != nil { Text("·").foregroundStyle(UsageTheme.mutedForeground) }
                HStack(spacing: 2) {
                    Image(systemName: "ticket").font(.system(size: 9, weight: .semibold))
                    Text("\(credits)").fontWeight(.semibold)
                }
                .foregroundStyle(UsageTheme.foreground)
            }
        }
        .font(UsageTheme.font(11))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    /// Nothing to say: no reset time and no credit.
    static func isEmpty(state: UsageProviderState, row: UsageLimitRow) -> Bool {
        row.resetsAt == nil && state.limits.ticketCount == 0
    }
}

private struct UsageResetChip: View {
    let state: UsageProviderState
    let row: UsageLimitRow
    let now: Double

    var body: some View {
        if !UsageResetCountdown.isEmpty(state: state, row: row) {
            UsageResetCountdown(state: state, row: row, now: now)
                .frame(height: 16)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: UsageTheme.Radius.sm)
                    .fill(UsageTheme.background.opacity(0.85)))
        }
    }
}

/// The row under a narrow bar, T3's legend row for the one account there is: its colour, its
/// name, what is left, and the countdown the bar has no room for. It opens the same popover.
private struct UsageLimitLegend: View {
    @ObservedObject var store: UsageStore
    let state: UsageProviderState
    let row: UsageLimitRow

    var body: some View {
        UsageHover { hovered in
            Button { store.togglePopover(provider: state.provider, row: row.id) } label: {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: UsageTheme.Radius.sm)
                        .fill(UsageTheme.provider(state.provider).opacity(0.35))
                        .frame(width: 16, height: 16)
                    Text(state.limits.title).fontWeight(.medium)
                    Text("\(row.remainingPercent)%").fontWeight(.semibold).monospacedDigit()
                    Spacer(minLength: 8)
                    UsageResetCountdown(state: state, row: row, now: store.snapshot.now)
                        .foregroundStyle(UsageTheme.mutedForeground)
                }
                .font(UsageTheme.font(12))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: UsageTheme.Radius.md)
                    .fill(UsageTheme.accent).opacity(hovered ? 1 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The bar above already speaks for the window.
            .accessibilityHidden(true)
        }
    }
}

// MARK: - the result of a redemption

/// "Codex Using reset credit…", then how it ended: T3's status line, outside the popover because
/// the popover is gone by the time there is anything to report.
private struct UsageResetStatusLine: View {
    let store: UsageStore
    let state: UsageProviderState
    let status: String

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            sentence
                .font(UsageTheme.font(12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !state.resetBusy {
                UsageIconButton(symbol: "xmark", label: "Dismiss", symbolSize: 8, side: 18) {
                    store.dismissResetStatus(provider: state.provider)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The provider's name leads, as in T3. Several of the model's sentences already begin with
    /// it ("Claude resets are cooling down…"), and T3 prints the name twice there; here the
    /// sentence's own first word is the one set in the name's weight.
    private var sentence: Text {
        let title = state.limits.title
        let rest = status.hasPrefix(title + " ") ? String(status.dropFirst(title.count + 1)) : status
        let name: Text = Text(title).fontWeight(.medium).foregroundColor(UsageTheme.foreground)
        let tail: Text = Text(" " + rest).foregroundColor(UsageTheme.mutedForeground)
        return name + tail
    }
}

// MARK: - notices

/// T3's amber box: one line per provider whose limits could not be shown, last on the page.
private struct UsageLimitNotices: View {
    let notices: [String]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.xl)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(UsageTheme.warning)
                .frame(width: 16, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notices, id: \.self) { notice in
                    Text(notice)
                        .font(UsageTheme.font(14, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 20, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .foregroundStyle(UsageTheme.warningForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(UsageTheme.warningSurface))
        .overlay(shape.strokeBorder(UsageTheme.warningBorder, lineWidth: 1))
    }
}

// MARK: - the account popover

struct UsageAccountPopover: View {
    @ObservedObject var store: UsageStore
    let state: UsageProviderState
    let row: UsageLimitRow
    // Not the State attribute: its macro plugin ships only with Xcode (see Motion.swift).
    private let emailShown = State(initialValue: false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.lg)
        let choices = state.limits.resetChoices(now: store.snapshot.now)
        VStack(alignment: .leading, spacing: 10) {
            identity
            divider
            details
            if !choices.isEmpty {
                divider
                resets(choices)
            }
        }
        .font(UsageTheme.font(12))
        .frame(width: 288, alignment: .leading)
        // 16 inside a 1pt border, as on the cards.
        .padding(17)
        .background(shape.fill(UsageTheme.card).shadow(color: .black.opacity(0.22), radius: 18, y: 12))
        .overlay(shape.strokeBorder(UsageTheme.foreground.opacity(0.1), lineWidth: 1))
        // A click on the popover's own surface is not a click on the page under it.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                UsageProviderLogo(provider: state.provider)
                Text(state.limits.title)
                    .font(UsageTheme.font(14, .medium))
                    .lineLimit(1)
            }
            if let email = state.limits.email {
                emailLine(email)
            }
        }
    }

    /// Hidden until clicked, as in T3, so the window can be shown or screenshotted with the
    /// popover open. What is blurred is a stand-in of the same shape, not the address: a blur
    /// can be sharpened again.
    private func emailLine(_ email: String) -> some View {
        let shown = emailShown.wrappedValue
        return Button { emailShown.wrappedValue.toggle() } label: {
            Text(shown ? email : Self.standIn(for: email))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(UsageTheme.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
                .blur(radius: shown ? 0 : 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shown ? "Click to hide email" : "Click to reveal email")
        .accessibilityLabel("Toggle account email visibility")
    }

    /// The plan, then this window's figures, in one grid so both blocks share a label column as
    /// wide as the longest label. T3's fixed 72px column is too narrow for "Even pace" in some of
    /// its own translations.
    private var details: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
            if !state.limits.accountRows.isEmpty {
                ForEach(state.limits.accountRows, id: \.label) { detail in line(detail) }
                // 10pt on either side of the line, less the grid's own 4pt between rows.
                divider
                    .padding(.vertical, 6)
                    .gridCellUnsizedAxes(.horizontal)
            }
            ForEach(row.details(now: store.snapshot.now), id: \.label) { detail in line(detail) }
        }
    }

    private func line(_ detail: UsageDetailRow) -> some View {
        GridRow {
            Text(detail.label)
                .foregroundStyle(UsageTheme.mutedForeground)
                .fixedSize()
            Text(detail.value)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var divider: some View {
        Rectangle().fill(UsageTheme.borderSoft).frame(height: 1)
    }

    /// What is banked and the button that spends it: one line per kind of reset the provider
    /// tells apart. The button only asks; the confirmation is what redeems.
    private func resets(_ choices: [UsageResetChoice]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(choices, id: \.key) { choice in
                HStack(spacing: 0) {
                    Text(choice.summary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if choice.redeemable {
                        Button(state.resetBusy ? UsageResetCredit.busyButton : choice.actionLabel) {
                            store.askReset(provider: state.provider, choice: choice)
                        }
                        .buttonStyle(UsageButtonStyle(size: .xs))
                        .disabled(!state.mayRedeem(creditId: choice.creditId))
                    }
                }
            }
            if state.resetNeedsRefresh {
                Text(UsageProviderState.resetRefreshHint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(UsageTheme.mutedForeground)
    }

    /// T3's `redactedPlaceholder`: letters and digits replaced by others picked from a hash of
    /// the address, the punctuation that gives an address its shape kept.
    private static func standIn(for email: String) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var state: UInt32 = 0x811c9dc5
        for unit in email.utf16 { state = (state ^ UInt32(unit)) &* 0x01000193 }
        return String(email.map { character -> Character in
            if "@.-_".contains(character) { return character }
            state = (state ^ (state >> 13)) &* 0x85ebca6b
            state = (state ^ (state >> 16)) &* 0xc2b2ae35
            return alphabet[Int(state % UInt32(alphabet.count))]
        })
    }
}

// MARK: - the confirmation

/// "Use a reset credit?" — T3's alert: what the credit does, Cancel, and the one button in the
/// window that spends something that cannot be given back.
struct UsageResetConfirm: View {
    @ObservedObject var store: UsageStore
    let request: UsageResetRequest

    var body: some View {
        let state = store.limits.first { $0.provider == request.provider }
        let busy = state?.resetBusy ?? false
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(UsageResetCredit.confirmTitle)
                    .font(UsageTheme.font(20, .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(request.choice.confirmDescription)
                    .font(UsageTheme.font(14))
                    .foregroundStyle(UsageTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(UsageTheme.border).frame(height: 1)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(UsageResetCredit.cancelButton) { store.cancelReset() }
                    .buttonStyle(UsageButtonStyle())
                Button(busy ? UsageResetCredit.busyButton : UsageResetCredit.confirmButton) {
                    store.redeemReset(provider: request.provider, creditId: request.choice.creditId)
                }
                .buttonStyle(UsageButtonStyle(variant: .primary))
                // The files are re-read under an open dialog, so it asks the same rule as the
                // button that opened it; without the provider's state nothing may be spent.
                .disabled(state?.mayRedeem(creditId: request.choice.creditId) != true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(UsageTheme.muted.opacity(0.72))
        }
    }
}
