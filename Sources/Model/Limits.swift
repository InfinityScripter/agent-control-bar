import Cocoa

/// One rate-limit window as limits.json carries it: a rounded percentage and, when the
/// writer knew it, the epoch second the window resets at.
struct LimitWindow: Equatable {
    let used: Int
    let resets: Double?

    init?(json: Any?) {
        // as? Int, deliberately: the statusLine payload reports fractional percentages and
        // hooks/statusline.py rounds them on the way in. If a writer ever forgets, the limits
        // vanish from the menu while limits.json still looks perfectly healthy — so the
        // rounding lives in one place and is covered by a test.
        guard let o = json as? [String: Any], let used = o["used_percentage"] as? Int else { return nil }
        self.used = used
        self.resets = o["resets_at"] as? Double
    }

    /// Fraction for the gauges; the percentage stays an Int on disk so the file is diffable.
    var fraction: Double { Double(used) / 100 }
}

/// The account's limits as read from limits.json. Two windows every subscriber has, plus the
/// weekly Fable window that only shows up for plans with that model — so it is optional
/// rather than defaulted, and the menu omits its row instead of drawing an empty bar.
struct Limits {
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
    let fable: LimitWindow?
    let source: String
    let ts: Double

    /// The usage endpoint carries the Fable window inside its `limits[]` array (a weekly_scoped
    /// entry for the model), and scripts/mcpbar.py lifts it out under `seven_day_fable`, the
    /// name the per-model windows follow (seven_day_opus, seven_day_sonnet). Any other key
    /// carrying the model's name is the fallback, so a renamed window keeps the row rather
    /// than silently dropping it. Nothing else qualifies: the endpoint also reports windows
    /// under codenames, and a row that guesses one of those is Fable would be a lie.
    static func fableKey(in keys: [String]) -> String? {
        if keys.contains("seven_day_fable") { return "seven_day_fable" }
        return keys.filter { $0 != "ts" && $0 != "source" && $0.lowercased().contains("fable") }
            .sorted().first
    }

    init?(json root: [String: Any]) {
        let five = LimitWindow(json: root["five_hour"])
        let seven = LimitWindow(json: root["seven_day"])
        let fable = Limits.fableKey(in: Array(root.keys)).flatMap { LimitWindow(json: root[$0]) }
        guard five != nil || seven != nil || fable != nil else { return nil }
        self.fiveHour = five
        self.sevenDay = seven
        self.fable = fable
        self.source = root["source"] as? String ?? ""
        self.ts = root["ts"] as? Double ?? 0
    }

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil && fable == nil }
}

/// One window with the words the panel puts above it. Claude's three are named here because the
/// account always has the same three; Codex's are named from the duration its own snapshot
/// reports, because which pair a plan carries is not fixed — a Free plan has no weekly window at
/// all, and other plans carry windows that are neither 5 hours nor a week.
struct NamedWindow: Equatable {
    /// The key the window arrived under, kept so the icon can ask for one by name rather than by
    /// position — a plan without a 5-hour window would otherwise put the weekly figure first.
    let key: String
    let title: String
    /// The short capsule after the name; only Claude's Fable window has one.
    let badge: String?
    /// How long the window is. Nil when the writer did not say, which is also what makes a
    /// snapshot undatable — see `live(at:ts:)`.
    let minutes: Int?
    let window: LimitWindow

    /// The two characters the menu bar icon has room for beside a bar, or nil when the window's
    /// length is unknown. The icon labels every bar it draws, and there is no honest short label
    /// for a window whose duration the writer never reported — so that bar is not drawn at all.
    var shortTitle: String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        // Not a whole number of hours, and the label is two characters wide: 90 minutes would
        // have to be drawn as "1h", which is a wrong label on a real bar rather than a rounded
        // one. No bar beats a mislabelled bar, and the panel still lists the window in full.
        guard minutes % 60 == 0 else { return nil }
        return "\(minutes / 60)h"
    }

    /// Whether the figure is still about the window it was measured in.
    ///
    /// A snapshot lifted out of a transcript can be a week old: the 12% it recorded belonged to a
    /// window that has since rolled over, and drawing it today would be a plain lie. The reset
    /// time answers it outright; without one, the window's own duration does, because a figure
    /// cannot outlive the window it measures.
    func live(at now: Double, ts: Double) -> Bool {
        if let resets = window.resets { return resets > now }
        guard let minutes, minutes > 0 else { return false }
        return now - ts < Double(minutes) * 60
    }
}

/// One provider's limits, whatever shape its plan gives them. Both files the app reads
/// (`limits.json`, `codex/limits.json`) land here, so the panel, the strip and the icon have one
/// type to draw and one place where "this window is stale" is decided.
struct LimitsSet: Equatable {
    /// "claude" or "codex" — a string rather than an enum for the same reason every other status
    /// in this app is one: the value comes out of a JSON file that a script writes.
    let provider: String
    let windows: [NamedWindow]
    let source: String
    let ts: Double
    /// The subscription the figures belong to, when the writer knew it. Shown in the tooltip, not
    /// on a bar: it explains the windows rather than measuring anything.
    let plan: String?

    var isEmpty: Bool { windows.isEmpty }

    /// A record lifted out of a transcript rather than asked for. Only these go stale on their
    /// own: a poll rewrites its file every few minutes, a rollout file is whatever the last
    /// session happened to leave behind.
    var isSnapshot: Bool { source == "rollout" }

    /// The windows still worth drawing. For a polled source that is all of them — a window whose
    /// reset has just passed is corrected by the next poll minutes later. For a snapshot it is
    /// only the windows that have not rolled over since it was written, which is what makes a
    /// provider disappear from the strip instead of showing last week's numbers.
    func live(at now: Double) -> [NamedWindow] {
        guard isSnapshot else { return windows }
        return windows.filter { $0.live(at: now, ts: ts) }
    }

    /// The window that will run out first — what a one-line summary of a provider should say.
    /// Ties go to the earlier reset, because at equal fullness that is the one that bites sooner.
    static func worst(_ windows: [NamedWindow]) -> NamedWindow? {
        windows.max { a, b in
            if a.window.used != b.window.used { return a.window.used < b.window.used }
            return (a.window.resets ?? .greatestFiniteMagnitude)
                > (b.window.resets ?? .greatestFiniteMagnitude)
        }
    }

    /// What the panel calls a window of this many minutes. The pair Codex reports is
    /// plan-dependent, so the duration it sends is the only honest source for the label.
    static func title(minutes: Int?, kind: String) -> String {
        guard let minutes, minutes > 0 else {
            // No duration in the snapshot. Codex's own words for the pair it always shows, so the
            // strip says something rather than "window" — and never guesses a number of hours.
            return kind == "secondary" ? "Weekly" : "Session"
        }
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return days == 1 ? "1 day" : "\(days) days"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

extension NamedWindow {
    /// One entry of the `windows` array in codex/limits.json, as scripts/mcpbar.py writes it from
    /// the rollout snapshot: a percentage, the window's length in minutes, and the reset stamp.
    init?(codex object: [String: Any]) {
        guard let window = LimitWindow(json: object) else { return nil }
        let kind = object["kind"] as? String ?? ""
        let minutes = (object["window_minutes"] as? NSNumber)?.intValue
        self.key = kind.isEmpty ? "window" : kind
        self.minutes = minutes.flatMap { $0 > 0 ? $0 : nil }
        self.title = LimitsSet.title(minutes: self.minutes, kind: kind)
        self.badge = nil
        self.window = window
    }
}

extension LimitsSet {
    /// codex/limits.json. An array rather than named keys on purpose: which windows a Codex plan
    /// reports is not fixed, and a file of named keys would have had to invent a name for each.
    init?(codex root: [String: Any]) {
        guard let raw = root["windows"] as? [[String: Any]] else { return nil }
        let windows = raw.compactMap { NamedWindow(codex: $0) }
        guard !windows.isEmpty else { return nil }
        self.provider = "codex"
        self.windows = windows
        self.source = root["source"] as? String ?? ""
        self.ts = root["ts"] as? Double ?? 0
        self.plan = (root["plan"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension Limits {
    /// The account's three Claude windows in the provider-independent shape. The titles live here
    /// rather than in the panel so that both providers are named in one place, and so the model
    /// check can cover them.
    var set: LimitsSet {
        let named: [NamedWindow?] = [
            fiveHour.map { NamedWindow(key: "five_hour", title: "5 hours", badge: nil,
                                       minutes: 300, window: $0) },
            sevenDay.map { NamedWindow(key: "seven_day", title: "7 days", badge: nil,
                                       minutes: 10080, window: $0) },
            // The badge is what says this is the model's slice of the week rather than the
            // account's own window, and it is what earns the row its own tint in the strip.
            fable.map { NamedWindow(key: "seven_day_fable", title: "Fable", badge: "7d",
                                    minutes: 10080, window: $0) },
        ]
        return LimitsSet(provider: "claude", windows: named.compactMap { $0 },
                         source: source, ts: ts, plan: nil)
    }
}
