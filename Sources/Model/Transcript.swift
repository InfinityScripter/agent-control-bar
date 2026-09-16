import Foundation

/// Reading what Claude Code writes into `~/.claude/projects/**/*.jsonl`.
///
/// Its own file so the checks in `tests/model` can compile it. main.swift carries the top-level
/// `app.run()` and cannot be linked into a test binary, which is how the one piece of transcript
/// parsing the whole session state hangs on went uncovered — and stayed wrong.
enum Transcript {
    /// What Claude Code writes when a turn is cut short with Esc or a denied permission. Neither
    /// fires a hook, so the session's state file freezes mid-turn and this marker is the only
    /// thing that says the turn is over.
    static let interruptMarkers: Set<String> = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

    /// The line parsed as a turn record (`"type":"user"` / `"type":"assistant"`), or nil for
    /// bookkeeping records and lines that do not parse — the shared prologue of every check here.
    private static func record(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String, type == "user" || type == "assistant"
        else { return nil }
        return root
    }

    /// Whether the line parses as a turn record at all — the log-gate for format drift: a record
    /// that parses but yields no timestamp is drift worth a trace, a half-written line from a
    /// streaming transcript is routine and must not be.
    static func isTurnRecord(_ line: String) -> Bool { record(line) != nil }

    /// Unix time of a turn record, from the ISO-8601 `timestamp` Claude Code stamps on every
    /// line. Anything else — bookkeeping records, a missing field, a line that does not parse —
    /// is nil, never a guess: the caller compares this against a hook-written clock, and a wrong
    /// number would end a wait that is real.
    static func turnTimestamp(_ line: String) -> Double? {
        guard let root = record(line), let stamp = root["timestamp"] as? String else { return nil }
        return unixTime(stamp)
    }

    /// Unix time from an ISO-8601 stamp, or nil for anything that does not parse as one.
    ///
    /// Shared rather than private because Codex stamps its rollout envelopes the same way, and the
    /// two-formatter dance below is the whole reason a second copy would be worth avoiding: it is
    /// not obvious, and a reader who writes the obvious one line gets nil for every timestamp
    /// either agent actually writes.
    static func unixTime(_ stamp: String) -> Double? {
        isoParser.date(from: stamp)?.timeIntervalSince1970
            ?? isoParserPlain.date(from: stamp)?.timeIntervalSince1970
    }

    /// Both agents write milliseconds ("2026-07-03T09:32:46.368Z"); the plain parser is the
    /// fallback because ISO8601DateFormatter refuses fractions unless told to expect them.
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoParserPlain = ISO8601DateFormatter()

    /// Whether a transcript line IS the interrupt marker — parsed, not searched.
    ///
    /// The raw JSONL used to be scanned for "interrupted by user" anywhere in the line, and a tool
    /// result is itself a `"type":"user"` record carrying whatever the tool returned. So reading
    /// any file that contains the phrase — this repository's own sources do, in three places —
    /// froze a session that was plainly working: mid-turn the animation and the timer stopped, and
    /// one waiting on permission lost its amber alert. Measured across this machine's transcripts:
    /// 27 lines carry the phrase without being an interrupt, against 2 that are one.
    static func wasInterrupted(_ line: String) -> Bool {
        guard line.contains("interrupted by user"),   // cheap gate before paying for the parse
              let root = record(line),
              root["type"] as? String == "user",      // an assistant record typing the marker out is not one
              let message = root["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return interruptMarkers.contains(text) }
        return (message["content"] as? [[String: Any]] ?? []).contains {
            ($0["text"] as? String).map(interruptMarkers.contains) ?? false
        }
    }
}
