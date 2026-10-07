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

    /// Blocking requests wait for a tool result; accepted async cards wait for per-question
    /// user replies. Codex does not record local Skip/X/timeout actions, so an unanswered async
    /// card can only be cleared reliably when the turn ends or a new one starts.
    /// Consume appended records once rather than rereading the conversation on every panel tick.
    struct Questions {
        private static let callType = Data("\"type\":\"function_call\"".utf8)
        private static let syncName = Data("\"name\":\"request_user_input\"".utf8)
        private static let asyncName = Data("\"name\":\"request_user_input_async\"".utf8)
        private static let outputType = Data("\"type\":\"function_call_output\"".utf8)
        private static let replyTag = "<send_user_message_question_reply>"
        private static let replyNeedle = Data(replyTag.utf8)
        private static let eventType = Data("\"type\":\"event_msg\"".utf8)
        private static let boundaryNeedles = endTypes.union(startTypes).map { Data("\"type\":\"\($0)\"".utf8) }

        private var offset: UInt64 = 0
        private var size: UInt64 = 0
        private var mtime: Date = .distantPast
        private var inode: UInt64 = 0
        private var waiting: Set<String> = []
        private var asyncWaiting: [String: (remaining: Set<Int>, accepted: Bool)] = [:]

        private var hasPending: Bool {
            !waiting.isEmpty || asyncWaiting.values.contains { $0.accepted }
        }

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
                return hasPending
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
            } catch { return hasPending }
            size = currentSize
            mtime = currentMtime
            inode = currentInode
            return hasPending
        }

        private mutating func consume(_ data: Data) {
            let call = data.range(of: Self.callType) != nil
                && (data.range(of: Self.syncName) != nil || data.range(of: Self.asyncName) != nil)
            let output = (!waiting.isEmpty || !asyncWaiting.isEmpty)
                && data.range(of: Self.outputType) != nil
            let reply = !asyncWaiting.isEmpty && data.range(of: Self.replyNeedle) != nil
            let boundary = data.range(of: Self.eventType) != nil
                && Self.boundaryNeedles.contains(where: { data.range(of: $0) != nil })
            guard call || output || reply || boundary else { return }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { return }
            if root["type"] as? String == "event_msg" {
                if endTypes.contains(type) || startTypes.contains(type) {
                    waiting.removeAll()
                    asyncWaiting.removeAll()
                }
                return
            }
            guard root["type"] as? String == "response_item" else { return }
            if type == "function_call", let name = payload["name"] as? String,
               name == "request_user_input" || name == "request_user_input_async",
               let id = payload["call_id"] as? String,
               let arguments = payload["arguments"] as? String,
               let argumentData = arguments.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any],
               let questions = values["questions"] as? [[String: Any]], !questions.isEmpty {
                if name == "request_user_input" {
                    waiting.insert(id)
                } else {
                    asyncWaiting[id] = (Set(questions.indices), false)
                }
            } else if type == "function_call_output", let id = payload["call_id"] as? String {
                waiting.remove(id)
                if asyncWaiting[id] != nil {
                    let output = (payload["output"] as? String)?.data(using: .utf8)
                    let values = output.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    if values?["accepted"] as? Bool == true {
                        asyncWaiting[id]?.accepted = true
                    } else {
                        asyncWaiting[id] = nil
                    }
                }
            } else if type == "message", payload["role"] as? String == "user",
                      let content = payload["content"] as? [[String: Any]] {
                let closingTag = "</send_user_message_question_reply>"
                for item in content {
                    guard let text = item["text"] as? String else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix(Self.replyTag), trimmed.hasSuffix(closingTag),
                          let json = trimmed.dropFirst(Self.replyTag.count).dropLast(closingTag.count)
                            .data(using: .utf8),
                          let values = try? JSONSerialization.jsonObject(with: json) else { continue }
                    let replies = values as? [[String: Any]] ?? (values as? [String: Any]).map { [$0] } ?? []
                    for reply in replies {
                        guard let key = (reply["questionItemId"] as? String)?.data(using: .utf8),
                              let parts = try? JSONSerialization.jsonObject(with: key) as? [Any],
                              parts.count == 3, parts[0] as? String == "request_user_input_async",
                              let id = parts[1] as? String, let index = parts[2] as? Int,
                              reply["answer"] is String else { continue }
                        asyncWaiting[id]?.remaining.remove(index)
                        if asyncWaiting[id]?.remaining.isEmpty == true { asyncWaiting[id] = nil }
                    }
                }
            }
        }
    }
}
