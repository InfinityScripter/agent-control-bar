import Foundation

/// Every live session, and everything decided about them tick by tick: which files to read, which
/// sessions are dead, when a finished turn chimes, when a permission prompt asks for the user, how
/// same-named projects are told apart and which session leads the menu bar.
///
/// The disk, the clock, the process table and the frontmost app come in from outside; the
/// decisions come back out, and the caller does the deleting and the playing. That is what lets
/// the model check cover the loop around SessionEngine, which is where the bugs used to be.
final class SessionBoard {
    /// A state file as found on disk this pass.
    struct File {
        let key: String
        let path: String
        let provider: String
        let id: String
        let mtime: Date
    }

    /// The settings a tick reads, passed in so the board holds no copy that could go stale.
    struct Rules {
        /// The minimum turn length, in seconds, that chimes on completion; 0 is off.
        var soundThreshold: Double
        /// How long an idle session without a pid is kept; 0 keeps it forever.
        var stalePruneAge: Double
        var thinkingWords: [String]
        /// Whether a confirmed request for the user cues a sound at all.
        var needsYou: Bool
    }

    struct Tick {
        /// Sessions whose process has died. Already gone from the board; the caller deletes their
        /// files.
        var reaped: [Session] = []
        /// A turn longer than the threshold has just finished.
        var chime = false
        /// A session has just started waiting for the user, and its terminal is not in front.
        var needsYou = false
        /// The single most important session: permission > working > the rest, most recent first.
        var lead: Session?
    }

    let engine: SessionEngine
    private(set) var sessions: [String: Session] = [:]
    /// Keyed like `sessions`, "<provider>:<id>". Cleared together in `forget(_:)` and nowhere
    /// else, so a session cannot leave one of them behind.
    private var mtimes: [String: Date] = [:]
    private var prevState: [String: String] = [:]
    private var words: [String: String] = [:]
    private var turnStart: [String: Double] = [:]

    init(engine: SessionEngine) { self.engine = engine }

    /// How many session files are on disk — also counts a file whose JSON did not parse.
    var fileCount: Int { mtimes.count }

    /// The thinking word picked for this session's current turn, if it is thinking.
    func word(for key: String) -> String? { words[key] }

    /// Re-read the files whose mtime changed and drop the sessions whose file is gone. Writes are
    /// atomic renames, so a content update bumps the mtime and is never read torn. `branch` is
    /// asked only on a changed file — a hook event — never on a bare tick.
    func reload(_ files: [File], read: (String) -> [String: Any]?, branch: (String) -> String) {
        let present = Set(files.map(\.key))
        for key in Array(mtimes.keys) where !present.contains(key) { forget(key) }
        for f in files {
            if mtimes[f.key] == f.mtime { continue }
            mtimes[f.key] = f.mtime
            guard let json = read(f.path) else { continue }
            var s = Session(json: json, id: f.id)
            s.eff = sessions[f.key]?.eff ?? ""
            // The directory a file was found in settles the provider, whatever the file says: a
            // hand-edited or truncated `provider` must not send the reap at another agent's
            // directory, and a file in codex/state.d is a Codex session by construction.
            s.provider = f.provider
            s.branch = branch(s.cwd)
            sessions[f.key] = s
        }
    }

    /// Branches otherwise refresh only on hook events; the panel asks again when it opens, to
    /// catch a checkout made while a session sat idle.
    func refreshBranches(_ branch: (String) -> String) {
        for (key, s) in sessions where !s.cwd.isEmpty { sessions[key]?.branch = branch(s.cwd) }
    }

    func tick(now: Double, rules: Rules, pidAlive: (Int32) -> Bool,
              frontmost: () -> String?) -> Tick {
        var out = Tick()
        for key in sessions.keys.sorted() {
            guard var s = sessions[key] else { continue }
            let previousEffective = s.eff
            s.eff = engine.effectiveState(s, now: now)   // once per tick; the menu and tooltip reuse it
            // Reap on PROCESS death, not idle time: a session leaves only when its process is gone
            // (closed or crashed terminal, quit app), so an idle-but-open session stays and the
            // icon holds. Pre-upgrade files have no pid (0) — fall back to the idle+age prune so
            // they cannot linger forever. This is also what keeps state.d self-cleaning.
            let dead = s.pid > 0 ? !pidAlive(s.pid)
                                 : (s.eff == "idle" && rules.stalePruneAge > 0
                                    && now - s.ts > rules.stalePruneAge)
            if dead {
                out.reaped.append(s)
                forget(key)
                continue
            }
            sessions[key] = s
            pickWord(s, from: rules.thinkingWords)
            if completionEdge(s, now: now, threshold: rules.soundThreshold) { out.chime = true }
            // The frontmost-app lookup is a workspace query, so it runs only on a confirmed edge.
            if rules.needsYou, s.eff == "permission", previousEffective != "permission",
               NeedsYouSound.shouldCue(prevState: previousEffective, effective: s.eff,
                                       hostBundle: s.termBundle, frontmost: frontmost()) {
                out.needsYou = true
            }
            prevState[key] = s.state
        }
        nameClones()
        out.lead = sessions.values.max { a, b in
            let pa = Self.priority(of: a.eff), pb = Self.priority(of: b.eff)
            return pa == pb ? a.ts < b.ts : pa < pb
        }
        return out
    }

    /// Rank an EFFECTIVE state for surfacing, so a session awaiting permission is never hidden
    /// behind one merely thinking. `eff` only ever yields permission / thinking / tool / idle.
    static func priority(of eff: String) -> Int {
        eff == "permission" ? 2 : (isWorkingState(eff) ? 1 : 0)
    }

    private func forget(_ key: String) {
        if let gone = sessions[key], !gone.transcript.isEmpty {
            engine.dropCache(forTranscript: gone.transcript)
        }
        sessions[key] = nil
        mtimes[key] = nil; prevState[key] = nil; words[key] = nil; turnStart[key] = nil
    }

    /// Re-pick a word each time a session ENTERS thinking (a prompt, or a tool -> thinking `post`),
    /// avoiding an immediate repeat, so a tool round-trip lands a different word. Held steady while
    /// the session stays thinking.
    private func pickWord(_ s: Session, from list: [String]) {
        guard s.state == "thinking", prevState[s.key] != "thinking" else { return }
        var w = list.randomElement() ?? "Thinking"
        if list.count > 1 { while w == words[s.key] { w = list.randomElement() ?? w } }
        words[s.key] = w
    }

    /// Working -> done edge, gated on the turn lasting at least `threshold` seconds (0 = off).
    /// Reads prevState, which the tick writes only after this runs.
    private func completionEdge(_ s: Session, now: Double, threshold: Double) -> Bool {
        if isWorkingState(s.state), s.startedAt > 0 { turnStart[s.key] = s.startedAt }
        let prev = prevState[s.key] ?? ""
        var edge = false
        if threshold > 0, s.state == "done", prev != "done", let start = turnStart[s.key], start > 0,
           now - start >= threshold { edge = true }
        if s.state == "done" { turnStart[s.key] = 0 }
        return edge
    }

    /// Same-named projects (two clones or worktrees of one repo) get a parent-folder qualifier —
    /// "work/myrepo" vs "tmp/myrepo" — so their rows stay tellable apart. Runs after the reap so
    /// dead sessions cannot force a qualifier onto a now-unique name. Only non-empty cwds count as
    /// locations: a file without one is location-unknown, and counting "" as a place forced a bogus
    /// qualifier onto a genuinely unique row.
    private func nameClones() {
        var cwdsByProject: [String: Set<String>] = [:]
        for s in sessions.values where !s.project.isEmpty && !s.cwd.isEmpty {
            cwdsByProject[s.project, default: []].insert(s.cwd)
        }
        for (key, s) in sessions {
            if !s.cwd.isEmpty, (cwdsByProject[s.project]?.count ?? 0) > 1 {
                let parent = ((s.cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
                sessions[key]?.displayName = parent.isEmpty ? s.project : parent + "/" + s.project
            } else {
                sessions[key]?.displayName = s.project
            }
        }
    }
}
