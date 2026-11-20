import Combine
import SwiftUI

// What the Usage window draws, as plain values, plus the actions its controls perform.
//
// The same arrangement as PanelStore, for the same reason: the window is SwiftUI, the app's state
// lives on an NSObject that a 2.5 Hz tick rewrites, and this stands between them. A view reads
// `snapshot` and the UI state below and calls the action methods; it never touches the
// controller, a file or a process (.claude/rules/architecture.md). The types of that state and
// of the snapshot are in Model/UsageWindowModel.swift, where the model check compiles them.
//
// The three tab files are written against this surface, so every member says in one line what a
// view may rely on.

// MARK: - the store

final class UsageStore: ObservableObject {
    private weak var controller: StatusController?
    /// Nil in the render mode, which must not write the user's preferences.
    private let defaults: UserDefaults?

    /// The picture. Replaced as a whole, and only when something in it changed.
    @Published private(set) var snapshot = UsageSnapshot()
    /// The selected tab. Starts on the remembered one (Limits the first time).
    @Published private(set) var tab: UsageTab
    /// The selected period in days: 1, 7, 30 or 90. Ignored by the Limits tab.
    @Published private(set) var days: Int
    /// The provider filter as chosen. Views want `providers` and `usageProvider` instead.
    @Published private(set) var filter: UsageProviderFilter
    /// The dialog standing over the page, or nil. Drawn by the root view; a tab only opens it.
    @Published private(set) var surface: UsageSurface?
    /// The limit window whose account popover is open, or nil. Drawn by the Limits tab. It is
    /// kept here rather than in the tab because the window's keys are read before SwiftUI sees
    /// them: this is what lets Esc close the popover instead of the window, and what closes it
    /// as a reset is asked for or the tab is left, as in T3.
    @Published private(set) var popover: UsagePopoverTarget?

    init(controller: StatusController?, defaults: UserDefaults? = .standard) {
        self.controller = controller
        self.defaults = defaults
        let saved = defaults.map(UsagePreferences.init(defaults:)) ?? UsagePreferences()
        tab = saved.tab
        days = saved.days
        filter = saved.filter
    }

    // MARK: publishing

    /// Re-read everything and publish if anything moved. Called from the tick while the window
    /// is visible, and by the controller whenever a command it ran has finished.
    func refresh() {
        guard let controller else { return }
        publish(controller.usageSnapshot())
    }

    /// The render mode's way in: it has a snapshot and no controller.
    func publish(_ next: UsageSnapshot) {
        if next != snapshot { snapshot = next }
        // A dialog about something that is gone goes with it, as in T3.
        if case .model = surface, dialogModel == nil { surface = nil }
        if popover != nil, popoverRow == nil { popover = nil }
    }

    // MARK: what the tabs read

    /// The providers on screen: the shown ones that pass the filter, Claude first.
    var providers: [String] {
        guard let only = effectiveFilter.provider else { return snapshot.providers }
        return snapshot.providers.filter { $0 == only }
    }

    /// The Limits tab's sections: one per provider on screen.
    var limits: [UsageProviderState] { snapshot.limits.filter { providers.contains($0.provider) } }

    /// The notices box of the Limits tab: one line per provider that has one.
    var limitNotices: [String] { limits.compactMap(\.notice) }

    /// The section and the row the open popover belongs to; nil when it is closed or its row is
    /// no longer on screen.
    var popoverRow: (state: UsageProviderState, row: UsageLimitRow)? {
        guard let popover, let state = limits.first(where: { $0.provider == popover.provider }),
              let row = state.limits.rows.first(where: { $0.id == popover.row })
        else { return nil }
        return (state, row)
    }

    /// What to hand `UsageTotals(period:provider:)`: nil while every provider is on screen.
    var usageProvider: String? { providers.count == 1 ? providers[0] : nil }

    /// The filter after the app's own setting: a remembered "Codex only" on a Mac that now shows
    /// Claude alone would be an empty window, so there it reads as all.
    var effectiveFilter: UsageProviderFilter {
        guard let only = filter.provider, snapshot.providers.contains(only), snapshot.providers.count > 1
        else { return .all }
        return filter
    }

    /// The header's menu is only worth showing when there is something to choose between.
    var canFilterProviders: Bool { snapshot.providers.count > 1 }

    /// The filter's label: "All providers", or the one provider's name.
    var filterTitle: String {
        if let only = effectiveFilter.provider { return Provider.named(only).title }
        return snapshot.providers.count == 1 ? Provider.named(snapshot.providers[0]).title : "All providers"
    }

    /// The Cost/Tokens figure of the current tab; `.cost` on Limits, where nothing reads it.
    var metric: UsageChartMetric { tab.metric ?? .cost }

    /// The selected period of the summary; an empty period while there is no summary.
    var period: UsagePeriod { usage.period }

    /// The page's reduction for the selected period and providers. Cached: a body may read it on
    /// every redraw, and it is rebuilt only when the summary, the period or the filter changed.
    var totals: UsageTotals { usage.totals }

    /// The zone the summary bucketed its days in; labels must use it, not this Mac's own.
    var timeZone: TimeZone { snapshot.summary?.summary.zone ?? .current }

    /// Dim the figures: a scan is running over figures already on screen.
    var usageDimmed: Bool { snapshot.usagePhase == .refreshing }

    /// The header's second line on Cost and Tokens: the window ("Oct 21 to Nov 19") and, while a
    /// scan runs or after one failed, what it is doing. Empty on Limits.
    var statusLine: String {
        guard tab != .limits else { return "" }
        // With no provider on screen the period is the empty one, and its label is a bare " to ".
        let window = snapshot.summary == nil || providers.isEmpty ? nil
            : UsageFormat.windowLabel(period, timeZone: timeZone, hour12: snapshot.hour12)
        let scan = snapshot.scan.progressText(busy: snapshot.usageRunning, hasSummary: snapshot.summary != nil)
            ?? snapshot.usageError
        return [window, scan].compactMap { $0 }.joined(separator: " · ")
    }

    /// The header's refresh button is spinning: the refresh that belongs to this tab is running.
    var refreshing: Bool { tab == .limits ? snapshot.limitsRefreshing : snapshot.usageRunning }

    /// The model whose dialog is open, resolved against the totals on screen; nil when the dialog
    /// is closed or the model is no longer in them.
    var dialogModel: UsageModelTotals? {
        guard case .model(let id) = surface else { return nil }
        return totals.models.first { $0.id == id }
    }

    /// The dialog's own reduction (trend chart, cost bars) for the open model. Cached like `totals`.
    func totals(of model: UsageModelTotals) -> UsageTotals {
        if modelCache?.id != model.id || modelCache?.key != usageKey {
            modelCache = (model.id, usageKey, UsageTotals(period: period, model: model))
        }
        return modelCache?.totals ?? UsageTotals(period: period, model: model)
    }

    /// Every model id seen in the summary's widest period: the editor's suggestions.
    var seenModels: [String] {
        Array(Set(snapshot.summary?.summary.period(90).buckets.map(\.model) ?? [])).sorted()
    }

    /// The model the open prices editor was asked to price, when "Set price" opened it.
    var pricesModel: String? {
        guard case .prices(let model) = surface else { return nil }
        return model
    }

    // MARK: actions — header

    /// Switch tabs. Remembered; brings `now` forward and starts whatever refresh the tab is due.
    func selectTab(_ next: UsageTab) {
        guard next != tab else { return }
        tab = next
        popover = nil
        save()
        controller?.usageSelectionChanged(tab: next)
    }

    /// Switch the period (1, 7, 30, 90). Instant: all four are in the summary already. A summary
    /// that has aged past five minutes is rescanned behind the figures, as on a tab switch.
    func selectPeriod(_ next: Int) {
        guard UsageSummary.periodDays.contains(next), next != days else { return }
        days = next
        save()
        controller?.usageSelectionChanged(tab: tab)
    }

    func selectProvider(_ next: UsageProviderFilter) {
        guard next != filter else { return }
        filter = next
        if popover != nil, popoverRow == nil { popover = nil }
        save()
    }

    /// The refresh button. On Limits: ask both providers for limits now, past the debounces. On
    /// Cost and Tokens: `usage --refresh`, a rescan that may also refetch prices. A press while
    /// that refresh is already running does nothing.
    func refreshNow() { controller?.refreshUsage(tab: tab) }

    /// A key the window was sent. Tabs and periods are deaf while a dialog is open, as in T3.
    func perform(_ shortcut: UsageShortcut) {
        switch shortcut {
        case .dismiss:
            // Innermost first: the dialog, then the popover, then the window itself.
            if surface != nil {
                closeSurface()
            } else if popover != nil {
                hidePopover()
            } else {
                controller?.closeUsageWindow()
            }
        case _ where surface != nil: break
        case .tab(let tab): selectTab(tab)
        // Limits have no period; the keys are swallowed there rather than changing a hidden choice.
        case .period(let days): if tab != .limits { selectPeriod(days) }
        case .refresh: refreshNow()
        }
    }

    // MARK: actions — dialogs

    /// Open the model dialog for a row of the model table (`UsageModelTotals.id`). An id that is
    /// not among the totals on screen opens nothing, rather than a scrim with no dialog on it.
    func openModel(_ id: String) {
        guard totals.models.contains(where: { $0.id == id }) else { return }
        surface = .model(id)
    }
    func closeModel() { if case .model = surface { surface = nil } }

    /// Open "Custom model prices"; `model` pre-fills a row for a model without a price.
    func openPrices(model: String? = nil) { surface = .prices(model: model) }
    func closePrices() { if case .prices = surface { surface = nil } }

    /// Save the editor's rows to usage/prices.json through the model's own `save`, and rescan
    /// when the file changed (prices are applied by the scan, not here). False when the write
    /// failed; the editor keeps its drafts then. The dialog stays open either way.
    func savePrices(_ editor: inout UsagePriceEditor) -> Bool {
        controller?.saveUsagePrices(&editor) ?? false
    }

    /// Open the account popover of one limit window (`UsageLimitRow.id`), or move it there.
    func showPopover(provider: String, row: String) {
        let next = UsagePopoverTarget(provider: provider, row: row)
        if popover != next { popover = next }
    }

    func hidePopover() { if popover != nil { popover = nil } }

    /// Ask before spending a credit: opens the confirmation for one of `resetChoices(now:)`.
    /// The popover the button sat in closes first, as in T3.
    func askReset(provider: String, choice: UsageResetChoice) {
        hidePopover()
        surface = .resetConfirm(UsageResetRequest(provider: provider, choice: choice))
    }

    func cancelReset() { if case .resetConfirm = surface { surface = nil } }

    /// Spend the credit. Only ever from the confirmation's own button: it cannot be undone.
    /// Closes the confirmation; the provider's `resetBusy` and `resetStatus` report the rest.
    func redeemReset(provider: String, creditId: String?) {
        cancelReset()
        controller?.redeemUsageReset(provider: provider, creditId: creditId)
    }

    /// Take the result line under a provider's bars away.
    func dismissResetStatus(provider: String) { controller?.dismissUsageResetStatus(provider: provider) }

    /// Close whatever dialog is open.
    func closeSurface() { surface = nil }

    // MARK: render mode

    /// The render mode's pick of UI state; never called by the app.
    func preview(tab: UsageTab, days: Int, surface: UsageSurface? = nil, popover: UsagePopoverTarget? = nil) {
        self.tab = tab
        self.days = days
        self.surface = surface
        self.popover = popover
    }

    /// The model the render mode opens the dialog for: the first row of the current tab's table.
    var previewModel: UsageModelTotals? { totals.models(by: metric).first }

    /// The window whose popover the render mode draws: the first row of the first provider that
    /// has a credit to offer, else the first row there is.
    var previewPopover: (state: UsageProviderState, row: UsageLimitRow)? {
        let state = limits.first { !$0.limits.resetChoices(now: snapshot.now).isEmpty && !$0.limits.rows.isEmpty }
            ?? limits.first { !$0.limits.rows.isEmpty }
        return state.flatMap { state in state.limits.rows.first.map { (state, $0) } }
    }

    /// The reset the render mode asks to confirm: the first one that can be redeemed.
    var previewReset: UsageResetRequest? {
        for state in limits {
            if let choice = state.limits.resetChoices(now: snapshot.now).first(where: \.redeemable) {
                return UsageResetRequest(provider: state.provider, choice: choice)
            }
        }
        return nil
    }

    // MARK: -

    private struct UsageKey: Equatable {
        let stamp: Date?
        let days: Int
        let provider: String?
        let shown: [String]
    }

    private var usageKey: UsageKey {
        UsageKey(stamp: snapshot.summary?.stamp, days: days, provider: usageProvider, shown: snapshot.providers)
    }

    private var usageCache: (key: UsageKey, period: UsagePeriod, totals: UsageTotals)?
    private var modelCache: (id: String, key: UsageKey, totals: UsageTotals)?

    /// The period and its totals for the current key. With no provider on screen at all (both
    /// switched off in Settings) the page is the empty period, not the other agent's figures.
    private var usage: (period: UsagePeriod, totals: UsageTotals) {
        let key = usageKey
        if let cached = usageCache, cached.key == key { return (cached.period, cached.totals) }
        let period = providers.isEmpty ? UsagePeriod.empty : snapshot.summary?.summary.period(days) ?? .empty
        let totals = UsageTotals(period: period, provider: usageProvider)
        usageCache = (key, period, totals)
        return (period, totals)
    }

    private func save() {
        guard let defaults else { return }
        var preferences = UsagePreferences()
        preferences.tab = tab
        preferences.days = days
        preferences.filter = filter
        preferences.save(to: defaults)
    }
}
