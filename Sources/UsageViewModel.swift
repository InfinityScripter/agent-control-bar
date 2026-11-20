import SwiftUI

// The dialog a row of the model table opens: one model's figures for the window on screen. The
// surface, the ✕ and the 768pt width limit are the root view's (UsageView.swift); this is the
// content, with T3's own paddings.
//
// The headline figures come from the row that was clicked; the trend chart and the two cost bars
// from the same reduction run over that model's buckets alone (`store.totals(of:)`).
struct UsageModelDialog: View {
    @ObservedObject var store: UsageStore
    let model: UsageModelTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // As tall as its content while the window has room for it; in a short window the
            // heading and the footer stay put and only the body between them scrolls.
            ViewThatFits(in: .vertical) {
                panel
                ScrollView(.vertical) { panel }
            }
            if model.unpricedTokens > 0 { footer }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Claude · 60.7% of cost"; a model whose cost is unknown has no share to name.
    private var subtitle: String {
        let name = UsageCopy.providerName(model.provider)
        return model.isCostUnknown ? name : "\(name) · \(UsageFormat.percent(model.costShare)) of cost"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UsageProviderMark(provider: model.provider, size: 20)
                Text(model.model)
                    .font(UsageTheme.font(20, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(subtitle).monospacedDigit().foregroundStyle(UsageTheme.mutedForeground)
        }
        .padding(.top, 24)
        .padding(.leading, 24)
        // Clear of the ✕ the surface puts in this corner.
        .padding(.trailing, 48)
        .padding(.bottom, 12)
    }

    private var stats: [UsageDialogStat] {
        var stats = [UsageDialogStat(label: "Cost",
                                     value: model.isCostUnknown ? UsageCopy.unpriced : UsageFormat.usd(model.costUsd)),
                     UsageDialogStat(label: "Tokens", value: UsageFormat.tokens(model.totalTokens))]
        if let perMillion = model.costPerMillionTokens {
            stats.append(UsageDialogStat(label: "Per 1M tokens", value: UsageFormat.usd(perMillion)))
        }
        if let hitRate = model.cacheHitRate {
            stats.append(UsageDialogStat(label: "Cache hit", value: UsageFormat.percent(hitRate)))
        }
        return stats
    }

    private var panel: some View {
        let own = store.totals(of: model)
        let period = store.period
        // An unknown cost is not zero, so its trend is drawn in tokens on the Cost tab too.
        let metric = model.trendMetric(store.metric)
        let data = UsageChartData(period: period, totals: own, metric: metric, providers: [model.provider])
        let shown = stats
        // Cost and tokens side by side whichever tab is behind the dialog.
        let bars: [UsageShareBarData?] = [model.isCostUnknown ? nil : UsageShareBarData.costByType(own.categoryCost),
                                          UsageShareBarData.tokensByType(model.tokens),
                                          UsageShareBarData.costBySpeed(own.speedCost)]
        return VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(shown) { stat in UsageStat(label: stat.label, value: stat.value, large: true) }
                // Four columns whatever there is to put in them, so the figures do not spread out.
                ForEach(shown.count..<max(shown.count, 4), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
            UsageChartView(data: data, metric: metric, period: period, timeZone: store.timeZone,
                           hour12: store.snapshot.hour12)
            UsageBarGrid(bars: bars.compactMap { $0 }, columnGap: 40)
        }
        .padding(.top, 4)
        .padding(.horizontal, 24)
        .padding(.bottom, model.unpricedTokens > 0 ? 4 : 24)
    }

    /// Only for a model with tokens nobody has a price for: how many, and the way to give one.
    private var footer: some View {
        HStack(spacing: 12) {
            Text(UsageCopy.unpricedFooter(tokens: model.unpricedTokens))
                .font(UsageTheme.font(12))
                .monospacedDigit()
                .foregroundStyle(UsageTheme.mutedForeground)
            Spacer(minLength: 0)
            // Opening the editor takes this dialog's place, as in T3: one dialog at a time.
            Button("Set price") { store.openPrices(model: model.model) }
                .buttonStyle(UsageButtonStyle(variant: .primary))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

/// One of the dialog's headline figures.
private struct UsageDialogStat: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}
