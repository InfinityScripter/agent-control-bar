import Foundation

// The model behind the Usage window's Limits tab: what each provider's rows say, and every number
// and sentence the tab draws from them. The maths and the English copy are T3 Code's (its
// usageLimits.ts and usageLimitsCopy.ts), reduced to what one machine with one account per
// provider can show — no pooling across accounts, no weights, no environments.
//
// The rows start from the same LimitsSet the 300pt panel draws, so the window and the panel cannot
// disagree about a figure; the account sidecar only adds what those files cannot hold.

// MARK: - Reading the sidecar's JSON

/// A JSON number, or nil. A boolean is an NSNumber too, and `true` where a percentage belongs is a
/// damaged file, not 1%.
func usageNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    return double.isFinite ? double : nil
}

/// An epoch second, or nil: zero and negatives are how a writer says "no time".
private func usageEpoch(_ value: Any?) -> Double? {
    usageNumber(value).flatMap { $0 > 0 ? $0 : nil }
}

private func usageText(_ value: Any?) -> String? {
    let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? nil : text
}

/// Every formula below assumes 0...100, and limits.json does not promise it for Claude.
private func usageClampPercent(_ value: Double) -> Double {
    value.isFinite ? min(100, max(0, value)) : 0
}

/// JavaScript's Math.round for the non-negative values that occur here: a half rounds up.
private func usageRound(_ value: Double) -> Int { value.rounded().clampedInt }

// MARK: - Account sidecar (account.json, codex/account.json)

/// A limit row the panel's own files cannot hold: a model-scoped Claude week other than Fable,
/// Codex's monthly credit limit.
struct UsageExtraWindow: Equatable {
    let id: String
    /// session | weekly | monthly | other
    let kind: String
    /// Claude: the model's display name. Codex: the row's own name.
    let name: String
    let usedPercent: Double
    let resetsAt: Double?
    let windowMinutes: Int?
}

extension UsageExtraWindow {
    init?(json: Any?) {
        guard let o = json as? [String: Any], let id = usageText(o["id"]),
              let used = usageNumber(o["usedPercent"]) else { return nil }
        let kind = o["kind"] as? String ?? ""
        self.id = id
        self.kind = ["session", "weekly", "monthly"].contains(kind) ? kind : "other"
        self.name = usageText(o["name"]) ?? ""
        self.usedPercent = usageClampPercent(used)
        self.resetsAt = usageEpoch(o["resetsAt"])
        self.windowMinutes = usageNumber(o["windowMinutes"]).flatMap { $0 > 0 ? $0.clampedInt : nil }
    }
}

/// Claude's pay-as-you-go budget for the month, as a share already spent.
struct UsageSpend: Equatable {
    let enabled: Bool
    let usedPercent: Double?
}

extension UsageSpend {
    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        self.enabled = o["enabled"] as? Bool ?? false
        self.usedPercent = usageNumber(o["usedPercent"]).flatMap { $0 >= 0 ? usageClampPercent($0) : nil }
    }
}

/// One kind of banked Claude reset, redeemed by its credit id.
struct UsageResetOption: Equatable {
    let creditId: String
    /// session | weekly | fable | full — what the reset refills.
    let kind: String
    let availableCount: Int
    let expiresAt: Double?
}

extension UsageResetOption {
    init?(json: Any?) {
        guard let o = json as? [String: Any], let creditId = usageText(o["creditId"]) else { return nil }
        self.creditId = creditId
        self.kind = o["kind"] as? String ?? ""
        self.availableCount = max(0, usageNumber(o["availableCount"])?.clampedInt ?? 0)
        self.expiresAt = usageEpoch(o["expiresAt"])
    }
}

/// Banked reset credits. Codex has a bare counter; Claude adds `options`, because its resets
/// differ in what they refill.
struct UsageResetCredits: Equatable {
    let availableCount: Int
    let nextExpiresAt: Double?
    let options: [UsageResetOption]?
}

extension UsageResetCredits {
    /// nil is "nothing known", and so is an account that is not eligible for resets at all: T3
    /// publishes no credits block for it rather than a zero.
    init?(json: Any?) {
        guard let o = json as? [String: Any], o["eligible"] as? Bool != false else { return nil }
        self.availableCount = max(0, usageNumber(o["availableCount"])?.clampedInt ?? 0)
        self.nextExpiresAt = usageEpoch(o["nextExpiresAt"])
        self.options = (o["options"] as? [Any])?.compactMap { UsageResetOption(json: $0) }
    }
}

/// What the limits poll learned about the account besides the windows the panel draws. Every piece
/// is optional: a missing one is unknown, never an error.
struct UsageAccount: Equatable {
    let provider: String
    let ts: Double
    /// Claude's subscription word, e.g. "max".
    let subscriptionType: String?
    /// Codex's plan word, e.g. "promax".
    let planType: String?
    let email: String?
    let extraWindows: [UsageExtraWindow]
    let spend: UsageSpend?
    let resetCredits: UsageResetCredits?
}

extension UsageAccount {
    /// `provider` is the caller's: which of the two files this is decides it, not a key inside.
    init(json: [String: Any], provider: String) {
        self.provider = provider
        self.ts = usageNumber(json["ts"]) ?? 0
        self.subscriptionType = usageText(json["subscriptionType"])
        self.planType = usageText(json["planType"])
        self.email = usageText(json["email"])
        self.extraWindows = (json["extraWindows"] as? [Any] ?? []).compactMap { UsageExtraWindow(json: $0) }
        self.spend = UsageSpend(json: json["spend"])
        self.resetCredits = UsageResetCredits(json: json["resetCredits"])
    }
}

// MARK: - Plan labels

/// The sidecars carry the providers' own plan words; the names shown are T3's.
enum UsagePlan {
    /// "max" → "Claude Max Subscription". An unknown word is shown in title case rather than
    /// dropped: a new tier should read oddly, not vanish.
    static func claudeLabel(_ subscriptionType: String?) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "_-"))
        let words = (subscriptionType ?? "").components(separatedBy: separators).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let short: String
        switch words.joined().lowercased() {
        case "claudemaxsubscription", "claudemax5xsubscription", "max", "maxplan", "max5": short = "Max"
        case "claudemax20xsubscription", "max20": short = "Ultra"
        case "claudeenterprisesubscription", "enterprise": short = "Enterprise"
        case "claudeteamsubscription", "team": short = "Team"
        case "claudeprosubscription", "pro": short = "Pro"
        case "claudefreesubscription", "free": short = "Free"
        default: short = words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
        // A word that already says "Claude" or "Subscription" is not wrapped in it a second time.
        let squeezed = short.lowercased().replacingOccurrences(of: " ", with: "")
        switch (squeezed.hasPrefix("claude"), squeezed.hasSuffix("subscription")) {
        case (true, true): return short
        case (true, false): return short + " Subscription"
        case (false, true): return "Claude " + short
        case (false, false): return "Claude " + short + " Subscription"
        }
    }

    /// Exact, case-sensitive words: the table is Codex's own enum, not something typed by hand.
    static func codexLabel(_ planType: String?) -> String? {
        switch planType {
        case "free": return "ChatGPT Free Subscription"
        case "go": return "ChatGPT Go Subscription"
        case "plus": return "ChatGPT Plus Subscription"
        case "pro": return "ChatGPT Pro 200 Subscription"
        case "prolite": return "ChatGPT Pro 100 Subscription"
        case "promax": return "ChatGPT Pro 500 Subscription"
        case "self_serve_business_prolite": return "ChatGPT Business Premium Subscription"
        case "team", "self_serve_business_usage_based", "business": return "ChatGPT Business Subscription"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise":
            return "ChatGPT Enterprise Subscription"
        case "edu", "edu_plus", "edu_pro": return "ChatGPT Edu Subscription"
        case "unknown": return "ChatGPT Subscription"
        default: return nil
        }
    }

    /// The limits answer asks the backend, the account's word comes from the cached login, so the
    /// first wins — unless all it says is "unknown", which only counts when nothing better exists.
    static func codexLabel(limitsPlan: String?, accountPlan: String?) -> String? {
        (limitsPlan == "unknown" ? nil : codexLabel(limitsPlan)) ?? codexLabel(accountPlan)
            ?? codexLabel(limitsPlan)
    }
}

// MARK: - Maths

enum UsageLimitMath {
    /// The panel's clock, asked about a window that is only a reset time and a length here. The
    /// line on the panel's bars and the tick on the Usage window's are the same two functions of
    /// NamedWindow, so the two cannot put one moment in different places.
    private static func clock(resetsAt: Double?, windowMinutes: Int?) -> NamedWindow {
        NamedWindow(key: "", title: "", badge: nil, minutes: windowMinutes,
                    window: LimitWindow(used: 0, resets: resetsAt))
    }

    /// How much of the window's time has passed, 0...1; nil when the window has no clock. The
    /// window is taken to have started one length before its reset.
    static func elapsedShare(resetsAt: Double?, windowMinutes: Int?, now: Double) -> Double? {
        clock(resetsAt: resetsAt, windowMinutes: windowMinutes).elapsedShare(at: now)
    }

    /// The share of the window's TIME still ahead, which is what an even spender would have left.
    /// The Usage window's bars show what is left, so this is also where the pace tick sits on
    /// them. nil is "no tick".
    static func evenPacePercent(resetsAt: Double?, windowMinutes: Int?, now: Double) -> Int? {
        clock(resetsAt: resetsAt, windowMinutes: windowMinutes).timeLeftPercent(at: now)
    }

    /// ahead | on | under. Both edges are strict: a gap of exactly five points is still on pace.
    /// The panel's NamedWindow.pace(at:) is this rule for the whole percents its files carry;
    /// the sidecar's rows come with fractions, which that one cannot take.
    static func paceClass(usedPercent: Double, elapsed: Double) -> String {
        let gap = usedPercent - elapsed * 100
        if gap > 5 { return "ahead" }
        if gap < -5 { return "under" }
        return "on"
    }

    static func remainingPercent(usedPercent: Double) -> Int {
        usageRound(100 - usageClampPercent(usedPercent))
    }

    /// Where the pace tick's centre goes on a bar `width` points wide. It keeps 3pt from either
    /// end so the 6pt slot cut around it stays inside the bar, and a bar too narrow for that slot
    /// draws no tick at all.
    static func tickX(percent: Int?, width: Double) -> Double? {
        guard let percent, width >= 6 else { return nil }
        return min(max(width * Double(percent) / 100, 3), width - 3)
    }

    /// Codex's `primary` and `secondary` are positions, not meanings: a Business plan reports its
    /// week first. The length is what says which window this is.
    static func codexKind(minutes: Int) -> String {
        if minutes >= 43200 { return "monthly" }
        if minutes >= 10080 { return "weekly" }
        return "session"
    }

    /// The length to assume for a slot that came without one: paid plans pair 5 hours with a week,
    /// Free and Go have a month in the first slot.
    static func codexFallbackMinutes(slot: String, plan: String?) -> Int {
        if slot == "secondary" { return 10080 }
        return plan == "free" || plan == "go" ? 43200 : 300
    }
}

// MARK: - Rows

/// One window card of the Limits tab, with everything its bar and its popover show.
struct UsageLimitRow: Equatable {
    /// The key the panel knows the window by ("five_hour", "primary", "reserve:primary"), or the
    /// sidecar's id.
    let id: String
    /// session | weekly | monthly | other
    let kind: String
    let label: String
    /// 100 for a session blocked by a spent week, whatever the session itself had used.
    let usedPercent: Int
    /// What the bar's fill is drawn from. Rounded on its own, as T3 does, so with a half percent
    /// on disk the two can add up to 101.
    let remainingPercent: Int
    /// When the quota comes back. For a blocked session that is when it becomes usable again,
    /// which can be the weekly reset.
    let resetsAt: Double?
    /// ahead | on | under, or nil when the window has no clock to judge against.
    let pace: String?
    /// Where the pace tick sits, in the same percent-left space as the fill; nil is no tick.
    let evenPacePercent: Int?
    /// What the reset gives back, in this window's own percent.
    let refillPercent: Double
    /// `refillPercent` as the popover prints it; nil without a reset time.
    let restoresPercent: Int?
    /// Width of the hatched "comes back at the reset" part at the right end, in percent; 0 is none.
    let hatchPercent: Double
}

struct UsageDetailRow: Equatable {
    let label: String
    let value: String
}

/// One provider's section of the Limits tab.
struct UsageProviderLimits: Equatable {
    let provider: String
    let title: String
    let plan: String?
    let email: String?
    let rows: [UsageLimitRow]
    let credits: UsageResetCredits?

    /// The number beside the ticket; zero means no ticket is drawn.
    var ticketCount: Int { credits?.availableCount ?? 0 }

    /// The popover's account block.
    var accountRows: [UsageDetailRow] {
        plan.map { [UsageDetailRow(label: "Plan", value: $0)] } ?? []
    }

    /// The popover's reset block. Empty without a banked credit: "none banked" is not worth a block.
    func resetChoices(now: Double) -> [UsageResetChoice] {
        guard let credits, credits.availableCount > 0 else { return [] }
        return UsageResetCredit.choices(credits, provider: provider, now: now)
    }
}

/// A window on its way to becoming a row.
private struct UsageWindowFacts {
    let id: String
    let kind: String
    let label: String
    var used: Double
    var resetsAt: Double?
    var minutes: Int?
    /// When the figure was measured.
    let ts: Double
    let reserve: Bool
    /// The panel's own figure for a window it draws, not held to 0...100: the panel's pace verdict
    /// reads it that way, so the row's does too. Nil for the sidecar's rows.
    var paceUsed: Double? = nil
}

extension UsageProviderLimits {
    /// `set` is the provider's limits as read from its file; the rows are built from the same
    /// `drawable(at:)` the panel uses, so a window whose reset has passed is empty in both.
    init(provider: String, set: LimitsSet?, account: UsageAccount?, now: Double) {
        self.provider = provider
        self.title = Provider.named(provider).title
        self.email = account?.email
        self.credits = account?.resetCredits
        self.plan = provider == "codex"
            ? UsagePlan.codexLabel(limitsPlan: set?.plan, accountPlan: account?.planType)
            : UsagePlan.claudeLabel(account?.subscriptionType)

        var windows = (set?.drawable(at: now) ?? []).compactMap {
            UsageWindowFacts($0, provider: provider, plan: set?.plan ?? account?.planType, recordTs: set?.ts ?? 0)
        }
        // The panel's files win: a row the sidecar repeats would otherwise be drawn twice, with
        // two figures for one window.
        for extra in account?.extraWindows ?? [] where !windows.contains(where: { $0.id == extra.id }) {
            windows.append(UsageWindowFacts(extra: extra, provider: provider, ts: account?.ts ?? 0, now: now))
        }
        if let spend = account?.spend, spend.enabled, let used = spend.usedPercent {
            windows.append(UsageWindowFacts(id: "monthly_spend", kind: "monthly", label: "Monthly spend",
                                            used: used, resetsAt: nil, minutes: nil,
                                            ts: account?.ts ?? 0, reserve: false))
        }

        let rank = ["session": 0, "weekly": 1, "monthly": 2]
        let ordinary = windows.filter { !$0.reserve }
            .sorted { a, b in
                let (ra, rb) = (rank[a.kind] ?? 3, rank[b.kind] ?? 3)
                return ra != rb ? ra < rb : a.id < b.id
            }
        // The Reserve pool is not part of the ordinary allowance: it neither blocks the ordinary
        // session nor is blocked by the ordinary week, and it is listed after them.
        self.rows = ordinary.map { UsageLimitRow($0.blocked(among: ordinary, provider: provider, now: now), now: now) }
            + windows.filter(\.reserve).map { UsageLimitRow(($0, $0.used), now: now) }
    }
}

extension LimitsSet {
    /// `drawn` as the account can use them, which is how the panel and the icon show them: a session
    /// window the spent week blocks has nothing left, no pace to judge and the week's reset,
    /// whatever it used itself. Built by the Usage window's own rule (`UsageWindowFacts.blocked`),
    /// with the plan it reads, so the two never show one window two ways. The name stays the
    /// session's own. `account` is the provider's account.json, nil when it has not been read.
    func usable(_ drawn: [NamedWindow], account: UsageAccount?, now: Double) -> [NamedWindow] {
        let ordinary = drawn.compactMap {
            UsageWindowFacts($0, provider: provider, plan: plan ?? account?.planType, recordTs: ts)
        }.filter { !$0.reserve }
        return drawn.map { window in
            guard let facts = ordinary.first(where: { $0.id == window.key }),
                  facts.spentWeek(among: ordinary, provider: provider) != nil else { return window }
            let shown = facts.blocked(among: ordinary, provider: provider, now: now).window
            // Without a length there is no clock, so no line and no pace, as on the Usage row.
            return NamedWindow(key: window.key, title: window.title, badge: window.badge, minutes: nil,
                               ts: window.ts, window: LimitWindow(used: 100, resets: shown.resetsAt))
        }
    }
}

extension UsageWindowFacts {
    /// One of the panel's windows; nil for a Claude window the tab does not list.
    init?(_ window: NamedWindow, provider: String, plan: String?, recordTs: Double) {
        if provider == "codex" {
            self.init(codex: window, plan: plan, recordTs: recordTs)
        } else {
            self.init(claude: window, recordTs: recordTs)
        }
    }

    /// Claude's rows come from a fixed list. limits.json also carries per-model and codename
    /// windows that T3 does not show, and a row made from "every key in the file" would.
    init?(claude window: NamedWindow, recordTs: Double) {
        let known = ["five_hour": ("session", "Session"), "seven_day": ("weekly", "Weekly"),
                     "seven_day_fable": ("weekly", "Weekly · Fable")]
        guard let (kind, label) = known[window.key] else { return nil }
        self.init(id: window.key, kind: kind, label: label, used: usageClampPercent(Double(window.window.used)),
                  resetsAt: window.window.resets, minutes: window.minutes, ts: recordTs, reserve: false,
                  paceUsed: Double(window.window.used))
    }

    init(codex window: NamedWindow, plan: String?, recordTs: Double) {
        let reserve = window.key.hasPrefix("reserve:")
        // No guessed length for the Reserve pool: the slot fallbacks describe the ordinary pair.
        // A guessed length only names the row. The clock keeps the real one, so a window of unknown
        // length has no pace tick here, as it has no line on the panel.
        let assumed = window.minutes
            ?? (reserve ? nil : UsageLimitMath.codexFallbackMinutes(slot: window.key, plan: plan))
        let kind = assumed.map(UsageLimitMath.codexKind) ?? "other"
        self.init(id: window.key, kind: kind, label: reserve ? "Reserve" : UsageWindowFacts.label(kind: kind),
                  used: usageClampPercent(Double(window.window.used)), resetsAt: window.window.resets,
                  minutes: window.minutes, ts: window.ts ?? recordTs, reserve: reserve,
                  paceUsed: Double(window.window.used))
    }

    init(extra: UsageExtraWindow, provider: String, ts: Double, now: Double) {
        // The panel's rule for its own windows, applied to the sidecar's: a figure measured in a
        // window that has since rolled over is about nothing that still exists.
        let passed = extra.resetsAt.map { $0 <= now } ?? false
        let label = provider == "claude" && extra.kind == "weekly" && !extra.name.isEmpty
            ? "Weekly · " + extra.name
            : (extra.name.isEmpty ? UsageWindowFacts.label(kind: extra.kind) : extra.name)
        self.init(id: extra.id, kind: extra.kind, label: label, used: passed ? 0 : extra.usedPercent,
                  resetsAt: passed ? nil : extra.resetsAt, minutes: extra.windowMinutes, ts: ts, reserve: false)
    }

    static func label(kind: String) -> String {
        switch kind {
        case "session": return "Session"
        case "weekly": return "Weekly"
        case "monthly": return "Monthly"
        default: return "Other"
        }
    }

    /// The window as its row shows it, and what its reset gives back.
    ///
    /// A session window is worth nothing while the account's week is spent, however little of the
    /// session itself was used — so it is shown empty, and its reset becomes the moment it is
    /// usable again. Claude's week is the window named `seven_day` (a model's own week blocks only
    /// that model); for Codex it is whichever ordinary window is a week long.
    func blocked(among ordinary: [UsageWindowFacts], provider: String, now: Double)
        -> (window: UsageWindowFacts, refill: Double) {
        guard let weekly = spentWeek(among: ordinary, provider: provider) else { return (self, used) }
        var shown = self
        shown.used = 100
        shown.resetsAt = nil
        // Being blocked is not session spending, so there is no session pace to judge.
        shown.minutes = nil
        var refill = 0.0
        // A reset at or before the moment the figures were read cannot say when the quota returns.
        let cutoff = max(now, ts, weekly.ts)
        if let weeklyReset = weekly.resetsAt, let sessionReset = resetsAt,
           weeklyReset > cutoff, sessionReset > cutoff {
            if sessionReset <= weeklyReset {
                // By the weekly reset the session has rolled over too: a whole session comes back.
                (shown.resetsAt, refill) = (weeklyReset, 100)
            } else if used >= 100 {
                // The week unblocks first, but the session is spent until its own reset.
                (shown.resetsAt, refill) = (sessionReset, 100)
            } else {
                // The session is still running when the week unblocks: its unspent part returns.
                (shown.resetsAt, refill) = (weeklyReset, 100 - used)
            }
        }
        return (shown, refill)
    }

    /// The spent week that blocks this window, or nil when this is not a session or the week has
    /// room. The panel asks the same question through `LimitsSet.usable(_:account:now:)`.
    func spentWeek(among ordinary: [UsageWindowFacts], provider: String) -> UsageWindowFacts? {
        guard kind == "session" else { return nil }
        return ordinary.first {
            $0.used >= 100 && (provider == "claude" ? $0.id == "seven_day" : $0.kind == "weekly")
        }
    }
}

extension UsageLimitRow {
    fileprivate init(_ entry: (window: UsageWindowFacts, refill: Double), now: Double) {
        let window = entry.window
        let elapsed = UsageLimitMath.elapsedShare(resetsAt: window.resetsAt, windowMinutes: window.minutes, now: now)
        let remaining = UsageLimitMath.remainingPercent(usedPercent: window.used)
        self.id = window.id
        self.kind = window.kind
        self.label = window.label
        self.usedPercent = usageRound(window.used)
        self.remainingPercent = remaining
        self.resetsAt = window.resetsAt
        self.pace = elapsed.map { UsageLimitMath.paceClass(usedPercent: window.paceUsed ?? window.used, elapsed: $0) }
        self.evenPacePercent = UsageLimitMath.evenPacePercent(resetsAt: window.resetsAt,
                                                              windowMinutes: window.minutes, now: now)
        self.refillPercent = entry.refill
        self.restoresPercent = window.resetsAt == nil ? nil : usageRound(entry.refill)
        // Normally the hatch is the whole empty part. For a blocked session that gets back only
        // its unspent share, it is that share at the right end and the rest stays bare.
        self.hatchPercent = remaining < 100 && window.resetsAt != nil && entry.refill > 0
            ? min(Double(100 - remaining), entry.refill) : 0
    }

    /// The popover's rows about this window. `now` is the moment the rows were built for.
    func details(now: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> [UsageDetailRow] {
        var rows = [UsageDetailRow(label: "Left", value: "\(remainingPercent)%")]
        if let resetsAt {
            let countdown = UsageLimitText.resetsIn(resetsAt, now: now, style: .short).map { " · " + $0 } ?? ""
            rows.append(UsageDetailRow(
                label: "Resets",
                value: UsageLimitText.resetTime(resetsAt, now: now, locale: locale, timeZone: timeZone) + countdown))
        }
        if let evenPacePercent {
            rows.append(UsageDetailRow(label: "Even pace", value: "\(evenPacePercent)% left by now"))
        }
        if let restoresPercent, restoresPercent > 0 {
            rows.append(UsageDetailRow(label: "Restores", value: "+\(restoresPercent)% of pool"))
        }
        return rows
    }

    /// What VoiceOver says for the bar: every part that exists, comma-joined.
    func accessibilityLabel(name: String, credits: Int, now: Double) -> String {
        var parts = ["\(name): \(remainingPercent)% left"]
        if let countdown = UsageLimitText.resetsIn(resetsAt, now: now, style: .full) { parts.append(countdown) }
        if let evenPacePercent { parts.append("\(evenPacePercent)% of the window left") }
        if credits > 0 { parts.append(UsageLimitText.creditsBanked(credits)) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Words

/// T3's three ways to say a countdown: "resets in 2h 5m", "in 2h 5m", "↻ 2h 5m".
enum UsageResetStyle {
    case full, short, refill
}

enum UsageLimitText {
    /// Two units at most, always rounded down, the smaller one printed even when zero ("1d 0h"):
    /// a countdown that rounds up promises quota a minute before it exists.
    static func duration(_ seconds: Double) -> String {
        let total = max(0, seconds.clampedInt)
        let (days, hours, minutes) = (total / 86400, total % 86400 / 3600, total % 3600 / 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// nil without a reset time. The two closest states read the same in every style, with T3's
    /// own uneven capitals.
    static func resetsIn(_ resetsAt: Double?, now: Double, style: UsageResetStyle) -> String? {
        guard let resetsAt else { return nil }
        let left = resetsAt - now
        if left <= 0 { return "resets now" }
        if left < 60 { return "Resets momentarily" }
        switch style {
        case .full: return "resets in " + duration(left)
        case .short: return "in " + duration(left)
        case .refill: return "↻ " + duration(left)
        }
    }

    /// When the window resets, as a clock time a person plans by: the time alone today, "tomorrow
    /// at …" the next calendar day, otherwise month/day (with the year when it differs) and time.
    /// The words are English; the shape of the date and the 12/24-hour clock follow the region,
    /// which is why a Russian region reads "23.11 14:40".
    static func resetTime(_ resetsAt: Double, now: Double, locale: Locale = .current,
                          timeZone: TimeZone = .current) -> String {
        guard resetsAt.isFinite, now.isFinite else { return "" }
        let date = Date(timeIntervalSince1970: resetsAt), today = Date(timeIntervalSince1970: now)
        let formatted = { (template: String) -> String in
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Calendar days, not multiples of 24 hours: half past midnight is "tomorrow" at 23:30.
        // Counted from noon to noon rather than between two midnights: where the clocks jump at
        // midnight (Cairo, Santiago, Havana) that day starts at 01:00 and is 23 hours long, and
        // 23 hours from one start of day to the next count as zero days.
        let noon = { (moment: Date) -> Date in
            var parts = calendar.dateComponents([.year, .month, .day], from: moment)
            parts.hour = 12
            return calendar.date(from: parts) ?? moment
        }
        let days = calendar.dateComponents([.day], from: noon(today), to: noon(date)).day ?? 0
        let time = formatted("jmm")
        switch days {
        case 0: return time
        case 1: return "tomorrow at " + time
        case -1: return "yesterday at " + time
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: today)
            return formatted(sameYear ? "Md" : "yMd") + " " + time
        }
    }

    /// The trend icon's tooltip.
    static func paceLabel(_ pace: String) -> String {
        switch pace {
        case "ahead": return "Ahead of pace: spending faster than the window elapses"
        case "on": return "On pace with the window"
        case "under": return "Under pace: headroom left for the rest of the window"
        default: return ""
        }
    }

    static func creditsBanked(_ count: Int) -> String {
        count == 1 ? "1 reset credit banked" : "\(count) reset credits banked"
    }
}

// MARK: - Reset credits

/// One line of the popover's reset block: what is banked, and the button that spends it.
struct UsageResetChoice: Equatable {
    /// The credit id, or "next" for the single counter.
    let key: String
    /// What the redeem command is given. nil is Codex: its backend picks the next credit itself.
    let creditId: String?
    let summary: String
    let actionLabel: String
    /// The body of the confirmation. Redeeming spends a credit and cannot be taken back.
    let confirmDescription: String
    let availableCount: Int
    /// Whether the button is offered at all.
    let redeemable: Bool
}

enum UsageResetCredit {
    static let confirmTitle = "Use a reset credit?"
    static let confirmButton = "Use credit"
    static let cancelButton = "Cancel"
    /// The button's label while a redemption runs.
    static let busyButton = "Using…"
    /// The line under the bar while a redemption runs.
    static let busyStatus = "Using reset credit…"

    private static let kinds: [String: (label: String, description: String)] = [
        "session": ("5-hour reset", "Refills your 5-hour limit."),
        "weekly": ("Weekly reset", "Refills your weekly limit."),
        "fable": ("Fable reset", "Refills your Fable allowance and gives back what Fable used on your weekly limit."
            + " It doesn't reset your whole week."),
        "full": ("Full reset", "Refills your 5-hour and weekly limits."),
    ]

    /// One choice per kind of reset when the provider tells them apart (Claude), otherwise the one
    /// counter (Codex). `compact` is the popover's short wording.
    static func choices(_ credits: UsageResetCredits, provider: String, now: Double,
                        compact: Bool = true) -> [UsageResetChoice] {
        let expiresIn = { (at: Double?) in at.map { UsageLimitText.duration($0 - now) } }
        if let options = credits.options {
            // A kind without a description is left out: a button that spends a credit has to be
            // able to say on what.
            return options.compactMap { option in
                guard let (label, description) = kinds[option.kind] else { return nil }
                let left = "\(label) · \(option.availableCount) left"
                return UsageResetChoice(
                    key: option.creditId, creditId: option.creditId,
                    summary: left + (expiresIn(option.expiresAt).map { " · expires in " + $0 } ?? ""),
                    actionLabel: "Use",
                    confirmDescription: "\(label): \(description) This cannot be undone.",
                    availableCount: option.availableCount, redeemable: option.availableCount > 0)
            }
        }
        let count = credits.availableCount, expires = expiresIn(credits.nextExpiresAt)
        let summary: String
        if count == 0 {
            summary = "No reset credits banked"
        } else if compact {
            summary = "\(count) banked" + (expires.map { " · expires in " + $0 } ?? "")
        } else {
            summary = UsageLimitText.creditsBanked(count) + (expires.map { " · next expires in " + $0 } ?? "")
        }
        return [UsageResetChoice(
            key: "next", creditId: nil, summary: summary, actionLabel: "Use reset",
            confirmDescription: "This redeems one credit on your account and clears the current rate-limit windows."
                + " It cannot be undone.",
            availableCount: count,
            // Claude's command redeems a named grant and refuses anything else, so a bare Claude
            // counter has nothing to press.
            redeemable: count > 0 && provider == "codex")]
    }
}

/// How the last redemption ended, as the redeem command wrote it to reset-credit-result.json. The
/// file holds fixed words only; the sentences are here.
struct UsageResetResult: Equatable {
    let provider: String
    let ts: Double
    let creditId: String?
    /// reset | nothingToReset | noCredit | alreadyRedeemed, or nil when the call brought no answer.
    let outcome: String?
    /// The failure's category, or nil.
    let error: String?
    /// Whether a fresh limits reading arrived after the redemption.
    let confirmed: Bool
}

extension UsageResetResult {
    init(json: [String: Any], provider: String) {
        self.provider = provider
        self.ts = usageNumber(json["ts"]) ?? 0
        self.creditId = usageText(json["creditId"])
        self.outcome = usageText(json["outcome"])
        self.error = usageText(json["error"])
        self.confirmed = json["confirmed"] as? Bool ?? false
    }

    /// The line shown under the bar once the redemption is over.
    var message: String {
        let name = Provider.named(provider).title
        switch outcome {
        case "reset":
            // The credit is spent either way; without a fresh reading the bars on screen are the
            // old ones, and saying "cleared" over them would be a lie.
            return confirmed ? "Reset applied. Your windows have cleared."
                : "The reset was applied, but \(name) could not confirm the new limits. Refresh to check."
        case "nothingToReset": return "Nothing to reset right now."
        case "noCredit": return "No reset credit left."
        case "alreadyRedeemed": return "That credit was already redeemed."
        default: break
        }
        switch (provider, error) {
        case (_, nil): return "Could not use the reset credit."
        // Not a T3 sentence: T3 queues a second click in one process, here it is a second process
        // that found the lock held.
        case (_, "busy"?): return "A reset is already in progress. Try again in a moment."
        // Codex's failures all leave the attempt open for a retry with the same key; T3 tells
        // them apart no further.
        case ("codex", _): return "Codex could not redeem the reset credit."
        case (_, "malformedCredit"?): return "Claude returned a malformed reset credit."
        case (_, "loginUnreadable"?): return "Claude could not read its login."
        case (_, "accountUnreadable"?): return "Claude could not read its account."
        case (_, "signedOut"?): return "Sign in to Claude again to redeem resets."
        case (_, "rateLimited"?): return "Claude is rate limiting resets. Try again soon."
        case (_, "coolingDown"?): return "Claude resets are cooling down. Try again later."
        case (_, "unconfirmed"?):
            return "Claude could not confirm the reset. If you are still limited in a moment, try again."
        default: return "Claude could not redeem the reset."
        }
    }
}
