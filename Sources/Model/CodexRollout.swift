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

    /// Questions remain visible while a turn works in the background. The async tool's immediate
    /// `accepted` output means the card was offered, not that the user answered it. Rollouts are
    /// append-only in normal use, so consume each new record once rather than rereading a long
    /// conversation on every panel tick.
    struct Questions {
        private static let callType = Data("\"type\":\"function_call\"".utf8)
        private static let asyncName = Data("\"name\":\"request_user_input_async\"".utf8)
        private static let syncName = Data("\"name\":\"request_user_input\"".utf8)
        private static let outputType = Data("\"type\":\"function_call_output\"".utf8)
        private static let userRole = Data("\"role\":\"user\"".utf8)
        private static let replyTag = Data("<send_user_message_question_reply>".utf8)
        private static let eventType = Data("\"type\":\"event_msg\"".utf8)
        private static let endNeedles = endTypes.map { Data("\"type\":\"\($0)\"".utf8) }

        private var offset: UInt64 = 0
        private var size: UInt64 = 0
        private var mtime: Date = .distantPast
        private var inode: UInt64 = 0
        private var offered: [String: Set<Int>] = [:]
        private var waiting: [String: Set<Int>] = [:]

        mutating func pending(in path: String) -> Bool {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let currentSize = (attrs[.size] as? NSNumber)?.uint64Value else {
                self = Questions()
                return false
            }
            let currentMtime = attrs[.modificationDate] as? Date ?? .distantPast
            let currentInode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if currentSize < size || (inode != 0 && currentInode != inode)
                || (currentSize == size && currentMtime != mtime) {
                self = Questions()
            }
            if currentSize == size && currentMtime == mtime && currentInode == inode {
                return !waiting.isEmpty
            }
            guard let file = FileHandle(forReadingAtPath: path) else { return false }
            defer { try? file.close() }
            do {
                try file.seek(toOffset: offset)
                let data = try file.readToEnd() ?? Data()
                let completeEnd = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
                for line in data[..<completeEnd].split(separator: 10) { consume(Data(line)) }
                offset += UInt64(completeEnd)
                if completeEnd < data.count {
                    let last = Data(data[completeEnd...])
                    if (try? JSONSerialization.jsonObject(with: last)) != nil {
                        consume(last)
                        offset += UInt64(last.count)
                    }
                }
            } catch { return !waiting.isEmpty }
            size = currentSize
            mtime = currentMtime
            inode = currentInode
            return !waiting.isEmpty
        }

        private mutating func consume(_ data: Data) {
            let call = data.range(of: Self.callType) != nil
                && (data.range(of: Self.asyncName) != nil || data.range(of: Self.syncName) != nil)
            let output = (!offered.isEmpty || !waiting.isEmpty)
                && data.range(of: Self.outputType) != nil
            let reply = data.range(of: Self.userRole) != nil
                && data.range(of: Self.replyTag) != nil
            let end = data.range(of: Self.eventType) != nil
                && Self.endNeedles.contains(where: { data.range(of: $0) != nil })
            guard call || output || reply || end else { return }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { return }
            if root["type"] as? String == "event_msg" {
                if endTypes.contains(type) {
                    // The desktop removes an unanswered async card when the turn ends.
                    offered.removeAll()
                    waiting.removeAll()
                }
                return
            }
            guard root["type"] as? String == "response_item" else { return }
            if type == "function_call", let name = payload["name"] as? String,
               let id = payload["call_id"] as? String,
               let arguments = payload["arguments"] as? String,
               let argumentData = arguments.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any],
               let questions = values["questions"] as? [[String: Any]], !questions.isEmpty {
                if name == "request_user_input_async" {
                    offered[id] = Set(questions.indices)
                } else if name == "request_user_input" {
                    waiting[id] = Set(questions.indices)
                }
            } else if type == "function_call_output", let id = payload["call_id"] as? String {
                if let questions = offered.removeValue(forKey: id) {
                    if let output = payload["output"] as? String,
                       let outputData = output.data(using: .utf8),
                       let result = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
                       result["accepted"] as? Bool == true {
                        waiting[id] = questions
                    }
                } else {
                    waiting[id] = nil
                }
            } else if type == "message", payload["role"] as? String == "user",
                      let content = payload["content"] as? [[String: Any]] {
                for part in content {
                    guard let text = part["text"] as? String,
                          let start = text.range(of: "<send_user_message_question_reply>"),
                          let end = text.range(of: "</send_user_message_question_reply>",
                                               range: start.upperBound..<text.endIndex),
                          let replyData = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8),
                          let replies = try? JSONSerialization.jsonObject(with: replyData) as? [[String: Any]]
                    else { continue }
                    for reply in replies {
                        guard let rawId = reply["questionItemId"] as? String,
                              let idData = rawId.data(using: .utf8),
                              let parts = try? JSONSerialization.jsonObject(with: idData) as? [Any],
                              parts.count == 3,
                              parts[0] as? String == "request_user_input_async",
                              let callId = parts[1] as? String,
                              let index = parts[2] as? Int else { continue }
                        waiting[callId]?.remove(index)
                        if waiting[callId]?.isEmpty == true { waiting[callId] = nil }
                    }
                }
            }
        }
    }
}
