import SwiftUI

/// The pages of the Settings window.
///
/// A flat list, not the sectioned and searchable sidebar a large app needs: there are five pages,
/// and a search field over five rows is furniture rather than navigation. The shape is here to
/// grow into — a case added here shows up in the sidebar and in the switch below, and nowhere
/// else has to be told about it.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, motion, sounds, about

    /// The page itself, so the sidebar's selection is a page rather than a raw string.
    var id: SettingsPage { self }

    var title: String {
        switch self {
        case .general:    return "General"
        case .appearance: return "Appearance"
        case .motion:     return "Motion"
        case .sounds:     return "Sounds"
        case .about:      return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .appearance: return "paintbrush"
        case .motion:     return "wand.and.rays"
        case .sounds:     return "speaker.wave.2"
        case .about:      return "info.circle"
        }
    }
}

/// Everything that used to sit under Options in the dropdown, plus the version line and the
/// release notes. They moved out for the same reason: a panel read at a glance — which sessions
/// are running, which servers answered, how much of the limit is gone — should not also be where
/// an animation style gets picked or a version number is parked.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var page: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(SettingsPage.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 180, max: 220)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // .balanced rather than .prominentDetail: the sidebar is four rows and never needs to be
        // collapsed out of the way, and the detail pane is the same width either way.
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detail: some View {
        // An unset selection is only possible for the instant before the sidebar settles; General
        // is what the window opens on, so it is also what an empty selection shows.
        switch page ?? .general {
        case .general:    GeneralSettings(store: store)
        case .appearance: AppearanceSettings(store: store)
        case .motion:     MotionSettings(store: store)
        case .sounds:     SoundsSettings(store: store)
        case .about:      AboutSettings(store: store)
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: SettingsStore

    /// The environment variable wins over the switch, and a disabled switch with no explanation
    /// reads as broken, so the footer says which of the two is in charge.
    private var analyticsFooter: String {
        if store.analyticsBlockedByEnvironment {
            return "Switched off by \(AnalyticsPing.optOutVariable) in this app\u{2019}s environment; "
                + "the setting here does nothing while it is set."
        }
        return "Once a day, so the project can count how many copies are in use: app version, "
            + "macOS version, chip and install channel, with no identifier of any kind. The first "
            + "ping waits a day after this switch is first seen. Off means the request never "
            + "happens. PRIVACY.md has the exact bytes."
    }

    // The two footers below are typed constants rather than `+` chains written inside Text().
    // In there every `+` between literals multiplies the overloads the type checker has to weigh,
    // and this body — a nine-part chain and a three-part one — was past what Swift 6.0.3 will
    // solve at all: "unable to type-check this expression in reasonable time". CI's newer compiler
    // took it, which is how it shipped; the plugin compiles the app on the user's own Mac, with
    // whatever Swift that Mac's Command Line Tools carry, and there `build.sh` simply failed.
    private static let limitsFooter: String = "Polls Anthropic's usage endpoint with your own Claude "
        + "OAuth token, which is sent to api.anthropic.com and nowhere else. With this off, the 5h "
        + "and 7d bars only move when a status line happens to write them."

    // Worth spelling out, because "reads your Codex sessions" sounds like more than it is: the
    // numbers are already on disk, and nothing but them is looked at.
    private static let codexFooter: String = "Codex records how much of your OpenAI limits is gone "
        + "into its own session file as it works. This reads the newest one for those two figures — "
        + "no token, no request, nothing sent anywhere. A figure older than the window it measures "
        + "is dropped rather than shown, so the row disappears until Codex runs again.\n\n"
        + "The second switch lists Codex's own MCP servers in the MCP tab, with the same switches. "
        + "Asking Codex for the tool names starts each configured server, the way Codex itself "
        + "does — so with a slow server, turn this off and the servers stop being asked."

    var body: some View {
        Form {
            Section("Menu bar") {
                // "in menu bar", because the dropdown rows keep their own timers regardless: a
                // switch reading "Show timer" that leaves timers visible reads as broken.
                Toggle("Timer in menu bar", isOn: store.showTimer)
                Toggle("Thinking words", isOn: store.thinkingWords)
            }
            Section {
                Toggle("Limits via Anthropic API", isOn: store.oauthLimits)
            } header: {
                Text("Limits")
            } footer: {
                Text(Self.limitsFooter)
            }
            Section {
                Toggle("Codex limits", isOn: store.codexLimits)
                Toggle("Codex MCP servers", isOn: store.codexServers)
            } header: {
                Text("Codex")
            } footer: {
                Text(Self.codexFooter)
            }
            if store.analyticsConfigured {
                Section {
                    Toggle("Anonymous usage ping", isOn: store.analytics)
                        .disabled(store.analyticsBlockedByEnvironment)
                } header: {
                    Text("Usage")
                } footer: {
                    Text(analyticsFooter)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Animation", selection: store.animStyle) {
                    ForEach(StatusController.AnimStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                Picker("Color", selection: store.iconSystem) {
                    Text("Orange").tag(false)
                    Text("System").tag(true)
                }
            } header: {
                Text("Menu bar icon")
            } footer: {
                Text("System draws the icon as a template — black on a light menu bar, white on a "
                     + "dark one — the way every other menu bar icon behaves. Orange keeps the "
                     + "brand colour on both.")
            }
            Section {
                Picker("Layout", selection: store.limitsLayout) {
                    ForEach(PanelLimitsLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
            } header: {
                Text("Limits strip")
            } footer: {
                // Said plainly, because with one provider the picker visibly does nothing, and a
                // setting that appears to do nothing reads as broken.
                Text(store.limitsLayout.wrappedValue.detail
                     + " This only changes anything once a second provider has figures: with one, "
                     + "the strip is a single row either way.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MotionSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Level", selection: store.motionLevel) {
                    ForEach(Motion.Level.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
            } header: {
                Text("Animation in the panel")
            } footer: {
                Text(store.motionLevel.wrappedValue.detail)
            }
            // Said here rather than left as a mystery: with Reduce Motion on, picking Expressive
            // changes very little, and a setting that visibly does nothing reads as broken.
            if Motion.systemReducesMotion {
                Section {
                    Label("Reduce Motion is on in System Settings, so movement is replaced by a "
                          + "crossfade whatever is picked above.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SoundsSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Chime", selection: store.soundThreshold) {
                    Text("Off").tag(0.0)
                    Text("Every turn").tag(0.1)
                    Text("1 min+").tag(60.0)
                    Text("5 min+").tag(300.0)
                    Text("15 min+").tag(900.0)
                }
            } header: {
                Text("When a turn finishes")
            } footer: {
                Text("A threshold rather than a switch: a chime after every two-second turn is "
                     + "noise, one after a turn you walked away from is the point.")
            }
            Section {
                Picker("Sound", selection: store.needsYouSound) {
                    Text("Off").tag("")
                    ForEach(NeedsYouSound.choices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            } header: {
                Text("When Claude needs you")
            } footer: {
                Text("Picking a sound plays it once. Nothing is played when the session's own "
                     + "window is already the one you are looking at.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Where this copy stands. It is here rather than in the panel because a version number is looked
/// up once in a while and read never — the panel says something is out of date when it is, and
/// that banner is the only thing about updating that belongs in a glance.
private struct AboutSettings: View {
    @ObservedObject var store: SettingsStore

    /// A typed constant rather than a `+` chain inside Text(), for the reason spelled out above
    /// GeneralSettings' footers: that shape took the General page past what Swift 6.0.3 would
    /// type-check at all.
    private static let hooksFooter: String = "Sessions reach this app only through hooks \u{2014} "
        + "small Node scripts Claude Code and Codex run on every prompt and tool call. This copy "
        + "writes them into ~/.claude/settings.json and ~/.codex/hooks.json each time it starts, "
        + "then checks that the node they call actually starts. While either fails, it tries again "
        + "every few minutes and says why here and in the panel."

    /// The cause is selectable here and not in the panel: this is a normal window, and a path or a
    /// library name is exactly what someone wants to paste into a terminal or a bug report.
    @ViewBuilder
    private var hooksStatus: some View {
        if !store.hooksManaged {
            Label("Not managed by this copy \u{2014} it is not in Applications",
                  systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        } else if let problem = store.hooksHealth.problem {
            Label(problem.title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(problem.reason)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let hint = problem.hint {
                Text(hint)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else if store.hooksHealth == .ok {
            Label("Installed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Label("Checking\u{2026}", systemImage: "clock")
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: store.version)
                Button("What\u{2019}s new in \(store.version)") { store.showWhatsNew() }
            } header: {
                Text(store.appName)
            }
            Section {
                hooksStatus
                if store.hooksManaged {
                    Button(store.hooksChecking ? "Checking\u{2026}" : "Install hooks again") {
                        store.checkHooks()
                    }
                    .disabled(store.hooksChecking)
                }
            } header: {
                Text("Hooks")
            } footer: {
                Text(Self.hooksFooter)
            }
            Section {
                if let newer = store.newerVersion {
                    LabeledContent("Latest release", value: newer)
                    Button("What\u{2019}s new in \(newer)") { store.showLatestNotes() }
                    // Homebrew owns the bundle, and a DMG swapped under it would be undone by the
                    // next `brew upgrade` — so the command is handed over rather than performed.
                    if store.brewManaged {
                        LabeledContent("Update with", value: store.brewUpgradeCommand)
                            .textSelection(.enabled)
                    }
                } else {
                    Label("This copy is up to date", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Button("Check now") { store.checkForUpdate() }
            } header: {
                Text("Updates")
            } footer: {
                Text("Checked once a day against the project\u{2019}s GitHub releases and the "
                     + "Homebrew cask. Nothing about this machine is sent anywhere \u{2014} both "
                     + "are plain public reads.")
            }
        }
        .formStyle(.grouped)
    }
}
