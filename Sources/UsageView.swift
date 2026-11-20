import SwiftUI

// The Usage window's frame: T3's page header, the scrolling page under it, and whichever dialog
// stands over both. The three tab bodies and the dialogs' contents are in UsageViewCost.swift,
// UsageViewLimits.swift and UsageViewPrices.swift; this file only places them.
//
// What a tab body can rely on: it is laid out inside the page container — at most 1024pt wide,
// centred, 24pt from the sides and the header, 48pt above the bottom edge, in a vertical scroll
// view — with the page's foreground colour and a 14pt font already set. A dialog's content is put
// on the dialog surface (16pt radius, border, shadow, the ✕ where T3 has one) at T3's maximum
// width for it; the content brings its own padding. Only the width is limited: a dialog is as
// tall as its content, up to the window less 16pt on each side, so content that can outgrow a
// small window scrolls inside itself, as T3's dialog panels do.
struct UsageView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            UsageHeader(store: store)
            // The reader is for the page's least height: the page fills the window even when its
            // content does not, so a click on the empty part under the last card is still a
            // click on the page — which is what puts an open popover away.
            GeometryReader { viewport in
                ScrollView(.vertical) {
                    page
                        .frame(maxWidth: UsageTheme.pageWidth, alignment: .topLeading)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 48)
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                        .usageDismissesPopover(store)
                }
                .scrollDisabled(store.surface != nil)
            }
        }
        // Under a dialog the header and the page are out of reach of the keyboard too: with
        // "Keyboard navigation" on, Tab walked out of the dialog into the controls under the
        // scrim, and Space pressed them there.
        .disabled(store.surface != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(store.surface != nil)
        .overlayPreferenceValue(UsageBarAnchors.self) { UsagePopoverLayer(store: store, anchors: $0) }
        .overlay { dialog }
        .background(UsageTheme.background)
        .foregroundStyle(UsageTheme.foreground)
        .font(UsageTheme.font(14))
        // A cross-fade only, at every motion level that moves at all: a dialog that slid in over
        // figures would be movement for its own sake.
        .animation(Motion.enabled ? .easeInOut(duration: Motion.time(0.2)) : nil, value: store.surface)
    }

    @ViewBuilder
    private var page: some View {
        switch store.tab {
        case .cost, .tokens: UsageCostTab(store: store)
        case .limits: UsageLimitsTab(store: store)
        }
    }

    @ViewBuilder
    private var dialog: some View {
        if let surface = store.surface {
            ZStack {
                // The scrim swallows every click meant for the page. Only the model dialog closes
                // on it: the editor may hold unsaved rows and the confirmation is a decision.
                UsageTheme.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { if case .model = surface { store.closeModel() } }
                content(of: surface)
                    .padding(16)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func content(of surface: UsageSurface) -> some View {
        switch surface {
        case .model:
            if let model = store.dialogModel {
                UsageDialogSurface(close: store.closeModel) { UsageModelDialog(store: store, model: model) }
                    .frame(maxWidth: 768)
            }
        case .prices(let model):
            UsageDialogSurface(close: store.closePrices) { UsagePricesEditor(store: store, model: model) }
                .frame(maxWidth: 896)
        case .resetConfirm(let request):
            UsageDialogSurface(close: nil) { UsageResetConfirm(store: store, request: request) }
                .frame(maxWidth: 512)
        }
    }
}

private extension View {
    /// A click on this view that no control took puts the open account popover away, as a click
    /// outside T3's popup does. The bars are buttons, so a click on one moves the popover
    /// instead. The gesture exists only while a popover is open: the rest of the time the page
    /// and the header have no business claiming clicks.
    func usageDismissesPopover(_ store: UsageStore) -> some View {
        contentShape(Rectangle())
            .gesture(store.popover == nil ? nil : TapGesture().onEnded { store.hidePopover() })
    }
}

/// T3's page header in one row: "Usage / All providers ⌄" on the left with the window and scan
/// status under it, and on the right the model-prices button, the period, the three tabs and
/// refresh. T3's environment menu has no counterpart on one Mac; the two things it held that
/// still matter — the scan status and "Model prices" — are the second line and the button.
///
/// The window's own close button stands in for T3's ✕: this is a window, not a modal page.
struct UsageHeader: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 12) {
            title.frame(maxWidth: .infinity, alignment: .leading)
            // Measured first, so the status line gets what is left: a cut "Refreshing… 940 of
            // 11,8…" is better than a control pushed out of the window. At the window's minimum
            // width the row still fits whole, which is why there is no narrower variant of it.
            controls.layoutPriority(1)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        // One height on all three tabs, so the page under it does not shift when the second
        // line comes and goes with the Limits tab.
        .frame(height: UsageTheme.headerHeight)
        .usageDismissesPopover(store)
        .overlay(alignment: .bottom) { Rectangle().fill(UsageTheme.border).frame(height: 1) }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 1) {
            breadcrumb
            if !store.statusLine.isEmpty {
                Text(store.statusLine)
                    .font(UsageTheme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(UsageTheme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Text("Usage")
                .foregroundStyle(UsageTheme.mutedForeground)
                .accessibilityAddTraits(.isHeader)
            Text("/").foregroundStyle(UsageTheme.mutedForeground)
            if store.canFilterProviders {
                providerMenu
            } else {
                Text(store.filterTitle)
            }
        }
        .font(UsageTheme.font(14, .medium))
        .lineLimit(1)
        .fixedSize()
    }

    /// T3's provider menu keeps a set of hidden providers behind check marks; with two providers
    /// that is three states, shown here as the three things one can ask for.
    private var providerMenu: some View {
        Menu {
            Toggle("All providers", isOn: choice(.all))
            Divider()
            ForEach(store.snapshot.providers, id: \.self) { provider in
                if let filter = UsageProviderFilter(rawValue: provider) {
                    Toggle(Provider.named(provider).title, isOn: choice(filter))
                }
            }
        } label: {
            UsageMenuLabel(title: store.filterTitle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Providers")
    }

    private func choice(_ filter: UsageProviderFilter) -> Binding<Bool> {
        Binding(get: { store.effectiveFilter == filter }, set: { _ in store.selectProvider(filter) })
    }

    /// Right to left the row is fixed — refresh, then the tabs — so switching to Limits, which
    /// drops the period and the prices button, never moves the control under the pointer.
    private var controls: some View {
        HStack(spacing: 8) {
            if store.tab != .limits {
                UsageIconButton(symbol: "dollarsign.circle", label: "Model prices") { store.openPrices() }
                UsageSegmented(label: "Usage period", segments: Self.periods,
                               selection: store.days, select: store.selectPeriod)
            }
            UsageSegmented(label: "Usage metric", segments: Self.tabs,
                           selection: store.tab, select: store.selectTab)
            // 12, not the button's 14: this glyph fills its box where T3's 14px one is drawn
            // inside it, and at 14 it stood a third larger than the tabs' text beside it.
            UsageIconButton(symbol: "arrow.triangle.2.circlepath", label: refreshLabel, symbolSize: 12,
                            busy: store.refreshing) { store.refreshNow() }
        }
        .fixedSize()
    }

    private var refreshLabel: String {
        store.tab == .limits ? "Refresh limits (⌘R)" : "Refresh usage (⌘R)"
    }

    private static let tabs: [UsageSegment<UsageTab>] = UsageTab.allCases.map { tab in
        UsageSegment(value: tab, label: tab.title, help: "\(tab.title) (\(tab.key))")
    }

    private static let periods: [UsageSegment<Int>] = UsagePeriodOption.all.map { option in
        UsageSegment(value: option.days, label: option.label, help: "\(option.label) (⇧⌘\(option.digit))")
    }
}

/// The trigger of the header's menu: its current value and a small chevron that comes forward
/// under the pointer.
private struct UsageMenuLabel: View {
    let title: String

    var body: some View {
        UsageHover { hovered in
            HStack(spacing: 3) {
                Text(title).foregroundStyle(UsageTheme.foreground)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UsageTheme.mutedForeground)
                    .opacity(hovered ? 1 : 0.6)
            }
            .font(UsageTheme.font(14, .medium))
            .contentShape(Rectangle())
        }
    }
}
