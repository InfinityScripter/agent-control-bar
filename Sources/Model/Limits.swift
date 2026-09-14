import Cocoa

/// One rate-limit window as limits.json carries it: a rounded percentage and, when the
/// writer knew it, the epoch second the window resets at.
struct LimitWindow: Equatable {
    let used: Int
    let resets: Double?

    init(used: Int, resets: Double?) {
        self.used = used
        self.resets = resets
    }

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
    /// snapshot undatable — see `ended(at:ts:)`.
    let minutes: Int?
    /// When THIS window was measured, when the writer said so per window rather than per record.
    /// Codex's file keeps the last figure for each pool, and once a session has moved onto the
    /// reserve those figures come from different moments — the ordinary pair from the last
    /// ordinary turn, the reserve one from just now. Nil means "whatever the record says".
    let ts: Double?
    let window: LimitWindow

    init(key: String, title: String, badge: String?, minutes: Int?, ts: Double? = nil,
         window: LimitWindow) {
        self.key = key
        self.title = title
        self.badge = badge
        self.minutes = minutes
        self.ts = ts
        self.window = window
    }

    /// The two characters the menu bar icon has room for beside a bar, or nil when the window's
    /// length is unknown. The icon labels every bar it draws, and there is no honest short label
    /// for a window whose duration the writer never reported — so that bar is not drawn at all.
    var shortTitle: String? { NamedWindow.short(minutes: minutes) }

    /// The same label as a free function, because a window whose title is the POOL's name — the
    /// reserve one — has to carry its length in the badge, and a badge is a stored property that
    /// cannot ask a computed one during init.
    static func short(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        // Not a whole number of hours, and the label is two characters wide: 90 minutes would
        // have to be drawn as "1h", which is a wrong label on a real bar rather than a rounded
        // one. No bar beats a mislabelled bar, and the panel still lists the window in full.
        guard minutes % 60 == 0 else { return nil }
        return "\(minutes / 60)h"
    }

    /// Whether the window this figure was measured in is over by `now` — nil when that cannot be
    /// answered at all.
    ///
    /// The question every drawn bar depends on. A percentage belongs to one window, and once that
    /// window has rolled over the figure is not stale so much as about something that no longer
    /// exists: 94% recorded a minute before the weekly reset is 0% a minute after it. The reset
    /// time answers it outright; without one, the window's own duration does, because a figure
    /// cannot outlive the window it measures. With neither, nothing here can date the figure.
    func ended(at now: Double, ts: Double) -> Bool? {
        if let resets = window.resets { return resets <= now }
        guard let minutes, minutes > 0 else { return nil }
        return now - (self.ts ?? ts) >= Double(minutes) * 60
    }

    /// The same window, known empty. What a reset means: the window rolled over, and nothing has
    /// been measured against the new one yet — which for a figure read out of a transcript is
    /// exact, because using the agent is what would have written a newer one.
    ///
    /// The reset time goes with the old figure. When the next window opens is not knowable: a
    /// five-hour window starts at the first request made in it, not on the hour.
    var emptied: NamedWindow {
        NamedWindow(key: key, title: title, badge: badge, minutes: minutes, ts: ts,
                    window: LimitWindow(used: 0, resets: nil))
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

    /// The windows as they should be drawn at `now`: measured figures for windows still running,
    /// empty bars for windows that have rolled over since they were measured.
    ///
    /// This is the one place that decides it, for both providers, because both used to get it
    /// wrong in their own way. A polled file is rewritten every few minutes, so Claude's bars
    /// showed the pre-reset figure for up to five minutes after every rollover — at its worst a
    /// near-full red bar where the truth was empty. A Codex snapshot only changes when its owner
    /// runs Codex, so its rolled-over windows used to vanish from the panel entirely and stay
    /// gone, taking with them the fact that the ordinary pool had become available again.
    func drawable(at now: Double) -> [NamedWindow] {
        windows.compactMap { window in
            switch window.ended(at: now, ts: ts) {
            case true?: return window.emptied
            case false?: return window
            // Neither a reset stamp nor a length: the figure cannot be dated. A poll rewrites its
            // own file every few minutes, so its figures are fresh by construction and are kept.
            // A snapshot out of a transcript can be a week old, and an undatable week-old figure
            // is the one thing here that cannot be shown honestly at all.
            case nil: return isSnapshot ? nil : window
            }
        }
    }

    /// The moment of the newest rollover these figures have already outlived, or nil when they
    /// are still about the windows they were measured in. `handled` is the last rollover that
    /// already prompted a fresh reading, so one rollover asks for one reading rather than one
    /// per tick.
    ///
    /// Only a reset later than the measurement counts. That is what makes the figures stale, and
    /// it is also what makes this fall quiet by itself: a fresh answer carries reset times in the
    /// future, so nothing here fires again until the next rollover.
    func rolledOver(since handled: Double, at now: Double) -> Double? {
        windows.compactMap { $0.window.resets }
            .filter { $0 <= now && $0 > ts && $0 > handled }
            .max()
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
    ///
    /// `pool` says which pool of the account the figure measures: the ordinary one, or the
    /// reserve Codex moves a session onto once the ordinary limit runs out. Naming a reserve
    /// window "7 days" like any other weekly window would be the strip's worst kind of lie — the
    /// figure is real, but it is about a pool the reader is not thinking about. So the pool takes
    /// the name and the length moves to the badge, exactly as Fable's weekly slice is drawn.
    ///
    /// It rides on the window rather than on the record because one record carries both: the
    /// writer keeps the last figure for each pool, and a reserve snapshot has nothing to say
    /// about the ordinary windows it did not measure.
    init?(codex object: [String: Any], legacyReserve: Bool) {
        guard let window = LimitWindow(json: object) else { return nil }
        let kind = object["kind"] as? String ?? ""
        // The record-wide flag is how the previous version marked it, and the file outlives the
        // update that replaces the app: read it when the window itself does not say.
        let reserve = (object["pool"] as? String ?? (legacyReserve ? "reserve" : "codex")) == "reserve"
        let minutes = (object["window_minutes"] as? NSNumber)?.intValue
        // Both pools report a window under kind "primary", so the kind alone is not a name. The
        // key has to stay unique within the provider: it is what a one-line summary names the row
        // it quotes by, and two rows answering to "primary" would make that pick ambiguous.
        self.key = (reserve ? "reserve:" : "") + (kind.isEmpty ? "window" : kind)
        self.minutes = minutes.flatMap { $0 > 0 ? $0 : nil }
        self.title = reserve ? "Reserve" : LimitsSet.title(minutes: self.minutes, kind: kind)
        self.badge = reserve ? NamedWindow.short(minutes: self.minutes) : nil
        self.ts = (object["ts"] as? NSNumber)?.doubleValue
        self.window = window
    }
}

extension LimitsSet {
    /// codex/limits.json. An array rather than named keys on purpose: which windows a Codex plan
    /// reports is not fixed, and a file of named keys would have had to invent a name for each.
    init?(codex root: [String: Any]) {
        guard let raw = root["windows"] as? [[String: Any]] else { return nil }
        let legacyReserve = root["reserve"] as? Bool ?? false
        let windows = raw.compactMap { NamedWindow(codex: $0, legacyReserve: legacyReserve) }
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
