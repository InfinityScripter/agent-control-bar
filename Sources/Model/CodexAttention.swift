import Foundation

struct CodexAttention {
    struct Observation {
        var pid: Int32
        var turn: String
        var awaitingApproval: Bool
        var observedAt: Double
    }
    private var observations: [String: Observation] = [:]

    init(json: [String: Any]) {
        guard let version = json["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              json["status"] as? String == "ok", let records = json["sessions"] as? [[String: Any]] else { return }
        for record in records {
            guard let thread = record["thread_id"] as? String, !thread.isEmpty, thread.count <= 128,
                  let turn = record["turn_id"] as? String, !turn.isEmpty, turn.count <= 128,
                  let pid = record["pid"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
                  pid.doubleValue > 0, pid.doubleValue <= Double(Int32.max),
                  pid.doubleValue.rounded(.towardZero) == pid.doubleValue,
                  let awaiting = record["awaiting_approval"] as? NSNumber,
                  CFGetTypeID(awaiting) == CFBooleanGetTypeID(),
                  let stamp = record["observed_at"] as? NSNumber, CFGetTypeID(stamp) != CFBooleanGetTypeID(),
                  stamp.doubleValue.isFinite, stamp.doubleValue > 0, observations[thread] == nil else {
                observations.removeAll()
                return
            }
            observations[thread] = Observation(pid: pid.int32Value, turn: turn, awaitingApproval: awaiting.boolValue,
                                               observedAt: stamp.doubleValue)
        }
    }

    func approval(for session: Session, now: Double) -> Observation? {
        guard session.provider == "codex", session.started, session.pid > 0, !session.turnID.isEmpty,
              let observation = observations[session.id], observation.awaitingApproval,
              observation.pid == session.pid, observation.turn == session.turnID,
              now.isFinite, now >= observation.observedAt, now - observation.observedAt <= 10 else { return nil }
        return observation
    }

    static func read(at path: String, gate: inout Date?, previous: CodexAttention?) -> CodexAttention? {
        switch StateFileLook.at(path, gate: &gate) {
        case .missing: return nil
        case .changed(let object): return CodexAttention(json: object)
        case .unchanged:
            guard previous != nil else { return nil }
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            // The shared gate keeps its last parse on corrupt JSON; approval must fall back instead.
            return stamp == gate ? previous : nil
        }
    }
}

struct CodexAttentionPoll {
    private var lastPolledAt: Double = 0
    private var inFlight = false

    mutating func begin(now: Double, sessions: [Session], pidAlive: (Int32) -> Bool) -> Bool {
        guard !inFlight, now - lastPolledAt >= 5,
              sessions.contains(where: { $0.provider == "codex" && $0.started && $0.pid > 0
                  && !$0.turnID.isEmpty && pidAlive($0.pid) }) else { return false }
        inFlight = true
        lastPolledAt = now
        return true
    }

    mutating func finish() { inFlight = false }
}
