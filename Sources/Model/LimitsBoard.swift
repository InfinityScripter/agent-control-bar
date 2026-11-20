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
    ///
    /// The windows are the panel's `usable(_:account:now:)` ones, so a session the spent week blocks
    /// is a full bar without a line here too. No account: the plan only names a Codex window
    /// without a length, and the icon draws none of those.
    func gauge(at now: Double) -> Gauge {
        let drawn = claude.map { $0.usable($0.drawable(at: now), account: nil, now: now) } ?? []
        let (five, seven) = (drawn.first { $0.key == "five_hour" }, drawn.first { $0.key == "seven_day" })
        let pair = Gauge(fiveHour: five?.window.fraction, sevenDay: seven?.window.fraction,
                         timeLeft: (Self.timeLeft(five, at: now), Self.timeLeft(seven, at: now)))
        if !pair.isEmpty { return pair }
        // A window whose length Codex never reported has no honest two-character label, so it
        // gets no bar rather than a guessed one.
        let live = codexBarWindows(at: now)
        guard let first = live.first else { return Gauge() }
        let second = live.count > 1 ? live.last : nil
        return Gauge(fiveHour: first.window.window.fraction, sevenDay: second?.window.window.fraction,
                     labels: (first.label, second?.label ?? ""),
                     timeLeft: (Self.timeLeft(first.window, at: now), Self.timeLeft(second?.window, at: now)))
    }

    /// Where the bar's line goes. From the whole percent, like the panel's line, so the icon is
    /// redrawn when the line has moved by a visible amount and not on every tick.
    private static func timeLeft(_ window: NamedWindow?, at now: Double) -> Double? {
        window?.timeLeftPercent(at: now).map { Double($0) / 100 }
    }

    /// Reserve is a separate pool, not a second ordinary window. Never mix it into a pair. Each
    /// window comes as the account can use it, with the label of the length its writer reported:
    /// a session the spent week blocks loses its clock in `usable`, not its name.
    func codexBarWindows(at now: Double) -> [(window: NamedWindow, label: String)] {
        guard let codex else { return [] }
        let drawn = codex.drawable(at: now)
        let labelled = zip(codex.usable(drawn, account: nil, now: now), drawn).compactMap { usable, window in
            window.shortTitle.map { (window: usable, label: $0) }
        }
        let ordinary = labelled.filter { !$0.window.key.hasPrefix("reserve:") }
        return Array((ordinary.isEmpty ? labelled : ordinary).prefix(2))
    }

    /// Which provider the switcher shows. A remembered pick that has no figures right now falls
    /// back to the first one rather than to an empty strip — a provider can go quiet for a week
    /// and come back, and the pick is worth keeping across that.
    static func showing(_ pick: String, among providers: [String]) -> String? {
        providers.contains(pick) ? pick : providers.first
    }
}
