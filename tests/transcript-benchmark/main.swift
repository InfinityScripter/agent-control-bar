// Synthetic append/cache benchmark; no conversation contents are read.
// swiftc -O Sources/Model/*.swift tests/transcript-benchmark/main.swift -o /tmp/ccb-bench -framework Cocoa
// /tmp/ccb-bench
import Foundation

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("ccb-bench-" + UUID().uuidString).path
try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: root) }
let now = 1_792_000_000.0
func json(_ value: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
let completion = json(["timestamp": "2026-10-14T00:00:00Z", "type": "event_msg",
                       "payload": ["type": "task_complete", "turn_id": "benchmark"]])
let append = json(["type": "response_item", "payload": ["type": "function_call_output",
                                                          "call_id": "tick", "output": "still building"]])
var sessions: [Session] = []
var expected: [String] = []
let engine = SessionEngine()
for (index, count) in [200, 3_000, 25_000, 80_000].enumerated() {
    let output = json(["type": "response_item", "payload": ["type": "function_call_output",
        "call_id": "build-\(index)", "output": String(repeating: "日本語🦀e\u{301}", count: count)]])
    let path = root + "/\(index).jsonl"
    var data = completion
    data.append(10)
    data.append(output)
    data.append(10)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    let session = Session(json: ["provider": "codex", "state": "tool", "ts": now,
                                 "transcript": path, "turn_id": "benchmark"], id: "\(index)")
    sessions.append(session)
    // The largest fixture puts completion outside the existing 1 MB tail ceiling.
    expected.append(index == 3 ? "tool" : "idle")
    precondition(engine.effectiveState(session, now: now) == expected[index])
    print("fixture=\(index) bytes=\(data.count)")
}
func ms(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
var total = 0.0
for round in 0..<7 {
    for session in sessions {
        let file = FileHandle(forWritingAtPath: session.transcript)!
        try file.seekToEnd()
        try file.write(contentsOf: append)
        try file.write(contentsOf: Data([10]))
        try file.close()
    }
    let elapsed = ms {
        for (index, session) in sessions.enumerated() {
            precondition(engine.effectiveState(session, now: now) == expected[index])
        }
    }
    total += elapsed
    print(String(format: "append_round=%d four_sessions_ms=%.3f", round, elapsed))
}
let cacheMS = ms {
    for _ in 0..<1_000 {
        for (index, session) in sessions.enumerated() {
            precondition(engine.effectiveState(session, now: now) == expected[index])
        }
    }
}
print(String(format: "append_mean_ms=%.3f cache_4000_calls_ms=%.3f expected_decisions_verified=true", total / 7, cacheMS))
