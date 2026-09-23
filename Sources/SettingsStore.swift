import Combine
import SwiftUI

/// What the Settings window edits, exposed as bindings straight into the object that already owns
/// every one of these values.
///
/// It deliberately keeps no copies. Each binding reads from StatusController and writes through
/// the matching `apply` method below — the same method that performs the side effect the old menu
/// row performed inline: re-rendering the bar, re-polling limits, previewing the picked sound.
/// A second copy of a setting is how a switch ends up disagreeing with the thing it switches, and
/// this window stays open while the menu, the poll timer and the hooks all keep running.
final class SettingsStore: ObservableObject {
    private weak var controller: StatusController?

    init(controller: StatusController) { self.controller = controller }

    /// Everything this window shows that moves on its own — a hook check or an update check
    /// finishing, Codex answering about its hooks — compared on every tick, exactly as PanelStore
    /// compares its snapshot. It used to be announced by hand before each change, and the one
    /// change that forgot to announce itself was a "Check now" that looked like it did nothing.
    /// Only a change detector: the getters below still read the controller, so there is no second
    /// copy of anything to disagree with.
    private struct Live: Equatable {
        let hooksHealth: HookHealth
        let hooksChecking: Bool
        let codexPresent: Bool
        let codexHooksUntrusted: Int?
        let updateChecking: Bool
        let updateCheckedAt: Date?
        let updateProblem: String?
        let newerVersion: String?
    }
    private var live: Live?

    func refresh() {
        let next = Live(hooksHealth: hooksHealth, hooksChecking: hooksChecking,
                        codexPresent: codexPresent, codexHooksUntrusted: codexHooksUntrusted,
                        updateChecking: updateChecking, updateCheckedAt: updateCheckedAt,
                        updateProblem: updateProblem, newerVersion: newerVersion)
        guard next != live else { return }
        live = next
        objectWillChange.send()
    }

    /// `fallback` is only reachable once the controller has gone away, which in this app means the
    /// process is on its way out. It is never shown; it exists so the binding stays total.
    private func bind<Value>(_ read: @escaping (StatusController) -> Value,
                             _ write: @escaping (StatusController, Value) -> Void,
                             or fallback: Value) -> Binding<Value> {
        Binding(
            get: { [weak self] in
                guard let controller = self?.controller else { return fallback }
                return read(controller)
            },
            set: { [weak self] value in
                guard let self, let controller = self.controller else { return }
                // Announced before the write, not after. SwiftUI re-reads the getter once it has
                // been told the object changed, so announcing afterwards leaves the control
                // showing the previous value until something else happens to redraw it.
                self.objectWillChange.send()
                write(controller, value)
            })
    }

    var showTimer: Binding<Bool> {
        bind({ $0.showTimer }, { $0.applyShowTimer($1) }, or: false)
    }
    var thinkingWords: Binding<Bool> {
        bind({ $0.useThinkingWords }, { $0.applyThinkingWords($1) }, or: true)
    }
    var oauthLimits: Binding<Bool> {
        bind({ $0.oauthLimits }, { $0.applyOAuthLimits($1) }, or: true)
    }
    var codexLimits: Binding<Bool> {
        bind({ $0.codexLimits }, { $0.applyCodexLimits($1) }, or: true)
    }
    var codexServers: Binding<Bool> {
        bind({ $0.codexServers }, { $0.applyCodexServers($1) }, or: true)
    }
    var exactTerminalFocus: Binding<Bool> {
        bind({ $0.exactTerminalFocus }, { $0.applyExactTerminalFocus($1) }, or: false)
    }
    var limitsLayout: Binding<PanelLimitsLayout> {
        bind({ $0.limitsLayout }, { $0.applyLimitsLayout($1) }, or: .rows)
    }
    var analytics: Binding<Bool> {
        bind({ $0.analytics }, { $0.applyAnalytics($1) }, or: true)
    }
    /// Whether this Mac has Codex at all. The hook-trust row below is about a program that is not
    /// on most machines, and a settings window that explains a problem the reader cannot have is
    /// worse than one that stays quiet.
    var codexPresent: Bool {
        controller?.codexInstalled ?? false
    }
    /// How many of this app's hooks Codex is still skipping, and whether an answer has been had at
    /// all. Nil means Codex has not been asked yet — a fresh launch, or a Codex that did not
    /// answer — and that is not the same as zero: saying "all approved" on the strength of never
    /// having looked is the one wrong thing this row could say.
    var codexHooksUntrusted: Int? { controller?.codexHooksAnswered == true
        ? controller?.codexHooksUntrusted : nil }
    func approveCodexHooks() { controller?.approveCodexHooks() }
    func revealCodexHooks() { controller?.revealCodexHooks() }

    /// Whether the ping row is shown at all: a build with no receiver, or a machine whose
    /// environment forbids the ping, has nothing to switch. The footer says which.
    var analyticsConfigured: Bool { AnalyticsPing.configured }
    var analyticsBlockedByEnvironment: Bool {
        ProcessInfo.processInfo.environment[AnalyticsPing.optOutVariable] != nil
    }
    var pet: Binding<String> {
        bind({ $0.petID }, { $0.applyPet($1) }, or: "")
    }
    /// The pet for rows belonging to Codex. Its own setting, so someone running both agents can
    /// tell the two kinds of row apart without reading a word.
    var codexPet: Binding<String> {
        bind({ $0.codexPetID }, { $0.applyPet($1, provider: "codex") }, or: "")
    }
    /// What the pet picker shows: each pet with its frames, so the choice is the animal itself
    /// rather than its name. The pictures are the controller's and are given back when the
    /// Settings window closes — see petPreviews() there.
    var petChoices: [(pet: Pet, atlas: PetAtlas?)] {
        controller?.petPreviews() ?? []
    }
    /// The same for the menu bar, where the choice includes the three styles the app draws itself
    /// and every picture is the size the bar will actually show.
    var iconChoices: [(icon: MenuBarIcon, name: String, frames: [NSImage])] {
        controller?.iconChoicePreviews() ?? []
    }
    var animStyle: Binding<MenuBarIcon> {
        bind({ $0.animStyle }, { $0.applyAnimStyle($1) }, or: .crab)
    }
    /// Whether the Color setting below does anything: a pet is a painted sprite and is always
    /// drawn as itself, so the switch would be a control that visibly does nothing.
    var iconIsPet: Bool { controller?.animStyle.isPet ?? false }
    var iconSystem: Binding<Bool> {
        bind({ $0.iconSystem }, { $0.applyIconSystem($1) }, or: false)
    }
    var soundThreshold: Binding<Double> {
        bind({ $0.soundThreshold }, { $0.applySoundThreshold($1) }, or: 0)
    }
    var needsYouSound: Binding<String> {
        bind({ $0.needsYouSound }, { $0.applyNeedsYouSound($1) }, or: NeedsYouSound.defaultChoice)
    }
    /// The one value that does not live on the controller: Motion is asked for it from views that
    /// have no controller to reach. It still writes through the controller, so every setting keeps
    /// exactly one write path.
    var motionLevel: Binding<Motion.Level> {
        bind({ _ in Motion.level }, { $0.applyMotionLevel($1) }, or: .subtle)
    }

    // MARK: About
    //
    // Read-only, and read at draw time rather than stored: the version cannot change under an open
    // window, and the update state is the panel's job to report live — this page only has to say
    // where this copy stands when someone comes looking for it. The one thing it follows live is
    // a check, since "Check now" is pressed here: the controller announces its start and its end.

    var appName: String { controller?.appName ?? "Claude Control Bar" }
    var version: String { controller?.currentVersion ?? "0" }

    /// The newer version on offer, or nil when this copy is current.
    var newerVersion: String? {
        guard let controller,
              let latest = UserDefaults.standard.string(forKey: "latestVersion"),
              StatusController.versionIsNewer(latest, than: controller.currentVersion)
        else { return nil }
        return latest
    }

    /// True when Homebrew owns this bundle, so updating is `brew upgrade` rather than our own swap.
    var brewManaged: Bool { controller?.brewManaged ?? false }
    var brewUpgradeCommand: String { controller?.brewUpgradeCommand ?? "" }

    func showWhatsNew() { controller?.showWhatsNewCurrent() }
    func showLatestNotes() { controller?.showWhatsNewLatest() }
    func checkForUpdate() { controller?.checkForUpdate(force: true) }
    var updateChecking: Bool { controller?.updateCheckRunning ?? false }
    var updateCheckedAt: Date? { controller?.updateCheckedAt }
    var updateProblem: String? { controller?.updateCheckProblem }

    // MARK: Hooks
    //
    // Read at draw time like the rest of this page; a look that finishes while the window is open
    // redraws it through refresh().

    /// False for a build run outside Applications, which never touches settings.json — so the
    /// page says that, rather than showing a status nobody checked.
    var hooksManaged: Bool { controller?.isInstalledCopy ?? false }
    var hooksHealth: HookHealth { controller?.hookHealth ?? .unchecked }
    var hooksChecking: Bool { controller?.hookCheckRunning ?? false }
    func checkHooks() { controller?.checkHooks(thenApproveCodex: true) }
}

// Applying a setting: the value, the UserDefaults key it is remembered under, and the side effect
// that makes the change visible now rather than at the next poll. These were the bodies of the
// menu's @objc choosers; they moved here whole when the Options block became a window, so the
// behaviour of every switch is unchanged and there is still one place that performs it.
extension StatusController {

    func applyShowTimer(_ on: Bool) {
        showTimer = on
        UserDefaults.standard.set(on, forKey: "showTimer")
        applyTitle()
    }

    func applyThinkingWords(_ on: Bool) {
        useThinkingWords = on
        UserDefaults.standard.set(on, forKey: "thinkingWords")
        evaluate()   // re-render the bar label immediately with or without the rotating word
    }

    /// Off is a real choice here, not decoration: the poll authenticates with the user's own
    /// Claude OAuth token (sent to api.anthropic.com and nowhere else). Switching it back on polls
    /// immediately — waiting up to five minutes to see the effect of a click reads as a click that
    /// did not land.
    func applyOAuthLimits(_ on: Bool) {
        oauthLimits = on
        UserDefaults.standard.set(on, forKey: "oauthLimits")
        // The parse gate would otherwise keep the pre-toggle figures until the file's next
        // rewrite: off must drop oauth-sourced numbers on the next tick, on must re-adopt them.
        limitsMTime = nil
        if on { pollLimits() }
    }

    /// Off empties the Codex groups in the MCP tab rather than leaving a stale list: the list is
    /// only true while something keeps asking Codex for it.
    func applyCodexServers(_ on: Bool) {
        codexServers = on
        UserDefaults.standard.set(on, forKey: "codexServers")
        if on, codexInstalled {
            runQuietCommand(.mcpRefresh(provider: "codex"))
        }
        refreshCounts()
    }

    /// Off drops the figures rather than freezing them, exactly as the Anthropic switch does.
    /// Nothing is spent either way: Codex's numbers are read out of a file it wrote itself, so
    /// what this switches off is the reading, not a request.
    func applyCodexLimits(_ on: Bool) {
        codexLimits = on
        UserDefaults.standard.set(on, forKey: "codexLimits")
        // The mtime gate would otherwise hold the pre-toggle figures until the file's next
        // rewrite, which for a quiet Codex install could be days.
        codexLimitsMTime = nil
        // The same gate pollLimits applies: switching this on where Codex has never run should
        // not spawn a process to be told there is nothing to read.
        if on, codexHasRun {
            runQuietCommand(.limits(provider: "codex"))
        }
        loadCodexLimits()
        refreshCounts()
    }

    /// Exact terminal focus: on a click, jump to the window and tab a CLI session runs in rather
    /// than raising its terminal app.
    ///
    /// Off by default and never turned on for anybody, because the first click after this costs a
    /// macOS Automation prompt — and a permission prompt that arrives with no warning is the thing
    /// this project spends the most care avoiding. The app explains itself first, in its own words,
    /// so the system prompt arrives as the expected second step and not as an ambush; the
    /// explanation is shown once, and again after a refusal, since a refusal means the first one
    /// did not land.
    ///
    /// Deferred to the next turn of the run loop so the switch finishes moving before a modal takes
    /// the window: a toggle frozen mid-animation behind an alert reads as a hang.
    func applyExactTerminalFocus(_ on: Bool) {
        exactTerminalFocus = on
        UserDefaults.standard.set(on, forKey: "exactTerminalFocus")
        guard on, !UserDefaults.standard.bool(forKey: "exactFocusExplained") else { return }
        UserDefaults.standard.set(true, forKey: "exactFocusExplained")
        DispatchQueue.main.async { [weak self] in self?.explainExactTerminalFocus() }
    }

    /// The app's own words, before macOS's. It names what is being asked for, who it is asked of,
    /// and where to take it back — the three things the system prompt does not say.
    func explainExactTerminalFocus() {
        let alert = NSAlert()
        alert.messageText = "Exact terminal focus"
        alert.informativeText = Self.exactFocusExplanation
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Typed constant per the code conventions.
    static let exactFocusExplanation: String =
        "Clicking a session will now jump to the exact terminal window and tab it runs in, "
        + "instead of just bringing the terminal to the front.\n\n"
        + "To do that the app has to control your terminal, so macOS will ask you once, the next "
        + "time you click a session. It asks about Terminal or iTerm only, and the app uses it for "
        + "nothing but selecting the tab.\n\n"
        + "You can take it back at any time in System Settings → Privacy & Security → Automation. "
        + "Saying no also switches this off, so clicks go back to raising the terminal app."

    /// Nothing to re-read: the layout is only how the same figures are arranged, so the panel
    /// republishing is the whole effect.
    func applyLimitsLayout(_ layout: PanelLimitsLayout) {
        limitsLayout = layout
        UserDefaults.standard.set(layout.rawValue, forKey: "limitsLayout")
        refreshCounts()
    }

    /// The switcher's pick, written from the panel rather than from Settings. Remembered so that
    /// someone who went looking for their Codex figures finds them there next time.
    func applyLimitsProvider(_ provider: String) {
        limitsProvider = provider
        UserDefaults.standard.set(provider, forKey: "limitsProvider")
    }

    func applyPet(_ id: String, provider: String = "claude") {
        if provider == "codex" {
            codexPetID = id
            UserDefaults.standard.set(id, forKey: "codexPetID")
        } else {
            petID = id
            UserDefaults.standard.set(id, forKey: "petID")
        }
        refreshCounts()   // the rows are drawn from the snapshot, which carries the pets
    }

    func applyAnimStyle(_ style: MenuBarIcon) {
        animStyle = style
        UserDefaults.standard.set(style.raw, forKey: "animStyle")
        animTimer?.invalidate(); animTimer = nil   // recreated at the new style's fps by render()
        frameIdx = 0
        evaluate()
    }

    func applyIconSystem(_ system: Bool) {
        iconSystem = system
        UserDefaults.standard.set(system, forKey: "iconSystem")
        evaluate()   // re-render the current state in the new colour
    }

    func applySoundThreshold(_ seconds: Double) {
        soundThreshold = seconds
        UserDefaults.standard.set(seconds, forKey: "soundThreshold")
    }

    func applyNeedsYouSound(_ name: String) {
        needsYouSound = name
        UserDefaults.standard.set(name, forKey: "needsYouSound")
        playNeedsYou()   // the pick is its own preview
    }

    /// Nothing to re-render: the menu is rebuilt on every open, and each animation asks Motion for
    /// the level at the moment it is committed rather than baking it into a view.
    func applyMotionLevel(_ level: Motion.Level) {
        Motion.level = level
        UserDefaults.standard.set(level.rawValue, forKey: "motionLevel")
    }
}
