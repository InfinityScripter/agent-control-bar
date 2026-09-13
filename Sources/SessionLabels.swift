import Cocoa

// How a session reads: its words, its truncation, and the per-session ranking the status item and
// the panel rows share. Only text and numbers live here — the drawing is SwiftUI's, in
// PanelTabs.swift, and the values it draws are assembled in PanelData.swift.
extension StatusController {
    /// evaluate() caches the effective state on the session once per tick; anything that runs
    /// before that tick (a menu opened on a freshly read file) computes it on the spot.
    func effState(_ s: Session, now: Double) -> String {
        s.eff.isEmpty ? engine.effectiveState(s, now: now) : s.eff
    }

    func sessionMenuLine(_ s: Session) -> String {
        let now = Date().timeIntervalSince1970
        let eff = effState(s, now: now)
        // The icon carries the state (spinner / amber dot / caret); the row text is just the project,
        // plus a live timer while working since the spinner can't convey elapsed. Same name length
        // as the drawn row (nameMax) so the accessible title and the pixels agree.
        var line = truncated(sessionName(s), max: 30, keep: 30)
        if !s.branch.isEmpty { line += " · " + truncated(s.branch, max: 22, keep: 20) }
        if isWorkingState(eff), s.startedAt > 0 {
            line += "  " + elapsed(max(0, (now - s.startedAt).clampedInt))
        }
        return line
    }

    // Live layout knobs from ~/.claude/control-bar/uiconfig.json, so a numeric tweak takes effect
    // on the next open with NO rebuild. Only `boxWidth` survives the panel: the row-geometry knobs
    // (nameMax, pillInset, timerGap, pillTextY) described an AppKit row that no longer exists —
    // SwiftUI truncates by pixel and lays the row out itself. Re-read only when the file's mtime
    // moves: this runs on every refresh while the panel is open.
    func uiConfig() -> [String: Double] {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/control-bar/uiconfig.json")
        let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        if let cached = uiConfigCache, cached.mtime == m { return cached.values }
        var values: [String: Double] = [:]
        if let d = FileManager.default.contents(atPath: p),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            values = j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
        uiConfigCache = (m, values)
        return values
    }

    var boxWidth: CGFloat { CGFloat(uiConfig()["boxWidth"] ?? 300) }


    // Only ever asked for an active state: a resting lead renders the bare icon, no text.
    func statusText(_ s: Session, eff: String) -> String {
        eff == "permission" ? "Needs you" : workingLabel(s)
    }

    // Just the repo/cwd (parent-qualified on a name collision); the surface (CLI/APP) renders as a
    // trailing badge instead of inline.
    func sessionName(_ s: Session) -> String {
        if !s.displayName.isEmpty { return s.displayName }
        return s.project.isEmpty ? "session" : s.project
    }

    // Moved to SessionFormat.surfaceTag: it is pure, it now has to answer for two agents, and
    // only the model half is covered by the model checks.




    // Keep the bar narrow: over `max` chars, show the first `keep` + an ellipsis (full text stays in the tooltip).
    // Clamped at zero: `keep` arrives from uiconfig.json (a hand-tuning file), and String.prefix
    // TRAPS on a negative length — "nameMax": -1 typed there crashed every menu open, straight
    // into the hooks' relaunch loop. The one file-fed number that reached a trapping stdlib call.
    func truncated(_ s: String, max: Int = 20, keep: Int = 18) -> String {
        let keep = Swift.max(0, keep)
        return s.count > Swift.max(max, keep) ? String(s.prefix(keep)) + "…" : s
    }

    // Rank a session's EFFECTIVE state for surfacing (higher = more important), so a session
    // awaiting YOUR permission is never hidden behind one merely thinking. `eff` only ever yields
    // permission / thinking / tool / idle (done collapses to idle; waiting is never emitted).
    func priority(of eff: String) -> Int {
        eff == "permission" ? 2 : (isWorkingState(eff) ? 1 : 0)   // idle / unknown = 0
    }

    func workingLabel(_ s: Session) -> String {
        // Off means no word, not a duller word. It used to fall through to the hook's own label,
        // so unchecking "Thinking words" left the bar reading "Thinking…" — indistinguishable
        // from the switch doing nothing, and reported as exactly that. The icon already says
        // Claude is working and the timer says for how long.
        guard useThinkingWords else { return "" }
        if s.state == "thinking", let w = sessionWord[s.key], !w.isEmpty { return w + "…" }
        if !s.label.isEmpty { return s.label }
        return s.state == "tool" ? "Working…" : "Thinking…"
    }

    // Re-pick a word each time a session ENTERS the thinking state (prompt, or a tool->thinking `post`),
    // avoiding an immediate repeat, so a tool round-trip lands a different word. Held steady while the
    // session stays thinking. Computed regardless of the toggle so flipping it on shows instantly.
    func updateThinkingWord(_ s: Session) {
        let prev = prevState[s.key] ?? ""
        guard s.state == "thinking", prev != "thinking" else { return }
        var w = thinkingWords.randomElement() ?? "Thinking"
        if thinkingWords.count > 1 { while w == sessionWord[s.key] { w = thinkingWords.randomElement() ?? w } }
        sessionWord[s.key] = w
    }


    // "1m 1s" / "43s" — Claude Code's elapsed-clock style.
    func elapsed(_ secs: Int) -> String {
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    // The marker keeps update.js's self-relaunch from undoing an explicit Quit; cleared on the
    // next SessionStart (lifecycle.js) or the next manual launch (below), whichever comes first.
}
