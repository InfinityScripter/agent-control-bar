import Foundation

/// When the app may quit on its own: it stays while the Claude desktop app is open, a session is
/// active or someone is looking at its windows, and otherwise quits after a short debounced grace
/// (warmup-session churn must not kill it).
///
/// Only the debounce lives here. The two probes that get the last word — the process table and a
/// live LaunchServices query — are slow, so the caller runs them only once this says the grace
/// has run out, and resets the debounce if either finds something.
struct IdleQuit {
    /// Settle time after launch before the app may quit at all.
    static let launchGrace: TimeInterval = 5
    /// "Not needed" must persist this long before quitting.
    static let delay: TimeInterval = 3

    enum Verdict: Equatable {
        /// Needed, still settling, or not idle for long enough yet.
        case stay
        /// Idle past the delay: ask the slow probes, and quit if they find nothing.
        case confirm
    }

    let launchedAt: Date
    private(set) var notNeededSince: Date?

    init(launchedAt: Date) { self.launchedAt = launchedAt }

    /// One look. `inUse` is an open Settings window or panel; `needed` is a session file on disk
    /// or the desktop app running.
    mutating func step(now: Date, inUse: Bool, needed: Bool) -> Verdict {
        if now.timeIntervalSince(launchedAt) < Self.launchGrace { return .stay }
        // An open Settings window or panel is someone using the app right now. Without this the
        // idle quit fires three seconds after the last session ends and closes what they are
        // looking at under their hands — which the panel made reachable in a way the menu did not:
        // a menu ran a modal tracking loop that the timer could not interrupt, a window does not.
        if inUse || needed {
            notNeededSince = nil
            return .stay
        }
        guard let since = notNeededSince else {
            notNeededSince = now
            return .stay
        }
        return now.timeIntervalSince(since) >= Self.delay ? .confirm : .stay
    }

    /// A probe found the app needed after all.
    mutating func reset() { notNeededSince = nil }
}
