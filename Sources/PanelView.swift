import SwiftUI

// The panel itself: the limits strip, the two tabs, and the footer. Everything above the tabs is
// deliberately fixed — the strip and the banner are what a glance is for, and a glance should not
// have to scroll or switch tabs to land on them.
struct PanelView: View {
    @ObservedObject var store: PanelStore
    @Environment(\.colorScheme) private var scheme
    /// How tall the list wants to be, measured from the content itself. The starting value only
    /// has to be non-zero: the first layout replaces it.
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            if let update = store.snapshot.update {
                PanelUpdateBanner(update: update, store: store)
                    .padding(.bottom, 7)
            }
            limitsStrip
            tabBar
            // The panel grows with its content up to a cap and scrolls past it, so a machine with
            // two servers does not get the window a machine with twenty needs. Both halves of that
            // are load-bearing, and each one was a bug on its own:
            //
            //   .fixedSize on the CONTENT makes it report its ideal height whatever the scroll
            //   view proposes. Without it the frame below and the measurement feed each other and
            //   the list collapses to nothing while the panel around it looks perfectly healthy.
            //
            //   .fixedSize on the SCROLL VIEW instead — which looks like the tidier spelling —
            //   is wrong: a list longer than the cap then draws at full height straight through
            //   its own frame, over the tabs above it and the footer below.
            //
            // The height is read back through onAppear/onChange rather than a PreferenceKey: a
            // preference published from inside a ScrollView's content arrived here as its default
            // 0 and never moved, which is the same collapse by another route.
            ScrollView(.vertical) {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(GeometryReader { geo in
                        Color.clear
                            .onAppear { contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { contentHeight = $0 }
                    })
            }
            .scrollIndicators(.never)
            .frame(height: min(max(contentHeight, 1), store.snapshot.contentCap))
            .clipped()
            if store.snapshot.notificationsDenied { notificationsWarning }
            footer
        }
        .padding(PanelTheme.pad)
        .frame(width: store.snapshot.width)
        .background(PanelMaterial())
        // The corner is clipped here rather than on the window's layer: the window's shadow is
        // computed from the alpha channel, so rounding the content is also what rounds the shadow.
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelTheme.corner, style: .continuous)
                .strokeBorder(PanelTheme.cardBorder(scheme), lineWidth: 0.5))
        // Motion asks for the level at the moment the animation is committed rather than baking it
        // into a view; Reduce Motion is handled inside Motion itself.
        .animation(Motion.moves ? .easeOut(duration: Motion.time(0.18)) : nil, value: store.tab)
        .animation(Motion.moves ? .easeOut(duration: Motion.time(0.18)) : nil, value: store.expanded)
    }

    // MARK: limits

    @ViewBuilder
    private var limitsStrip: some View {
        let groups = store.snapshot.limitGroups
        if groups.isEmpty {
            Text(store.snapshot.limitsNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PanelTheme.wellFill(scheme)))
        } else if groups.count == 1, let only = groups.first {
            // One provider needs no switcher and no second name to be told apart from — with one
            // exception. A Claude-only strip is what most installs have always seen and keeps its
            // bare row of cells; a lone Codex one would otherwise show "5 HOURS" and "7 DAYS"
            // that read exactly like Claude's, so it keeps its name.
            limitRow(only, named: only.provider != "claude")
        } else {
            switch store.snapshot.limitsLayout {
            case .rows:
                VStack(spacing: 6) {
                    ForEach(groups) { limitRow($0, named: true) }
                }
            case .switcher:
                VStack(spacing: 6) {
                    providerSwitcher(groups)
                    limitRow(shownGroup(groups), named: false)
                }
            }
        }
    }

    /// Which provider the switcher is showing. A remembered pick that no longer has figures falls
    /// back to the first group rather than to an empty strip — a provider can go quiet for a week
    /// and come back, and the pick is worth keeping across that.
    private func shownGroup(_ groups: [PanelLimitGroup]) -> PanelLimitGroup {
        groups.first { $0.provider == store.snapshot.limitsProvider } ?? groups[0]
    }

    private func limitRow(_ group: PanelLimitGroup, named: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if named { limitHeader(group) }
            HStack(spacing: 5) {
                ForEach(group.limits) { limit in
                    PanelLimitTile(limit: limit)
                }
            }
        }
        .help(group.tip)
    }

    /// Who the row belongs to, and when the first of its windows comes back. The reset sits here
    /// rather than in every cell because at 300pt a cell has room for a name, a figure and a bar
    /// — and the window that resets first is the only one whose countdown changes a decision.
    private func limitHeader(_ group: PanelLimitGroup) -> some View {
        HStack(spacing: 4) {
            Image(systemName: group.glyph).font(.system(size: 9, weight: .semibold))
            Text(group.plan.map { "\(group.title) · \($0)" } ?? group.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let resets = group.resets {
                Text("resets \(resets)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 3)
    }

    /// The switcher, built like the tab bar below it because it is the same gesture in the same
    /// window. The hairline under each name is the part that matters: a switcher whose inactive
    /// side says nothing turns the other provider into a blind spot, and "am I about to run out
    /// of anything" is the question the strip exists to answer. So every tab carries its
    /// provider's fullest window, coloured by the same thresholds as the bars themselves.
    private func providerSwitcher(_ groups: [PanelLimitGroup]) -> some View {
        let current = shownGroup(groups).provider
        return HStack(spacing: 2) {
            ForEach(groups) { group in
                let active = group.provider == current
                Button { store.selectLimitsProvider(group.provider) } label: {
                    VStack(spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: group.glyph).font(.system(size: 10, weight: .medium))
                            Text(group.title)
                                .font(.system(size: 11.5, weight: active ? .medium : .regular))
                                .lineLimit(1)
                            if let resets = group.resets {
                                Text(resets)
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        if let worst = group.worst {
                            PanelBar(value: worst.fraction,
                                     fill: PanelTheme.level(worst.fraction)
                                        ?? Color.primary.opacity(active ? 0.45 : 0.25),
                                     height: 2.5)
                                .padding(.horizontal, 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(active ? PanelTheme.raisedFill(scheme) : .clear)
                            .shadow(color: active ? .black.opacity(0.10) : .clear,
                                    radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
                .accessibilityLabel(group.tip + (group.worst.map { ", fullest window \($0.used)%" } ?? ""))
                .help(group.tip)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(PanelTheme.wellFill(scheme)))
    }

    // MARK: tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button { store.tab = tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon).font(.system(size: 11, weight: .medium))
                        Text(tab.title).font(.system(size: 12,
                                                     weight: store.tab == tab ? .medium : .regular))
                        if let count = badge(for: tab) {
                            Text(count)
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(store.tab == tab ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(store.tab == tab ? PanelTheme.raisedFill(scheme) : .clear)
                            .shadow(color: store.tab == tab ? .black.opacity(0.10) : .clear,
                                    radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(store.tab == tab ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(PanelTheme.wellFill(scheme)))
        .padding(.top, 7)
    }

    private func badge(for tab: PanelTab) -> String? {
        switch tab {
        case .sessions:
            let n = store.snapshot.sessions.count
            return n > 0 ? "\(n)" : nil
        case .mcp:
            let mcp = store.snapshot.mcp
            return mcp.isEmpty ? nil : "\(mcp.live)/\(mcp.visible)"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.tab {
        case .sessions: PanelSessionsTab(store: store)
        case .mcp:      PanelMCPTab(store: store)
        }
    }

    // MARK: footer

    private var notificationsWarning: some View {
        Button { store.openNotificationSettings() } label: {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash").font(.system(size: 10))
                Text("Notifications are off — open System Settings")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(nsColor: .systemOrange))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .systemOrange).opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        // macOS asks once per app, ever. Alerts like "MCP server went down" stay muted until
        // notifications are switched back on in System Settings.
        .help("macOS asks once per app, ever. Alerts stay muted until this is switched back on.")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(store.snapshot.limitGroups.isEmpty ? "" : "Limits · " + store.snapshot.limitsNote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { store.openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(PanelIconLabelStyle())
            }
            .buttonStyle(PanelButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            Button { store.quit() } label: {
                Label("Quit", systemImage: "power")
                    .labelStyle(PanelIconLabelStyle())
            }
            .buttonStyle(PanelButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.top, 9)
        .padding(.horizontal, 3)
    }
}

/// A glyph and its word, sized for the footer and the section headers.
struct PanelIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}

/// One limit window in the strip: its name, the figure, and a hairline bar under both.
struct PanelLimitTile: View {
    @Environment(\.colorScheme) private var scheme
    let limit: PanelLimit

    var body: some View {
        // A warning level outranks Fable's own tint, at 75% and again at 90%: the colour of
        // "nearly out" has to mean one thing across the whole strip. The badge is what says this
        // is the model's window rather than the account's, so it is also what earns the tint.
        let level = PanelTheme.level(limit.fraction)
        let tint = level ?? (limit.badge != nil ? PanelTheme.fable : Color.primary.opacity(0.5))
        return VStack(alignment: .leading, spacing: 2) {
            Text(limit.badge.map { "\(limit.title) \($0)" } ?? limit.title)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.35)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(limit.used)%")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(level ?? Color.primary)
                Spacer(minLength: 0)
            }
            PanelBar(value: limit.fraction, fill: tint)
                .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(PanelTheme.wellFill(scheme)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([limit.title, limit.badge, "\(limit.used)% used",
                             limit.resets.map { "resets in \($0)" }]
            .compactMap { $0 }.joined(separator: ", "))
        .help(limit.resets.map { "Resets in \($0)" } ?? limit.title)
    }
}

/// The out-of-date banner, in its three shapes. It is the panel's whole first row when it is
/// there — a card rather than a line, so it is seen without reading down.
struct PanelUpdateBanner: View {
    let update: PanelUpdate
    /// A plain reference, not @ObservedObject: this view calls methods on the store and reads
    /// nothing published from it, and the subscription would only make it redraw on every publish.
    let store: PanelStore

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(update.stage ?? subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if update.stage == nil {
                    Image(systemName: update.kind == .brew ? "doc.on.doc" : "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: PanelTheme.cardCorner, style: .continuous)
                .fill(Color(nsColor: .controlAccentColor).opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private var icon: String {
        switch update.kind {
        case .available: return "arrow.down.circle"
        case .restart:   return "arrow.clockwise.circle"
        case .brew:      return "terminal"
        }
    }

    private var title: String {
        switch update.kind {
        case .available, .brew: return "Update available: \(update.version)"
        case .restart:          return "Restart to finish updating"
        }
    }

    private var subtitle: String {
        switch update.kind {
        case .available: return "Read what changed, then install"
        case .restart:   return "\(update.version) is installed and waiting"
        case .brew:      return update.command ?? ""
        }
    }

    private var tip: String {
        switch update.kind {
        case .available:
            return "The release notes open first; from there one click replaces this app."
        case .restart:
            // macOS keeps the copy that was running when it was replaced, so this one is still on
            // the old version until it restarts.
            return "\(update.version) is already installed. macOS keeps the copy that was running"
                + " when it was replaced, so this one stays on the old version until it restarts."
        case .brew:
            // brew owns the bundle, and a DMG swapped under it would be undone by the next upgrade.
            return "Homebrew owns this copy. Click to copy the upgrade command."
        }
    }

    private func act() {
        switch update.kind {
        case .available: store.showWhatsNew()
        case .restart:   store.restartIntoInstalled()
        case .brew:      if let command = update.command { store.copyToPasteboard(command) }
        }
    }
}
