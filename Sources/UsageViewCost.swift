import SwiftUI

// The Cost and Tokens tabs of the Usage window: T3's usage overview, one page for both.
// `store.metric` says which figure the page is about; the layout is the same either way.
//
// Top to bottom: what could not be read, the summary beside the chart, Totals, the share bars,
// and the Breakdown tables. The chart and the share bar are in UsageViewChart.swift, the dialog a
// model row opens in UsageViewModel.swift.
//
// T3 folds this page into one column and narrower grids below certain widths. The window's
// minimum width is above every one of them, so the wide layout is the only one here.

/// Which table the Breakdown section shows.
private enum UsageBreakdown: Hashable {
    case model, time
}

struct UsageCostTab: View {
    @ObservedObject var store: UsageStore
    // T3 keeps this choice in the page, not in the saved preferences: it lasts while the two tabs
    // are on screen and starts over after a visit to Limits. Not the State attribute — its macro
    // plugin ships only with Xcode (see Motion.swift).
    private let breakdown = State(initialValue: UsageBreakdown.model)

    private static let noProviders: String = "No providers are shown, so there is no usage to show."
    private static let notRead: String = "Usage has not been read yet."

    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if store.providers.isEmpty {
            UsagePageMessage(text: Self.noProviders)
        } else {
            switch store.snapshot.usagePhase {
            case .loading:
                UsageSkeleton(providers: store.providers)
            case .unavailable:
                UsagePageMessage(text: store.snapshot.usageError ?? Self.notRead)
            case .ready, .refreshing:
                overview
            }
        }
    }

    private var overview: some View {
        let totals = store.totals
        let period = store.period
        let dimmed = store.usageDimmed
        return VStack(alignment: .leading, spacing: 24) {
            ForEach(period.warnings(provider: store.usageProvider), id: \.self) { warning in
                Text(warning)
                    .foregroundStyle(UsageTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
            }
            HStack(alignment: .top, spacing: 24) {
                UsageSummaryColumn(totals: totals, metric: store.metric, dimmed: dimmed)
                    .frame(width: UsageSummaryColumn.width, alignment: .leading)
                chart(totals, period, dimmed: dimmed)
            }
            UsageTotalsRow(totals: totals, dimmed: dimmed)
            if totals.totalTokens > 0 {
                UsageBarGrid(bars: bars(totals), columnGap: 48).usageFigure(dimmed: dimmed)
            }
            breakdownSection(totals, period, dimmed: dimmed)
        }
    }

    private func chart(_ totals: UsageTotals, _ period: UsagePeriod, dimmed: Bool) -> some View {
        // `loading` only matters with nothing to plot yet: the grid then has lines and no numbers.
        let data = UsageChartData(period: period, totals: totals, metric: store.metric,
                                  providers: totals.activeProviders, loading: dimmed)
        return VStack(alignment: .leading, spacing: 12) {
            Text(UsageCopy.chartHeading(hourly: period.isHourly, metric: store.metric))
                .font(UsageTheme.font(14, .medium))
            UsageChartView(data: data, metric: store.metric, period: period, timeZone: store.timeZone,
                           hour12: store.snapshot.hour12, dimmed: dimmed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bars(_ totals: UsageTotals) -> [UsageShareBarData] {
        if store.metric == .tokens { return [.tokensByType(totals.tokens)] }
        let speed: [UsageShareBarData] = UsageShareBarData.costBySpeed(totals.speedCost).map { [$0] } ?? []
        return [.costByType(totals.categoryCost)] + speed
    }

    private func breakdownSection(_ totals: UsageTotals, _ period: UsagePeriod, dimmed: Bool) -> some View {
        let choices: [UsageSegment<UsageBreakdown>] = [
            UsageSegment(value: .model, label: "Model"),
            UsageSegment(value: .time, label: period.isHourly ? "Hour" : "Day"),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Breakdown").font(UsageTheme.font(14, .medium))
                Spacer(minLength: 0)
                UsageSegmented(label: "Usage breakdown", segments: choices,
                               selection: breakdown.wrappedValue) { breakdown.wrappedValue = $0 }
            }
            switch breakdown.wrappedValue {
            case .model:
                UsageModelTable(models: totals.models(by: store.metric), metric: store.metric, dimmed: dimmed,
                                open: store.openModel)
            case .time:
                // Newest first, and only the periods that have data: the chart is the zero-filled view.
                UsageTimeTable(rows: totals.timeline(hourly: period.isHourly).reversed(),
                               providers: totals.activeProviders, hourly: period.isHourly,
                               timeZone: store.timeZone, hour12: store.snapshot.hour12, dimmed: dimmed)
            }
        }
    }
}

/// The page when there is nothing to lay out: one quiet line in the middle.
private struct UsagePageMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(UsageTheme.mutedForeground)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
    }
}

// MARK: - summary column

/// The left column: the period's headline figure, then one row per provider that has any usage,
/// the larger figure of the tab first.
private struct UsageSummaryColumn: View {
    let totals: UsageTotals
    let metric: UsageChartMetric
    let dimmed: Bool

    /// T3's `18rem`.
    static let width: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headline
            ForEach(totals.rankedProviders(by: metric), id: \.provider) { provider in
                row(provider)
            }
        }
    }

    private var headline: some View {
        let figure: String = metric == .tokens ? UsageFormat.tokens(totals.totalTokens) : UsageFormat.usd(totals.costUsd)
        let unpriced: Double = metric == .cost ? totals.costQuality.unpricedShare : 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(figure)
                .font(UsageTheme.font(36, .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .usageFigure(dimmed: dimmed)
            HStack(spacing: 4) {
                Text(UsageCopy.sessionsCaption(totals.sessions, metric: metric))
                    .monospacedDigit()
                    .usageFigure(dimmed: dimmed)
                if unpriced > 0 {
                    UsageInfoMark(label: "Unpriced usage details", text: UsageCopy.unpricedNotice(share: unpriced))
                }
            }
            .font(UsageTheme.font(12))
            .foregroundStyle(UsageTheme.mutedForeground)
        }
    }

    private func row(_ provider: UsageProviderTotals) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(UsageTheme.provider(provider.provider)).frame(width: 8, height: 8)
                UsageProviderMark(provider: provider.provider)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(UsageCopy.providerName(provider.provider)).truncationMode(.tail)
                    Text(UsageCopy.providerSessions(provider.sessions))
                        .font(UsageTheme.font(11))
                        .monospacedDigit()
                        .foregroundStyle(UsageTheme.mutedForeground)
                        .fixedSize()
                        .usageFigure(dimmed: dimmed)
                }
                Spacer(minLength: 8)
                Text(metric.text(provider.value(metric)))
                    .font(UsageTheme.font(14, .medium))
                    .monospacedDigit()
                    .fixedSize()
                    .usageFigure(dimmed: dimmed)
            }
            .lineLimit(1)
            Text(UsageCopy.providerDetail(provider, metric: metric))
                .font(UsageTheme.font(12))
                .monospacedDigit()
                .foregroundStyle(UsageTheme.mutedForeground)
                .lineLimit(1)
                .usageFigure(dimmed: dimmed)
        }
    }
}

/// The small "i" beside "API estimate": under the pointer it says how much of the usage had no
/// price. T3 opens a popover in its tooltip style there, at once; the system tooltip would make
/// the reader wait for the one sentence that qualifies the headline figure.
private struct UsageInfoMark: View {
    let label: String
    let text: String

    var body: some View {
        UsageHover { hovered in
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
                .overlay(alignment: .top) {
                    // A frame of no height on the mark's top edge, with the bubble standing on it.
                    if hovered { UsageTip(text: text).frame(height: 0, alignment: .bottom).offset(y: -4) }
                }
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue(text)
        }
    }
}

/// T3's tooltip surface: one line on the raised colour.
private struct UsageTip: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.md, style: .continuous)
        Text(text)
            .font(UsageTheme.font(12))
            .foregroundStyle(UsageTheme.foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(shape.fill(UsageTheme.card).shadow(color: .black.opacity(0.08), radius: 3, y: 2))
            .overlay(shape.strokeBorder(UsageTheme.border, lineWidth: 1))
            .allowsHitTesting(false)
    }
}

// MARK: - totals

/// A label over a figure: the cells of Totals and, larger, the model dialog's headline figures.
struct UsageStat: View {
    let label: String
    let value: String
    var large = false
    var dimmed = false

    var body: some View {
        let font: Font = large ? UsageTheme.font(24, .semibold) : UsageTheme.font(16, .medium)
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(UsageTheme.font(12)).foregroundStyle(UsageTheme.mutedForeground)
            Text(value).font(font).monospacedDigit().usageFigure(dimmed: dimmed)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "Totals": the same five figures on both tabs.
private struct UsageTotalsRow: View {
    let totals: UsageTotals
    let dimmed: Bool

    static let labels: [String] = ["Processed tokens", "Cached input", "Uncached input", "Output", "Cache savings"]

    var body: some View {
        let values: [String] = [UsageFormat.tokens(totals.totalTokens),
                                UsageFormat.tokens(totals.tokens.cachedInputTokens),
                                UsageFormat.tokens(totals.tokens.uncachedInputTokens),
                                UsageFormat.tokens(totals.tokens.outputTokens),
                                UsageFormat.usd(totals.costQuality.cacheSavingsUsd)]
        VStack(alignment: .leading, spacing: 8) {
            Text("Totals").font(UsageTheme.font(14, .medium))
            HStack(alignment: .top, spacing: 24) {
                ForEach(Array(zip(Self.labels, values)), id: \.0) { label, value in
                    UsageStat(label: label, value: value, dimmed: dimmed)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - breakdown tables

/// One column of the model table: its heading and the widest value in it.
private struct UsageColumn {
    let heading: String
    let widest: String

    /// The face the figures are set in, to tell which of them is widest.
    private static let figures = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)

    init(_ heading: String, _ values: [String]) {
        self.heading = heading
        // Measured, not counted: "12.3M" has as many characters as "1.11B" and is wider, and a
        // column sized to the narrower of the two pushes that one row's figures out of line.
        widest = values.max { Self.width($0) < Self.width($1) } ?? ""
    }

    private static func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: figures]).width
    }
}

/// A right-aligned cell of a column that sizes itself. Every cell also holds, unseen, the
/// column's heading and its widest value, so all the cells of a column come out equally wide
/// without a measuring pass — which is what a table does and a stack of rows does not.
private struct UsageColumnCell: View {
    let column: UsageColumn
    let text: String
    /// The heading row and the rank are a size smaller than the figures.
    var small = false
    var color: Color = UsageTheme.mutedForeground
    var alignment: Alignment = .trailing

    var body: some View {
        let size: CGFloat = small ? 12 : 14
        ZStack(alignment: alignment) {
            Text(column.heading).font(UsageTheme.font(12)).hidden()
            Text(column.widest).font(UsageTheme.font(14)).hidden()
            Text(text).font(UsageTheme.font(size)).foregroundStyle(color)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// A table's hairline under a row: the heading's is the full border, a row's half of it.
private struct UsageRowLine: View {
    var heading = false

    var body: some View {
        Rectangle().fill(UsageTheme.border).opacity(heading ? 1 : 0.5).frame(height: 1)
    }
}

/// What both tables say when the window holds nothing.
private struct UsageTableEmpty: View {
    var body: some View {
        Text(UsageCopy.noActivity)
            .foregroundStyle(UsageTheme.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

/// "By model": rank, model, cost, share and tokens. A row is one button that opens the model's
/// dialog; the thin bar under a name is the model's figure against the largest in the list.
private struct UsageModelTable: View {
    let models: [UsageModelTotals]
    let metric: UsageChartMetric
    let dimmed: Bool
    let open: (String) -> Void

    private struct Columns {
        let rank: UsageColumn
        let cost: UsageColumn
        let share: UsageColumn
        let tokens: UsageColumn
    }

    private static let barWidth: CGFloat = 192

    var body: some View {
        let columns = Columns(rank: UsageColumn("#", [String(models.count)]),
                              cost: UsageColumn("Cost", models.map(costText)),
                              share: UsageColumn("Share", models.map(shareText)),
                              tokens: UsageColumn("Tokens", models.map { UsageFormat.tokens($0.totalTokens) }))
        let peak: Double = models.reduce(0) { max($0, $1.value(metric)) }
        VStack(spacing: 0) {
            header(columns)
            if models.isEmpty { UsageTableEmpty() }
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                UsageHover { hovered in row(model, rank: index + 1, peak: peak, columns: columns, hovered: hovered) }
            }
        }
    }

    private func costText(_ model: UsageModelTotals) -> String {
        model.isCostUnknown ? UsageCopy.unpriced : UsageFormat.usd(model.costUsd)
    }

    /// Empty for a model whose cost is unknown: it has no share of a cost nobody knows.
    private func shareText(_ model: UsageModelTotals) -> String {
        model.share(metric).map { UsageFormat.percent($0) } ?? ""
    }

    private func header(_ columns: Columns) -> some View {
        HStack(spacing: 0) {
            UsageColumnCell(column: columns.rank, text: "#", small: true, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, 12)
            Text("Model").font(UsageTheme.font(12)).frame(maxWidth: .infinity, alignment: .leading)
            UsageColumnCell(column: columns.cost, text: "Cost", small: true).padding(.leading, 24)
            UsageColumnCell(column: columns.share, text: "Share", small: true).padding(.leading, 24)
            UsageColumnCell(column: columns.tokens, text: "Tokens", small: true)
                .padding(.leading, 24)
                .padding(.trailing, 8)
        }
        .foregroundStyle(UsageTheme.mutedForeground)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { UsageRowLine(heading: true) }
    }

    private func row(_ model: UsageModelTotals, rank: Int, peak: Double, columns: Columns,
                     hovered: Bool) -> some View {
        let value: Double = model.value(metric)
        let bar: Double? = value > 0 && peak > 0 ? value / peak : nil
        let costInk: Color = model.isCostUnknown ? UsageTheme.mutedForeground : UsageTheme.foreground
        let fill: Color = hovered ? UsageTheme.muted.opacity(0.5) : .clear
        return Button { open(model.id) } label: {
            HStack(spacing: 0) {
                UsageColumnCell(column: columns.rank, text: String(rank), small: true, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                name(model, bar: bar).frame(maxWidth: .infinity, alignment: .leading)
                UsageColumnCell(column: columns.cost, text: costText(model), color: costInk)
                    .padding(.leading, 24)
                    .usageFigure(dimmed: dimmed)
                UsageColumnCell(column: columns.share, text: shareText(model))
                    .padding(.leading, 24)
                    .usageFigure(dimmed: dimmed)
                UsageColumnCell(column: columns.tokens, text: UsageFormat.tokens(model.totalTokens))
                    .padding(.leading, 24)
                    .padding(.trailing, 8)
                    .usageFigure(dimmed: dimmed)
            }
            .padding(.vertical, 10)
            .background(fill)
            .overlay(alignment: .bottom) { UsageRowLine() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func name(_ model: UsageModelTotals, bar: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                UsageProviderMark(provider: model.provider, size: 14)
                // A long id wraps, as in T3's table; the figures beside it never do.
                Text(model.model).fixedSize(horizontal: false, vertical: true)
            }
            // Without a bar the name keeps the height the bar would have added, as in T3.
            .padding(.vertical, bar == nil ? 4 : 0)
            if let bar {
                Capsule()
                    .fill(UsageTheme.provider(model.provider))
                    .frame(width: max(8, bar * Self.barWidth), height: 2)
                    .usageFigure(dimmed: dimmed)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// "By day" or "By hour": one row per period that has data, newest first. The provider columns
/// and Total are cost on both tabs — that is T3's table, not an oversight of the Tokens tab.
private struct UsageTimeTable: View {
    let rows: [UsagePeriodTotals]
    let providers: [String]
    let hourly: Bool
    let timeZone: TimeZone
    let hour12: Bool
    let dimmed: Bool

    var body: some View {
        VStack(spacing: 0) {
            UsageTimeColumns {
                Text(hourly ? "Hour" : "Day").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                ForEach(providers, id: \.self) { provider in figure(UsageCopy.providerName(provider)) }
                figure("Total")
                figure("Tokens").padding(.trailing, 8)
            }
            .font(UsageTheme.font(12))
            .foregroundStyle(UsageTheme.mutedForeground)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { UsageRowLine(heading: true) }
            if rows.isEmpty { UsageTableEmpty() }
            ForEach(rows, id: \.key) { entry in
                UsageHover { hovered in row(entry, hovered: hovered) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage breakdown by time")
    }

    private func row(_ entry: UsagePeriodTotals, hovered: Bool) -> some View {
        let fill: Color = hovered ? UsageTheme.muted.opacity(0.5) : .clear
        let label: String = UsageFormat.periodLabel(entry.key, hourly: hourly, timeZone: timeZone, hour12: hour12)
        return UsageTimeColumns {
            Text(label).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
            ForEach(providers, id: \.self) { provider in
                figure(UsageFormat.usd(entry.byProvider[provider]?.costUsd ?? 0))
                    .foregroundStyle(UsageTheme.mutedForeground)
                    .usageFigure(dimmed: dimmed)
            }
            figure(UsageFormat.usd(entry.costUsd)).usageFigure(dimmed: dimmed)
            figure(UsageFormat.tokens(entry.totalTokens))
                .foregroundStyle(UsageTheme.mutedForeground)
                .usageFigure(dimmed: dimmed)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 8)
        .background(fill)
        .overlay(alignment: .bottom) { UsageRowLine() }
        .accessibilityElement(children: .combine)
    }

    private func figure(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 16)
    }
}

/// The time table's columns: the first gets two fifths of the width, as in T3's table, and the
/// figures share the rest equally — so the columns line up from row to row without measuring.
private struct UsageTimeColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width }
        let width: CGFloat = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        var height: CGFloat = 0
        for (subview, column) in zip(subviews, columns(width, count: subviews.count)) {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: column, height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, column) in zip(subviews, columns(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: column, height: bounds.height))
            x += column
        }
    }

    private func columns(_ width: CGFloat, count: Int) -> [CGFloat] {
        guard count > 1 else { return Array(repeating: width, count: count) }
        let first = width * 0.4
        return [first] + Array(repeating: (width - first) / CGFloat(count - 1), count: count - 1)
    }
}

// MARK: - skeleton

/// The page while the first scan runs: its own layout in grey blocks, with the headings and
/// labels that are already known as real text. The blocks do not pulse as T3's do — nothing in
/// this app repeats an animation for as long as something takes (docs/motion.md); the header's
/// refresh button turns and its status line counts the files.
private struct UsageSkeleton: View {
    let providers: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                summary.frame(width: UsageSummaryColumn.width, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    UsageBlock(width: 96, height: 20)
                    VStack(spacing: 4) {
                        UsageBlock(height: 224)
                        UsageBlock(height: 16)
                    }
                    .padding(.leading, 64)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Totals").font(UsageTheme.font(14, .medium))
                HStack(alignment: .top, spacing: 24) {
                    ForEach(UsageTotalsRow.labels, id: \.self) { label in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(UsageTheme.font(12)).foregroundStyle(UsageTheme.mutedForeground)
                            UsageBlock(width: 64, height: 24)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 10) {
                    UsageBlock(width: 112, height: 20)
                    UsageBlock(height: 8)
                    UsageBlock(width: 288, height: 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Breakdown").font(UsageTheme.font(14, .medium))
                    Spacer(minLength: 0)
                    UsageBlock(width: 112, height: 28, radius: UsageTheme.Radius.lg)
                }
                UsageBlock(height: 176)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading usage")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                UsageBlock(width: 144, height: 40)
                UsageBlock(width: 128, height: 16)
            }
            ForEach(providers, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        UsageBlock(width: 8, height: 8, radius: 4)
                        UsageBlock(width: 16, height: 16, radius: 8)
                        UsageBlock(width: 80, height: 14)
                        Spacer(minLength: 0)
                        UsageBlock(width: 56, height: 14)
                    }
                    .frame(minHeight: 20)
                    UsageBlock(width: 144, height: 16)
                }
            }
        }
    }
}

/// One grey block of the skeleton; without a width it fills what it is given.
private struct UsageBlock: View {
    var width: CGFloat?
    let height: CGFloat
    var radius: CGFloat = UsageTheme.Radius.sm

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(UsageTheme.skeleton)
            .frame(width: width, height: height)
    }
}
