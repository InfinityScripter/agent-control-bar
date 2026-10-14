import SwiftUI

// The rows below are laid out at fixed heights so the card's height can be known before it is
// laid out: the scroll cap under it is computed from the controller, ahead of any layout pass,
// and a guess there is what lets a long session list push the panel off its icon.
private enum Metrics {
    static let gap: CGFloat = 7
    static let header: CGFloat = 28
    static let hairline: CGFloat = 0.5
    static let inset: CGFloat = 8
    static let titleLine: CGFloat = 13
    static let cells: CGFloat = 42
    static let line: CGFloat = 13
    static let lineGap: CGFloat = 5
    static let blockGap: CGFloat = 12
    static let footer: CGFloat = 26
    static let footerGap: CGFloat = 10
}

extension PanelResetOdds {
    /// What the card takes above the scrolling half, the gap over it included.
    func cardHeight(open: Bool) -> CGFloat {
        let folded = Metrics.gap + Metrics.header
        guard open, state == "ok", !rows.isEmpty else { return folded }
        let blocks = rows.reduce(CGFloat(0)) { sum, row in
            sum + Metrics.titleLine + Metrics.lineGap + Metrics.cells
                + (row.counts == nil ? 0 : Metrics.lineGap + Metrics.line)
                + (row.banked == nil ? 0 : Metrics.lineGap + Metrics.line)
        }
        return folded + Metrics.hairline + Metrics.inset * 2 + blocks
            + Metrics.blockGap * CGFloat(rows.count - 1) + Metrics.footerGap + Metrics.footer
    }
}

/// whenreset.app's odds of an early limit reset, under the limits strip: one line folded, a block
/// per provider unfolded.
struct PanelResetOddsCard: View {
    @ObservedObject var store: PanelStore
    let odds: PanelResetOdds
    @Environment(\.colorScheme) private var scheme

    private var open: Bool {
        odds.state == "ok" && store.expanded.contains(PanelStore.resetOddsID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if open {
                Rectangle()
                    .fill(PanelTheme.cardBorder(scheme))
                    .frame(height: Metrics.hairline)
                PanelResetOddsDetail(store: store, odds: odds)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(PanelTheme.wellFill(scheme)))
        .padding(.top, Metrics.gap)
    }

    @ViewBuilder
    private var header: some View {
        if odds.state == "ok" {
            HStack(spacing: 0) {
                Button { store.toggleResetOdds() } label: { PanelResetOddsSummary(odds: odds) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.spoken(odds.rows))
                    .help(odds.stale ? odds.note : Self.summaryHelp)
                Button { store.toggleResetOdds() } label: {
                    PanelDisclosure(open: open)
                        .frame(width: 24, height: Metrics.header)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide details" : "Show details")
            }
            .opacity(odds.stale ? 0.55 : 1)
        } else {
            PanelResetOddsPending(odds: odds)
        }
    }

    private static let summaryHelp: String = "Chance that the limits are reset early within "
        + "24 hours, estimated by whenreset.app from past resets"

    static func spoken(_ rows: [PanelResetOddsRow]) -> String {
        let parts = rows.map { row in
            row.title + " " + (row.p24.map { "\($0) percent" } ?? "unknown")
        }
        return "Reset odds in 24 hours: " + parts.joined(separator: ", ")
    }
}

private struct PanelResetOddsSummary: View {
    let odds: PanelResetOdds

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Reset in 24h")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            ForEach(odds.rows) { PanelResetOddsPill(row: $0) }
        }
        .padding(.leading, 9)
        .frame(height: Metrics.header)
        .contentShape(Rectangle())
    }
}

private struct PanelResetOddsPill: View {
    @Environment(\.colorScheme) private var scheme
    let row: PanelResetOddsRow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.glyph)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(PanelResetOddsCell.percent(row.p24))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(row.p24 == nil ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(PanelTheme.raisedFill(scheme)))
    }
}

/// Loading and unavailable: the same line, with no figures and nothing to unfold.
private struct PanelResetOddsPending: View {
    let odds: PanelResetOdds

    private var loading: Bool { odds.state == "loading" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("Reset odds")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(loading ? "loading…" : odds.note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if loading { PanelSpinner() }
        }
        .padding(.horizontal, 9)
        .frame(height: Metrics.header)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loading ? "Reset odds loading" : "Reset odds unavailable: " + odds.note)
        .help(loading ? "Asking whenreset.app" : odds.note)
    }
}

private struct PanelResetOddsDetail: View {
    let store: PanelStore
    let odds: PanelResetOdds

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.blockGap) {
                ForEach(odds.rows) { PanelResetOddsBlock(row: $0) }
            }
            .padding(.top, Metrics.inset)
            .padding(.bottom, Metrics.footerGap)
            PanelResetOddsFooter(store: store, note: odds.note)
                .padding(.bottom, Metrics.inset)
        }
        .padding(.horizontal, Metrics.inset)
    }
}

private struct PanelResetOddsBlock: View {
    let row: PanelResetOddsRow

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.lineGap) {
            title
            HStack(spacing: 5) {
                PanelResetOddsCell(title: "24h", value: row.p24, spoken: "24 hours")
                PanelResetOddsCell(title: "48h", value: row.p48, spoken: "48 hours")
                PanelResetOddsCell(title: "7d", value: row.p7d, spoken: "7 days")
            }
            .frame(height: Metrics.cells)
            if let counts = row.counts {
                PanelResetOddsLine(glyph: "number", text: counts)
            }
            if let banked = row.banked {
                PanelResetOddsLine(glyph: "gift", text: banked)
            }
        }
    }

    private var title: some View {
        HStack(spacing: 4) {
            Image(systemName: row.glyph).font(.system(size: 9, weight: .semibold))
            Text(row.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let last = row.lastReset {
                Text("last reset " + last)
                    .font(.system(size: 9.5).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 3)
        .frame(height: Metrics.titleLine)
    }
}

/// One horizon, drawn like a limit tile but smaller. The bar is green, not PanelTheme.level:
/// there a fuller bar means closer to running out, here it means a better chance of relief.
private struct PanelResetOddsCell: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let value: Int?
    let spoken: String

    static func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .kerning(0.35)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .lineLimit(1)
            Text(Self.percent(value))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // An unknown chance drawn as an empty bar would read as 0%, which is a figure.
            if let value {
                PanelBar(value: Double(value) / 100, fill: Color(nsColor: .systemGreen), height: 3)
            } else {
                Capsule()
                    .fill(PanelTheme.track(scheme))
                    .opacity(0.4)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 5)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(PanelTheme.wellFill(scheme)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reset within \(spoken): " + (value.map { "\($0) percent" } ?? "unknown"))
    }
}

private struct PanelResetOddsLine: View {
    let glyph: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.system(size: 8.5, weight: .medium))
                .frame(width: 10)
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 3)
        .frame(height: Metrics.line)
    }
}

private struct PanelResetOddsFooter: View {
    let store: PanelStore
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button { store.openResetOddsSite() } label: {
                HStack(spacing: 2) {
                    Text("whenreset.app")
                    Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: .linkColor))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open whenreset.app")
            .help(ResetOddsFeed.site)
            Text("· " + note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: Metrics.footer, maxHeight: Metrics.footer,
               alignment: .topLeading)
    }
}
