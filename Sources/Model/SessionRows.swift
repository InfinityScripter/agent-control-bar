/// Which sessions the panel lists, and the two notices that depend on that answer.
///
/// These rules were in the menu builder and then in the controller's panel code, and every one of
/// them is the fix for a reported bug. They are here so the model check can hold them: the
/// controller hands over what it knows and turns the keys that come back into rows.
enum SessionRows {
    /// The keys of the sessions a user should see, in the order they should see them.
    /// Each session carries its effective state in `eff` already.
    static func visible(_ sessions: [Session], now: Double, agents: AgentDisplay,
                        hiding hiddenServices: Set<ModelService>, stalePruneAge: Double) -> [String] {
        // Gate ONLY the desktop app: opening a conversation there seeds an idle session without
        // real activity, so a desktop session stays out until a prompt or tool fires. CLI, terminal
        // and editor sessions are launched deliberately and surface the moment they start.
        // An agent the setting leaves out is not listed at all — not even as the one row kept below
        // so the panel never goes empty: that row would be exactly the session asked not to show.
        let ordered = sessions.sorted {
            $0.ts == $1.ts ? $0.key < $1.key : $0.ts > $1.ts
        }.filter { s in
            guard agents.inPanel(s.provider), !hiddenServices.contains(s.modelService) else { return false }
            let gated = s.entrypoint == "claude-desktop"
            return !gated || s.started || isActiveState(s.eff)
        }
        // Hiding is render-only — the file, and thus liveness, is untouched. The most recent
        // session is always kept, so the panel never goes empty while one is alive.
        var visible = ordered.filter { s in
            let resting = SessionActivityGroup(state: s.eff, asyncQuestion: s.asyncQuestion) == .idle
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }
        return visible.map(\.key)
    }

    /// "Open Claude" stands in for an empty list, and only where it can lead somewhere: the
    /// desktop app is running and the panel is one that shows Claude at all.
    static func offersOpenClaude(rows: Int, desktopRunning: Bool, agents: AgentDisplay) -> Bool {
        rows == 0 && desktopRunning && agents.inPanel(Provider.claude.id)
    }

    /// Whether to say that Codex's sessions are missing because its hooks are not approved.
    ///
    /// Asked of every session this app knows about, not of the rows above: a Codex session that
    /// has simply been resting longer than the hide-idle age is missing from the list too, and
    /// saying "hidden — approve its hooks" about THAT one names the wrong cause entirely. Once
    /// Codex writes down a session at all, its hooks are running, whatever else is unapproved.
    static func codexHooksBlocked(untrusted: Int, agents: AgentDisplay, sessions: [Session]) -> Bool {
        untrusted > 0 && agents.inPanel(Provider.codex.id)
            && !sessions.contains { $0.provider == Provider.codex.id }
    }
}
