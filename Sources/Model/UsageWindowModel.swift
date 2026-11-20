import Cocoa

// The Usage window's pure half: the UI state it keeps, the picture it draws and the builder of
// that picture from plain values. It lives with the models, not beside the store and the
// controller that use it, for one reason: here the model check of CI compiles it, so the rules
// below (what the window remembers, which key does what, when a reset result is news, which
// notice a provider gets, when a summary is stale) are pinned by checks instead of by reading.
// Nothing in this file touches SwiftUI, the controller or a process.

// MARK: - UI state types

/// The three tabs, in T3's order. Limits is not a metric: it has no period and no chart.
enum UsageTab: String, CaseIterable, Identifiable {
    case cost, tokens, limits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        case .limits: return "Limits"
        }
    }

    /// The bare key that selects the tab, as its tooltip prints it.
    var key: String { String(title.prefix(1)) }

    /// The figure the Cost and Tokens tabs are about; nil on Limits.
    var metric: UsageChartMetric? {
        switch self {
        case .cost: return .cost
        case .tokens: return .tokens
        case .limits: return nil
        }
    }
}

/// Whose figures the window shows. T3 keeps a set of hidden providers; with two providers that
/// set has three useful states, and these are they.
enum UsageProviderFilter: String, CaseIterable, Identifiable {
    case all, claude, codex

    var id: String { rawValue }

    /// The one provider this choice keeps, or nil for all of them.
    var provider: String? { self == .all ? nil : rawValue }
}

/// One of the four periods of the summary file, with T3's label and shortcut.
struct UsagePeriodOption: Identifiable, Equatable {
    let days: Int
    let label: String
    /// The digit of its ⇧⌘ shortcut.
    let digit: Int

    var id: Int { days }

    static let all = [UsagePeriodOption(days: 1, label: "Past 24h", digit: 1),
                      UsagePeriodOption(days: 7, label: "7 days", digit: 2),
                      UsagePeriodOption(days: 30, label: "30 days", digit: 3),
                      UsagePeriodOption(days: 90, label: "90 days", digit: 4)]
}

/// What the window remembers between launches: T3's `{metric, windowDays, hiddenProviders}`,
/// under the same three names with a "usage" prefix.
struct UsagePreferences: Equatable {
    var tab: UsageTab = .limits
    var days = 30
    var filter: UsageProviderFilter = .all

    static let tabKey = "usageMetric"
    static let daysKey = "usageWindowDays"
    static let hiddenKey = "usageHiddenProviders"

    init() {}

    /// T3 validates the saved object as a whole: one field that is not a known value and the
    /// defaults apply to all three. Nothing saved yet is the defaults too.
    init(defaults: UserDefaults) {
        guard let tab = defaults.string(forKey: Self.tabKey).flatMap(UsageTab.init(rawValue:)),
              let days = defaults.object(forKey: Self.daysKey) as? Int, UsageSummary.periodDays.contains(days)
        else { return }
        let hidden = defaults.stringArray(forKey: Self.hiddenKey) ?? []
        guard hidden.allSatisfy({ UsageTotals.providerOrder.contains($0) }) else { return }
        self.tab = tab
        self.days = days
        // Hiding both is T3's "No providers", a state with nothing to look at; it reads as all.
        let visible = UsageTotals.providerOrder.filter { !hidden.contains($0) }
        self.filter = visible.count == 1 ? UsageProviderFilter(rawValue: visible[0]) ?? .all : .all
    }

    func save(to defaults: UserDefaults) {
        defaults.set(tab.rawValue, forKey: Self.tabKey)
        defaults.set(days, forKey: Self.daysKey)
        defaults.set(UsageTotals.providerOrder.filter { filter.provider != nil && $0 != filter.provider },
                     forKey: Self.hiddenKey)
    }
}

/// A reset the user asked for and has not confirmed yet.
struct UsageResetRequest: Equatable {
    let provider: String
    let choice: UsageResetChoice
}

/// The limit window whose account popover is open.
struct UsagePopoverTarget: Equatable {
    let provider: String
    /// `UsageLimitRow.id` within that provider's rows.
    let row: String
}

/// The one thing that can stand over the page: a tab's dialog. One at a time, as in T3, where
/// "Set price" closes the model dialog as it opens the editor.
enum UsageSurface: Equatable {
    /// The model dialog, by `UsageModelTotals.id`.
    case model(String)
    /// The "Custom model prices" editor; `model` is the one "Set price" was pressed for.
    case prices(model: String?)
    /// The "Use a reset credit?" confirmation.
    case resetConfirm(UsageResetRequest)
}

/// A key the window answers to. Matched by physical key, as T3 does, so C, T and L work on a
/// keyboard layout that types something else there.
enum UsageShortcut: Equatable {
    case tab(UsageTab)
    case period(Int)
    case refresh
    /// Esc: closes the dialog on top, or the window.
    case dismiss

    /// Modifiers must match exactly: a bare C is not ⌘C.
    static func match(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> UsageShortcut? {
        let held = modifiers.intersection([.command, .shift, .option, .control])
        switch (keyCode, held) {
        case (8, []): return .tab(.cost)
        case (17, []): return .tab(.tokens)
        case (37, []): return .tab(.limits)
        case (53, []): return .dismiss
        case (15, [.command]): return .refresh
        case (18, [.command, .shift]): return .period(1)
        case (19, [.command, .shift]): return .period(7)
        case (20, [.command, .shift]): return .period(30)
        case (21, [.command, .shift]): return .period(90)
        default: return nil
        }
    }
}

// MARK: - the picture

/// usage/summary.json as parsed, with the stamp of the file it came from. The summary itself is
/// not Equatable (it holds every bucket of four periods); the file is rewritten atomically, so a
/// changed stamp is the whole test for "this is another summary".
struct UsageSummaryFile: Equatable {
    let summary: UsageSummary
    let stamp: Date

    static func == (a: UsageSummaryFile, b: UsageSummaryFile) -> Bool {
        a.stamp == b.stamp && a.summary.readAt == b.summary.readAt
    }
}

/// Where the Cost and Tokens tabs stand.
enum UsageLoadPhase: Equatable {
    /// No summary yet and a scan is running: draw the skeleton.
    case loading
    /// Figures on screen and a scan is running: draw them dimmed (T3's 40% opacity).
    case refreshing
    case ready
    /// No summary and no scan running; `usageError` says why when the last scan failed.
    case unavailable
}

/// One provider's section of the Limits tab: what was read, and what the model made of it.
struct UsageProviderState: Equatable, Identifiable {
    let provider: String
    /// The limits as the panel reads them (limits.json, codex/limits.json); nil without figures.
    let set: LimitsSet?
    /// The account sidecar (account.json, codex/account.json); nil until a poll has written one.
    let account: UsageAccount?
    /// How the last limits poll ended; nil until the backend has written a status.
    let status: LimitsStatus?
    /// Whether this provider's limits poll is switched on in Settings.
    let pollEnabled: Bool
    /// Title, plan, e-mail, rows and credits, built for `UsageSnapshot.now`. Draw from this.
    let limits: UsageProviderLimits
    /// "Claude: Could not read limits." — a line for the amber notices box, or nil.
    let notice: String?
    /// The last reset-credit-result.json, whenever it was written; nil when there is none.
    let resetResult: UsageResetResult?
    /// A redemption for this provider is running: disable its buttons, label them "Using…".
    let resetBusy: Bool
    /// The line under the bars ("Using reset credit…", then how it ended), without the provider's
    /// name in front; nil when there is nothing to say or the line was dismissed. Only for a
    /// redemption made since the window was opened. A command that ended without any result
    /// reads "Could not use the reset credit.". While `resetNeedsRefresh` holds the line ends in
    /// `resetRefreshHint`, unless its own sentence already asks for a refresh.
    let resetStatus: String?
    /// The attempt that holds the reset buttons until a limits refresh, or nil: the last result
    /// when it may or may not have reached the provider, or when it changed the credits and the
    /// limits could not be read afterwards; else a key the redeem command left on disk
    /// (`UsageFiles.resetPending`). Ask `mayRedeem(creditId:)` which buttons it leaves.
    let resetOpen: UsageResetResult?

    /// The next redemption has to wait for a limits refresh, which is what re-publishes the
    /// credits it is checked against. Say `UsageProviderState.resetRefreshHint` beside the
    /// buttons while this holds.
    var resetNeedsRefresh: Bool { resetOpen != nil }

    var id: String { provider }
}

/// Everything the Usage window draws that comes from outside it. Published only when it differs.
struct UsageSnapshot: Equatable {
    /// The moment every countdown, pace tick and "left by now" is computed for. Frozen between
    /// refreshes, as in T3: it moves on opening, a tab switch, a finished refresh and — while
    /// the window is visible — when the wall-clock minute changes. Never read the clock in a view.
    var now: Double = 0
    /// The providers the app shows at all (Settings → agents), Claude first.
    var providers: [String] = []
    /// One entry per shown provider, in the same order.
    var limits: [UsageProviderState] = []
    /// A limits poll is on its way, whoever asked for it: the refresh button, the window's
    /// opening or the five-minute timer. The cards are not dimmed meanwhile, as in T3.
    var limitsRefreshing = false
    /// The parsed summary, or nil until a scan has written one.
    var summary: UsageSummaryFile?
    /// usage/status.json: progress in files and the failure category. Never "is it running".
    var scan = UsageScanStatus(json: [:])
    /// The `usage` command is running — the one truth for "busy" on Cost and Tokens.
    var usageRunning = false
    /// "Usage could not be read." when the last scan failed, else nil.
    var usageError: String?
    /// usage/prices.json as saved: what the prices editor starts from.
    var prices = UsagePriceSettings()
    /// Whether hours read "1 PM" rather than "13:00"; hand it to the UsageFormat functions.
    var hour12 = true

    /// Where the prices came from (fresh | cached | unavailable); nil without a summary.
    var pricing: UsageSummaryPricing? { summary?.summary.pricing }

    var usagePhase: UsageLoadPhase {
        if summary != nil { return usageRunning ? .refreshing : .ready }
        return usageRunning ? .loading : .unavailable
    }
}

// MARK: - the files and the builder

/// The state files only the Usage window reads, parsed, each behind its own mtime gate.
struct UsageFiles {
    /// usage/summary.json; nil until a scan has written one.
    var summary: UsageSummaryFile?
    /// usage/status.json; nil until a scan has started once.
    var scan: UsageScanStatus?
    /// account.json and codex/account.json, by provider id.
    var accounts: [String: UsageAccount] = [:]
    /// reset-credit-result.json of each provider, by provider id.
    var resetResults: [String: UsageResetResult] = [:]
    /// reset-credit-pending.json of each provider, read as the `requestFailed` it stands for: the
    /// redeem command saves its key there before it sends and drops it after a definite answer, so
    /// a key on disk is an attempt that may have gone out, even one whose command died before it
    /// could write a result. The attempt's `ts` is its last send (`sentAt`), `createdAt` when the key
    /// was made; the key itself is not kept.
    var resetPending: [String: (attempt: UsageResetResult, createdAt: Double)] = [:]
    /// usage/prices.json. Swift's own file, so there is always a value: no file is no overrides.
    var prices = UsagePriceSettings()

    private var gates: [String: Date] = [:]
    private var pricesStamp: Date?
    private var pricesRead = false

    static let summaryName = "usage/summary.json"
    static let pricesName = "usage/prices.json"

    /// A provider's files live beside its limits: Claude's in the root, Codex's under codex/.
    static func name(_ file: String, of provider: String) -> String {
        (provider == Provider.codex.id ? "codex/" : "") + file
    }

    /// Re-read whatever changed under `root`. A stat per file and no parse on a quiet call, like
    /// every other loader on the tick; see StateFileLook for what its three answers mean.
    mutating func reload(root: String) {
        let path = { (name: String) in (root as NSString).appendingPathComponent(name) }

        switch StateFileLook.at(path(Self.summaryName), gate: &gates[Self.summaryName]) {
        case .missing: summary = nil
        case .unchanged: break
        case .changed(let object):
            summary = gates[Self.summaryName].map { UsageSummaryFile(summary: UsageSummary(json: object), stamp: $0) }
        }
        switch StateFileLook.at(path("usage/status.json"), gate: &gates["usage/status.json"]) {
        case .missing: scan = nil
        case .unchanged: break
        case .changed(let object): scan = UsageScanStatus(json: object)
        }
        for provider in Provider.all.map(\.id) {
            let account = Self.name("account.json", of: provider)
            switch StateFileLook.at(path(account), gate: &gates[account]) {
            case .missing: accounts[provider] = nil
            case .unchanged: break
            case .changed(let object): accounts[provider] = UsageAccount(json: object, provider: provider)
            }
            let result = Self.name("reset-credit-result.json", of: provider)
            switch StateFileLook.at(path(result), gate: &gates[result]) {
            case .missing: resetResults[provider] = nil
            case .unchanged: break
            case .changed(let object): resetResults[provider] = UsageResetResult(json: object, provider: provider)
            }
            let pending = Self.name("reset-credit-pending.json", of: provider)
            switch StateFileLook.at(path(pending), gate: &gates[pending]) {
            case .missing: resetPending[provider] = nil
            case .unchanged: break
            case .changed(let object):
                let created = usageNumber(object["createdAt"]) ?? 0
                resetPending[provider] = (UsageResetResult(
                    json: ["ts": usageNumber(object["sentAt"]) ?? created, "creditId": object["creditId"] ?? NSNull(),
                           "error": "requestFailed"],
                    provider: provider), created)
            }
        }

        // Not through StateFileLook: that keeps the last parse while a file is unreadable, which
        // is right for a file caught mid-rewrite by another process and wrong here. Nobody else
        // writes this one, so unreadable means damaged by hand — and the scan reads a damaged
        // file as "no custom prices", so the editor has to show the same.
        let pricesPath = path(Self.pricesName)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: pricesPath)[.modificationDate]) as? Date
        if !pricesRead || stamp != pricesStamp {
            prices = UsagePriceSettings.load(at: pricesPath)
            pricesStamp = stamp
            pricesRead = true
        }
    }

    /// The editor saved: take its settings now rather than at the next stat, so the dialog that
    /// reopens a moment later starts from what was just written.
    mutating func saved(_ settings: UsagePriceSettings) {
        prices = settings
        pricesRead = false
    }
}

/// One provider's limits as the app already holds them for the panel.
struct UsageLimitsInput {
    var set: LimitsSet?
    var status: LimitsStatus?
    /// The provider's limits poll is switched on.
    var enabled = true
}

/// Everything the snapshot is made from.
struct UsageInputs {
    /// The frozen moment the picture is for.
    var now: Double
    /// The providers the app shows, Claude first.
    var providers: [String]
    var limits: [String: UsageLimitsInput] = [:]
    var files = UsageFiles()
    var usageRunning = false
    /// The last `usage` run ended without success.
    var usageFailed = false
    var limitsRefreshing = false
    /// Providers with a redemption in flight.
    var resetBusy: Set<String> = []
    /// Providers whose last redemption command ended without writing a result at all.
    var resetUnanswered: Set<String> = []
    /// A result written before this moment is history, not news: the file outlives the window,
    /// and "Reset applied" from last week must not greet the next opening.
    var resetNewsSince = Double.infinity
    /// The stamp of the result each provider's line was dismissed at.
    var resetDismissed: [String: Double] = [:]
    var hour12 = true
}

extension UsageSnapshot {
    init(_ inputs: UsageInputs) {
        now = inputs.now
        providers = inputs.providers
        limits = inputs.providers.map { UsageProviderState(provider: $0, inputs: inputs) }
        limitsRefreshing = inputs.limitsRefreshing
        summary = inputs.files.summary
        if let scan = inputs.files.scan { self.scan = scan }
        usageRunning = inputs.usageRunning
        // While a scan runs the file still holds the previous run's verdict; the run in flight
        // is what will replace it.
        if !inputs.usageRunning {
            usageError = scan.failureText
                ?? (inputs.usageFailed ? UsageScanStatus(json: ["state": "failed"]).failureText : nil)
        }
        prices = inputs.files.prices
        hour12 = inputs.hour12
    }
}

extension UsageProviderState {
    init(provider: String, inputs: UsageInputs) {
        let input = inputs.limits[provider] ?? UsageLimitsInput()
        let account = inputs.files.accounts[provider]
        let result = inputs.files.resetResults[provider]
        let busy = inputs.resetBusy.contains(provider)
        let news = result.flatMap { result in
            result.ts >= inputs.resetNewsSince && inputs.resetDismissed[provider] != result.ts ? result : nil
        }
        self.provider = provider
        set = input.set
        self.account = account
        status = input.status
        pollEnabled = input.enabled
        limits = UsageProviderLimits(provider: provider, set: input.set, account: account, now: inputs.now)
        notice = Self.notice(provider: provider, input: input, hasRows: !limits.rows.isEmpty, now: inputs.now)
        resetResult = result
        resetBusy = busy
        let line: String?
        if busy {
            line = UsageResetCredit.busyStatus
        } else if inputs.resetUnanswered.contains(provider) {
            // No result to read a sentence from, so the model's own "no outcome, no category"
            // one: T3's fallback, "Could not use the reset credit.".
            line = UsageResetResult(json: [:], provider: provider).message
        } else {
            line = news?.message
        }
        // Both categories leave the attempt open with its key bound to the grant, and an answer
        // written unconfirmed (a reset, an already redeemed grant) has changed the credits the
        // sidecar still lists; only a poll that re-publishes the credits (it rewrites the sidecar)
        // makes the next press safe.
        let accountTs = account?.ts ?? 0
        let unknown = ["requestFailed", "unconfirmed"].contains(result?.error ?? "")
            || (result?.outcome != nil && result?.confirmed == false)
        var open = unknown && accountTs <= (result?.ts ?? 0) ? result : nil
        // A saved key outranks the result file: the command may have died before writing one, or
        // a later run that sent nothing may have written over it. Only its grant's retry reuses
        // the key, and only for a day from its making (the script's KEY_TTL), after which the
        // script forgets it. A poll counts only if it came after the key's last send.
        if open?.outcome == nil, let pending = inputs.files.resetPending[provider],
           inputs.now - pending.createdAt < 86_400, accountTs <= pending.attempt.ts {
            open = pending.attempt
        }
        resetOpen = open
        // The sentence of a reset nobody confirmed already ends in "Refresh to check.".
        let hint = open != nil && !busy && line?.hasSuffix("Refresh to check.") == false
        resetStatus = hint ? line.map { $0 + " " + Self.resetRefreshHint } : line
    }

    /// What to say beside the reset buttons while `resetNeedsRefresh` holds. Not a T3 sentence:
    /// T3's server keeps the open attempt itself, here the next press is only safe after a poll.
    static let resetRefreshHint: String = "Refresh limits before using another reset."

    /// Whether the choice with this credit id may be redeemed now: what disables its button and
    /// the confirmation's, and what the controller asks again before it starts the command —
    /// a spent credit cannot be given back.
    ///
    /// While `resetOpen` holds, the only press that is safe is the retry of an attempt left open,
    /// for the same grant: it sends the stored key again, so the provider answers for the first
    /// request instead of spending a second credit. Any other grant would start a new request
    /// beside one that may have gone through. After an answer nobody could confirm there is no
    /// such retry: the credits changed and the list on screen predates that. Codex names no
    /// grant (nil on both sides), so its single choice is that retry.
    func mayRedeem(creditId: String?) -> Bool {
        guard !resetBusy else { return false }
        guard let open = resetOpen else { return true }
        return open.outcome == nil && open.creditId == creditId
    }

    /// A provider's line in the notices box, in T3's words: "Claude: Could not read limits.".
    ///
    /// WHEN there is something to explain is the panel's own rule (`LimitsStatus.notice`), so the
    /// window never reports a failure the panel stays silent about: not while the poll is switched
    /// off, and not while newer figures from the other writer stand over an old failure.
    ///
    /// `hasRows` is whether the provider has any window to draw at all: an account that answered
    /// without ordinary windows but with a sidecar row (an Enterprise credit limit) has reported
    /// its limits, and "No limits reported." beside that row would contradict it.
    static func notice(provider: String, input: UsageLimitsInput, hasRows: Bool, now: Double) -> String? {
        guard let status = input.status,
              LimitsStatus.notice(status, oauthLimits: input.enabled, figuresTs: input.set?.ts, now: now,
                                  provider: provider) != nil
        else { return nil }
        let message: String
        switch status.state {
        case "no-login": message = "Claude Code is not authenticated. Run `claude auth login` and try again."
        case "empty":
            if hasRows { return nil }
            message = "No limits reported."
        default: message = "Could not read limits."
        }
        return Provider.named(provider).title + ": " + message
    }
}

// MARK: - time

/// The window's two rules about time, kept apart from the controller so they read as rules.
enum UsageClock {
    /// A summary older than this is rescanned when the window opens or a usage tab is shown.
    static let summaryStaleAfter: Double = 300

    static func summaryIsStale(readAt: Double?, now: Double) -> Bool {
        guard let readAt else { return true }
        return now - readAt >= summaryStaleAfter
    }

    /// The frozen clock moves when the wall clock enters another minute: often enough for a
    /// countdown that prints minutes, and nothing to redraw in between.
    static func minuteChanged(frozen: Double, wall: Double) -> Bool {
        (frozen / 60).rounded(.down) != (wall / 60).rounded(.down)
    }
}
