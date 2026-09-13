import SwiftUI

// The two tabs. Sessions is what you look at, MCP is what you change — which is why they are two
// tabs at all: the list of servers is long enough that scrolling past it to check a session is
// the thing the old single menu got wrong.

// MARK: - Sessions

struct PanelSessionsTab: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        VStack(spacing: 0) {
            if store.snapshot.sessions.isEmpty {
                emptyState
            } else {
                PanelSectionTitle(text: "Running") {
                    Text("\(store.snapshot.sessions.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                PanelCard {
                    VStack(spacing: 0) {
                        ForEach(Array(store.snapshot.sessions.enumerated()), id: \.element.id) { i, session in
                            if i > 0 { PanelHairline() }
                            PanelSessionRow(session: session, store: store).panelEntrance(i)
                        }
                    }
                }
            }
            if store.snapshot.codexHooksBlocked { codexHooksNote }
        }
    }

    /// Codex runs only the hooks a human has approved, and the hook it is skipping is the one that
    /// writes a session file. Without this line the tab is simply empty of Codex — which reads as
    /// "Codex is not running", and sends the reader looking for a fault in the wrong place
    /// entirely. The approval lives in Codex's own screen, so there is nothing here to click.
    ///
    /// Worded as the thing to DO, not as "sessions are hidden": someone who has not started Codex
    /// today has no sessions to hide, and a line claiming otherwise would be its own small lie.
    private var codexHooksNote: some View {
        PanelNotice(glyph: "exclamationmark.triangle",
                    text: "Approve Codex's hooks to see its sessions")
        .padding(.top, 8)
        .help("Codex runs only the hooks it has been told to trust, and this app's are still "
              + "untrusted — so it writes down no session at all. Start Codex in a terminal and "
              + "approve them once, and its sessions appear here.")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(store.snapshot.offerOpenClaude ? "No session running" : "Nothing running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            // No live session to pin, but the desktop app is up — give a way back in.
            if store.snapshot.offerOpenClaude {
                Button("Open Claude") { store.openClaude() }
                    .buttonStyle(PanelButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct PanelSessionRow: View {
    let session: PanelSession
    @ObservedObject var store: PanelStore

    private var open: Bool { store.expanded.contains(session.id) }

    /// The dot's colour is the state: the app's own amber when the session is waiting on YOU —
    /// the same hue the menu bar badge uses, so one colour means one thing — and a quiet grey once
    /// it is resting. A working session draws a spinner instead of a dot.
    private var tint: Color {
        session.eff == "permission" ? Color(nsColor: StatusController.amber)
                                    : .secondary.opacity(0.45)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { store.openSession(session) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        marker.padding(.top, 4)
                        // The figure and the badge sit beside the NAME, not beside the pair of
                        // lines. Centred across both they took their width out of the subtitle
                        // too, and the clock at the end of it was the first thing to go:
                        // "main · Running command…" with no elapsed time at all.
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                // Which agent this row belongs to, as the same glyph the limits
                                // strip uses for Codex. A glyph and not a second pill: at 300pt
                                // a "CODEX" badge beside the "IDE" one takes the branch name off
                                // the line below, and the row already carries two figures.
                                // Claude rows get none — in a panel with no Codex in it there is
                                // nothing to tell apart, and a pill on every row is just noise.
                                if session.provider == "codex" {
                                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .help("An OpenAI Codex session")
                                }
                                Text(session.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                if let pct = session.pct {
                                    Text("\(session.assumed ? "~" : "")\(pct)%")
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                                if !session.tag.isEmpty { PanelTag(text: session.tag).fixedSize() }
                            }
                            Text(session.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to bring this session's window to the front")

                Button { store.toggleExpanded(session.id) } label: {
                    // The glyph is 9pt. Without a frame and a shape around it the hit area IS the
                    // drawn chevron, which is a target you have to aim at — measured: repeated
                    // clicks a couple of points off did nothing at all.
                    PanelDisclosure(open: open)
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide details" : "Show details")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if open { PanelSessionDetailView(detail: session.detail, pct: session.pct,
                                             assumed: session.assumed) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.name), \(session.subtitle)"
            + (session.pct.map { ", context \($0)%" } ?? ""))
    }

    @ViewBuilder
    private var marker: some View {
        if session.working {
            PanelSpinner()
        } else {
            Circle().fill(tint).frame(width: 7, height: 7)
        }
    }
}

/// What the row cannot carry: the context gauge with real token figures, the session totals a
/// status line captured, and the path. Every block is optional and simply absent when its data is
/// — a desktop-app session has no totals, a directory outside git has no branch.
struct PanelSessionDetailView: View {
    let detail: PanelSessionDetail
    let pct: Int?
    let assumed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let pct {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Context").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(contextFigure(pct))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    PanelBar(value: Double(max(0, min(100, pct))) / 100,
                             fill: PanelTheme.level(Double(pct) / 100)
                                ?? Color(nsColor: .systemGreen))
                }
            }
            if let cost = detail.cost, let duration = detail.duration {
                HStack(alignment: .top, spacing: 0) {
                    detailCell("Cost", String(format: "$%.2f", cost))
                    detailCell("Duration", SessionFormat.elapsed(duration))
                    if let added = detail.linesAdded, let removed = detail.linesRemoved,
                       added + removed > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("LINES").font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                            HStack(spacing: 4) {
                                Text("+\(added)").foregroundStyle(Color(nsColor: .systemGreen))
                                Text("−\(removed)").foregroundStyle(Color(nsColor: .systemRed))
                            }
                            .font(.system(size: 12).monospacedDigit())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let dirty = detail.dirty, dirty > 0 {
                Text("\(dirty) uncommitted \(dirty == 1 ? "file" : "files")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            if !detail.model.isEmpty || !detail.cwd.isEmpty {
                HStack(spacing: 6) {
                    if !detail.model.isEmpty {
                        Text(SessionFormat.prettyModel(detail.model))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if !detail.cwd.isEmpty {
                        Text(shortPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextFigure(_ pct: Int) -> String {
        var figure = (assumed ? "~" : "") + "\(pct)%"
        if let tokens = detail.tokens, let window = detail.window {
            figure += " · \(SessionFormat.compact(tokens)) of \(SessionFormat.compact(window))"
        }
        return figure
    }

    private var shortPath: String { (detail.cwd as NSString).abbreviatingWithTildeInPath }

    private func detailCell(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption.uppercased()).font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - MCP

struct PanelMCPTab: View {
    @ObservedObject var store: PanelStore

    private var mcp: PanelMCP { store.snapshot.mcp }
    /// The waiting list expands like any other row, out of the same set: a second piece of state
    /// would need its own animation gate and its own reset on open, and would drift from both.
    private var showWaiting: Bool { store.expanded.contains(PanelStore.waitingAuthID) }

    var body: some View {
        VStack(spacing: 0) {
            PanelSectionTitle(text: mcp.summary) {
                Text(mcp.toolsLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                // The two rows that used to sit at the bottom of the menu, as the two glyphs they
                // always were: one re-checks, one opens the file every switch here writes to.
                Button { store.checkMCPNow() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PanelButtonStyle(filled: false))
                .keyboardShortcut("r", modifiers: .command)
                .disabled(mcp.checking)
                .help(mcp.checking ? "Checking MCP…" : "Check MCP now (⌘R)")
                Button { store.openSettingsJSON() } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PanelButtonStyle(filled: false))
                .help("Open settings.json — every server and tool switch is written there")
            }

            if let change = mcp.change {
                Text("changed:  " + change)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mcp.changeIsBad ? Color(nsColor: .systemRed)
                                                     : Color(nsColor: .systemBlue))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 5)
                    // Worth saying exactly once, next to the change that prompts the question.
                    .help("Applies to new sessions — an open one keeps the tools it started with")
            }

            if !mcp.groups.isEmpty {
                PanelCard {
                    VStack(spacing: 0) {
                        ForEach(Array(mcp.groups.enumerated()), id: \.element.id) { i, group in
                            PanelGroupCaption(title: group.title, divided: i > 0)
                            ForEach(Array(group.servers.enumerated()), id: \.element.id) { j, server in
                                // The stagger counts rows down the whole list, not per group: a
                                // group starting its own count over would land its first row on
                                // top of the previous group's last one.
                                PanelServerRow(server: server, store: store)
                                    .panelEntrance(mcp.rowsBefore(group: i) + j)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }

            if !mcp.waitingAuth.isEmpty { waitingBlock }
            if let error = mcp.error { errorBlock(error) }
        }
    }

    private var waitingBlock: some View {
        VStack(spacing: 0) {
            Button { store.toggleExpanded(PanelStore.waitingAuthID) } label: {
                HStack(spacing: 6) {
                    Text("\(mcp.waitingAuth.count) waiting for authorisation")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    PanelDisclosure(open: showWaiting)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Run /mcp in a terminal to authorise these")

            if showWaiting {
                PanelCard {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(mcp.waitingAuth, id: \.self) { name in
                            Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func errorBlock(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Check failed: " + error)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemRed))
                .fixedSize(horizontal: false, vertical: true)
            // EPERM against a session's folder is macOS's network-volume permission in practice:
            // FUSE mounts (arc, sshfs) count as network volumes, the dialog is shown once, and a
            // declined one is never asked again by the system — the checks then fail forever with
            // nothing saying why or what to do.
            if store.snapshot.mcp.errorIsPermission {
                Button("Grant access to network volumes…") { store.openFilesPrivacySettings() }
                    .buttonStyle(PanelButtonStyle())
                    .help("A session lives on a volume this app was denied access to. Enable this"
                          + " app under Files & Folders in System Settings — network and FUSE"
                          + " mounts sit under Network Volumes, external drives under Removable"
                          + " Volumes, both in that pane.")
                // The second way out, and on some machines the only one: macOS shows the
                // network-volume dialog once, ever, and a declined one is never offered again by
                // the system. Resetting that decision is what makes it ask on the next check.
                Button("Copy the command that makes macOS ask again") {
                    store.copyResetCommand()
                }
                .buttonStyle(PanelButtonStyle())
                .help(store.resetCommand)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 9)
        .padding(.horizontal, 4)
    }
}

struct PanelGroupCaption: View {
    let title: String
    let divided: Bool

    var body: some View {
        VStack(spacing: 0) {
            if divided { PanelHairline().padding(.top, 5) }
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .medium))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
        }
    }
}

struct PanelServerRow: View {
    let server: PanelServer
    @ObservedObject var store: PanelStore

    private var open: Bool { store.expanded.contains(server.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                marker
                Text(server.name)
                    .font(.system(size: 13))
                    .foregroundStyle(server.enabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(server.tail)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(server.state == "failed" ? Color(nsColor: .systemRed)
                                                              : Color.secondary)
                if !server.tools.isEmpty {
                    Button { store.toggleExpanded(server.id) } label: {
                        PanelDisclosure(open: open)
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? "Hide tools" : "Show tools")
                }
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { store.setServer(server, enabled: $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .help(server.tip)

            if open {
                VStack(spacing: 0) {
                    Text("Click a switch to keep a tool out of Claude's context")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 3)
                        .padding(.bottom, 4)
                    ForEach(server.tools) { tool in
                        PanelToolRow(tool: tool, server: server, store: store)
                    }
                }
                .padding(.bottom, 5)
            }
        }
    }

    @ViewBuilder
    private var marker: some View {
        // "pending" alone would not justify a spinner: a server can sit pending for reasons no
        // check will resolve — an authorisation nobody has granted — and an arc turning next to
        // work nobody is doing claims progress that is not happening.
        if server.checking {
            PanelSpinner()
        } else {
            Circle().fill(PanelTheme.serverTint(server.state)).frame(width: 7, height: 7)
        }
    }
}

struct PanelToolRow: View {
    let tool: PanelTool
    let server: PanelServer
    /// A plain reference, not @ObservedObject: the row reads nothing published, and with a
    /// hundred-tool server expanded the subscription rebuilt a hundred bodies on every publish.
    let store: PanelStore

    var body: some View {
        HStack(spacing: 8) {
            Text(tool.name)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(tool.enabled ? Color.secondary : Color.secondary.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { tool.enabled },
                set: { store.setTool(server: server, tool: tool.name, enabled: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .help(tool.help)
    }
}

/// The divider between rows inside a card — thinner and quieter than a Divider().
struct PanelHairline: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(PanelTheme.cardBorder(scheme))
            .frame(height: 0.7)
    }
}
