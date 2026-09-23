/// Both agents' limit figures, and every rule about which of them the menu bar icon and the panel's
/// strip show. The icon, the strip and the height reserved for the strip used to decide this each
/// on their own, outside the model check, and they disagreed: the strip counted Claude as present
/// when it had any window and Codex only when it had one worth drawing.
struct LimitsBoard {
    let claude: LimitsSet?
    let codex: LimitsSet?

    /// Every provider with something to draw at `now`, Claude first, with its windows as drawn —
    /// a window whose reset has passed since it was measured reads as empty, see
    /// `LimitsSet.drawable(at:)`.
    func shown(at now: Double) -> [(set: LimitsSet, windows: [NamedWindow])] {
        [claude, codex].compactMap { set in
            guard let set else { return nil }
            let windows = set.drawable(at: now)
            return windows.isEmpty ? nil : (set, windows)
        }
    }

    /// What the menu bar icon draws. Claude's 5-hour and weekly pair when it has either; Codex's
    /// first two labelled windows only when Claude has no figures at all. The icon has room for two
    /// labelled bars, and a pair mixed from two accounts would need a provider mark beside each one
    /// to mean anything — so whoever has numbers gets the bars.
    ///
    /// Built first and tested for emptiness, rather than asking whether Claude has limits at all:
    /// a plan that reports only its Fable window has limits and still draws no bars here, and that
    /// used to leave the icon blank while Codex figures sat unused below.
    func gauge(at now: Double) -> Gauge {
        let drawn = claude?.drawable(at: now) ?? []
        let pair = Gauge(fiveHour: drawn.first { $0.key == "five_hour" }?.window.fraction,
                         sevenDay: drawn.first { $0.key == "seven_day" }?.window.fraction)
        if !pair.isEmpty { return pair }
        // A window whose length Codex never reported has no honest two-character label, so it
        // gets no bar rather than a guessed one.
        let live = (codex?.drawable(at: now) ?? []).filter { $0.shortTitle != nil }.prefix(2)
        guard let first = live.first else { return Gauge() }
        let second = live.count > 1 ? live.last : nil
        return Gauge(fiveHour: first.window.fraction, sevenDay: second?.window.fraction,
                     labels: (first.shortTitle ?? "", second?.shortTitle ?? ""))
    }

    /// Which provider the switcher shows. A remembered pick that has no figures right now falls
    /// back to the first one rather than to an empty strip — a provider can go quiet for a week
    /// and come back, and the pick is worth keeping across that.
    static func showing(_ pick: String, among providers: [String]) -> String? {
        providers.contains(pick) ? pick : providers.first
    }
}
