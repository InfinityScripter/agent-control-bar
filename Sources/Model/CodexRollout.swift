import Foundation

/// Reading what Codex writes into `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// Beside Transcript.swift rather than inside it, because the two agents share no format at all.
/// Claude Code writes one record per turn line and never states that a turn is over, so the end of
/// one has to be inferred there from an interrupt marker. Codex writes an envelope —
/// `{"timestamp":…,"type":"event_msg","payload":{"type":"task_complete",…}}` — and names the
/// boundaries of every turn outright.
///
/// That statement is what the panel falls back on when a hook does not arrive, and it is the half
/// that was missing: SessionEngine read EVERY transcript with Claude's parser, which finds nothing
/// whatsoever in a rollout — measured across this machine's rollout files, zero lines carry
/// `"type":"user"` and zero carry `"type":"assistant"`. So all three of the engine's recovery nets
/// were dead for Codex and only the flat caps were left, and a session whose Stop never landed sat
/// "Thinking…" — spinner, live timer and menu bar animation — for the full fifteen minutes.
enum CodexRollout {

    /// One turn boundary, as the rollout states it.
    struct Boundary: Equatable {
        /// True for a record that ENDS a turn, false for one that starts it. The distinction is the
        /// whole point: an end record on its own only says "some turn finished somewhere in this
        /// file", and the question the panel asks is whether the turn running NOW is over.
        var ends: Bool
        /// Unix time of the record, from the envelope's own ISO stamp.
        var at: Double
        /// `payload.turn_id`, or "" for a build that stamps none. The hook payload carries the same
        /// id (it is in Codex's own schema for every turn-scoped event), which is what lets a
        /// boundary be matched to a session's state file exactly rather than by clock.
        var turn: String
    }

    /// Payload types that END a turn: the model finished, or the turn was cut short — Esc, an
    /// error, a turn replaced by the next prompt.
    ///
    /// Two spellings, exactly as the hooks' surface table carries two spellings of the terminal:
    /// `task_started`/`task_complete` is what 0.154 writes into rollouts (verified against this
    /// machine's files), `turn_started`/`turn_complete` is what Codex's newer tracing subsystem
    /// calls the same boundary. A rename must not silently put every session back on a
    /// fifteen-minute spinner, and carrying both names costs one set lookup.
    static let endTypes: Set<String> = ["task_complete", "turn_complete", "turn_aborted"]

    /// And the types that START one.
    static let startTypes: Set<String> = ["task_started", "turn_started"]

    /// The quoted forms the cheap gate looks for, built once rather than per line. A rollout line
    /// runs large — a tool result, an image, the session_meta every file opens with, measured here
    /// at a 19 KB median and 70 KB at the widest — and the tail scan sees every one of them, so no
    /// line is handed to JSONSerialization on spec.
    private static let needles: [String] = endTypes.union(startTypes).map { "\"\($0)\"" }

    /// What a rollout line says about a turn boundary, or nil for every other record — including a
    /// tool result that merely QUOTES one of these names, which is why the substring gate above is
    /// not the answer on its own. A Codex session working on this repository produces exactly such
    /// a result, since these names are written out here in full.
    ///
    /// Takes any string slice so the tail scan can pass a Substring without copying it first.
    static func boundary<S: StringProtocol>(_ line: S) -> Boundary? {
        guard needles.contains(where: { line.contains($0) }),
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              let kind = payload["type"] as? String,
              endTypes.contains(kind) || startTypes.contains(kind),
              let stamp = root["timestamp"] as? String,
              let at = Transcript.unixTime(stamp)
        else { return nil }
        return Boundary(ends: endTypes.contains(kind), at: at,
                        turn: payload["turn_id"] as? String ?? "")
    }
}
