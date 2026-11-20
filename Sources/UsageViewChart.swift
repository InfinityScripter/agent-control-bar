import SwiftUI

// The drawn pieces the Cost and Tokens tabs share with the model dialog: T3's layered area chart
// and its share bar. Every number, label and coordinate comes from UsageSummaryModel.swift
// (UsageChartData, UsageChart, UsageFormat, UsageShareSegment); this file only puts ink where
// those say. Plain Canvas and Path — Swift Charts is deliberately not imported.

extension UsageChartMetric {
    /// A figure of this metric as the page prints it: tokens in T3's short form, cost in dollars.
    func text(_ value: Double) -> String {
        self == .tokens ? UsageFormat.tokens(value) : UsageFormat.usd(value)
    }
}

/// T3's dimming of a figure that is being re-read: 40% after a short wait, so a refresh that
/// answers at once never flashes. Labels are not dimmed, only what may change.
private struct UsageFigureDim: ViewModifier {
    let dimmed: Bool

    func body(content: Content) -> some View {
        content.opacity(dimmed ? 0.4 : 1).animation(animation, value: dimmed)
    }

    private var animation: Animation? {
        guard Motion.enabled else { return nil }
        return .easeInOut(duration: Motion.time(0.15)).delay(dimmed ? Motion.time(0.15) : 0)
    }
}

extension View {
    func usageFigure(dimmed: Bool) -> some View { modifier(UsageFigureDim(dimmed: dimmed)) }
}

private extension UsageChartSeries {
    /// The figure of one column; zero for a column the series does not reach.
    func value(at index: Int) -> Double { values.indices.contains(index) ? values[index] : 0 }
}

// MARK: - chart

/// The chart with its two axes: one translucent area and one line per provider, each from zero
/// (layered, not stacked), over every day or rolling hour of the window.
struct UsageChartView: View {
    let data: UsageChartData
    let metric: UsageChartMetric
    /// The window the columns belong to: it says whether they are hours and what "today" is.
    let period: UsagePeriod
    let timeZone: TimeZone
    let hour12: Bool
    var dimmed = false

    private static let plotHeight: CGFloat = 224
    private static let axisWidth: CGFloat = 56
    private static let axisGap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: Self.axisGap) {
                valueAxis
                UsageChartPlot(data: data, metric: metric, dimmed: dimmed, label: tooltipLabel)
            }
            .frame(height: Self.plotHeight)
            periodAxis.padding(.leading, Self.axisWidth + Self.axisGap)
        }
        // The plot answers only to a pointer. T3 backs it with a hidden table for screen readers;
        // here the same rows are the chart's accessibility children.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityChildren {
            ForEach(Array(data.periods.enumerated()), id: \.offset) { index, key in
                Text(tooltipLabel(key)).accessibilityValue(spoken(index))
            }
        }
    }

    /// "Daily cost by provider".
    private var caption: String {
        UsageCopy.chartHeading(hourly: period.isHourly, metric: metric) + " by provider"
    }

    /// One column read out: "Claude $15.84, Codex $8.11, Total $23.95". A single series is its
    /// own total, so the sum is only said when there is more than one.
    private func spoken(_ index: Int) -> String {
        var parts: [String] = data.series.map { series in
            UsageCopy.providerName(series.provider) + " " + metric.text(series.value(at: index))
        }
        if data.series.count > 1 { parts.append("Total " + metric.text(data.total(at: index))) }
        return parts.joined(separator: ", ")
    }

    private func tooltipLabel(_ key: String) -> String {
        UsageFormat.tooltipPeriodLabel(key, in: period, timeZone: timeZone, hour12: hour12)
    }

    /// One label per grid line, centred on it. The placeholder grid of a first load has none.
    private var valueAxis: some View {
        let ticks: [Double] = data.scale.labeled ? data.scale.ticks : []
        let top: Double = data.scale.max
        return ZStack {
            ForEach(ticks, id: \.self) { tick in
                Text(UsageChart.tickLabel(tick, metric: metric))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: Self.axisWidth, alignment: .trailing)
                    .position(x: Self.axisWidth / 2,
                              y: UsageChart.y(tick, max: top, height: Double(Self.plotHeight)))
            }
        }
        .font(UsageTheme.font(10))
        .monospacedDigit()
        .foregroundStyle(UsageTheme.mutedForeground)
        .frame(width: Self.axisWidth, height: Self.plotHeight)
    }

    /// The first, the middle and the last period, spread edge to edge.
    private var periodAxis: some View {
        let labels: [String] = UsageChart.axisLabels(data.periods, hourly: period.isHourly,
                                                     timeZone: timeZone, hour12: hour12)
        return HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                if index > 0 { Spacer(minLength: 4) }
                Text(label).lineLimit(1)
            }
        }
        .font(UsageTheme.font(10))
        .foregroundStyle(UsageTheme.mutedForeground)
        // An empty window has no labels; the row keeps its height so the page does not jump.
        .frame(maxWidth: .infinity, minHeight: 14)
    }
}

/// The plot itself: grid, areas, lines, and under the pointer a hairline with the column's figures.
private struct UsageChartPlot: View {
    let data: UsageChartData
    let metric: UsageChartMetric
    let dimmed: Bool
    /// The tooltip's name for a column.
    let label: (String) -> String

    // Where the pointer is, clamped to the plot; nil while it is elsewhere. Not the State
    // attribute: its macro plugin ships only with Xcode (see Motion.swift).
    private let pointer = State<UsageChartPoint?>(initialValue: nil)

    var body: some View {
        GeometryReader { geo in
            plot(width: Double(geo.size.width), height: Double(geo.size.height))
        }
    }

    private func plot(width: Double, height: Double) -> some View {
        ZStack {
            Canvas { context, size in drawGrid(&context, size) }
            // A layer of their own, so the series can fade while the grid stays put.
            Canvas { context, size in drawSeries(&context, size) }
                .usageFigure(dimmed: dimmed)
        }
        .overlay(alignment: .topLeading) { crosshair(width: width, height: height) }
        .overlay { tooltip(width: width) }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointer.wrappedValue = UsageChartPoint(x: min(width, max(0, Double(location.x))),
                                                       y: min(height, max(0, Double(location.y))))
            case .ended:
                pointer.wrappedValue = nil
            }
        }
    }

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        var lines = Path()
        for tick in data.scale.ticks {
            let y = UsageChart.y(tick, max: data.scale.max, height: Double(size.height))
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lines, with: .color(UsageTheme.border), lineWidth: 1)
    }

    /// Every area first, then every line, so no area ever washes over another series' line.
    private func drawSeries(_ context: inout GraphicsContext, _ size: CGSize) {
        let drawn: [(line: Path, color: Color)] = data.drawOrder.map { series in
            (line(series, size), UsageTheme.provider(series.provider))
        }
        for (line, color) in drawn where !line.isEmpty {
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.12)))
        }
        for (line, color) in drawn {
            context.stroke(line, with: .color(color), lineWidth: 2)
        }
    }

    private func line(_ series: UsageChartSeries, _ size: CGSize) -> Path {
        let points = data.points(series, width: Double(size.width), height: Double(size.height))
        var path = Path()
        for (index, piece) in UsageChart.curve(points).enumerated() {
            if index == 0 { path.move(to: CGPoint(x: piece.from.x, y: piece.from.y)) }
            path.addCurve(to: CGPoint(x: piece.to.x, y: piece.to.y),
                          control1: CGPoint(x: piece.c1.x, y: piece.c1.y),
                          control2: CGPoint(x: piece.c2.x, y: piece.c2.y))
        }
        return path
    }

    private func hovered(width: Double) -> Int? {
        pointer.wrappedValue.flatMap { UsageChart.hoverIndex(x: $0.x, width: width, count: data.periods.count) }
    }

    @ViewBuilder
    private func crosshair(width: Double, height: Double) -> some View {
        if let index = hovered(width: width) {
            // The hairline starts where the scale's maximum sits, not at the very top.
            let top: Double = UsageChart.y(1, max: 1, height: height)
            Rectangle()
                .fill(UsageTheme.mutedForeground)
                .frame(width: 1, height: height - top)
                .offset(x: UsageChart.x(index, count: data.periods.count, width: width) - 0.5, y: top)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func tooltip(width: Double) -> some View {
        if let at = pointer.wrappedValue, let index = hovered(width: width) {
            UsageTooltipPlace(pointer: at) { tooltip(at: index) }.allowsHitTesting(false)
        }
    }

    private func tooltip(at index: Int) -> UsageChartTooltip {
        let rows: [UsageChartTooltip.Row] = data.series.map { series in
            UsageChartTooltip.Row(provider: series.provider, value: metric.text(series.value(at: index)))
        }
        return UsageChartTooltip(label: label(data.periods[index]), rows: rows,
                                 total: metric.text(data.total(at: index)), dimmed: dimmed)
    }
}

/// Puts the tooltip beside the pointer by the model's rule — right of and below it, flipped where
/// it would not fit, never outside the plot. The rule needs the tooltip's own size, and a layout
/// is the one place that is told it before anything is drawn.
private struct UsageTooltipPlace: Layout {
    let pointer: UsageChartPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let origin = UsageChart.tooltipOrigin(pointer: pointer, tooltipWidth: Double(size.width),
                                                  tooltipHeight: Double(size.height),
                                                  plotWidth: Double(bounds.width), plotHeight: Double(bounds.height))
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: ProposedViewSize(size))
        }
    }
}

/// The figures of one column: a row per provider and their sum.
private struct UsageChartTooltip: View {
    struct Row: Identifiable {
        let provider: String
        let value: String

        var id: String { provider }
    }

    let label: String
    let rows: [Row]
    let total: String
    /// While the figures are being re-read they are printed in the muted colour instead of dimmed.
    let dimmed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UsageTheme.Radius.xl, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text(label).foregroundStyle(UsageTheme.mutedForeground).padding(.bottom, 4)
            ForEach(rows) { row in
                line(value: row.value) {
                    HStack(spacing: 6) {
                        UsageProviderMark(provider: row.provider, size: 12)
                        Text(UsageCopy.providerName(row.provider))
                    }
                }
            }
            Rectangle().fill(UsageTheme.border).frame(height: 1).padding(.top, 4)
            line(value: total) { Text("Total") }.padding(.top, 4)
        }
        .font(UsageTheme.font(12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 144)
        // T3's glass is the page colour at 80% over a blur of what is behind it. Without the
        // blur the lines under the box would run through its figures, so it is nearly opaque.
        .background(shape.fill(UsageTheme.background.opacity(0.94))
            .shadow(color: .black.opacity(0.1), radius: 7, y: 6))
        .overlay(shape.strokeBorder(UsageTheme.border.opacity(0.5), lineWidth: 1))
    }

    private func line<Name: View>(value: String, @ViewBuilder name: () -> Name) -> some View {
        let ink: Color = dimmed ? UsageTheme.mutedForeground : UsageTheme.foreground
        return HStack(spacing: 12) {
            // Never cut: a text measured at its ideal width and then laid out a fraction of a
            // point narrower would lose its last letters to an ellipsis.
            name().foregroundStyle(UsageTheme.mutedForeground).fixedSize()
            Spacer(minLength: 0)
            Text(value).monospacedDigit().foregroundStyle(ink).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - share bar

/// One share bar as data: its heading, its parts and which figure the parts are.
struct UsageShareBarData: Identifiable {
    let label: String
    let segments: [UsageShareSegment]
    let metric: UsageChartMetric
    /// What stands at the right of the heading: the speed bar's "Premium $1.20".
    var aside: AttributedString?

    var id: String { label }

    static func costByType(_ cost: UsageCategoryCost) -> UsageShareBarData {
        UsageShareBarData(label: "Cost by type", segments: cost.segments, metric: .cost)
    }

    static func tokensByType(_ tokens: UsageTokenTotals) -> UsageShareBarData {
        UsageShareBarData(label: "Tokens by type", segments: tokens.segments, metric: .tokens)
    }

    /// Nil unless something ran above the standard tier: a bar of one part says nothing.
    static func costBySpeed(_ speed: UsageSpeedCost) -> UsageShareBarData? {
        guard speed.hasFastTiers else { return nil }
        // The sentence is the model's; the amount inside it is picked out in the text colour.
        var aside = AttributedString(UsageCopy.premium(speed.premium))
        aside.foregroundColor = UsageTheme.mutedForeground
        if let amount = aside.range(of: UsageFormat.usd(speed.premium)) {
            aside[amount].foregroundColor = UsageTheme.foreground
        }
        return UsageShareBarData(label: "Cost by speed", segments: speed.segments, metric: .cost, aside: aside)
    }
}

/// Share bars two to a row, as T3's grid lays them out. A bar with nothing to show takes no cell.
struct UsageBarGrid: View {
    let bars: [UsageShareBarData]
    let columnGap: CGFloat

    var body: some View {
        let shown: [UsageShareBarData] = bars.filter { !UsageShareSegment.visible($0.segments).isEmpty }
        let rows: [[UsageShareBarData]] = stride(from: 0, to: shown.count, by: 2).map { start in
            Array(shown[start..<min(start + 2, shown.count)])
        }
        VStack(alignment: .leading, spacing: 32) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: columnGap) {
                    ForEach(rows[index]) { bar in
                        UsageShareBar(bar: bar).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // A lone bar keeps to its own half instead of stretching across both.
                    if rows[index].count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
        }
    }
}

/// T3's share bar: a heading, one thin bar cut in proportion, and a legend with every figure.
private struct UsageShareBar: View {
    let bar: UsageShareBarData

    private static let gap: Double = 2
    /// The narrowest a part is drawn, so the smallest share is still a visible mark.
    private static let floor: Double = 4

    var body: some View {
        let visible: [UsageShareSegment] = UsageShareSegment.visible(bar.segments)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(bar.label).font(UsageTheme.font(14, .medium))
                Spacer(minLength: 0)
                if let aside = bar.aside {
                    Text(aside).font(UsageTheme.font(12)).monospacedDigit()
                }
            }
            .lineLimit(1)
            GeometryReader { geo in strip(visible, width: Double(geo.size.width)) }
                .frame(height: 8)
                .accessibilityHidden(true)
            UsageFlow(columnGap: 16, rowGap: 4) {
                ForEach(visible, id: \.label) { segment in legend(segment) }
            }
        }
    }

    private func strip(_ visible: [UsageShareSegment], width: Double) -> some View {
        let widths: [Double] = Self.widths(visible.map(\.value), in: width)
        return HStack(spacing: Self.gap) {
            ForEach(Array(visible.enumerated()), id: \.element.label) { index, segment in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(UsageTheme.color(segment.ink))
                    .frame(width: widths[index])
                    .help(UsageShareSegment.tooltip(segment, among: bar.segments, metric: bar.metric))
            }
        }
        // The outer ends are fully round, the cuts between parts only slightly.
        .clipShape(Capsule())
    }

    private func legend(_ segment: UsageShareSegment) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(UsageTheme.color(segment.ink))
                .frame(width: 8, height: 8)
            Text(segment.label).foregroundStyle(UsageTheme.mutedForeground)
            Text(bar.metric.text(segment.value)).monospacedDigit()
        }
        .font(UsageTheme.font(12))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// Widths in proportion to the values, as CSS flex gives them with a minimum width: a part
    /// that would come out under the floor is set to it, and the others share what is left.
    private static func widths(_ values: [Double], in width: Double) -> [Double] {
        let room = max(0, width - gap * Double(max(0, values.count - 1)))
        var widths = [Double](repeating: floor, count: values.count)
        var growing = Array(values.indices)
        while !growing.isEmpty {
            let left = room - floor * Double(values.count - growing.count)
            let sum = growing.reduce(0.0) { $0 + values[$1] }
            guard left > 0, sum > 0 else { break }
            let small = growing.filter { values[$0] / sum * left < floor }
            if small.isEmpty {
                for index in growing { widths[index] = values[index] / sum * left }
                break
            }
            growing.removeAll { small.contains($0) }
        }
        return widths
    }
}

/// A row that wraps: the legend's entries one after another, onto a new line when one does not fit.
private struct UsageFlow: Layout {
    let columnGap: CGFloat
    let rowGap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowGap
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + columnGap
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
