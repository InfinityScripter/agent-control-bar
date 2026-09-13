import Foundation

// The per-session state model, separated from the UI so the model checks can hold it: every
// serious bug of the 0.7.x review lived in logic main.swift kept untestable. Sources/main.swift
// draws; this file decides. The state files parsed here are written by hooks/update.js and
// hooks/lifecycle.js — their key inventory is pinned by tests/merge.test.js and by the seam
// fixture the node suite writes for the model checks.

struct Session {
    var id: String, state: String, label: String, project: String, transcript: String
    var cwd: String         // session working directory; "" on pre-upgrade files
    var entrypoint: String  // CLAUDE_CODE_ENTRYPOINT: "cli", "claude-desktop", …
    var termProgram: String // TERM_PROGRAM for CLI sessions: "Apple_Terminal", "iTerm.app", …
    var termBundle: String  // __CFBundleIdentifier of the hosting app; "" over ssh / pre-upgrade files
    var pid: Int32          // the session's `claude` process; kill(pid,0) drives liveness. 0 = pre-upgrade file.
    var started: Bool       // true once the session had real activity (a prompt/tool); a merely-opened
                            // conversation seeds started=false and stays out of the dropdown.
    var startedAt: Double, ts: Double
    // How full this session's context window is, measured by hooks/update.js from the
    // transcript on every event. Claude Code hands this number to statusLine and to nothing
    // else, and the desktop app never runs statusLine — so it is recomputed rather than read.
    var pct: Int?
    var tokens: Int?
    var window: Int?
    var model: String = ""
    var assumed = false    // the window size is a family guess, not a known figure
    // Session totals Claude Code reports to statusLine only, captured by hooks/statusline.py
    // and carried into the state file by hooks/update.js. nil for a session no status line
    // ever ran for — the desktop app runs none — and the card leaves the block out.
    var cost: Double?      // USD so far, rounded to cents by the writer
    var duration: Int?     // seconds of wall time
    var linesAdded: Int?
    var linesRemoved: Int?
    var dirty: Int?        // files with uncommitted changes in cwd; nil outside a git repo

    // Which agent this session belongs to: "claude" or "codex". A string rather than an enum for
    // the same reason `state` is one — the value is produced by a hook in another language, and a
    // third agent must not require a synchronized Swift edit. A file without the field is
    // Claude's: it was written before Codex existed, and every pre-upgrade session has one.
    var provider: String = "claude"
    // Where a Codex session runs: "cli", "ide", "app", "exec", or "" when its rollout named an
    // originator we do not know. Claude's equivalent is inferred from entrypoint + TERM_PROGRAM
    // instead, because Claude Code does not state it.
    var surface: String = ""

    var eff: String = ""   // effective state, recomputed once per tick in evaluate()
    var branch: String = ""      // git branch (or short SHA when detached); "" outside a repo
    var displayName: String = "" // project, parent-qualified when two live sessions share a name

    // The key this session is held under, and the reason it is not just the id: two agents
    // generate session ids independently, and one collision would make a Codex session's file
    // overwrite a Claude session's row — or be deleted from the wrong directory.
    var key: String { provider + ":" + id }

    init(json o: [String: Any], id: String) {
        self.id = id
        self.state = o["state"] as? String ?? "idle"
        self.label = o["label"] as? String ?? ""
        self.project = o["project"] as? String ?? ""
        self.transcript = o["transcript"] as? String ?? ""
        self.cwd = o["cwd"] as? String ?? ""
        self.entrypoint = o["entrypoint"] as? String ?? ""
        self.termProgram = o["term_program"] as? String ?? ""
        self.termBundle = o["term_bundle"] as? String ?? ""
        self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
        self.started = o["started"] as? Bool ?? false
        self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
        self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
        self.pct = (o["pct"] as? NSNumber)?.intValue
        self.tokens = (o["tokens"] as? NSNumber)?.intValue
        self.window = (o["window"] as? NSNumber)?.intValue
        self.model = o["model"] as? String ?? ""
        self.assumed = o["assumed"] as? Bool ?? false
        self.cost = (o["cost"] as? NSNumber)?.doubleValue
        self.duration = (o["duration"] as? NSNumber)?.intValue
        self.linesAdded = (o["linesAdded"] as? NSNumber)?.intValue
        self.linesRemoved = (o["linesRemoved"] as? NSNumber)?.intValue
        self.dirty = (o["dirty"] as? NSNumber)?.intValue
        self.provider = o["provider"] as? String ?? "claude"
        self.surface = o["surface"] as? String ?? ""
    }
}

/// The state machine behind every session row and the menu bar icon.
final class SessionEngine {
    // private so the compiler guards the seam: dropCache is the one sanctioned door in.
    private var turnLineCache: [String: (size: UInt64, mtime: Date, interrupted: Bool, turnTs: Double?)] = [:]

    /// A dead session's transcript leaves the cache with it — keyed by path, not id.
    func dropCache(forTranscript path: String) { turnLineCache[path] = nil }

    // Per-session effective state with two recovery nets: an absolute age cap, plus the transcript
    // "interrupted by user" marker (Esc / denied permission fire no hook, freezing the file). "done"
    // collapses to rest.
    func effectiveState(_ s: Session, now: Double) -> String {
        if isActiveState(s.state) {
            // The ts is stamped by the last hook event and untouched while a tool runs — there
            // is no "still running" hook — so every cap here is a last resort, not a measurement.
            // tool gets an hour: builds and test suites legitimately run for tens of minutes,
            // and the old flat 15 read them as idle while the stale-prune (same clock) hid the
            // row mid-build. A genuinely dead one is caught far earlier by the interrupt net or
            // the pid reap. 30 minutes for permission, not the 2 hours it once was: with the
            // transcript nets below this is a last resort, and a frozen amber dot outranks
            // every live session.
            let cap: Double = s.state == "permission" ? 1800 : (s.state == "tool" ? 3600 : 900)
            let facts = s.transcript.isEmpty ? nil : turnFacts(ofFileAt: s.transcript)
            if now - s.ts > cap {
                // A streaming transcript is proof of life past the cap for a THINKING session:
                // records append every ~1.7s median while the model streams, so a fresh mtime
                // means work, not a wedge. Extension only — never demotion — so it cannot
                // collide with the v0.5.6 decision against turn-record-based demotion. Tool
                // states get no such net on purpose: the transcript is silent by design while
                // a tool runs (its record lands at completion), which is why their cap is an
                // hour instead. The mtime comes from the turnFacts stat above — this path used
                // to stat the same file a second time for the same answer.
                var streaming = false
                if s.state == "thinking", let mtime = facts?.mtime {
                    streaming = now - mtime.timeIntervalSince1970 <= 120
                }
                if !streaming { return "idle" }
            }
            if let facts {
                if facts.interrupted { return "idle" }
                // While a permission prompt waits, the transcript is silent — the tool_use that
                // opened it is already on disk. So a turn record younger than the prompt means
                // the prompt was answered, whatever form the answer took: deny and Esc write
                // one without firing any hook. +2s keeps that same tool_use record, stamped in
                // the prompt's own second, from ending the wait it started. Permission only:
                // thinking/tool sessions append turn records as part of normal work (measured
                // median gap 1.7s), so the same test there would idle a session mid-stride.
                if s.state == "permission", let t = facts.turnTs, t > s.ts + 2 { return "idle" }
            }
            return s.state
        }
        return s.state == "done" ? "idle" : s.state
    }

    // What the transcript's last turn line (a user/assistant message, ignoring the bookkeeping
    // Claude Code appends after an interrupt) says about the session: the interrupt marker, the
    // record's timestamp, and the file's own mtime (the streaming-proof above rides on it — one
    // stat serves both questions). Marker and timestamp are computed when the file changes and
    // cached — a sampling pass once put the raw per-tick read among the timer's top costs, and
    // parsing the same unchanged line every tick is the same class of waste. One stat() per
    // tick otherwise.
    private func turnFacts(ofFileAt path: String) -> (interrupted: Bool, turnTs: Double?, mtime: Date) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        if let hit = turnLineCache[path], hit.size == size, hit.mtime == mtime {
            return (hit.interrupted, hit.turnTs, mtime)
        }
        let line = readLastTurnLine(ofFileAt: path)
        let interrupted = line.map(Transcript.wasInterrupted) ?? false
        let turnTs = line.flatMap(Transcript.turnTimestamp)
        // A record that parses as a turn but carries no usable timestamp is format drift — the
        // permission net below dies silently without it. Once per file change, not per tick, so
        // Console gets a trace instead of "sessions sometimes sit amber for the whole cap".
        if let line, turnTs == nil, Transcript.isTurnRecord(line) {
            NSLog("ClaudeControlBar: turn record without a parseable timestamp — transcript format drift? \(path)")
        }
        turnLineCache[path] = (size, mtime, interrupted, turnTs)
        return (interrupted, turnTs, mtime)
    }

    private func readLastTurnLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        // Escalating windows, 8 KB first: a streaming transcript invalidates the cache on every
        // append, so the hot path must stay at the old price — the last line there IS the turn
        // record. The larger reads pay only when the tail is all bookkeeping: Claude Code appends
        // it after an interrupt in lines measured up to 112 KB, and any fixed window is a bet
        // against the next release's line, so the ladder ends at a hard ceiling instead.
        for chunk: UInt64 in [8_192, 262_144, 1_048_576] {
            try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
            guard let data = try? fh.readToEnd() else { return nil }
            // Never the failable String(data:encoding:): a window cut mid-way through a multi-
            // byte character made it return nil for the ENTIRE chunk, and the cache then pinned
            // that nil for as long as the file sat still — a permission wait, by definition.
            let s = String(decoding: data, as: UTF8.self)
            if let line = s.split(separator: "\n").last(where: {
                $0.contains("\"type\":\"user\"") || $0.contains("\"type\":\"assistant\"")
            }) { return String(line) }
            if size <= chunk { return nil }  // the whole file is read — there is nowhere left to look
        }
        return nil
    }
}

// The state vocabulary is strings written by the Node hooks (see code-conventions.md), so the
// two questions every layer asks of a state live here, once. Eleven hand-written copies of
// `== "thinking" || == "tool"` is how a fifth state would silently miss the icon or the menu.
/// A turn is in progress: the model is thinking or a tool is running.
func isWorkingState(_ state: String) -> Bool { state == "thinking" || state == "tool" }
/// The session needs the icon: working, or waiting for the user's permission.
func isActiveState(_ state: String) -> Bool { isWorkingState(state) || state == "permission" }
