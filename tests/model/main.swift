import Cocoa

// Checks on the MCP model, the transcript reader and the desktop-session lookup:
//   swiftc -O Sources/Model/*.swift tests/model/main.swift -o /tmp/t -framework Cocoa && /tmp/t
// There is no test target in this project (it builds with a bare swiftc, no Xcode project), so
// this is a plain executable that exits non-zero on the first failure.
//
// Top-level code runs in order: a check that names a global declared further down reads memory
// that is not initialised yet and dies with a bare segfault, no message. Declare before use.

var failures = 0
func check(_ passed: Bool, _ what: String) {
    print((passed ? "ok   " : "FAIL ") + what)
    if !passed { failures += 1 }
}

let fixture: [String: Any] = [
    "checked_at": 1_785_000_000.0,
    "servers": [
        ["name": "wiki", "state": "ok", "source": "user", "status": "✔ Connected",
         "tools": 3, "toolNames": ["Read", "Write", "Delete"],
         "toolDocs": ["Read": "read a page"],
         "toolParams": ["Read": [["name": "id", "type": "integer", "required": true,
                                  "description": "page id"]]],
         "deniedTools": ["Delete"]],
        ["name": "yt", "state": "failed", "source": "user", "status": "✘ Failed to connect",
         "tools": 2, "toolNames": ["A", "B"], "deniedTools": []],
        ["name": "off-one", "state": "off", "source": "user", "status": "disabled",
         "tools": 5, "toolNames": [], "deniedTools": []],
    ],
    "auth": ["needs-oauth"],
]

let dir = NSTemporaryDirectory() + "ccb-model-test/"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let path = dir + "mcp.json"
try! JSONSerialization.data(withJSONObject: fixture).write(to: URL(fileURLWithPath: path))

let model = MCPModel(path: path)
check(model.reloadIfChanged(), "reads the file")

check(model.servers.count == 3, "three servers parsed")
check(model.visible.count == 2, "a switched-off server is not counted as visible")
check(model.live == 1, "one of the visible two answered")
// wiki has 3 tools with Delete denied -> 2; yt has 2, none denied.
check(model.toolsOn == 4, "tools reaching Claude: \(model.toolsOn), expected 4")
check(model.toolsTotal == 5, "tools offered: \(model.toolsTotal), expected 5")

let wiki = model.servers.first { $0.name == "wiki" }!
check(wiki.tools.first { $0.name == "Delete" }?.enabled == false, "a denied tool reads as off")
check(wiki.tools.first { $0.name == "Read" }?.params.first?.required == true,
      "tool parameters survive the parse")

// The user's report: flipping a switch left every count stale until the menu was reopened.
model.setToolLocally(server: "wiki", tool: "Read", enabled: false)
check(model.toolsOn == 3, "switching a tool off moves the total at once: \(model.toolsOn)")
model.setToolLocally(server: "wiki", tool: "Delete", enabled: true)
check(model.toolsOn == 4, "and back on again: \(model.toolsOn)")

model.setServerLocally("yt", enabled: false)
check(model.visible.count == 1, "switching a server off drops it out of visible")
model.setServerLocally("yt", enabled: true)
// Not "ok": the server list is assembled when a session starts, so switching it back on cannot
// reconnect it. Claiming otherwise would show a green dot for something that is not there.
check(model.servers.first { $0.name == "yt" }?.state == "pending",
      "switching a server back on says pending, not connected")

// A change is only reported against a previous read — otherwise every server "appears" at launch
// and the first look fires a notification storm.
check(model.freshChange() == nil, "the first read reports no change")
var next = fixture
var servers = next["servers"] as! [[String: Any]]
servers[1]["state"] = "ok"
next["servers"] = servers
next["checked_at"] = 1_785_000_100.0
try! JSONSerialization.data(withJSONObject: next).write(to: URL(fileURLWithPath: path))
check(model.reloadIfChanged(force: true), "re-reads on force")
check(model.freshChange()?.up == ["yt"], "a server coming back is reported as up")
check(model.freshChange()?.deservesNotification == true, "a server coming back is worth a notification")

// Switching a server off has to change what its row SAYS, not only whether it counts. Leaving
// a green dot beside an off switch read as the click having done nothing.
model.setServerLocally("wiki", enabled: false)
let offWiki = model.servers.first { $0.name == "wiki" }!
check(offWiki.disabled, "a switched-off server reports itself disabled")
check(mcpGlyph(offWiki.state) == "\u{25CB}", "and its glyph is the hollow one, not the green dot")
check(mcpTint(offWiki.state) == .tertiaryLabelColor, "and its colour is dimmed")
model.setServerLocally("wiki", enabled: true)
check(mcpGlyph(model.servers.first { $0.name == "wiki" }!.state) == "\u{23F8}",
      "back on, it shows the paused glyph until a new session picks it up")

// The spinner claims work is happening, so it needs both halves to be true. "pending" outlives
// the check that resolves it — a server can wait on an authorisation no check will grant — and an
// arc turning against nothing is a promise the app cannot keep.
check(model.isChecking("wiki", backendBusy: true),
      "a pending server spins while the backend is working")
check(!model.isChecking("wiki", backendBusy: false),
      "and stops the moment nothing is checking")
check(!model.isChecking("yt", backendBusy: true),
      "a server that already answered does not spin")
check(!model.isChecking("nosuch", backendBusy: true), "an unknown server does not spin")

// A tool's deny rule is built from the prefix the transcript proves Claude Code uses, not from
// the display name. Built from the name, the rule matched no tool at all: the switch went off,
// the tool kept loading, and the "N/M tools on" count promised a saving that never happened.
let prefixed = try! JSONSerialization.data(withJSONObject: ["servers": [
    ["name": "claude.ai Figma", "toolPrefix": "b6d68fb1", "state": "ok", "source": "claude.ai",
     "toolNames": ["get_screenshot"]],
    ["name": "wiki", "state": "ok", "source": "user", "toolNames": ["GetPageById"]],
]])
try! prefixed.write(to: URL(fileURLWithPath: path))
check(model.reloadIfChanged(force: true), "re-reads the prefixed picture")
check(model.servers.first { $0.name == "claude.ai Figma" }?.toolPrefix == "b6d68fb1",
      "a connector carries the prefix its tools actually use")
check(model.servers.first { $0.name == "wiki" }?.toolPrefix == "wiki",
      "a server without one falls back to its own name")

// A truncated or non-JSON mcp.json (a torn hand edit; the writer itself is atomic) must keep
// the previous picture on screen, not blank the menu.
try! "not json {".write(toFile: path, atomically: true, encoding: .utf8)
_ = model.reloadIfChanged(force: true)
check(model.servers.count == 2,
      "a corrupt mcp.json keeps the previous servers instead of blanking the menu")

// The interrupt marker, told apart from a line that merely quotes it. A tool result is itself a
// "type":"user" record, so reading any file containing the phrase used to stop the animation and
// the timer in the middle of a turn that was still running.
check(Transcript.wasInterrupted(
    #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#),
      "the marker as a plain string is an interrupt")
check(Transcript.wasInterrupted(
    #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#),
      "the marker inside a text block is an interrupt too")
check(!Transcript.wasInterrupted(
    #"{"type":"user","message":{"content":[{"type":"tool_result","content":"…interrupted by user…"}]}}"#),
      "a tool result quoting the phrase is NOT an interrupt")
check(!Transcript.wasInterrupted(
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#),
      "and neither is an assistant message that types it out")
check(!Transcript.wasInterrupted("not json at all, interrupted by user"),
      "a line that does not parse is not an interrupt")

// The timestamp of a turn record. A permission prompt keeps the transcript silent while it
// waits, so a user/assistant record younger than the prompt is proof the prompt is gone —
// deny and Esc write one without firing any hook.
check(Transcript.turnTimestamp(
    #"{"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"content":"hi"}}"#)
        == 1_767_225_600,
      "a user record's timestamp parses to unix time")
check(Transcript.turnTimestamp(
    #"{"type":"assistant","timestamp":"2026-01-01T00:00:00.500Z","message":{"content":[]}}"#)
        == 1_767_225_600.5,
      "fractional seconds survive — Claude Code writes milliseconds")
check(Transcript.turnTimestamp(
    #"{"type":"file-history-snapshot","timestamp":"2026-01-01T00:00:00Z"}"#) == nil,
      "a bookkeeping record is not a turn, whatever its timestamp")
check(Transcript.turnTimestamp(#"{"type":"user","message":{"content":"hi"}}"#) == nil,
      "a turn record without a timestamp yields nothing rather than a guess")
check(Transcript.turnTimestamp("not json") == nil,
      "a line that does not parse yields nothing")
// Format drift is the net's silent killer: a numeric timestamp (or any unparseable shape) must
// yield nil — and isTurnRecord is what lets the app log that drift instead of swallowing it,
// while staying quiet for the half-written lines a streaming transcript ends with.
check(Transcript.turnTimestamp(
    #"{"type":"user","timestamp":1767225600,"message":{"content":"hi"}}"#) == nil,
      "a timestamp of a drifted type yields nothing rather than a crash or a guess")
check(Transcript.isTurnRecord(#"{"type":"user","timestamp":1767225600,"message":{}}"#),
      "the drifted record still counts as a turn — that is what makes it drift worth logging")
check(!Transcript.isTurnRecord(#"{"type":"user","timestamp":"2026-"#),
      "a half-written streaming line is not a turn record, so it is not logged as drift")

// Resolving a row's CLI session id to the id Claude for Desktop answers to. Without it every
// desktop row merely focused the app — which is already frontmost — so all of them did the same
// nothing and clicking a session read as broken.
let sessionsRoot = NSTemporaryDirectory() + "ccb-desktop-sessions/"
let workspace = sessionsRoot + "account/workspace/"
try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
func writeSession(_ name: String, cli: String, modified: Date, tail: String = "") {
    let path = workspace + name + ".json"
    // Exactly how the desktop app writes it: JSON.stringify, no spaces.
    try? #"{"sessionId":"\#(name)","cliSessionId":"\#(cli)","cwd":"/tmp"\#(tail)}"#
        .write(toFile: path, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
}
writeSession("local_older", cli: "cli-1", modified: Date(timeIntervalSince1970: 1_000))
writeSession("local_newer", cli: "cli-1", modified: Date(timeIntervalSince1970: 2_000))
writeSession("local_other", cli: "cli-2", modified: Date(timeIntervalSince1970: 3_000))
// The app files every enabled MCP tool into the record, one key per tool, and with a few
// hundred tools on the account the file passes 200 KB. Measured 2026-09-08: 150 of 718
// records over that size, and every click on one of them fell back to "just open Claude".
writeSession("local_fat", cli: "cli-fat", modified: Date(timeIntervalSince1970: 4_000),
             tail: ",\"enabledMcpTools\":{" + String(repeating: "\"tool\":true,", count: 30_000) + "\"z\":true}")

check(DesktopSessions.sessionID(forCLI: "cli-2", root: sessionsRoot) == "local_other",
      "a session id resolves through two directory levels")
// Importing a CLI session leaves a second record pointing at the same conversation; the one the
// app is actually showing is the most recent.
check(DesktopSessions.sessionID(forCLI: "cli-1", root: sessionsRoot) == "local_newer",
      "when two records claim one conversation, the newest wins")
check(DesktopSessions.sessionID(forCLI: "cli-fat", root: sessionsRoot) == "local_fat",
      "a record grown past 200 KB by the tool map still resolves")
check(DesktopSessions.sessionID(forCLI: "cli-3", root: sessionsRoot) == nil,
      "a conversation this machine never opened resolves to nothing")
check(DesktopSessions.sessionID(forCLI: "", root: sessionsRoot) == nil,
      "an empty id matches nothing rather than the first file on disk")
check(DesktopSessions.sessionID(forCLI: "cli-1", root: sessionsRoot + "missing/") == nil,
      "a missing sessions folder is answered, not crashed on")
// /code/ wants a bridge id a local conversation does not have; /resume is an import verb that
// spawns a duplicate record on every click. This route is the only one that focuses.
check(DesktopSessions.focusURL(sessionID: "local_x")?.absoluteString
        == "claude://claude.ai/epitaxy/local_x",
      "the focus link is the epitaxy route")

// The last word on whether the app is still needed. Counting hook-written session files answers
// that only when the hooks fired at all; on the evidence of an empty state.d the app quit about
// ten seconds after launch with Claude Code running in a terminal the whole time.
check(RunningProcesses.exists(named: ProcessInfo.processInfo.processName),
      "a process that is plainly running is found")
// This process is the NEWEST pid and sits at the head of the newest-first list, so the check
// above passed even when only a quarter of the table was walked (proc_listallpids returns a
// pid count, and dividing it by the pid width again cut the loop short). Membership of pid 1
// — the far end of that list — pins the wholeness. Membership, not exists(named: "launchd"):
// proc_name answers only for this user's processes, and pid 1 is root's, so the named lookup
// is blind to it however much of the table is walked.
check(RunningProcesses.allPids().contains(1),
      "pid 1, at the far end of the newest-first list, is in the walked table")
check(!RunningProcesses.exists(named: "ccb-no-such-process"),
      "and one that is not, is not")

// Int(Double) is a TRAPPING conversion — NaN or an out-of-range value crashes the process.
// The doubles fed to it come from JSON files on disk (limits.json, state.d/*.json): written
// sane by our own code, but a corrupted or hand-edited file must degrade to a wrong number,
// not a crash loop that the self-relaunch walks straight back into on every menu open.
check((9.9e30).clampedInt == Int.max, "an absurd timestamp clamps instead of trapping")
check((-9.9e30).clampedInt == Int.min, "and so does an absurdly negative one")
check(Double.nan.clampedInt == 0, "NaN reads as zero, not a crash")
check(Double.infinity.clampedInt == Int.max, "infinity clamps to the edge")
check((-Double.infinity).clampedInt == Int.min, "negative infinity clamps to the other edge")
check((42.9).clampedInt == 42, "a normal value truncates exactly like Int() always did")
check((-7.9).clampedInt == -7, "truncation toward zero holds for negatives too")

// The state files Session parses are written by the Node hooks and can be hand-edited or
// corrupted: every field of the wrong TYPE must degrade to its documented default, never trap —
// the hooks relaunch the app straight back into the same crash otherwise.
let mangled = Session(json: ["state": 5, "pid": "x", "ts": [], "pct": "z", "started": "yes",
                             "tokens": NSNull(), "window": false, "project": 7,
                             "cwd": [:], "transcript": 1.5, "cost": "free", "duration": [1],
                             "dirty": NSNull()], id: "mangled")
check(mangled.state == "idle" && mangled.pid == 0 && mangled.ts == 0,
      "wrong-typed state/pid/ts degrade to their defaults instead of trapping")
check(mangled.pct == nil && mangled.tokens == nil && !mangled.started,
      "wrong-typed optionals read as absent, not as garbage")
check(mangled.cost == nil && mangled.duration == nil && mangled.dirty == nil,
      "wrong-typed session totals read as absent too")
let totals = Session(json: ["cost": 0.42, "duration": 4500, "linesAdded": 48, "linesRemoved": 6,
                            "dirty": 1], id: "totals")
check(totals.cost == 0.42 && totals.duration == 4500 && totals.linesAdded == 48
      && totals.linesRemoved == 6 && totals.dirty == 1,
      "session totals parse from the state file")
check(mangled.project.isEmpty && mangled.cwd.isEmpty && mangled.transcript.isEmpty,
      "wrong-typed strings degrade to empty")

check(SessionFormat.prettyModel("claude-fable-5-1") == "Fable 5.1", "model id reads as a name")
check(SessionFormat.prettyModel("claude-opus-4-8-20260101") == "Opus 4.8",
      "a date suffix is not a version component")
check(SessionFormat.prettyModel("") == "" && SessionFormat.prettyModel("2-x") == "2-x",
      "an unrecognized id is shown as is, not mangled")
check(SessionFormat.compact(87_956) == "88k" && SessionFormat.compact(1_000_000) == "1M"
      && SessionFormat.compact(1_500_000) == "1.5M" && SessionFormat.compact(999) == "999",
      "token counts compact to a glanceable figure")
check(SessionFormat.elapsed(4500) == "1h 15m" && SessionFormat.elapsed(59) == "0m"
      && SessionFormat.elapsed(720) == "12m", "session wall time reads in minutes and hours")

// The session state machine — the logic behind every serious bug of the 0.7.x review, and
// untestable until it moved out of main.swift into SessionEngine.
let engine = SessionEngine()
let sessionsDir = NSTemporaryDirectory() + "ccb-sessions-test/"
try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

func makeSession(state: String, ts: Double, transcript: String = "") -> Session {
    Session(json: ["state": state, "ts": ts, "transcript": transcript, "pid": 1], id: "s")
}
func writeTranscript(_ name: String, lines: [String], mtime: Date? = nil) -> String {
    let path = sessionsDir + name
    try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    if let mtime { try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path) }
    return path
}
// The timestamp format real transcripts carry: fractional-second ISO-8601. A bare
// ISO8601DateFormatter writes WITHOUT fractions, which exercises only turnTimestamp's
// fallback parser — the primary branch (the one production hits) stayed untested and a
// probe proved these checks kept passing with that branch broken.
func turnRecord(ts: Double, content: String) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = iso.string(from: Date(timeIntervalSince1970: ts))
    return "{\"type\":\"user\",\"timestamp\":\"\(stamp)\",\"message\":{\"content\":\"\(content)\"}}"
}

let nowTs = Date().timeIntervalSince1970
check(engine.effectiveState(makeSession(state: "thinking", ts: nowTs - 10), now: nowTs) == "thinking",
      "fresh thinking stays thinking")
check(engine.effectiveState(makeSession(state: "tool", ts: nowTs - 10), now: nowTs) == "tool",
      "fresh tool stays tool")
check(engine.effectiveState(makeSession(state: "done", ts: nowTs), now: nowTs) == "idle",
      "done collapses to rest")
check(engine.effectiveState(makeSession(state: "permission", ts: nowTs - 1900), now: nowTs) == "idle",
      "a permission wait past its 30-minute cap idles out")
check(engine.effectiveState(makeSession(state: "permission", ts: nowTs - 1700), now: nowTs) == "permission",
      "and inside the cap it holds")

let codexFalsePermission = Session(json: ["provider": "codex", "state": "permission",
                                         "ts": nowTs, "pid": 1], id: "codex-false")
check(engine.effectiveState(codexFalsePermission, now: nowTs) == "idle",
      "a Codex PermissionRequest alone does not prove the user saw a prompt")

func codexLine(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": payload])
    return String(decoding: data, as: UTF8.self)
}
let questionArguments = #"{"questions":[{"title":"first"},{"title":"second"}]}"#
let questionCall = codexLine(["type": "function_call", "name": "request_user_input_async",
                              "call_id": "q1", "arguments": questionArguments])
let questionAccepted = codexLine(["type": "function_call_output", "call_id": "q1",
                                  "output": #"{"accepted":true}"#])
func codexQuestionReply(_ index: Int) -> String {
    let questionId = String(decoding: try! JSONSerialization.data(
        withJSONObject: ["request_user_input_async", "q1", index]), as: UTF8.self)
    let answer = String(decoding: try! JSONSerialization.data(
        withJSONObject: [["questionItemId": questionId, "answer": "yes"]]), as: UTF8.self)
    return codexLine(["type": "message", "role": "user", "content": [["type": "input_text",
        "text": "<send_user_message_question_reply>\n\(answer)\n</send_user_message_question_reply>"]]])
}
let codexQuestionPath = writeTranscript("codex-question.jsonl", lines: [questionCall, questionAccepted])
let codexQuestionSession = Session(json: ["provider": "codex", "state": "tool",
                                          "transcript": codexQuestionPath, "ts": nowTs,
                                          "pid": 1], id: "codex-question")
check(engine.effectiveState(codexQuestionSession, now: nowTs) == "permission",
      "an accepted Codex Question needs the user even while tools continue")
func appendCodexLine(_ line: String, to path: String) {
    let file = FileHandle(forWritingAtPath: path)!
    try! file.seekToEnd()
    try! file.write(contentsOf: Data(("\n" + line).utf8))
    try! file.close()
}
appendCodexLine(codexQuestionReply(0), to: codexQuestionPath)
check(engine.effectiveState(codexQuestionSession, now: nowTs) == "permission",
      "answering one of two questions leaves the other pending")
appendCodexLine(codexQuestionReply(1), to: codexQuestionPath)
check(engine.effectiveState(codexQuestionSession, now: nowTs) == "tool",
      "the Codex Question clears after all its answers arrive")
let completedQuestionPath = writeTranscript("codex-question-completed.jsonl", lines: [
    questionCall, questionAccepted, #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
])
let completedQuestionSession = Session(json: ["provider": "codex", "state": "done",
                                             "transcript": completedQuestionPath, "ts": nowTs,
                                             "pid": 1], id: "codex-completed")
check(engine.effectiveState(completedQuestionSession, now: nowTs) == "idle",
      "an unanswered async Question stops needing input when Codex ends the turn")

// The interrupt net: Esc / deny write a marker record but fire no hook.
let interrupted = writeTranscript("interrupted.jsonl", lines: [
    #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#,
])
check(engine.effectiveState(makeSession(state: "thinking", ts: nowTs - 10, transcript: interrupted),
                            now: nowTs) == "idle",
      "an interrupt marker idles a thinking session at once")

// The permission-answered net: a turn record younger than the prompt means the prompt is gone.
let promptTs = nowTs - 60
let answered = writeTranscript("answered.jsonl", lines: [turnRecord(ts: promptTs + 30, content: "denied")])
check(engine.effectiveState(makeSession(state: "permission", ts: promptTs, transcript: answered),
                            now: nowTs) == "idle",
      "a turn record younger than the prompt ends the permission wait")
let stale = writeTranscript("stale.jsonl", lines: [turnRecord(ts: promptTs - 30, content: "before")])
check(engine.effectiveState(makeSession(state: "permission", ts: promptTs, transcript: stale),
                            now: nowTs) == "permission",
      "a turn record older than the prompt does not end the wait")

// A long tool call is alive, not idle. The ts is stamped at PreToolUse and untouched until
// PostToolUse — there is no "still running" hook — so a flat 900s cap read a 20-minute build
// as an idle session and the stale-prune (same clock) hid its row while the tool worked.
// tool gets an hour: the interrupt net and the pid reap still catch dead ones far earlier
// in practice, and lying "idle" about a running build is the worse error.
check(engine.effectiveState(makeSession(state: "tool", ts: nowTs - 1200), now: nowTs) == "tool",
      "a 20-minute tool call is still a tool call, not idle")
check(engine.effectiveState(makeSession(state: "tool", ts: nowTs - 4000), now: nowTs) == "idle",
      "but past an hour even a tool call idles out")
check(engine.effectiveState(makeSession(state: "thinking", ts: nowTs - 1200), now: nowTs) == "idle",
      "thinking keeps the 15-minute cap — no stream for that long means stuck")
// A streaming transcript is proof of life: its mtime moves with every appended record.
let streaming = writeTranscript("streaming.jsonl", lines: [
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"still going"}]}}"#,
], mtime: Date(timeIntervalSince1970: nowTs - 30))
check(engine.effectiveState(makeSession(state: "thinking", ts: nowTs - 1200, transcript: streaming),
                            now: nowTs) == "thinking",
      "a thinking session whose transcript moved recently is alive past the cap")
let silent = writeTranscript("silent.jsonl", lines: [
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"long ago"}]}}"#,
], mtime: Date(timeIntervalSince1970: nowTs - 1100))
check(engine.effectiveState(makeSession(state: "thinking", ts: nowTs - 1200, transcript: silent),
                            now: nowTs) == "idle",
      "and one whose transcript went silent idles out as before")

// The js→swift seam, reader half: parse the state file the real update.js wrote during the
// node suite. Run the node suite first — CI does.
let sessionSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/session.json"
if !FileManager.default.fileExists(atPath: sessionSeamPath) {
    check(false, "session seam fixture missing at \(sessionSeamPath) — run the node suite first "
        + "(node --test tests/*.test.js), it writes build/seam/session.json")
} else if let data = FileManager.default.contents(atPath: sessionSeamPath),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    let parsed = Session(json: raw, id: raw["sessionId"] as? String ?? "?")
    check(parsed.state == "tool", "the state the hook wrote survives the js→swift trip")
    check(parsed.pid > 0, "the pid crosses over as a number")
    check(parsed.started, "real activity crosses over as started")
    check(parsed.pct != nil, "the measured context percentage crosses over")
    check(!parsed.transcript.isEmpty, "the transcript path crosses over")
    // The pin test writes the fixture from a repo-less sandbox with no status line record,
    // so both are null on disk — and null must read as absent, not as zero.
    check(parsed.dirty == nil && parsed.cost == nil,
          "null totals cross over as absent")
} else {
    check(false, "session seam fixture unreadable")
}

// MARK: Codex sessions — a second agent in the same list, told apart by one field

// An old state file has no provider at all and must keep reading as Claude's: the app keys its
// session map by "<provider>:<id>", and a nil-ish provider there would key every pre-upgrade
// session under ":<id>" and reap it from a directory that does not exist.
let claudeShaped = Session(json: ["state": "thinking", "pid": 4242], id: "old")
check(claudeShaped.provider == "claude", "a file without a provider is Claude's")
check(claudeShaped.surface.isEmpty, "and carries no surface")

let codexSession = Session(json: [
    "state": "tool", "label": "Running command", "provider": "codex", "surface": "ide",
    "model": "gpt-5.6-sol", "pid": 777, "ts": nowTs, "started": true,
    "pct": 21, "tokens": 41_420, "window": 200_000, "assumed": false,
], id: "c1")
check(codexSession.provider == "codex", "the provider crosses over")
check(codexSession.surface == "ide", "so does the surface")
check(codexSession.key == "codex:c1" && claudeShaped.key == "claude:old",
      "the map key carries the provider, so two agents' ids cannot collide: "
      + "\(codexSession.key) / \(claudeShaped.key)")
// The states are the same vocabulary for both agents, or every consumer of isWorkingState,
// priority(of:) and the icon renderer would need a second branch.
check(isWorkingState(codexSession.state) && isActiveState(codexSession.state),
      "a Codex session works and is active by the same words as Claude's")

// The badge. Codex's surface is a fact from its own rollout, Claude's is guessed from an
// entrypoint — so they are two paths to one pill, and an unknown Codex surface shows nothing
// rather than a wrong "CLI".
check(SessionFormat.surfaceTag(codexSession) == "IDE", "the Codex surface becomes its badge")

// Where a click on a Codex row lands. Its desktop app registers codex:// and spells one thread
// as codex://threads/<id>, so a desktop session can open the CONVERSATION rather than just the
// window — the same depth a Claude desktop row already gets.
let codexDesktop = Session(json: ["provider": "codex", "surface": "app"], id: "t-1")
check(SessionFormat.codexThreadURL(codexDesktop)?.absoluteString == "codex://threads/t-1",
      "a desktop Codex session opens its own thread: "
        + "\(SessionFormat.codexThreadURL(codexDesktop)?.absoluteString ?? "nil")")
// A terminal session is where the user left it — the deep link would drag them into a different
// app to read a conversation they are already looking at.
let codexCLI = Session(json: ["provider": "codex", "surface": "cli",
                              "term_bundle": "com.googlecode.iterm2"], id: "t-2")
check(SessionFormat.codexThreadURL(codexCLI) == nil, "a terminal Codex session keeps its terminal")
// Nothing known about where it runs. Tempting to call it a desktop session — it often is — but
// this build answers "unknown" for any originator it has not been taught, and a terminal session
// whose host left no trace would then be dragged into the desktop app to read what is already on
// screen in front of the user. Unknown stays unknown; the ordinary rules take the click.
let codexUnknown = Session(json: ["provider": "codex"], id: "t-3")
check(SessionFormat.codexThreadURL(codexUnknown) == nil,
      "an unplaceable Codex session is not assumed to be a desktop one")
check(SessionFormat.codexThreadURL(
        Session(json: ["provider": "codex", "surface": "app"], id: "")) == nil,
      "no id, no link — there is no thread to name")
check(SessionFormat.codexThreadURL(
        Session(json: ["provider": "claude", "surface": "app"], id: "t-4")) == nil,
      "and a Claude session never goes to Codex")
// An id is a path component: one with a slash in it would otherwise address a different route
// of the app entirely.
check(SessionFormat.codexThreadURL(
        Session(json: ["provider": "codex", "surface": "app"], id: "a/b?x"))?
        .absoluteString == "codex://threads/a%2Fb%3Fx",
      "an odd id is escaped rather than taken as a path")
check(SessionFormat.surfaceTag(Session(json: ["provider": "codex", "surface": "exec"], id: "x")) == "EXEC",
      "a non-interactive codex exec run says so")
check(SessionFormat.surfaceTag(Session(json: ["provider": "codex", "surface": ""], id: "x")).isEmpty,
      "an unnamed surface gets no badge instead of a guessed one")
check(SessionFormat.surfaceTag(Session(json: ["entrypoint": "claude-desktop"], id: "x")) == "APP",
      "Claude's own badges are untouched")

// MARK: the tty a click focuses — normalised, and refused when it is not a device name

check(SessionFormat.ttyDevice("/dev/ttys004") == "/dev/ttys004", "the hook's own spelling passes")
check(SessionFormat.ttyDevice("ttys004") == "/dev/ttys004",
      "and the bare name `ps` prints is completed, because the dictionaries compare full paths")
check(SessionFormat.ttyDevice("") == nil, "no terminal, nothing to focus")
// The string is interpolated into `if tty of t is "…"` in an AppleScript. A quote closes the
// literal and leaves the rest as script, and the state file is one a user is invited to read and
// can edit — so "our own hook wrote it" is not a guarantee about its contents.
check(SessionFormat.ttyDevice("/dev/ttys0\" then do shell script \"x\" end if --") == nil,
      "a quote does not reach the script")
check(SessionFormat.ttyDevice("/dev/pts/0") == nil, "and neither does a device that is not a tty")
check(SessionFormat.ttyDevice("/etc/passwd") == nil, "nor a path that is not a device at all")
check(SessionFormat.ttyDevice("/dev/tty" + String(repeating: "s", count: 200)) == nil,
      "an absurd length is refused rather than pasted into a script")
check(Session(json: ["tty": "/dev/ttys009"], id: "x").tty == "/dev/ttys009",
      "and the field crosses from the state file")
check(Session(json: [:], id: "x").tty.isEmpty, "a pre-upgrade file simply has none")

// MARK: the Codex turn-over net — the rollout says when a turn ended, so a missing hook cannot
// leave a row spinning

// A rollout envelope, in the shape Codex actually writes: the record's own ISO stamp on the
// outside, the event on the payload. Nothing here is a turn record by Claude's rules, which is
// the whole reason this net had to be written — see the premise check below.
func codexEvent(ts: Double, _ type: String, turn: String = "") -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = iso.string(from: Date(timeIntervalSince1970: ts))
    let id = turn.isEmpty ? "" : ",\"turn_id\":\"\(turn)\""
    return "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"\(id)}}"
}
func makeCodex(state: String, ts: Double, transcript: String, turn: String = "") -> Session {
    Session(json: ["state": state, "ts": ts, "transcript": transcript, "pid": 1,
                   "provider": "codex", "surface": "cli", "turn_id": turn], id: "c")
}

// The premise, pinned so it cannot quietly stop being true: Claude's parser finds NOTHING in a
// rollout line. That is why every net in the engine was dead for Codex — the parser was asked the
// question and honestly answered "no turn records here", for the whole life of the session.
let rolloutLine = codexEvent(ts: nowTs, "task_complete", turn: "t1")
check(!Transcript.isTurnRecord(rolloutLine) && Transcript.turnTimestamp(rolloutLine) == nil,
      "a Codex rollout line is not a Claude turn record and never was")
check(CodexRollout.boundary(rolloutLine)?.ends == true,
      "and the Codex parser reads the same line as the end of a turn")

let ended = writeTranscript("codex-ended.jsonl", lines: [
    codexEvent(ts: nowTs - 90, "task_started", turn: "t1"),
    codexEvent(ts: nowTs - 30, "task_complete", turn: "t1"),
])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60, transcript: ended, turn: "t1"),
                            now: nowTs) == "idle",
      "a finished turn idles the row even though Stop never arrived")
check(engine.effectiveState(makeCodex(state: "tool", ts: nowTs - 60, transcript: ended, turn: "t1"),
                            now: nowTs) == "idle",
      "the same for a tool state, whose cap is a whole hour away")
// The net that was dead outright: a denied permission fires no hook at all in Codex, and the
// amber dot outranks every other session in the menu bar while it is up.
check(engine.effectiveState(makeCodex(state: "permission", ts: nowTs - 60, transcript: ended, turn: "t1"),
                            now: nowTs) == "idle",
      "and a permission wait whose turn has ended stops being a wait")

// Still running: the newest boundary starts a turn, so the older completion says nothing about it.
let running = writeTranscript("codex-running.jsonl", lines: [
    codexEvent(ts: nowTs - 90, "task_complete", turn: "t1"),
    codexEvent(ts: nowTs - 30, "task_started", turn: "t2"),
])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 20, transcript: running, turn: "t2"),
                            now: nowTs) == "thinking",
      "a turn that has started and not ended keeps working")

// The id is what makes this exact. The previous turn's completion is newer than this turn's first
// hook whenever a prompt is sent inside the same second the last one finished in — the hook stamps
// whole seconds, the rollout milliseconds — so the clock alone would end a turn that just began.
let otherTurn = writeTranscript("codex-other-turn.jsonl", lines: [
    codexEvent(ts: nowTs - 10, "task_complete", turn: "t1"),
])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 20, transcript: otherTurn, turn: "t2"),
                            now: nowTs) == "thinking",
      "another turn's completion is not this turn's")

// No id on either side — an older Codex. The clock is all there is, and it takes no margin: a
// margin that swallowed the boundary would leave the row spinning for the whole cap.
let noID = writeTranscript("codex-no-id.jsonl", lines: [codexEvent(ts: nowTs - 30, "task_complete")])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60, transcript: noID),
                            now: nowTs) == "idle",
      "without ids a completion newer than the state ends the turn")
let noIDStale = writeTranscript("codex-no-id-stale.jsonl", lines: [codexEvent(ts: nowTs - 90, "task_complete")])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60, transcript: noIDStale),
                            now: nowTs) == "thinking",
      "and one older than the state does not")

// Esc, an error, a replaced turn: all arrive as turn_aborted, and all end the turn.
let aborted = writeTranscript("codex-aborted.jsonl", lines: [
    codexEvent(ts: nowTs - 90, "task_started", turn: "t1"),
    codexEvent(ts: nowTs - 30, "turn_aborted", turn: "t1"),
])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60, transcript: aborted, turn: "t1"),
                            now: nowTs) == "idle",
      "an aborted turn is an ended turn")

// Codex's newer tracing subsystem names the same boundary turn_started / turn_complete. Carrying
// both spellings costs one set lookup; not carrying them costs every user a fifteen-minute
// spinner on the release that renames them, silently.
let renamed = writeTranscript("codex-renamed.jsonl", lines: [
    codexEvent(ts: nowTs - 90, "turn_started", turn: "t1"),
    codexEvent(ts: nowTs - 30, "turn_complete", turn: "t1"),
])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60, transcript: renamed, turn: "t1"),
                            now: nowTs) == "idle",
      "the other spelling of the same boundary is read too")

// A tool result that QUOTES a boundary name is not one — and a Codex session working on this
// repository produces exactly that, because these names are written out in the sources.
let quoted = writeTranscript("codex-quoted.jsonl", lines: [
    codexEvent(ts: nowTs - 90, "task_started", turn: "t1"),
    "{\"timestamp\":\"x\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\","
      + "\"output\":\"grep found \\\"task_complete\\\" in Sessions.swift\"}}",
])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60, transcript: quoted, turn: "t1"),
                            now: nowTs) == "thinking",
      "a tool result naming a boundary does not end the turn")

// Claude keeps its own parser: a rollout-shaped line must not reach into a Claude session, or the
// two agents' formats start deciding each other's state.
let codexShapedForClaude = writeTranscript("claude-with-codex-line.jsonl", lines: [
    codexEvent(ts: nowTs - 10, "task_complete", turn: "t1"),
])
check(engine.effectiveState(makeSession(state: "thinking", ts: nowTs - 60,
                                        transcript: codexShapedForClaude), now: nowTs) == "thinking",
      "a Claude session is unmoved by a Codex boundary record")

// The js→swift seam for Codex, written by the real update.js during the node suite.
let codexSessionSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/codex-session.json"
if !FileManager.default.fileExists(atPath: codexSessionSeamPath) {
    check(false, "codex seam fixture missing at \(codexSessionSeamPath) — run the node suite first "
        + "(node --test tests/*.test.js), it writes build/seam/codex-session.json")
} else if let data = FileManager.default.contents(atPath: codexSessionSeamPath),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    let parsed = Session(json: raw, id: raw["sessionId"] as? String ?? "?")
    check(parsed.provider == "codex", "the provider the hook wrote survives the js→swift trip")
    check(parsed.surface == "ide", "the surface read from the rollout crosses over")
    check(parsed.label == "Editing", "a Codex tool name arrives as a word a person can read")
    check(parsed.pct == 21 && parsed.window == 200_000,
          "the context Codex itself reported crosses over: \(parsed.pct.map(String.init) ?? "nil")")
    check(!parsed.assumed, "and is not marked a guess, because Codex states the window")
    check(parsed.model == "gpt-5.6-sol", "the model crosses over from the payload")
    // Without this the turn-over net falls back to comparing a whole-second hook clock against a
    // millisecond rollout one, which is the one case it can get wrong.
    check(parsed.turnID == "turn-7", "the turn id the hook wrote survives the js→swift trip")
} else {
    check(false, "codex seam fixture unreadable")
}

try? FileManager.default.removeItem(atPath: sessionsDir)

// The python→swift seam. Everything above parses a fixture written BY HAND — the same schema
// pinned twice independently, so a coordinated key rename passed both suites while the menu
// silently emptied. This file is written by the real refresh() during the python suite
// (SeamContract copies it out); parsing it here is the only check that crosses the language
// border. Run the python suite first — CI does.
let seamPath = FileManager.default.currentDirectoryPath + "/build/seam/mcp.json"
if !FileManager.default.fileExists(atPath: seamPath) {
    check(false, "seam fixture missing at \(seamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/mcp.json")
} else {
    let seam = MCPModel(path: seamPath)
    check(seam.reloadIfChanged(), "the mcp.json the real refresh() wrote parses")
    let seamWiki = seam.servers.first { $0.name == "wiki" }
    check(seamWiki != nil, "a user server survives the python→swift trip")
    check(seamWiki?.tools.count == 3, "its tool list arrives whole")
    check(seamWiki?.tools.first { $0.name == "Delete" }?.enabled == false,
          "a deny rule python computed reads as a switched-off tool here")
    check(seamWiki?.tools.first { $0.name == "Read" }?.params.first?.required == true,
          "tool parameters survive the real writer, not just the hand fixture")
    check(seam.servers.first { $0.name == "claude.ai Figma" }?.toolPrefix == "b6d68fb1",
          "a connector's prefix is its uuid across the border — the deny rule depends on it")
    check(seam.servers.first { $0.name == "off-one" }?.disabled == true,
          "a server disabled in settings arrives disabled")
    check(seam.waitingAuth == ["needs-oauth"], "the waiting-for-auth list crosses over")
}

// The same border for Claude's limits.json, written by the real statusline.py during the python
// suite (LimitsWriters in tests/test_statusline.py, which also holds mcpbar.py to the same record).
let limitsSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/limits.json"
if let data = FileManager.default.contents(atPath: limitsSeamPath),
   let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    let seamLimits = Limits(json: root)
    check(seamLimits?.fiveHour == LimitWindow(used: 4, resets: 1_790_164_800),
          "a fractional percentage and an ISO reset arrive as numbers the app can read")
    check(seamLimits?.sevenDay?.used == 69, "the weekly window crosses over")
    check(seamLimits?.source == "statusline" && (seamLimits?.ts ?? 0) > 0,
          "the reserved keys stay the record's own, not windows")
} else {
    check(false, "limits seam fixture missing at \(limitsSeamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/limits.json")
}

// MARK: Changelog — the "What's new" source

let changelogFixture = """
# Changelog

Intro prose that belongs to no version.

## [0.7.4] - 2026-08-12

### Added

- **A first bullet.** Its continuation line,
  hard-wrapped like the real file writes them.
- A second bullet with `inline code`.

A closing paragraph
on two lines.

## [0.7.3] - 2026-08-07

### Fixed

- The last section runs to the end of the file.
"""

check(Changelog.section(for: "0.9.9", in: changelogFixture) == nil,
      "a version the changelog has never heard of is nil, not garbage")
let mid = Changelog.section(for: "0.7.4", in: changelogFixture)
check(mid?.hasPrefix("### Added") == true, "a section starts at its own first content line")
check(mid?.contains("0.7.3") == false, "a section stops at the next version header")
check(Changelog.section(for: "0.7.3", in: changelogFixture)?
        .contains("end of the file") == true, "the last section is bounded by EOF")

let blocks = Changelog.blocks(from: mid ?? "")
check(blocks.first == .heading("Added"), "### becomes a heading block, marker gone")
check(blocks.contains(.bullet("**A first bullet.** Its continuation line, hard-wrapped like the real file writes them.")),
      "a wrapped continuation line reflows into its bullet, inline markers intact")
check(blocks.contains(.bullet("A second bullet with `inline code`.")),
      "backticks ride through blocks for spans to resolve")
check(blocks.last == .paragraph("A closing paragraph on two lines."),
      "a plain paragraph reflows too")

check(Changelog.blocks(from: "- a bullet\r\n  wrapped over CRLF\r\n")
        == [.bullet("a bullet wrapped over CRLF")],
      "a GitHub release body's CRLF line endings reflow cleanly")

check(Changelog.date(for: "0.7.4", in: changelogFixture) == "2026-08-12",
      "the header's date half comes out alone")
check(Changelog.date(for: "0.9.9", in: changelogFixture) == nil,
      "no header, no date")

check(Changelog.spans(from: "**Lead.** Rest with `code`.") ==
        [.bold("Lead."), .plain(" Rest with "), .code("code"), .plain(".")],
      "bold lead and inline code split into styled runs")
check(Changelog.spans(from: "an ** unpaired marker") ==
        [.plain("an "), .plain("** unpaired marker")],
      "an unbalanced ** stays literal instead of bolding the rest of the text")
check(Changelog.spans(from: "odd ` tick") == [.plain("odd "), .plain("` tick")],
      "an unbalanced backtick stays literal too")
check(Changelog.spans(from: "**bold with `code` inside**") ==
        [.bold("bold with "), .code("code"), .bold(" inside")],
      "code nested in bold keeps both runs")

check(WhatsNewMenuSelection(currentIsUnseen: true, updateAvailable: true) == .latest,
      "an available update replaces the current-version notes instead of duplicating them")
check(WhatsNewMenuSelection(currentIsUnseen: true, updateAvailable: false) == .current,
      "current-version notes remain visible when there is no newer release")
check(WhatsNewMenuSelection(currentIsUnseen: false, updateAvailable: true) == .latest,
      "latest release notes remain visible after current-version notes were opened")
check(WhatsNewMenuSelection(currentIsUnseen: false, updateAvailable: false) == .none,
      "no release-notes row appears when neither version needs one")

// The shipped CHANGELOG.md must actually contain the version this source tree claims,
// or the row falls back to the release page for everyone: pin the contract here.
let repoRoot = FileManager.default.currentDirectoryPath
if let real = try? String(contentsOfFile: repoRoot + "/CHANGELOG.md", encoding: .utf8),
   let manifest = try? String(contentsOfFile: repoRoot + "/.claude-plugin/plugin.json", encoding: .utf8),
   let vRange = manifest.range(of: "\"version\": \""),
   let vEnd = manifest[vRange.upperBound...].firstIndex(of: "\"") {
    let want = String(manifest[vRange.upperBound..<vEnd])
    check(Changelog.section(for: want, in: real) != nil,
          "CHANGELOG.md carries a section for the manifest version \(want)")
}

// MARK: Gauge — the limit bars must be honest

// The measurable contract: fill width = round(percent × track width) in device pixels.
// The old formula floored the fill at barH (15% of the track), so 1% and 15% drew the same
// stub and the user read 18% as "almost empty".
// 1% is the one sanctioned deviation from pure rounding: round(0.01 × 40px) = 0, but the
// battery gauge never draws "empty" for a non-zero charge, so anything above zero keeps a
// one-device-pixel sliver.
for (pct, px) in [(0.01, 1.0), (0.05, 2.0), (0.18, 7.0), (0.50, 20.0), (0.95, 38.0), (1.00, 40.0)] {
    check(Gauge.fillWidth(pct) * 2 == CGFloat(px),
          "fillWidth(\(Int(pct * 100))%) is \(Gauge.fillWidth(pct) * 2)px, expected \(px)px")
}
check(Gauge.fillWidth(-0.5) == 0, "a negative value clamps to empty")
check(Gauge.fillWidth(3.0) == Gauge.barW, "an absurd value clamps to full")

// And the same width must survive the actual drawing code: rasterise image(icon:) at 2x and
// count the filled pixels along the bar's centre row. A pure function can be honest while the
// bezier path lies (that is exactly what happened).
func measuredFillPx(_ pct: Double) -> Int {
    let image = Gauge(fiveHour: pct, sevenDay: nil).image(icon: nil)
    let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return -1 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * 2, height: image.size.height * 2),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let barHeight = image.size.height
    let y0 = ((barHeight - Gauge.rowH) / 2).rounded()
    let barY = y0 + ((Gauge.rowH - Gauge.barH) / 2).rounded() + Gauge.barH / 2
    let row = h - 1 - Int(barY * 2)            // bitmap rows are top-down, the image is not
    let barX = Int((Gauge.sideInset + Gauge.labelW + Gauge.labelGap) * 2)
    var count = 0
    for x in barX..<(barX + Int(Gauge.barW * 2)) {
        guard let c = rep.colorAt(x: x, y: row) else { continue }
        if c.alphaComponent > 0.6 { count += 1 }
    }
    return count
}
for (pct, px) in [(0.05, 2), (0.18, 7), (0.50, 20), (0.95, 38), (1.00, 40)] {
    let got = measuredFillPx(pct)
    check(abs(got - px) <= 1,
          "drawn fill at \(Int(pct * 100))% is \(got)px of 40, expected \(px)±1 (antialiasing)")
}
let sliver = measuredFillPx(0.01)
check(sliver >= 1 && sliver <= 2, "1% draws a \(sliver)px sliver — visible, but nothing like the 15% stub")

let redIcon = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
    NSColor(deviceRed: 0.9, green: 0.1, blue: 0.05, alpha: 1).setFill(); rect.fill(); return true
}
redIcon.isTemplate = false
func renderedPixel(_ image: NSImage, at point: NSPoint, scale: CGFloat = 2) -> NSColor? {
    let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.colorAt(x: Int(point.x * scale), y: h - 1 - Int(point.y * scale))
}
let neutralGaugeWithRedIcon = Gauge(fiveHour: 0.50, sevenDay: nil).image(icon: redIcon)
check(!neutralGaugeWithRedIcon.isTemplate,
      "a full-colour icon keeps a neutral gauge composite out of template mode")
let criticalGaugeWithRedIcon = Gauge(fiveHour: 0.95, sevenDay: nil).image(icon: redIcon)
let preservedRed = renderedPixel(criticalGaugeWithRedIcon,
                                 at: NSPoint(x: Gauge.sideInset + 2, y: criticalGaugeWithRedIcon.size.height / 2))
check((preservedRed?.redComponent ?? 0) > 0.7 && (preservedRed?.greenComponent ?? 1) < 0.3,
      "a critical coloured gauge preserves the icon's own red pixels")

let badgeBase = NSImage(size: NSSize(width: 10, height: 18), flipped: false) { rect in
    NSColor(deviceRed: 0.15, green: 0.45, blue: 0.85, alpha: 1).setFill(); rect.fill(); return true
}
badgeBase.isTemplate = false
let badgeAmber = NSColor(deviceRed: 0.95, green: 0.73, blue: 0.18, alpha: 1)
let badgedIcon = attentionBadgeIcon(badgeBase, color: badgeAmber)
check(badgedIcon.size == NSSize(width: 12, height: 18),
      "the permission badge adds only a 2pt trailing gutter")
check(!badgedIcon.isTemplate, "a coloured permission badge makes the composite non-template")
check(crabHasPixel(badgedIcon) { $0.blueComponent > 0.7 && $0.redComponent < 0.3 },
      "the permission badge keeps the mascot pixels instead of replacing them")
check(crabHasPixel(badgedIcon) { $0.redComponent > 0.8 && $0.greenComponent > 0.55
    && $0.blueComponent < 0.35 }, "the permission badge contains visible amber pixels")
let gaugedBadge = Gauge(fiveHour: 0.50, sevenDay: nil).image(icon: badgedIcon)
check(crabHasPixel(gaugedBadge) { $0.redComponent > 0.8 && $0.greenComponent > 0.55
    && $0.blueComponent < 0.35 }, "a neutral usage gauge preserves the amber permission badge")
let templateBadgeBase = NSImage(size: NSSize(width: 10, height: 18), flipped: false) { rect in
    NSColor.black.setFill(); rect.fill(); return true
}
templateBadgeBase.isTemplate = true
let templateBadgedIcon = attentionBadgeIcon(templateBadgeBase, color: badgeAmber)
let templateMascotPixel = renderedPixel(templateBadgedIcon, at: NSPoint(x: 2, y: 9))
check((templateMascotPixel?.alphaComponent ?? 0) > 0.5,
      "the permission badge preserves a System-template mascot")

// MARK: Crab load — the mascot reflects work happening now, not merely open sessions

// The app half is several files now; the contract below is about the app as a whole.
let appSources = ((try? FileManager.default.contentsOfDirectory(atPath: repoRoot + "/Sources")) ?? [])
    .filter { $0.hasSuffix(".swift") }.sorted()
    .compactMap { try? String(contentsOfFile: repoRoot + "/Sources/" + $0, encoding: .utf8) }
if !appSources.isEmpty {
    let mainSource = appSources.joined(separator: "\n")
    check(mainSource.contains("var animStyle: MenuBarIcon = .crab"),
          "Crab is the default animation when no preference was saved")
    check(mainSource.contains("d.string(forKey: \"animStyle\")"),
          "a saved animation preference still overrides the Crab default")
    check(mainSource.contains("d.string(forKey: \"codexPetID\") ?? (petID.isEmpty"),
          "a Codex pet nobody has chosen follows whether pets are on at all")
    check(mainSource.contains("\"Needs you\"") && !mainSource.contains("Awaiting permission"),
          "permission uses the short Needs you status-bar label")
    check(mainSource.contains("badge: true") && !mainSource.contains("dot: true"),
          "permission renders a badge over the mascot instead of replacing it with a dot")
    check(mainSource.contains("CrabMood.display("),
          "the status-bar mood is selected with the permission-aware display model")
} else {
    check(false, "Sources/*.swift are readable for the presentation defaults contract")
}

check(CrabMood.forEffectiveStates([]) == .sleeping,
      "zero working sessions puts the crab to sleep")
check(CrabMood.forEffectiveStates(["thinking"]) == .cigar,
      "one working session lets the crab relax with a cigar")
check(CrabMood.forEffectiveStates(["thinking", "tool"]) == .walking,
      "two working sessions keep the original walk")
check(CrabMood.forEffectiveStates(["tool", "thinking", "tool"]) == .walking,
      "three working sessions still keep the original walk")
check(CrabMood.forEffectiveStates(["thinking", "tool", "thinking", "tool"]) == .overheated,
      "four working sessions make the crab overheat")
check(CrabMood.forEffectiveStates(Array(repeating: "tool", count: 5)) == .overheated,
      "five working sessions are still the sweating tier")
check(CrabMood.forEffectiveStates(Array(repeating: "thinking", count: 6)) == .onFire,
      "six working sessions set the crab's head on fire")
check(CrabMood.forEffectiveStates(Array(repeating: "tool", count: 20)) == .onFire,
      "the fire tier has no upper bound")
check(CrabMood.forEffectiveStates(["permission", "idle", "done", "unknown"]) == .sleeping,
      "permission and resting sessions do not count as work")
check(CrabMood.forEffectiveStates(["permission", "thinking", "idle"]) == .cigar,
      "a permission wait does not inflate one genuinely working session")
check(CrabMood.display(forEffectiveStates: [], leadState: "permission") == .waitingPermission,
      "permission selects the dedicated waiting cycle over sleep")
check(CrabMood.display(forEffectiveStates: ["thinking", "permission"], leadState: "permission")
        == .waitingPermission,
      "permission selects the waiting cycle over concurrent load")
check(CrabMood.display(forEffectiveStates: ["thinking"], leadState: "thinking") == .cigar,
      "clearing permission returns immediately to the load mood")
check(CrabMood.display(forEffectiveStates: Array(repeating: "tool", count: 6), leadState: "tool")
        == .onFire,
      "ordinary lead states still use the load scale")

check(CrabMood.sleeping.framesPerSecond == 2, "sleep runs at a quiet 2 FPS")
check(CrabMood.waitingPermission.framesPerSecond == 3, "permission waits at a readable 3 FPS")
check(CrabMood.cigar.framesPerSecond == 4, "cigar smoke runs at 4 FPS")
check(CrabMood.walking.framesPerSecond == 12.5, "the original walk keeps its 12.5 FPS")
check(CrabMood.overheated.framesPerSecond == 8, "sweating runs at 8 FPS")
check(CrabMood.onFire.framesPerSecond == 10, "fire flickers at 10 FPS")
check(!CrabMood.sleeping.keepsColorInSystem && !CrabMood.cigar.keepsColorInSystem
        && !CrabMood.walking.keepsColorInSystem && !CrabMood.waitingPermission.keepsColorInSystem,
      "ordinary moods continue to respect System colour")
check(CrabMood.overheated.keepsColorInSystem && CrabMood.onFire.keepsColorInSystem,
      "semantic red and fire stay coloured in System mode")

let walkingCrabFrames = clawdCrabFramePNGs.compactMap {
    Data(base64Encoded: $0).flatMap(NSImage.init(data:))
}
let crabFrameSet = CrabFrameSet(walking: walkingCrabFrames)
check(crabFrameSet.frames(for: .sleeping).count == 6, "sleep has six production frames")
check(crabFrameSet.frames(for: .waitingPermission).count == 8,
      "permission has eight production frames")
check(crabFrameSet.frames(for: .cigar).count == 8, "cigar has eight production frames")
check(crabFrameSet.frames(for: .walking).count == 20, "walking keeps all twenty source frames")
check(crabFrameSet.frames(for: .overheated).count == 12, "overheating has twelve production frames")
check(crabFrameSet.frames(for: .onFire).count == 12, "fire has twelve production frames")
check(crabFrameSet.frames(for: .walking).first !== walkingCrabFrames.first,
      "the ordinary walk is a shaded copy of the source, not the flat original")
check(CrabMood.walking.framesPerSecond(working: 2) < CrabMood.walking.framesPerSecond(working: 3)
        && CrabMood.walking.framesPerSecond(working: 3) == 12.5,
      "two sessions walk slower than three; three keep the original tempo")
check(CrabMood.overheated.framesPerSecond(working: 4) < CrabMood.overheated.framesPerSecond(working: 5),
      "the sweating crab pants faster with a fifth session")
check(CrabMood.onFire.framesPerSecond(working: 6) < CrabMood.onFire.framesPerSecond(working: 12)
        && CrabMood.onFire.framesPerSecond(working: 12) == CrabMood.onFire.framesPerSecond(working: 40),
      "fire flickers faster with more sessions, up to a cap")
check(CrabMood.sleeping.framesPerSecond(working: 0) == 2 && CrabMood.cigar.framesPerSecond(working: 1) == 4,
      "the quiet moods keep their tempo")

// MARK: Crab shading — three tones from one, and the redrawn patches match the shell

func crabLum(_ c: NSColor) -> CGFloat { 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent }
func crabIsOrangeFamily(_ c: NSColor) -> Bool { c.redComponent > c.greenComponent + 0.2 && c.greenComponent > c.blueComponent }
// The shell's top edge is lit and its bottom edge is in shadow, on the first walking frame:
// the shell top runs along y=3 for x in 10...40, the underside of the body along y=26.
if let walk0 = crabBitmap(crabFrameSet.frames(for: .walking)[0]),
   let top = walk0.colorAt(x: 20, y: 3), let mid = walk0.colorAt(x: 20, y: 12),
   let bottom = walk0.colorAt(x: 24, y: 26) {
    check(crabLum(top) > crabLum(mid) + 0.04, "the shell's top edge is a lighter tone than its middle")
    check(crabLum(bottom) < crabLum(mid) - 0.04, "the shell's underside is a darker tone than its middle")
    check(crabIsOrangeFamily(top) && crabIsOrangeFamily(bottom), "both tones stay in the orange family")
} else {
    check(false, "the first walking frame has the pixels the shading contract looks at")
}
check(crabFrameSet.frames(for: .walking)[0].isTemplate == false, "shaded frames stay full color")
// The redrawn eye patches used to be a different orange than the shell; now every non-ink pixel in
// the eye band of the sleeping frame is the shell's own tone family and no lighter than its top edge.
if let sleep0 = crabBitmap(crabFrameSet.frames(for: .sleeping)[0]) {   // declared before `sleepingFrames` below
    // The retired constant was #E28B6A; the source shell is #D97757 plus its own faint noise.
    var offTone = 0
    for y in 6...10 { for x in 13...38 {
        if let c = sleep0.colorAt(x: x, y: y), c.alphaComponent > 0.9,
           abs(c.redComponent - 226 / 255) < 0.01, abs(c.greenComponent - 139 / 255) < 0.01 { offTone += 1 }
    } }
    check(offTone == 0, "the sleeping face carries no patch of the old lighter orange where the eyes were redrawn (\(offTone) px)")
}
if let hot = crabBitmap(crabFrameSet.frames(for: .overheated)[0]), let t = hot.colorAt(x: 20, y: 3), let m = hot.colorAt(x: 20, y: 12) {
    check(crabLum(t) > crabLum(m) + 0.03 && t.redComponent > 0.8, "the red shell is shaded too, and stays red")
}

func crabBitmap(_ image: NSImage) -> NSBitmapImageRep? {
    image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
}
for mood in CrabMood.allCases {
    let frames = crabFrameSet.frames(for: mood)
    check(frames.allSatisfy { frame in
        guard let rep = crabBitmap(frame) else { return false }
        return rep.pixelsWide == 51 && rep.pixelsHigh == 36 && rep.hasAlpha
    }, "every \(mood.rawValue) frame is a transparent 51×36 bitmap")
}

func crabHasPixel(_ image: NSImage, where predicate: (NSColor) -> Bool) -> Bool {
    guard let rep = crabBitmap(image) else { return false }
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.alphaComponent > 0.5, predicate(color) { return true }
        }
    }
    return false
}
func crabPixelCount(_ image: NSImage, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>,
                    where predicate: (NSColor) -> Bool) -> Int {
    guard let rep = crabBitmap(image) else { return -1 }
    var count = 0
    for y in yRange {
        for x in xRange {
            if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5,
               predicate(color) { count += 1 }
        }
    }
    return count
}
func crabAlphaCount(_ image: NSImage, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>,
                    above threshold: CGFloat) -> Int {
    guard let rep = crabBitmap(image) else { return -1 }
    var count = 0
    for y in yRange {
        for x in xRange where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > threshold {
            count += 1
        }
    }
    return count
}
func crabAlphaDifference(_ lhs: NSImage, _ rhs: NSImage,
                         xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Int {
    guard let a = crabBitmap(lhs), let b = crabBitmap(rhs) else { return -1 }
    var count = 0
    for y in yRange {
        for x in xRange {
            let aOpaque = (a.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            let bOpaque = (b.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            if aOpaque != bOpaque { count += 1 }
        }
    }
    return count
}
func crabMissingBaseAlpha(_ base: NSImage, _ frame: NSImage,
                          xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Int {
    guard let baseRep = crabBitmap(base), let frameRep = crabBitmap(frame) else { return -1 }
    var count = 0
    for y in yRange {
        for x in xRange {
            let baseOpaque = (baseRep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            let frameOpaque = (frameRep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            if baseOpaque && !frameOpaque { count += 1 }
        }
    }
    return count
}
func crabTopY(_ image: NSImage, xRange: ClosedRange<Int>) -> Int? {
    guard let rep = crabBitmap(image) else { return nil }
    for y in 0..<rep.pixelsHigh {
        if xRange.contains(where: { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.5 }) {
            return y
        }
    }
    return nil
}
func crabLeftEyeX(_ image: NSImage) -> Int? {
    guard let rep = crabBitmap(image) else { return nil }
    for x in 8...25 {
        for y in 5...16 {
            guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
            let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent
                + 0.114 * color.blueComponent
            if luminance < 0.15 { return x }
        }
    }
    return nil
}
func crabEffectYRange(_ frames: [NSImage], where predicate: (NSColor) -> Bool) -> Int {
    var ys: [Int] = []
    for frame in frames {
        guard let rep = crabBitmap(frame) else { continue }
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5,
                   predicate(color) { ys.append(y) }
            }
        }
    }
    guard let low = ys.min(), let high = ys.max() else { return -1 }
    return high - low
}
let sleepingBodyTops = crabFrameSet.frames(for: .sleeping).compactMap {
    crabTopY($0, xRange: 20...29)
}
check((sleepingBodyTops.max() ?? 0) - (sleepingBodyTops.min() ?? 0) >= 2,
      "sleep has at least 2px between its connected breathing key poses")
check(crabEffectYRange(crabFrameSet.frames(for: .cigar)) { color in
    abs(color.redComponent - color.greenComponent) < 0.08
        && abs(color.greenComponent - color.blueComponent) < 0.08
        && color.redComponent > 0.5
} >= 9, "the cigar smoke travels a clear vertical arc")
check(crabEffectYRange(crabFrameSet.frames(for: .overheated)) { color in
    color.blueComponent > color.redComponent + 0.3 && color.blueComponent > 0.8
} >= 12, "overheated sweat visibly falls instead of blinking in place")
let fireTopRange = crabFrameSet.frames(for: .onFire).compactMap { frame -> Int? in
    guard let rep = crabBitmap(frame) else { return nil }
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5,
               color.redComponent > 0.9, color.greenComponent > 0.4,
               color.blueComponent < 0.2 { return y }
        }
    }
    return nil
}
check((fireTopRange.max() ?? 0) - (fireTopRange.min() ?? 0) >= 4,
      "fire key poses have a clearly different flame height")
let permissionFrames = crabFrameSet.frames(for: .waitingPermission)
let permissionEyePositions = permissionFrames.compactMap(crabLeftEyeX)
check((permissionEyePositions.max() ?? 0) - (permissionEyePositions.min() ?? 0) >= 2,
      "permission moves its gaze between the watch and the screen")
check(permissionFrames.allSatisfy { frame in
    crabPixelCount(frame, xRange: 2...9, yRange: 11...20) { color in
        abs(color.redComponent - color.greenComponent) < 0.08
            && abs(color.greenComponent - color.blueComponent) < 0.08
            && color.redComponent > 0.45
    } >= 6
}, "the watch remains visible throughout the permission cycle")
func crabPixelDifference(_ lhs: NSImage, _ rhs: NSImage,
                         xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Int {
    guard let a = crabBitmap(lhs), let b = crabBitmap(rhs) else { return -1 }
    var count = 0
    for y in yRange {
        for x in xRange {
            let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            if abs((ca?.redComponent ?? 0) - (cb?.redComponent ?? 0)) > 0.05
                || abs((ca?.greenComponent ?? 0) - (cb?.greenComponent ?? 0)) > 0.05
                || abs((ca?.blueComponent ?? 0) - (cb?.blueComponent ?? 0)) > 0.05
                || abs((ca?.alphaComponent ?? 0) - (cb?.alphaComponent ?? 0)) > 0.05 {
                count += 1
            }
        }
    }
    return count
}
func crabIsInk(_ image: NSImage, x: Int, y: Int) -> Bool {
    guard let color = crabBitmap(image)?.colorAt(x: x, y: y), color.alphaComponent > 0.5 else {
        return false
    }
    return 0.299 * color.redComponent + 0.587 * color.greenComponent
        + 0.114 * color.blueComponent < 0.15
}
let restingCrab = walkingCrabFrames[0]
let sleepingFrames = crabFrameSet.frames(for: .sleeping)
let footRanges = [9...12, 17...20, 30...33, 38...41]
for mood in [CrabMood.sleeping, .waitingPermission, .cigar, .overheated, .onFire] {
    check(crabFrameSet.frames(for: mood).allSatisfy { frame in
        footRanges.allSatisfy {
            crabAlphaDifference(restingCrab, frame, xRange: $0, yRange: 27...35) == 0
        }
    }, "\(mood.rawValue) keeps all four feet planted while the acting happens above them")
}
for mood in [CrabMood.sleeping, .waitingPermission, .cigar, .overheated, .onFire] {
    let frames = crabFrameSet.frames(for: mood)
    check(frames.allSatisfy { frame in
        crabMissingBaseAlpha(frames[0], frame, xRange: 7...8, yRange: 11...18) == 0
            && crabMissingBaseAlpha(frames[0], frame,
                                    xRange: 42...43, yRange: 11...18) == 0
    }, "\(mood.rawValue) keeps both claw hinges attached to the shell")
}
check(crabAlphaDifference(permissionFrames[0], permissionFrames[3],
                          xRange: 0...8, yRange: 9...20) >= 6,
      "permission visibly raises the sign claw")
check(crabAlphaDifference(permissionFrames[0], permissionFrames[3],
                          xRange: 42...50, yRange: 9...20) == 0,
      "permission leaves the opposite claw still while holding up the sign")
check(permissionFrames.allSatisfy { frame in
    crabPixelCount(frame, xRange: 0...9, yRange: 6...20) { $0.alphaComponent > 0.9 && crabLum($0) > 0.8 } >= 30
}, "every permission frame holds up a light sign plate")
check(permissionFrames.allSatisfy { frame in
    crabPixelCount(frame, xRange: 0...9, yRange: 6...20) {
        $0.alphaComponent > 0.9 && (crabLum($0) < 0.15 || ($0.redComponent > 0.9 && $0.greenComponent < 0.5))
    } >= 9
}, "the plate carries a readable question mark, in ink or pulsing ember")
let cigarFrames = crabFrameSet.frames(for: .cigar)
check(sleepingFrames.allSatisfy {
    crabMissingBaseAlpha(sleepingFrames[0], $0, xRange: 9...41, yRange: 3...26) == 0
}, "sleeping deforms the head without cutting pixels out of the connected shell")
check(cigarFrames.allSatisfy {
    crabMissingBaseAlpha(cigarFrames[0], $0, xRange: 9...41, yRange: 3...26) == 0
}, "the cigar pose deforms the head without cutting it away from the body")
check(crabAlphaDifference(cigarFrames[0], cigarFrames[3],
                          xRange: 42...50, yRange: 9...20) >= 4,
      "the cigar action lifts the cigar-side claw")
check(crabAlphaDifference(cigarFrames[0], cigarFrames[3],
                          xRange: 0...8, yRange: 9...20) == 0,
      "the cigar action keeps the opposite claw relaxed")
let overheatedFrames = crabFrameSet.frames(for: .overheated)
check(overheatedFrames.allSatisfy {
    crabMissingBaseAlpha(overheatedFrames[0], $0, xRange: 9...41, yRange: 3...26) == 0
}, "overheating keeps one unbroken shell while the head stretches")
check(crabPixelDifference(overheatedFrames[0], overheatedFrames[3],
                          xRange: 9...41, yRange: 3...24) >= 20,
      "overheating stretches the upper body through a visible panting action")
let fireFrames = crabFrameSet.frames(for: .onFire)
check(fireFrames.allSatisfy {
    crabMissingBaseAlpha(fireFrames[0], $0, xRange: 9...41, yRange: 3...26) == 0
}, "fire panic keeps one unbroken shell while the head stretches")
check(crabAlphaDifference(fireFrames[0], fireFrames[2],
                          xRange: 0...8, yRange: 9...20) >= 12
        && crabAlphaDifference(fireFrames[0], fireFrames[3],
                               xRange: 42...50, yRange: 9...20) >= 12,
      "fire panic flails the claws on alternating action frames")
check(crabPixelDifference(cigarFrames[0], sleepingFrames[0],
                          xRange: 13...37, yRange: 6...10) >= 4,
      "the cigar mood wears an asymmetric smug squint instead of the sleeping face")
check(crabPixelCount(overheatedFrames[3], xRange: 22...28, yRange: 11...18) { color in
    0.299 * color.redComponent + 0.587 * color.greenComponent
        + 0.114 * color.blueComponent < 0.15
} >= 8, "overheating opens a clearly readable panting mouth on its heave frame")
let angryEyeInk = [
    (13, 7), (14, 7), (15, 8), (16, 8), (13, 9), (14, 9),
    (36, 7), (37, 7), (34, 8), (35, 8), (36, 9), (37, 9),
]
let angryEyeGaps = [(15, 7), (13, 8), (34, 7), (36, 8)]
check(angryEyeInk.allSatisfy { crabIsInk(fireFrames[0], x: $0.0, y: $0.1) }
        && angryEyeGaps.allSatisfy { !crabIsInk(fireFrames[0], x: $0.0, y: $0.1) },
      "fire anger draws unmistakable >< eye silhouettes")
check([2, 3].allSatisfy { frameIndex in
    angryEyeInk.allSatisfy {
        crabIsInk(fireFrames[frameIndex], x: $0.0, y: $0.1 - 3)
    }
}, "fire keeps the >< eyes readable through its strongest action frames")
check(crabPixelCount(fireFrames[0], xRange: 22...28, yRange: 13...18) { color in
    color.redComponent > 0.75 && color.greenComponent > 0.75 && color.blueComponent > 0.7
} >= 4, "fire anger shows bright clenched teeth inside a dark mouth")
check(crabPixelDifference(overheatedFrames[0], fireFrames[0],
                          xRange: 13...37, yRange: 6...18) >= 12,
      "overheating and fire remain distinct emotions even without sweat and flames")
check(crabAlphaDifference(crabFrameSet.frames(for: .sleeping)[0],
                          crabFrameSet.frames(for: .sleeping)[1],
                          xRange: 0...50, yRange: 3...35) == 0
        && crabAlphaDifference(permissionFrames[0], permissionFrames[1],
                               xRange: 0...50, yRange: 3...35) == 0
        && crabAlphaDifference(cigarFrames[0], cigarFrames[1],
                               xRange: 0...50, yRange: 3...35) == 0
        && crabAlphaDifference(overheatedFrames[0], overheatedFrames[1],
                               xRange: 0...50, yRange: 3...35) == 0
        && crabAlphaDifference(fireFrames[6], fireFrames[7],
                               xRange: 0...50, yRange: 3...35) == 0,
      "each mood includes a readable hold between its action phases")
check(crabAlphaDifference(permissionFrames[0], permissionFrames[7],
                          xRange: 0...50, yRange: 3...35) == 0,
      "permission recovers to its resting pose before the loop closes")
check(crabAlphaDifference(cigarFrames[0], cigarFrames[7],
                          xRange: 0...40, yRange: 3...35) == 0,
      "the cigar-side action recovers while the last smoke drifts away")
check(crabAlphaDifference(overheatedFrames[0], overheatedFrames[11],
                          xRange: 9...41, yRange: 3...35) == 0,
      "overheating closes the panting loop in its resting body pose")
check(crabAlphaDifference(fireFrames[0], fireFrames[11],
                          xRange: 0...50, yRange: 6...35) == 0,
      "fire recovers the body before the low-flame loop restarts")
check(crabPixelDifference(permissionFrames[3], permissionFrames[4],
                          xRange: 2...9, yRange: 11...20) >= 1,
      "the watch hand advances during the waiting hold")
let systemPermission = adaptiveCrabFrame(permissionFrames[3])
check(crabAlphaCount(systemPermission, xRange: 2...9, yRange: 11...20, above: 0.2) >= 6,
      "the watch remains visible in System colour")
let sleepingFirst = crabFrameSet.frames(for: .sleeping)[0]
check(crabPixelCount(sleepingFirst, xRange: 13...37, yRange: 8...8) { color in
    0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent < 0.45
} == 0, "sleep clears the old eye shadow above its closed slits")
check(crabFrameSet.frames(for: .cigar).contains { frame in
    crabHasPixel(frame) { $0.redComponent > 0.25 && $0.greenComponent > 0.15
        && $0.redComponent > $0.greenComponent * 1.2 && $0.blueComponent < 0.15 }
}, "the cigar cycle contains a visible brown cigar")
let systemCigar = adaptiveCrabFrame(crabFrameSet.frames(for: .cigar)[0])
check(crabAlphaCount(systemCigar, xRange: 40...48, yRange: 14...16, above: 0.2) >= 12,
      "the cigar remains a visible template stroke in System colour")
check(crabFrameSet.frames(for: .overheated).allSatisfy { frame in
    crabHasPixel(frame) { $0.redComponent > 0.75 && $0.greenComponent < 0.35 }
}, "every overheated frame visibly reddens the crab")
check(crabFrameSet.frames(for: .onFire).allSatisfy { frame in
    crabHasPixel(frame) { $0.redComponent > 0.9 && $0.greenComponent > 0.45
        && $0.blueComponent < 0.2 }
}, "every fire frame contains a hot orange or yellow flame pixel")
check(crabFrameSet.frames(for: .onFire).allSatisfy { frame in
    crabPixelCount(frame, xRange: 0...50, yRange: 5...5) { color in
        color.redComponent > 0.9 && color.greenComponent > 0.4 && color.blueComponent < 0.2
    } >= 12
}, "the flames join the shell instead of floating above a dark seam")

// MARK: Update feed — the DMG the one-click update installs, and what proves it is intact

let releaseFixture: [String: Any] = [
    "tag_name": "v0.8.0", "body": "### Fixed\n- a thing",
    "assets": [
        ["name": "SHA256SUMS", "browser_download_url": "https://x/SHA256SUMS", "size": 90],
        ["name": "claude-control-bar.dmg",
         "browser_download_url": "https://github.com/x/releases/download/v0.8.0/claude-control-bar.dmg",
         "size": 1_236_911,
         "digest": "sha256:72a5efc5ab509cc7184926b797dd9e0ed2367dea2391469d2495bed40397918a"],
    ],
]
let asset = UpdateFeed.dmgAsset(in: releaseFixture)
check(asset?.url.absoluteString.hasSuffix("/claude-control-bar.dmg") == true,
      "the .dmg asset is picked over the checksum file")
check(asset?.size == 1_236_911, "the advertised size rides along: \(asset?.size ?? -1)")
check(asset?.sha256 == "72a5efc5ab509cc7184926b797dd9e0ed2367dea2391469d2495bed40397918a",
      "the digest loses its sha256: prefix")
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "src.tar.gz", "browser_download_url": "https://x/a", "size": 1]]]) == nil,
      "a release without a DMG offers no asset")
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": "https://x/a.dmg", "size": 5]]])?.sha256 == nil,
      "a release that carries no digest still installs, without the checksum")
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": "https://x/a.dmg"]]]) == nil,
      "a size-less asset is refused: without it a truncated download cannot be told apart")
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": "https://x/a.dmg",
                                           "size": 5, "digest": "md5:abc"]]])?.sha256 == nil,
      "a digest of another algorithm is not mistaken for sha256")
// The asset survives the round trip through UserDefaults the way the daily check stores it.
let stored = asset!.dictionary
check(UpdateFeed.ReleaseAsset(dictionary: stored) == asset, "asset survives its dictionary round trip")
check(UpdateFeed.ReleaseAsset(dictionary: ["url": "https://x/a.dmg", "size": 7]) != nil,
      "a stored asset without a digest reads back")
check(UpdateFeed.ReleaseAsset(dictionary: ["url": "", "size": 7]) == nil, "an empty stored url is refused")
check(UpdateFeed.ReleaseAsset(dictionary: ["url": "https://x/a.dmg", "size": 0]) == nil, "a zero size is refused")
check(UpdateFeed.sha256Hex(of: Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "sha256 matches the reference vector for \"abc\"")
let dmgTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccb-asset-test.dmg")
try! Data("abc".utf8).write(to: dmgTmp)
let good = UpdateFeed.ReleaseAsset(url: URL(string: "https://x/a.dmg")!, size: 3,
    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check(UpdateFeed.verify(file: dmgTmp, against: good) == nil, "a download of the right size and digest verifies")
check(UpdateFeed.verify(file: dmgTmp, against: UpdateFeed.ReleaseAsset(url: good.url, size: 4, sha256: good.sha256)) != nil,
      "a size mismatch is refused before hashing")
check(UpdateFeed.verify(file: dmgTmp, against: UpdateFeed.ReleaseAsset(url: good.url, size: 3, sha256: "00")) != nil,
      "a digest mismatch is refused")
check(UpdateFeed.verify(file: dmgTmp, against: UpdateFeed.ReleaseAsset(url: good.url, size: 3, sha256: nil)) == nil,
      "no digest advertised: the size check alone stands")
try? FileManager.default.removeItem(at: dmgTmp)

// A check that found no release says why, on the About page, instead of nothing.
let rateLimited = UpdateFeed.checkProblem(status: 403, answer: [
    "message": "API rate limit exceeded for 203.0.113.7. (But here's the good news: Authenticated "
        + "requests get a higher rate limit. Check out the documentation for more details.)",
    "documentation_url": "https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting",
], error: nil)
check(rateLimited.contains("60"), "a rate-limit refusal names GitHub's hourly allowance: \(rateLimited)")
check(!rateLimited.contains("203.0.113.7"),
      "the refusal does not carry the address GitHub saw into a text meant for bug reports")
let offline = UpdateFeed.checkProblem(status: 0, answer: nil, error: URLError(.notConnectedToInternet))
check(offline.contains(URLError(.notConnectedToInternet).localizedDescription),
      "a request that never got an answer says what the system said: \(offline)")
let notFound = UpdateFeed.checkProblem(status: 404, answer: ["message": "Not Found"], error: nil)
check(notFound.contains("404") && notFound.contains("Not Found"),
      "any other refusal keeps its status and GitHub's own words: \(notFound)")
let noTag = UpdateFeed.checkProblem(status: 200, answer: ["name": "x"], error: nil)
check(!noTag.isEmpty && !noTag.localizedCaseInsensitiveContains("rate limit"),
      "an answer without a release in it is reported as that: \(noTag)")

// MARK: Needs-you sound — one cue per prompt, and none when the prompt is already on screen

check(NeedsYouSound.shouldCue(prevState: "tool", effective: "permission",
                              hostBundle: "com.apple.Terminal", frontmost: "com.apple.Safari"),
      "a session entering permission behind another app cues")
check(NeedsYouSound.shouldCue(prevState: "tool", effective: "permission",
                              hostBundle: "com.apple.Terminal", frontmost: "com.apple.Safari"),
      "a pending Codex Question cues even while the raw hook state says tool")
check(!NeedsYouSound.shouldCue(prevState: "permission", effective: "permission",
                               hostBundle: "com.apple.Terminal", frontmost: "com.apple.Safari"),
      "a session still waiting does not cue again on the next tick")
check(!NeedsYouSound.shouldCue(prevState: "tool", effective: "permission",
                               hostBundle: "com.apple.Terminal", frontmost: "com.apple.Terminal"),
      "no cue when the hosting terminal is the frontmost app — the prompt is already on screen")
check(NeedsYouSound.shouldCue(prevState: "tool", effective: "permission",
                              hostBundle: "", frontmost: "com.apple.Terminal"),
      "an unknown host (ssh, pre-upgrade file) always cues rather than guessing")
check(!NeedsYouSound.shouldCue(prevState: nil, effective: "idle",
                               hostBundle: "", frontmost: nil),
      "a stale permission file read at launch is silent: its effective state is idle")
check(NeedsYouSound.shouldCue(prevState: nil, effective: "permission",
                              hostBundle: "", frontmost: nil),
      "a session first seen already waiting cues once")
check(!NeedsYouSound.shouldCue(prevState: "tool", effective: "thinking",
                               hostBundle: "", frontmost: nil),
      "only the permission state cues")
check(NeedsYouSound.choices.contains(NeedsYouSound.defaultChoice), "the default is one of the choices")
check(NeedsYouSound.choices.allSatisfy { NSSound(named: NSSound.Name($0)) != nil },
      "every offered sound loads by name — the way the app plays it")

try? FileManager.default.removeItem(atPath: dir)
try? FileManager.default.removeItem(atPath: sessionsRoot)

// MARK: Limits — the third window is Fable's, and it is optional
// limits.json is written by two scripts that copy the endpoint's keys through untouched; the
// Fable window arrives as seven_day_fable beside seven_day_opus and friends. It is a row of its
// own in the menu, so the parse must find it, must survive its absence, and must not be fooled
// by the fractional percentage the writers are supposed to have rounded.
// Nested literals are typed explicitly: an untyped ["used_percentage": 42, "resets_at": 1.0]
// infers [String: Double] and turns 42 into 42.0, which `as? Int` rightly refuses — the very
// case the fractional check below covers, but not the one this fixture is about.
let fullLimits = Limits(json: [
    "ts": 1_785_000_000.0, "source": "oauth",
    "five_hour": ["used_percentage": 42, "resets_at": 1_785_003_600.0] as [String: Any],
    "seven_day": ["used_percentage": 71, "resets_at": 1_785_400_000.0] as [String: Any],
    "seven_day_opus": ["used_percentage": 9] as [String: Any],
    "seven_day_fable": ["used_percentage": 17, "resets_at": 1_785_400_000.0] as [String: Any],
])
check(fullLimits?.fiveHour?.used == 42 && fullLimits?.sevenDay?.used == 71,
      "the account windows read as before")
check(fullLimits?.fable?.used == 17, "seven_day_fable is the Fable window")
check(fullLimits?.fable?.resets == 1_785_400_000.0, "the Fable window keeps its reset time")
check(fullLimits?.fable?.fraction == 0.17, "the fraction feeds the same gauge maths as the bars")
check(fullLimits?.source == "oauth" && fullLimits?.ts == 1_785_000_000.0, "source and stamp survive")

let noFable = Limits(json: ["ts": 1.0, "five_hour": ["used_percentage": 3]])
check(noFable?.fable == nil && noFable?.isEmpty == false, "a plan without Fable has no Fable row")
check(Limits(json: ["ts": 1.0, "source": "statusline"]) == nil, "a file with no window is no data")

// A renamed window keeps the row; a served-up spelling other than the canonical one is still
// the same limit, and dropping it would look like the plan lost the model.
check(Limits.fableKey(in: ["seven_day", "weekly_fable"]) == "weekly_fable",
      "another key carrying the model's name is the fallback")
check(Limits.fableKey(in: ["seven_day_fable", "fable_beta"]) == "seven_day_fable",
      "the canonical key wins over other matches")
check(Limits.fableKey(in: ["seven_day", "five_hour"]) == nil, "no key, no window")
// An extra window under a codename is not Fable: the row must stay away rather than show a
// number that belongs to something else.
let codename = Limits(json: ["ts": 1.0, "source": "oauth",
                             "five_hour": ["used_percentage": 6] as [String: Any],
                             "seven_day": ["used_percentage": 60] as [String: Any],
                             "nimbus_quill": ["used_percentage": 0, "resets_at": NSNull()] as [String: Any]])
check(codename?.fable == nil && codename?.sevenDay?.used == 60,
      "a codename window is not mistaken for the Fable row")

// hooks/statusline.py rounds on the way in; a writer that forgets must not make the row vanish
// with the rest of the file still readable — and must not crash on it either.
let fractional = Limits(json: ["ts": 1.0, "seven_day_fable": ["used_percentage": 4.2] as [String: Any],
                               "five_hour": ["used_percentage": 5] as [String: Any]])
check(fractional?.fable == nil && fractional?.fiveHour?.used == 5,
      "a fractional Fable figure drops that window alone")

// The anonymous ping. The whole point is what it cannot do: line two pings up into a history.
let day: TimeInterval = 24 * 3600
let ping = AnalyticsPing.payload(version: "0.13.0", osMajor: 15, arch: "arm64", channel: "brew")
check(Set(ping.keys) == ["v", "app", "os", "arch", "channel"],
      "the payload has exactly the five documented fields: \(ping.keys.sorted())")
check((ping["os"] as? String) == "15" && (ping["v"] as? Int) == 1, "major OS version and schema ride as documented")
check(ping.values.allSatisfy { $0 is String || $0 is Int }, "no nested values, nothing that could carry an id")
check(AnalyticsPing.channel(brewManaged: true, ownerChannel: "plugin") == "brew",
      "Homebrew's Caskroom wins over owner.json")
check(AnalyticsPing.channel(brewManaged: false, ownerChannel: "plugin") == "plugin", "plugin channel from owner.json")
check(AnalyticsPing.channel(brewManaged: false, ownerChannel: nil) == "dmg", "no owner.json reads as a DMG install")
check(AnalyticsPing.channel(brewManaged: false, ownerChannel: "app") == "dmg", "the installer's own 'app' is the DMG channel")
// Notice first, ping a day later, then one a day — and never without the notice.
check(!AnalyticsPing.due(now: 10 * day, lastAttempt: nil, noticedAt: nil), "no notice, no ping")
check(!AnalyticsPing.due(now: 10 * day, lastAttempt: nil, noticedAt: 9.5 * day), "a ping within a day of the notice is refused")
check(AnalyticsPing.due(now: 10 * day, lastAttempt: nil, noticedAt: 9 * day), "the first ping is due a day after the notice")
check(!AnalyticsPing.due(now: 10 * day, lastAttempt: 9.5 * day, noticedAt: 1), "one attempt per day")
check(AnalyticsPing.due(now: 10 * day, lastAttempt: 9 * day, noticedAt: 1), "and the next one a day later")
check(!AnalyticsPing.configured || AnalyticsPing.endpoint.hasPrefix("https://"),
      "a configured endpoint is https or it is nothing")
check(["arm64", "x86_64", "other"].contains(AnalyticsPing.arch), "arch is one of three words")

// MARK: LimitsSet — one shape for two providers, and one place that decides "this is stale"

// Claude's three windows, named once in the model rather than in the panel: the strip, the text
// dump and the tooltip all read these words, and three spellings of "5 hours" drift.
let claudeSet = Limits(json: [
    "ts": 1_785_000_000.0, "source": "oauth",
    "five_hour": ["used_percentage": 42, "resets_at": 1_785_003_600.0] as [String: Any],
    "seven_day": ["used_percentage": 71] as [String: Any],
    "seven_day_fable": ["used_percentage": 17] as [String: Any],
])!.set
check(claudeSet.provider == "claude", "the Claude file lands in the shared shape")
check(claudeSet.windows.map { $0.title } == ["5 hours", "7 days", "Fable"],
      "account windows first, the model's own window last: \(claudeSet.windows.map { $0.title })")
check(claudeSet.windows.last?.badge == "7d", "only Fable carries a badge")
check(claudeSet.windows.first?.badge == nil, "and the account's own windows do not")
check(!claudeSet.isSnapshot, "a polled source is not a snapshot")
// The one rule this whole type exists for. A percentage measured before a reset is about a
// window that no longer exists, and the reset stamp sits in the same record — so the figure is
// not redrawn as if it were current. It reads as empty, which is what a reset means: the
// window rolled over and nothing has been measured against the new one yet.
check(claudeSet.drawable(at: 1_785_000_060).map { $0.window.used } == [42, 71, 17],
      "inside their windows the figures read as measured")
check(claudeSet.drawable(at: 9_999_999_999).map { $0.window.used } == [0, 0, 0],
      "and once every window has rolled over they read as empty, not as the old figures: "
        + "\(claudeSet.drawable(at: 9_999_999_999).map { $0.window.used })")
check(claudeSet.drawable(at: 9_999_999_999).count == 3,
      "the rows stay — a provider whose windows just reset has not stopped having windows")

let codexJSON: [String: Any] = [
    "ts": 1_789_000_000.0, "source": "rollout", "plan": "pro",
    "windows": [
        ["kind": "primary", "used_percentage": 12, "window_minutes": 300,
         "resets_at": 1_789_010_000.0] as [String: Any],
        ["kind": "secondary", "used_percentage": 58, "window_minutes": 10080,
         "resets_at": 1_789_500_000.0] as [String: Any],
    ] as [[String: Any]],
]
let codexSet = LimitsSet(codex: codexJSON)
check(codexSet?.provider == "codex", "codex/limits.json lands in the same shape")
check(codexSet?.plan == "pro", "the plan survives, for the tooltip that explains the windows")
check(codexSet?.windows.map { $0.title } == ["5 hours", "7 days"],
      "windows are named from their own length: \(codexSet?.windows.map { $0.title } ?? [])")
check(codexSet?.isSnapshot == true, "a rollout record is a snapshot and can go stale")
check(codexSet?.drawable(at: 1_789_005_000).map { $0.window.used } == [12, 58],
      "both windows read as measured while both are open")
check(codexSet?.drawable(at: 1_789_100_000).map { $0.window.used } == [0, 58],
      "a window that has rolled over since the snapshot reads as empty, not as last week's %")
check(codexSet?.drawable(at: 1_789_100_000).first?.window.resets == nil,
      "and it quotes no reset time: when the next window opens is not known until it is used")
check(codexSet?.drawable(at: 1_790_000_000).map { $0.window.used } == [0, 0],
      "a snapshot older than every window it carries is an account that has spent nothing since")

// The reserve pool: when the ordinary limit runs out, Codex moves the session onto its reserve
// model, and from then on the snapshot in the rollout measures a DIFFERENT pool. Unlabelled, its
// 13% reads as the ordinary weekly figure — while the five-hour window it replaced sits at 100%
// and is nowhere on screen. The badge is what stops the strip telling that lie.
let reserveSet = LimitsSet(codex: [
    "ts": 1_789_000_000.0, "source": "rollout", "plan": "plus",
    "windows": [["kind": "primary", "pool": "reserve", "used_percentage": 13,
                 "window_minutes": 10080, "resets_at": 1_789_500_000.0] as [String: Any]]
        as [[String: Any]],
])
check(reserveSet?.windows.first?.title == "Reserve",
      "a reserve window is named for the pool, not for its length: "
        + "\(reserveSet?.windows.first?.title ?? "nil")")
check(reserveSet?.windows.first?.badge == "7d",
      "and its length moves into the badge, the way Fable's weekly slice is already drawn")
check(reserveSet?.windows.first?.minutes == 10080,
      "the duration itself survives, because it is what dates the snapshot")
check(reserveSet?.drawable(at: 1_789_100_000).count == 1, "and the window is still dated by its reset")
// Without the mark nothing changes for anyone who never hit the reserve.
check(codexSet?.windows.first?.badge == nil, "an ordinary window carries no badge")

// Both pools in one record. This is the shape the writer keeps once a session has moved onto the
// reserve: Codex's reserve snapshot carries ONLY the reserve pool, so the ordinary windows are
// the last ones measured before the move, and they have to survive beside it. Otherwise the
// panel loses the five-hour window entirely — including the fact that its reset has passed and
// the ordinary pool is available again, which is exactly the state it used to get stuck in.
let bothPools = LimitsSet(codex: [
    "ts": 1_789_000_000.0, "source": "rollout", "plan": "plus",
    "windows": [
        ["kind": "primary", "pool": "codex", "ts": 1_789_000_000.0, "used_percentage": 97,
         "window_minutes": 300, "resets_at": 1_789_018_681.0] as [String: Any],
        ["kind": "secondary", "pool": "codex", "ts": 1_789_000_000.0, "used_percentage": 15,
         "window_minutes": 10080, "resets_at": 1_789_605_481.0] as [String: Any],
        ["kind": "primary", "pool": "reserve", "ts": 1_789_018_588.0, "used_percentage": 29,
         "window_minutes": 10080, "resets_at": 1_789_616_476.0] as [String: Any],
    ] as [[String: Any]],
])
check(bothPools?.windows.map { $0.title } == ["5 hours", "7 days", "Reserve"],
      "the ordinary pair keeps its own names beside the reserve row: "
        + "\(bothPools?.windows.map { $0.title } ?? [])")
check(Set(bothPools?.windows.map { $0.key } ?? []).count == 3,
      "and the keys stay distinct — the reserve window arrives under kind \"primary\" too, "
        + "so the row a summary names would otherwise be ambiguous")
// An hour after the five-hour window reset, with no newer Codex turn to measure: the ordinary
// session window is free again, and the reserve pool is still two thirds full.
check(bothPools?.drawable(at: 1_789_022_000).map { $0.window.used } == [0, 15, 29],
      "the reset session window reads empty while the others keep their figures: "
        + "\(bothPools?.drawable(at: 1_789_022_000).map { $0.window.used } ?? [])")
check(LimitsSet.worst(bothPools?.drawable(at: 1_789_022_000) ?? [])?.title == "Reserve",
      "and the one-line summary now quotes the pool that is actually running out")

// The file the previous version wrote: the pool was a mark on the whole record. Read as it was
// meant, so the first tick after an update does not relabel a reserve figure as an ordinary one.
let legacyReserve = LimitsSet(codex: [
    "ts": 1_789_000_000.0, "source": "rollout", "reserve": true,
    "windows": [["kind": "primary", "used_percentage": 13, "window_minutes": 10080,
                 "resets_at": 1_789_500_000.0] as [String: Any]] as [[String: Any]],
])
check(legacyReserve?.windows.first?.title == "Reserve",
      "a record from the previous version still names its pool")

// No reset stamp at all: the window's own length is what dates the figure. Without this rule a
// Codex build that stopped sending resets_at would either vanish or lie forever.
let undated = LimitsSet(codex: [
    "ts": 1_789_000_000.0, "source": "rollout",
    "windows": [["kind": "primary", "used_percentage": 30, "window_minutes": 300] as [String: Any]]
        as [[String: Any]],
])
check(undated?.drawable(at: 1_789_000_000 + 299 * 60).map { $0.window.used } == [30],
      "inside its own window the figure still counts")
check(undated?.drawable(at: 1_789_000_000 + 301 * 60).map { $0.window.used } == [0],
      "past its own length the window has ended, so it reads empty like any other rollover")
let unmeasurable = LimitsSet(codex: [
    "ts": 1_789_000_000.0, "source": "rollout",
    "windows": [["kind": "primary", "used_percentage": 30] as [String: Any]] as [[String: Any]],
])
check(unmeasurable?.drawable(at: 1_789_000_060).isEmpty == true,
      "a snapshot with neither a reset nor a length cannot be dated at all, so it is not shown")

check(LimitsSet(codex: ["ts": 1.0, "source": "rollout"]) == nil, "a file with no windows is no data")
check(LimitsSet(codex: ["windows": [["kind": "primary"] as [String: Any]] as [[String: Any]]]) == nil,
      "a window with no percentage is no window")

// The names come from the duration, because which pair a Codex plan carries is not fixed.
check(LimitsSet.title(minutes: 300, kind: "primary") == "5 hours", "300 minutes is 5 hours")
check(LimitsSet.title(minutes: 10080, kind: "secondary") == "7 days", "10080 minutes is 7 days")
check(LimitsSet.title(minutes: 1440, kind: "secondary") == "1 day", "and 1440 is one day, not 1 days")
check(LimitsSet.title(minutes: 60, kind: "primary") == "1 hour", "one hour, singular")
check(LimitsSet.title(minutes: 45, kind: "primary") == "45 min", "under an hour stays in minutes")
check(LimitsSet.title(minutes: 90, kind: "primary") == "1h 30m", "and an odd length is spelled out")
check(LimitsSet.title(minutes: nil, kind: "secondary") == "Weekly", "no length: Codex's own word")
check(LimitsSet.title(minutes: nil, kind: "primary") == "Session", "and for the shorter window")

// The icon labels every bar it draws, so a window it cannot label is a bar it does not draw.
check(NamedWindow(key: "p", title: "5 hours", badge: nil, minutes: 300,
                  window: LimitWindow(json: ["used_percentage": 1])!).shortTitle == "5h",
      "the icon's label for a five-hour window")
check(NamedWindow(key: "s", title: "7 days", badge: nil, minutes: 10080,
                  window: LimitWindow(json: ["used_percentage": 1])!).shortTitle == "7d",
      "and for a weekly one")
check(NamedWindow(key: "s", title: "Weekly", badge: nil, minutes: nil,
                  window: LimitWindow(json: ["used_percentage": 1])!).shortTitle == nil,
      "a window of unknown length has no honest short label")
// Two characters wide: 90 minutes drawn as "1h" is a wrong label rather than a rounded one.
check(NamedWindow(key: "p", title: "1h 30m", badge: nil, minutes: 90,
                  window: LimitWindow(json: ["used_percentage": 1])!).shortTitle == nil,
      "and neither does one that is not a whole number of hours")
check(NamedWindow(key: "p", title: "45 min", badge: nil, minutes: 45,
                  window: LimitWindow(json: ["used_percentage": 1])!).shortTitle == "45m",
      "under an hour it fits as minutes")

// When to stop waiting for the five-minute timer and ask again. Drawing a rolled-over window
// empty is honest but it is not an answer: the real figure is one request away, and on the timer
// alone the bars sat wrong for up to five minutes after every single reset.
let rolling = Limits(json: [
    "ts": 1_785_000_000.0, "source": "oauth",
    "five_hour": ["used_percentage": 42, "resets_at": 1_785_003_600.0] as [String: Any],
    "seven_day": ["used_percentage": 71, "resets_at": 1_785_007_200.0] as [String: Any],
])!.set
check(rolling.rolledOver(since: 0, at: 1_785_003_000) == nil,
      "while every window is still open there is nothing to ask about")
check(rolling.rolledOver(since: 0, at: 1_785_003_601) == 1_785_003_600,
      "a reset that has just passed is what brings the next reading forward")
check(rolling.rolledOver(since: 1_785_003_600, at: 1_785_003_601) == nil,
      "and having asked once, the same rollover does not ask again — not even on the next tick")
check(rolling.rolledOver(since: 1_785_003_600, at: 1_785_007_300) == 1_785_007_200,
      "the next window's own rollover still counts")
check(rolling.rolledOver(since: 0, at: 1_785_007_300) == 1_785_007_200,
      "two at once ask once, for the later of them")
// A fresh answer carries resets in the future, so this falls quiet by itself. The guard that
// makes it so is the one below: a reset older than the measurement is the previous window's,
// already accounted for by the very figures being read.
check(Limits(json: ["ts": 1_785_000_000.0, "source": "oauth",
                    "five_hour": ["used_percentage": 4, "resets_at": 1_784_000_000.0] as [String: Any]])!
        .set.rolledOver(since: 0, at: 1_785_000_001) == nil,
      "a reset older than the figures themselves is not a rollover they have outlived")

// What a one-line summary of a provider says: the window that runs out first.
check(LimitsSet.worst(claudeSet.windows)?.title == "7 days",
      "the fullest window is the one a summary quotes")
check(LimitsSet.worst([]) == nil, "and with no windows there is nothing to quote")

// VoiceOver reads the icon's labels aloud; "5h" out loud is "five aitch".
check(Gauge.spoken("5h") == "5 hour" && Gauge.spoken("7d") == "7 day", "short labels are spelled out")
check(Gauge.spoken("90m") == "90 minute", "including ones Claude never has")
check(Gauge.spoken("wk") == "wk", "and a label with no number is read as it is, not mislabelled")
check(Gauge(fiveHour: 0.1, sevenDay: 0.2, labels: ("1d", "30d")).rows.map { $0.0 } == ["1d", "30d"],
      "the bars carry whichever labels they were given")

// The python→swift seam for the Codex file: written by the real fetch_codex_limits() during the
// python suite, parsed here. The hand-written fixtures above pin the same schema twice
// independently, which is exactly how a coordinated rename passes both suites while the strip
// empties. Run the python suite first — CI does.
let codexSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/codex-limits.json"
if !FileManager.default.fileExists(atPath: codexSeamPath) {
    check(false, "codex seam fixture missing at \(codexSeamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/codex-limits.json")
} else if let data = FileManager.default.contents(atPath: codexSeamPath),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let seamSet = LimitsSet(codex: raw) {
    check(seamSet.provider == "codex", "the file the real reader wrote parses as Codex")
    check(seamSet.plan == "pro", "the plan crosses the python→swift border")
    check(seamSet.windows.map { $0.window.used } == [7, 42], "both percentages arrive as Ints")
    check(seamSet.windows.map { $0.title } == ["5 hours", "7 days"],
          "and are named from the durations the writer put in the file")
    // The fixture's snapshot is stamped 2026-09-11T10:00Z with its 5-hour window resetting at
    // 11:00Z: live an hour before that, half gone an hour after.
    check(seamSet.drawable(at: 1_789_121_000).map { $0.window.used } == [7, 42],
          "both windows read as measured inside them")
    check(seamSet.drawable(at: 1_789_200_000).map { $0.window.used } == [0, 42],
          "and the short window reads empty once its reset has passed")
} else {
    check(false, "codex seam fixture unreadable")
}

// The same seam for a reserve record: written by the real fetch_codex_limits() from a rollout
// whose last turn ran on the reserve model.
let reserveSeamPath = FileManager.default.currentDirectoryPath
    + "/build/seam/codex-limits-reserve.json"
if !FileManager.default.fileExists(atPath: reserveSeamPath) {
    check(false, "codex reserve seam fixture missing at \(reserveSeamPath) — run the python "
        + "suite first (/usr/bin/python3 -m unittest discover -s tests)")
} else if let data = FileManager.default.contents(atPath: reserveSeamPath),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let seamSet = LimitsSet(codex: raw) {
    check(seamSet.windows.first?.title == "Reserve",
          "the reserve flag the real writer put in the file reaches the strip's wording")
    check(seamSet.windows.first?.badge == "7d", "and its badge says how long the window is")
} else {
    check(false, "codex reserve seam fixture unreadable")
}

// And the seam for the shape that only exists because the writer remembers: an ordinary turn
// followed by a reserve turn, so the file carries both pools at once. Written by the real
// fetch_codex_limits() twice over, the way the poll does it.
let poolsSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/codex-limits-pools.json"
if !FileManager.default.fileExists(atPath: poolsSeamPath) {
    check(false, "codex pools seam fixture missing at \(poolsSeamPath) — run the python "
        + "suite first (/usr/bin/python3 -m unittest discover -s tests)")
} else if let data = FileManager.default.contents(atPath: poolsSeamPath),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let seamSet = LimitsSet(codex: raw) {
    check(seamSet.windows.map { $0.title } == ["5 hours", "7 days", "Reserve"],
          "the ordinary windows the reserve snapshot did not carry are still named: "
            + "\(seamSet.windows.map { $0.title })")
    check(seamSet.windows.map { $0.window.used } == [97, 15, 29],
          "with the figures each pool was last measured at")
    // The fixture's five-hour window resets at 2026-09-11T11:00Z; an hour later the ordinary
    // session pool is free again and only the reserve figure is worth reading.
    check(seamSet.drawable(at: 1_789_128_000).map { $0.window.used } == [0, 15, 29],
          "and once the session window resets it reads empty rather than disappearing")
} else {
    check(false, "codex pools seam fixture unreadable")
}

// MARK: Codex MCP — a second agent's servers in the same tab

// The whole point of writing codex/mcp.json in mcp.json's shape: one parser, no second
// reader to drift. If this breaks, the Codex group in the MCP tab silently empties.
let codexMCPSeam = FileManager.default.currentDirectoryPath + "/build/seam/codex-mcp.json"
if !FileManager.default.fileExists(atPath: codexMCPSeam) {
    check(false, "codex mcp seam fixture missing at \(codexMCPSeam) — run the python suite "
        + "first (/usr/bin/python3 -m unittest discover -s tests), it writes "
        + "build/seam/codex-mcp.json")
} else {
    let codexServers = MCPModel(path: codexMCPSeam)
    check(codexServers.reloadIfChanged(), "the codex/mcp.json the real refresh wrote parses")
    let wiki = codexServers.servers.first { $0.name == "wiki" }
    check(wiki != nil, "a Codex server survives the python→swift trip")
    check(wiki?.provider == "codex",
          "it knows which agent it belongs to, so a switch cannot be routed to the wrong one")
    check(wiki?.source == "codex", "and lands in the Codex group: \(wiki?.source ?? "nil")")
    check(wiki?.tools.count == 2, "its tool list arrives whole")
    check(wiki?.tools.first { $0.name == "Delete" }?.enabled == false,
          "a tool Codex's own deny list forbids reads as switched off here")
    check(wiki?.tools.first { $0.name == "Read" }?.params.first?.required == true,
          "tool parameters survive the border, not just the names")
    check(codexServers.servers.first { $0.name == "off-one" }?.disabled == true,
          "a server disabled in config.toml arrives disabled")
    check(codexServers.servers.first { $0.name == "needs-login" }?.state == "auth",
          "and one waiting for OAuth says so instead of reading as broken")
}

// An old Claude server file has no provider field at all and must keep reading as Claude's —
// the switch routing is a string comparison, and "" would route nowhere.
let claudeServer = MCPModel.parse(server: ["name": "wiki", "state": "ok"])
check(claudeServer.provider == "claude", "a server without a provider is Claude's")
check(claudeServer.plugin.isEmpty, "and carries no plugin id")

// Both agents' groups in one table, in the order the tab draws them. Codex's two are separate
// because the user changes them in different places: one in config.toml, one in the plugin.
check(mcpGroups.map(\.key) == ["user", "claude.ai", "plugin", "project", "codex", "codex-plugin"],
      "the group table carries both agents: \(mcpGroups.map(\.key))")

// MARK: hook install

// The failure these cover, as it happened: install.js was handed to the first executable node on
// the list, that node died in dyld, nothing read how it ended, and the Sessions tab stayed empty for
// hours with sessions running. Real child processes where the behaviour lives in the spawn.
let hookDir = NSTemporaryDirectory() + "ccb-hooks-\(ProcessInfo.processInfo.processIdentifier)/"
try? FileManager.default.createDirectory(atPath: hookDir, withIntermediateDirectories: true)
func hookScript(_ name: String, _ body: String) -> String {
    let file = hookDir + name
    FileManager.default.createFile(atPath: file, contents: Data(("#!/bin/sh\n" + body + "\n").utf8),
                                   attributes: [.posixPermissions: 0o755])
    return file
}

let hookSpoke = HookInstall.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
check(hookSpoke.end == .exited(3), "a child's exit code is read, not ignored: \(hookSpoke.end)")
check(hookSpoke.output.contains("out") && hookSpoke.output.contains("err"),
      "and both of its streams are kept: \(hookSpoke.output)")
check(HookInstall.run("/usr/bin/true", [], timeout: 10).succeeded, "exit 0 is a success")

// What dyld does to a node whose library Homebrew upgraded away: one line on stderr, then abort.
let hookDeadNode = hookScript("dead-node", """
    echo "dyld[13151]: Library not loaded: /opt/homebrew/opt/llhttp/lib/libllhttp.9.3.dylib" >&2
    echo "  Referenced from: <E834CE0F> /opt/homebrew/Cellar/node/25.8.2/bin/node" >&2
    kill -ABRT $$
    """)
let hookCrash = HookInstall.run(hookDeadNode, ["-e", ""], timeout: 10)
check(hookCrash.end == .signalled(SIGABRT), "a node killed at launch reads as a crash: \(hookCrash.end)")
check(!hookCrash.succeeded, "which is the one thing the old spawn could not tell from a finished install")
check(HookInstall.describe(hookCrash) == "Library not loaded: libllhttp.9.3.dylib",
      "and what it said is cut down to the library: \(HookInstall.describe(hookCrash))")

let hookHungAt = Date()
let hookHung = HookInstall.run("/bin/sleep", ["30"], timeout: 0.5)
check(hookHung.end == .timedOut, "a child that never ends is given up on: \(hookHung.end)")
check(Date().timeIntervalSince(hookHungAt) < 5, "promptly, not when it finally finishes")
if case .notStarted = HookInstall.run(hookDir + "no-such-node", [], timeout: 5).end {
    check(true, "a path that is not there reads as not started, not as a crash")
} else {
    check(false, "a path that is not there reads as not started, not as a crash")
}

let hookLiveNode = hookScript("live-node", "exit 0")
let hookPick = HookInstall.firstRunning([hookDir + "missing-node", hookDeadNode, hookDeadNode, hookLiveNode])
check(hookPick.node == hookLiveNode,
      "the first node that starts is picked, past a dead one: \(hookPick.node ?? "nil")")
check(hookPick.rejected.map(\.path) == [hookDeadNode],
      "the dead one is remembered once, the missing one skipped: \(hookPick.rejected.map(\.path))")

check(HookInstall.hookRuntime(isExecutable: { _ in true }) == "/opt/homebrew/bin/node",
      "the hooks call Homebrew's node first, as their PATH prefix says")
check(HookInstall.hookRuntime(isExecutable: { $0 == "/usr/local/bin/node" }) == "/usr/local/bin/node",
      "then /usr/local's")
check(HookInstall.hookRuntime(isExecutable: { _ in false }) == nil,
      "and with neither, the session's own PATH decides — which is not guessed at")

let hookDead = HookInstall.Rejected(path: "/opt/homebrew/bin/node", run: hookCrash)
let hookBrew: (String) -> Bool = { $0.hasPrefix("/opt/homebrew/") }
let hookInstalled = HookInstall.Run(end: .exited(0), output: "Hooks already current in settings.json")

// The machine this was written for: Homebrew's node dead, nvm's fine. The install succeeds with
// nvm's, and every hook still fails, because their PATH puts Homebrew's first.
let hookVerdict = HookInstall.health(rejected: [hookDead], installer: hookInstalled,
                                     runtime: "/opt/homebrew/bin/node", isHomebrew: hookBrew)
check(hookVerdict == .cannotRun(
        reason: "They call /opt/homebrew/bin/node, and it does not start: "
            + "Library not loaded: libllhttp.9.3.dylib",
        hint: "Usually fixed by: brew upgrade node"),
      "an install that worked with another node still says the hooks cannot run: \(hookVerdict)")
check(HookInstall.health(rejected: [hookDead], installer: hookInstalled,
                         runtime: "/usr/local/bin/node", isHomebrew: hookBrew) == .ok,
      "a dead node the hooks never call is not their problem")
check(HookInstall.health(rejected: [], installer: hookInstalled, runtime: "/opt/homebrew/bin/node") == .ok,
      "a clean install with a live node is fine")

let hookNoNode = HookInstall.health(rejected: [hookDead], installer: nil, runtime: nil, isHomebrew: hookBrew)
check(hookNoNode.problem?.title == "Session hooks aren't installed",
      "no node that starts means nothing was installed")
check(hookNoNode.problem?.reason
        == "/opt/homebrew/bin/node does not start: Library not loaded: libllhttp.9.3.dylib",
      "and it names the node and the reason: \(hookNoNode.problem?.reason ?? "nil")")
check(HookInstall.health(rejected: [], installer: nil, runtime: nil).problem?.hint?
        .contains("brew install node") == true,
      "a Mac with no node at all is told to install one")

let hookBusy = HookInstall.Run(end: .exited(75), output:
    "settings.json changed while we were working on it — leaving it alone.\nNothing was written.")
check(HookInstall.health(rejected: [], installer: hookBusy, runtime: nil) == .notInstalled(
        reason: "install.js failed: settings.json changed while we were working on it — leaving it alone.",
        hint: nil),
      "an installer that exits non-zero is a failure, with its first line as the reason")
check(HookHealth.ok.problem == nil && HookHealth.unchecked.problem == nil,
      "fine and not-yet-looked-at both show nothing")

let hookThrown = """
    node:internal/modules/cjs/loader:1228
      throw err;
      ^

    Error: Cannot find module '/Applications/Claude Control Bar.app/Contents/Resources/install.js'
        at Module._resolveFilename (node:internal/modules/cjs/loader:1225:15)
    """
check(HookInstall.summary(of: hookThrown)?.hasPrefix("Error: Cannot find module") == true,
      "an uncaught exception is summed up by its error line, not its caret")
check(HookInstall.summary(of: "\n   \n") == nil, "silence sums up to nothing")
check(HookInstall.describe(HookInstall.Run(end: .signalled(9), output: "")) == "crashed (signal 9)",
      "a crash that said nothing still says it crashed")

let hookCellarNode = hookDir + "Cellar/node/26.0.0/bin/node"
try? FileManager.default.createDirectory(atPath: (hookCellarNode as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
FileManager.default.createFile(atPath: hookCellarNode, contents: Data())
try? FileManager.default.createDirectory(atPath: hookDir + "bin", withIntermediateDirectories: true)
try? FileManager.default.createSymbolicLink(atPath: hookDir + "bin/node",
                                            withDestinationPath: "../Cellar/node/26.0.0/bin/node")
check(HookInstall.isHomebrew(hookDir + "bin/node"), "a node linked into a Cellar is Homebrew's")
check(!HookInstall.isHomebrew(hookLiveNode), "and one that is not is not offered brew's fix")

check(HookInstall.retryDelay(afterFailures: 1) < HookInstall.retryDelay(afterFailures: 2)
        && HookInstall.retryDelay(afterFailures: 2) < HookInstall.retryDelay(afterFailures: 3),
      "retries spread out")
check(HookInstall.retryDelay(afterFailures: 50) == 300, "and settle at five minutes")
check(HookInstall.checkDueOnOpen(problem: true, noSessions: false, sinceLastCheck: 11),
      "a warning on screen is looked at again when the panel opens")
check(!HookInstall.checkDueOnOpen(problem: true, noSessions: false, sinceLastCheck: 3),
      "but not on a second open straight after")
check(HookInstall.checkDueOnOpen(problem: false, noSessions: true, sinceLastCheck: 121),
      "an empty Sessions tab is worth a look")
check(!HookInstall.checkDueOnOpen(problem: false, noSessions: false, sinceLastCheck: 10_000),
      "a tab with sessions in it is proof enough")
try? FileManager.default.removeItem(atPath: hookDir)


// MARK: pets
//
// The sprite atlas is somebody else's format: Codex writes pets into ~/.codex/pets/ and a whole
// gallery of third-party ones targets the same layout. So the checks here are mostly about
// refusing the unfamiliar quietly — an atlas whose size we do not recognise, a manifest that is
// not JSON, a folder with no image in it. Every one of those has to come back nil and leave the
// other pets alone, because the alternative is an app that stops drawing when the format moves on.

let petDir = NSTemporaryDirectory() + "ccb-pet-test/"
try? FileManager.default.removeItem(atPath: petDir)
try? FileManager.default.createDirectory(atPath: petDir, withIntermediateDirectories: true)

/// A blank transparent atlas of a given size — the checks care about the dimensions, not the art.
func writeAtlas(_ width: Int, _ height: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

@discardableResult
func writePet(_ name: String, in folder: String = petDir,
              manifest: String, atlas: (Int, Int)?) -> String {
    let dir = folder + name + "/"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try! manifest.write(toFile: dir + "pet.json", atomically: true, encoding: .utf8)
    if let (w, h) = atlas { writeAtlas(w, h, to: dir + "spritesheet.png") }
    return dir
}

func petManifest(_ id: String?, name: String) -> String {
    let idLine = id.map { "\"id\": \"\($0)\", " } ?? ""
    return "{\(idLine)\"displayName\": \"\(name)\", \"spritesheetPath\": \"spritesheet.png\"}"
}

check(PetFormat.matching(width: 1536, height: 2288)?.version == 2, "the tall atlas is the v2 format")
check(PetFormat.matching(width: 1536, height: 2288)?.framesByRow.count == 11,
      "and it describes eleven rows")
check(PetFormat.matching(width: 1536, height: 1872)?.version == 1, "the short one is v1")
check(PetFormat.matching(width: 1536, height: 1872)?.framesByRow.count == 9,
      "with the two look rows missing")
check(PetFormat.matching(width: 1536, height: 2000) == nil,
      "a size nobody has published is not guessed at")

// The cell grid is what every frame rectangle is cut from, so an off-by-one here is a pet drawn
// with a slice of its neighbour attached. Row 7 column 3 of v2 is 3*192 across and 7*208 down.
let v2 = PetFormat.matching(width: 1536, height: 2288)!
check(v2.rect(row: .running, column: 3) == CGRect(x: 576, y: 1456, width: 192, height: 208),
      "a frame rectangle is its cell, counted from the top left")
check(v2.frames(for: .idle).count == 6, "idle is six frames long")
check(v2.frames(for: .runningRight).count == 8, "and a run is eight")
check(v2.frames(for: .idle).allSatisfy { $0.duration > 0 },
      "every frame is held for some time, or the animation never advances")
check(v2.frames(for: .idle).last!.duration > v2.frames(for: .idle)[1].duration,
      "the last frame rests longer than the middle of the loop")
// The panel wakes ten times a second; a duration that is not a whole number of those ticks is
// shown for a length nobody chose, rounded one way or the other by where the loop happens to sit.
check(v2.frames(for: .idle).allSatisfy { (($0.duration * 10).rounded() - $0.duration * 10).magnitude < 0.0001 },
      "and every duration is a whole number of panel ticks")

// Idle is five frames at 0.4 and a last one at 0.6, which is 2.6 seconds all told.
let idleLoop = PetLoop(images: [], durations: v2.frames(for: .idle).map(\.duration))
check(idleLoop.index(at: 0) == 0, "a loop starts on its first frame")
check(idleLoop.index(at: 0.3) == 0, "and stays there for as long as the frame is held")
check(idleLoop.index(at: 0.5) == 1, "then moves on")
check(idleLoop.index(at: 2.5) == 5, "the last frame is reached")
check(idleLoop.index(at: 2.7) == 0, "and the loop starts over")
// -3 seconds is 2.2 seconds into the loop two cycles earlier, and must name that same frame —
// asserting a particular number here instead would pin the test to the current timings rather
// than to the property, which is that the clock wraps in both directions.
check(idleLoop.index(at: -3) == idleLoop.index(at: -3 + 2.6 * 2),
      "a clock reading before the start wraps rather than indexing off the end")
check(PetLoop(images: [], durations: []).index(at: 3) == 0,
      "an empty loop never indexes out of bounds")

check(PetRow.forSessionState("permission") == .waiting, "a session that needs you is waiting")
check(PetRow.forSessionState("thinking") == .running, "a thinking session is working")
check(PetRow.forSessionState("tool") == .running, "so is one running a tool")
check(PetRow.forSessionState("idle") == .idle, "a resting session rests")
check(PetRow.forSessionState("something-new") == .idle,
      "and a state the hooks have not taught us yet rests rather than crashes")

let goodDir = writePet("good", manifest: petManifest("good", name: "Good Pet"), atlas: (1536, 2288))
let goodPet = Pet.load(directory: goodDir)
check(goodPet?.id == "good", "a well-formed pet folder loads")
check(goodPet?.displayName == "Good Pet", "with the name its manifest gives it")
check(goodPet?.format.version == 2, "and the format its image size implies")

writePet("torn", manifest: "{not json at all", atlas: (1536, 2288))
check(Pet.load(directory: petDir + "torn/") == nil, "a manifest that is not JSON is skipped")

writePet("odd-size", manifest: petManifest("odd-size", name: "Odd"), atlas: (800, 600))
check(Pet.load(directory: petDir + "odd-size/") == nil, "an atlas of an unknown size is skipped")

writePet("no-art", manifest: petManifest("no-art", name: "No Art"), atlas: nil)
check(Pet.load(directory: petDir + "no-art/") == nil, "a folder with no atlas in it is skipped")

// The id is what the setting stores, so a manifest that forgets it still has to produce a stable
// one: the folder name is the only thing the gallery CLIs guarantee.
writePet("nameless", manifest: petManifest(nil, name: "Nameless"), atlas: (1536, 2288))
check(Pet.load(directory: petDir + "nameless/")?.id == "nameless",
      "a pet with no id in its manifest is known by its folder")

let found = Pet.installed(inPetsFolder: petDir)
check(found.count == 2, "scanning a folder returns the pets that load and ignores the rest")
check(found.map(\.id) == ["good", "nameless"], "in a stable order, so the picker does not shuffle")
check(Pet.installed(inPetsFolder: petDir + "does-not-exist/").isEmpty,
      "and a missing pets folder is simply no pets, not an error")

// Two folders, ours and Codex's. What matters is what happens when they disagree: the id is what
// the setting stores, so one id has to mean one pet, and it has to keep meaning ours.
let codexPetDir = NSTemporaryDirectory() + "ccb-pet-codex/"
try? FileManager.default.removeItem(atPath: codexPetDir)
try? FileManager.default.createDirectory(atPath: codexPetDir, withIntermediateDirectories: true)
writePet("good", in: codexPetDir, manifest: petManifest("good", name: "Impostor"), atlas: (1536, 2288))
writePet("hoots", in: codexPetDir, manifest: petManifest("hoots", name: "Hoots"), atlas: (1536, 2288))

let library = Pet.library(bundled: petDir, codex: codexPetDir, archive: nil)
check(library.map(\.id) == ["good", "nameless", "hoots"], "ours come first, then the Codex ones")
check(library.first(where: { $0.id == "good" })?.displayName == "Good Pet",
      "and a Codex pet cannot take over an id of ours")
check(Pet.library(bundled: nil, codex: codexPetDir, archive: nil).map(\.id) == ["good", "hoots"],
      "with no bundled folder the Codex ones stand alone")

check(Pet.chosen("hoots", from: library)?.id == "hoots", "the saved id picks its pet")
check(Pet.chosen("", from: library) == nil, "an empty id is pets switched off, not a fallback")
check(Pet.chosen("deleted-yesterday", from: library)?.id == "good",
      "an id whose pet is gone falls back to the first, so no row loses its marker")
check(Pet.chosen("anything", from: []) == nil, "and with no pets at all there is nothing to draw")

try? FileManager.default.removeItem(atPath: codexPetDir)

// Pets that belong to an installed app rather than to a folder.
//
// ChatGPT.app keeps the Codex companions inside its Electron archive, so there is nothing loose
// for the folder reader to find. These checks build a miniature archive of the same shape — a
// length-prefixed JSON index, then the files end to end — and are mostly about what happens when
// it is not the shape we expected, because the only thing keeping a stranger's packaging from
// breaking the picker is that every surprise ends in "no pets".

/// Builds an archive the way an Electron app does: four header words, the JSON index padded to a
/// four-byte boundary, then every file's bytes in index order.
func writeArchive(_ entries: [(path: String, bytes: Data)], to path: String) {
    var files: [String: Any] = [:]
    var payload = Data()
    for entry in entries {
        files[entry.path] = ["size": entry.bytes.count, "offset": "\(payload.count)"]
        payload.append(entry.bytes)
    }
    let index = try! JSONSerialization.data(withJSONObject: ["files": ["assets": ["files": files]]])
    let padding = (4 - index.count % 4) % 4
    var out = Data()
    for word in [4, 4 + 4 + index.count + padding, 4 + index.count + padding, index.count] {
        withUnsafeBytes(of: UInt32(word).littleEndian) { out.append(contentsOf: $0) }
    }
    out.append(index)
    out.append(Data(repeating: 0, count: padding))
    out.append(payload)
    try! out.write(to: URL(fileURLWithPath: path))
}

func atlasBytes(_ width: Int, _ height: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    return rep.representation(using: .png, properties: [:])!
}

let archiveDir = NSTemporaryDirectory() + "ccb-pet-archive/"
try? FileManager.default.removeItem(atPath: archiveDir)
try? FileManager.default.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)
let archive = archiveDir + "app.asar"

writeArchive([
    // The hash in the middle of the name changes with every build of the app it came from, which
    // is the whole reason the archive is read rather than any path being remembered.
    ("hoots-spritesheet-v8-21cacd193ace.webp", atlasBytes(1536, 2288)),
    ("null-signal-spritesheet-v7-1e7dbf89200f.webp", atlasBytes(1536, 1872)),
    ("some-other-art-v2-abc.webp", atlasBytes(1536, 2288)),
    ("rocky-spritesheet-v5-97b5d14cdd54.webp", atlasBytes(64, 64)),
], to: archive)

let packed = PetArchive.pets(inAsar: archive)
check(packed.map(\.id) == ["hoots", "null-signal"],
      "the archive gives up its pets, by the name in front of the hash")
check(!packed.contains { $0.id.contains("some-other-art") },
      "and leaves art that is not a sprite sheet alone")
check(!packed.contains { $0.id == "rocky" },
      "a sheet whose size we do not know is skipped, like any other unknown atlas")
check(packed.first?.displayName == "Hoots", "an id becomes a name a person would recognise")
check(packed.first(where: { $0.id == "null-signal" })?.displayName == "Null Signal",
      "including the ones spelled with a dash")
check(packed.first?.format.version == 2, "the format still comes from the picture's own size")

// The frames have to come out of the middle of the archive, not out of a file — an offset that is
// off by even a byte gives a picture that will not decode, which is the failure this catches.
check(PetAtlas(packed.first!)?.loop(for: .idle).images.count == 6,
      "and the frames cut out of the archive are real pictures")

check(PetArchive.pets(inAsar: archiveDir + "no-such.asar").isEmpty,
      "a machine without that app simply has fewer pets")
try! Data("not an archive at all, just some bytes".utf8)
    .write(to: URL(fileURLWithPath: archiveDir + "junk.asar"))
check(PetArchive.pets(inAsar: archiveDir + "junk.asar").isEmpty,
      "and a file that is not an archive is no pets rather than a crash")
// A header claiming an index far larger than the file is the shape a truncated download takes.
var lying = Data()
for word in [4, 1_000_000, 999_000, 998_000] {
    withUnsafeBytes(of: UInt32(word).littleEndian) { lying.append(contentsOf: $0) }
}
try! lying.write(to: URL(fileURLWithPath: archiveDir + "lying.asar"))
check(PetArchive.pets(inAsar: archiveDir + "lying.asar").isEmpty,
      "a header that promises more than the file holds is refused, not read past")

// Ours, then Codex's folder, then the app's own — one id still means one pet.
writePet("hoots", in: petDir, manifest: petManifest("hoots", name: "Our Hoots"), atlas: (1536, 2288))
let withArchive = Pet.library(bundled: petDir, codex: codexPetDir, archive: archive)
check(withArchive.filter { $0.id == "hoots" }.count == 1, "the app's pets cannot double up an id")
check(withArchive.first(where: { $0.id == "hoots" })?.displayName == "Our Hoots",
      "and ours still wins it")
check(withArchive.contains { $0.id == "null-signal" }, "while the rest of them arrive")
try? FileManager.default.removeItem(atPath: archiveDir)
try? FileManager.default.removeItem(atPath: petDir)


// MARK: the menu bar's own icon
//
// The bar's choice is one value rather than a style plus an id kept beside it: with two values a
// setting can be saved half-written, and the picker would have a state ("a pet, but which one")
// that draws nothing. Anything the file does not spell correctly is the crab, because the icon is
// the app's only visible surface when the panel is closed — there is no blank to fall back to.

check(MenuBarIcon(raw: "web") == .web, "a saved drawn style reads back as itself")
check(MenuBarIcon(raw: "code") == .code, "each of them")
check(MenuBarIcon(raw: "crab") == .crab, "including the default")
check(MenuBarIcon(raw: "pet:hoots") == .pet("hoots"), "and a pet reads back with its id")
check(MenuBarIcon.pet("hoots").raw == "pet:hoots", "which is written the same way round")
check(MenuBarIcon.crab.raw == "crab", "while a drawn style is just its name")
check(MenuBarIcon(raw: "pet:") == .crab, "a pet with no id is not a pet")
check(MenuBarIcon(raw: "") == .crab, "an empty setting is the crab")
check(MenuBarIcon(raw: "walrus") == .crab, "and so is a style this version has never heard of")
check(MenuBarIcon(raw: "pet:one:two") == .pet("one:two"),
      "an id with a colon in it stays whole, since the ids are other people's folder names")

check(!MenuBarIcon.pet("hoots").title.isEmpty && !MenuBarIcon.crab.title.isEmpty,
      "every icon can name itself in the picker")

// The bar knows one thing about what is happening: the crab's mood. A pet has one animation per
// state instead of six moods, so the four busy moods land on the same one — which is why the
// variant below, and not the mood, is what decides that a cached picture is stale.
check(CrabMood.sleeping.petRow == .idle, "nothing running: the pet rests")
check(CrabMood.waitingPermission.petRow == .waiting, "a session needing you: the pet waits")
check(CrabMood.cigar.petRow == .running, "one working session already has the pet working")
check([CrabMood.walking, .overheated, .onFire].allSatisfy { $0.petRow == .running },
      "and the busier moods share that one animation")

check(MenuBarIcon.crab.variant(mood: .onFire) == CrabMood.onFire.rawValue,
      "the crab's picture changes with its mood")
check(MenuBarIcon.pet("hoots").variant(mood: .onFire)
        == MenuBarIcon.pet("hoots").variant(mood: .walking),
      "a pet's does not change between two moods it draws the same way")
check(MenuBarIcon.pet("hoots").variant(mood: .onFire)
        != MenuBarIcon.pet("hoots").variant(mood: .sleeping),
      "but it does when the animation itself changes")
check(MenuBarIcon.web.variant(mood: .onFire).isEmpty,
      "and a drawn style has no second picture to tell apart")

// MARK: a pet cut down to the menu bar
//
// The panel gives a pet a 32pt row and lets it fill the cell it was drawn in; the bar has 18
// points and the animal occupies about half of its cell's height. So the transparent margin is
// measured and dropped. The measurement is taken across every animation the bar can show at once:
// trimmed per animation, a pet changes size the moment a session starts working, and an icon that
// resizes reads as the bar jumping rather than as the pet moving.

let iconPetDir = NSTemporaryDirectory() + "ccb-pet-icon/"
try? FileManager.default.removeItem(atPath: iconPetDir)
try? FileManager.default.createDirectory(atPath: iconPetDir, withIntermediateDirectories: true)

/// A v2 atlas with a solid block inside the named cells. `x`/`y` are counted from the cell's own
/// top left, the way the format counts, so a mark can be placed where the art would be.
func writeMarkedAtlas(_ marks: [(row: PetRow, x: Int, y: Int, w: Int, h: Int)], to path: String) {
    let format = PetFormat.v2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: format.width,
                              pixelsHigh: format.height, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: format.width * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.red.setFill()
    for mark in marks {
        for column in 0..<format.frames(for: mark.row).count {
            let cell = format.rect(row: mark.row, column: column)
            // The atlas is addressed from the top down and this context draws from the bottom up.
            NSRect(x: cell.minX + CGFloat(mark.x),
                   y: CGFloat(format.height) - (cell.minY + CGFloat(mark.y + mark.h)),
                   width: CGFloat(mark.w), height: CGFloat(mark.h)).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// Deliberately three different blocks: the widest is in the running row and the tallest in the
// idle one, so a trim taken from either row alone would be visibly wrong.
// Together they cover x 40…159 and y 70…129 — 120 across by 60 down, which is 2:1.
let iconDir = iconPetDir + "marked/"
try? FileManager.default.createDirectory(atPath: iconDir, withIntermediateDirectories: true)
try! petManifest("marked", name: "Marked").write(toFile: iconDir + "pet.json",
                                                 atomically: true, encoding: .utf8)
writeMarkedAtlas([(.idle, 70, 70, 40, 60), (.running, 40, 80, 120, 30), (.waiting, 80, 90, 20, 20)],
                 to: iconDir + "spritesheet.png")

/// Whether anything was drawn at that point of a finished icon, counted from the TOP left the way
/// a picture is read rather than the way it is drawn.
func iconHasInk(_ image: NSImage, x: Int, y: Int) -> Bool {
    guard let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
          x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return false }
    return (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
}

let markedPet = Pet.load(directory: iconDir)
check(markedPet != nil, "the marked atlas loads as a pet at all")
let barFrames = PetIconFrames(markedPet!, height: 18)
check(barFrames != nil, "a pet with art in it can be cut down to the bar")

if let barFrames {
    let idle = barFrames.frames(for: .idle)
    let running = barFrames.frames(for: .running)
    let waiting = barFrames.frames(for: .waiting)
    check(!idle.isEmpty && !running.isEmpty && !waiting.isEmpty,
          "every animation the bar can ask for was cut")
    let sizes = Set((idle + running + waiting).map { "\($0.size)" })
    check(sizes.count == 1,
          "one size across every animation, or the icon resizes when a session starts working")
    check(idle.first?.size.height == 18, "cut to the height the bar has room for")
    // 120 across by 60 down is 2:1, so 18 points tall is 36 across. Asserted as the ratio the
    // marks describe rather than as a number typed in: the point is that the margin went.
    check((idle.first.map { $0.size.width / $0.size.height } ?? 0) == 2,
          "and as wide as the art it found, not as wide as the cell it sat in")

    // The bar steps through a fixed list ten times a second, so a frame held for four tenths is
    // four entries. The totals below are the format's own durations, not numbers chosen here.
    func ticks(_ row: PetRow) -> Int {
        Int((PetFormat.v2.frames(for: row).map(\.duration).reduce(0, +) * PetIconFrames.fps).rounded())
    }
    check(idle.count == ticks(.idle), "a resting loop lasts as long as its durations add up to")
    check(running.count == ticks(.running), "and so does a working one")
    check(idle.count != running.count, "which are not the same length, or the check proves nothing")

    // A trim is two numbers — where the art starts and how tall it is — and getting the first one
    // upside down still produces a picture of the right size, with the animal half out of frame.
    // The marks were placed so each edge of the shared box belongs to a known animation: the tall
    // block in the resting row reaches the top and the bottom, the wide one in the working row
    // reaches both sides. So after a tight trim each of them has to touch its own edges.
    let width = Int(idle.first?.size.width ?? 0), tall = Int(idle.first?.size.height ?? 0)
    check((0..<width).contains { iconHasInk(idle[0], x: $0, y: 0) },
          "the resting pet reaches the top of its icon")
    check((0..<width).contains { iconHasInk(idle[0], x: $0, y: tall - 1) },
          "and the bottom, so the trim is not measured upside down")
    check((0..<tall).contains { iconHasInk(running[0], x: 0, y: $0) },
          "the working pet reaches the left edge")
    check((0..<tall).contains { iconHasInk(running[0], x: width - 1, y: $0) },
          "and the right one, so nothing was cut off the side")
    check(!(0..<width).contains { iconHasInk(running[0], x: $0, y: 0) },
          "while the row that does not reach the top does not suddenly fill it")
}

// A pet whose rows are empty has no margin to measure, and dividing by that height is how an
// icon ends up infinitely wide. Nothing to draw has to come back as nothing to draw.
let blankDir = writePet("blank", in: iconPetDir, manifest: petManifest("blank", name: "Blank"),
                        atlas: (1536, 2288))
check(PetIconFrames(Pet.load(directory: blankDir)!, height: 18) == nil,
      "a pet with nothing drawn in it cannot become an icon")

try? FileManager.default.removeItem(atPath: iconPetDir)

// The session lifecycle around SessionEngine: reading files, reaping, the chime and "needs you"
// edges, same-named projects, the lead session. It used to live in StatusController, tangled
// with the disk, timers and NSWorkspace, and the per-session side tables were cleared in three
// places that had to stay in step.
do {
    let now = 1_800_000_000.0
    let mtime = Date(timeIntervalSince1970: 1)
    var disk: [String: [String: Any]] = [:]
    var reads = 0
    func file(_ provider: String, _ id: String, at stamp: Date = mtime) -> SessionBoard.File {
        SessionBoard.File(key: provider + ":" + id, path: "/\(provider)/\(id).json",
                          provider: provider, id: id, mtime: stamp)
    }
    func read(_ path: String) -> [String: Any]? { reads += 1; return disk[path] }
    var alive: Set<Int32> = [11, 12, 13]
    var rules = SessionBoard.Rules(soundThreshold: 60, stalePruneAge: 900,
                                   thinkingWords: ["Pondering", "Musing"], needsYou: true)

    let board = SessionBoard(engine: SessionEngine())
    disk["/claude/a.json"] = ["state": "thinking", "project": "myrepo", "cwd": "/work/myrepo",
                              "pid": 11, "ts": now, "startedAt": now - 120, "provider": "codex"]
    disk["/claude/b.json"] = ["state": "idle", "project": "myrepo", "cwd": "/tmp/myrepo",
                              "pid": 12, "ts": now]
    board.reload([file("claude", "a"), file("claude", "b")], read: read) { cwd in
        cwd == "/work/myrepo" ? "main" : ""
    }
    check(board.sessions.count == 2 && board.fileCount == 2, "two session files, two sessions")
    check(board.sessions["claude:a"]?.provider == "claude",
          "the directory settles the provider, not what the file claims")
    check(board.sessions["claude:a"]?.branch == "main", "the branch comes with the read")
    board.reload([file("claude", "a"), file("claude", "b")], read: read) { _ in "" }
    check(reads == 2, "an unchanged mtime is not read again: \(reads) reads")

    var tick = board.tick(now: now, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
    check(board.sessions["claude:a"]?.displayName == "work/myrepo",
          "two clones of one repo are told apart by their parent folder")
    check(board.sessions["claude:b"]?.displayName == "tmp/myrepo", "and so is the other one")
    check(tick.lead?.id == "a", "a working session leads an idle one")
    let word = board.word(for: "claude:a")
    check(word != nil && rules.thinkingWords.contains(word!), "entering thinking picks a word")
    _ = board.tick(now: now + 1, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
    check(board.word(for: "claude:a") == word, "and keeps it while the session stays thinking")

    // The turn ends after two minutes, over the one-minute threshold: one chime, once.
    disk["/claude/a.json"] = ["state": "done", "project": "myrepo", "cwd": "/work/myrepo",
                              "pid": 11, "ts": now + 2]
    let later = Date(timeIntervalSince1970: 2)
    board.reload([file("claude", "a", at: later), file("claude", "b")], read: read) { _ in "" }
    tick = board.tick(now: now + 2, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
    check(tick.chime, "a turn longer than the threshold chimes when it finishes")
    tick = board.tick(now: now + 3, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
    check(!tick.chime, "and only on the edge, not on every tick after it")

    // Needs you: only on the edge, and not when the session's own terminal is in front.
    disk["/claude/c.json"] = ["state": "permission", "project": "other", "cwd": "/x/other",
                              "pid": 13, "ts": now, "term_bundle": "com.apple.Terminal"]
    board.reload([file("claude", "a", at: later), file("claude", "b"), file("claude", "c")],
                 read: read) { _ in "" }
    tick = board.tick(now: now + 4, rules: rules, pidAlive: { alive.contains($0) },
                      frontmost: { "com.apple.Terminal" })
    check(!tick.needsYou, "no cue when the terminal asking is already in front")
    disk["/claude/c.json"]?["ts"] = now + 5
    board.reload([file("claude", "a", at: later), file("claude", "b"),
                  file("claude", "c", at: Date(timeIntervalSince1970: 3))], read: read) { _ in "" }
    check(!board.tick(now: now + 5, rules: rules, pidAlive: { alive.contains($0) },
                      frontmost: { "com.other" }).needsYou,
          "a permission already seen is not an edge the second time")
    check(board.tick(now: now + 5, rules: rules, pidAlive: { alive.contains($0) },
                     frontmost: { nil }).lead?.id == "c",
          "a session waiting for permission leads everything else")

    // A dead process is reaped: the session goes, its path comes back to be deleted, and nothing
    // about it is remembered — the same file showing up again is read afresh.
    alive.remove(11)
    tick = board.tick(now: now + 6, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
    check(tick.reaped.map(\.key) == ["claude:a"], "a session whose process died is reaped")
    check(board.sessions["claude:a"] == nil && board.word(for: "claude:a") == nil,
          "and its side tables go with it")
    check(board.sessions["claude:b"]?.displayName == "myrepo",
          "the survivor of two clones drops its qualifier")
    let before = reads
    board.reload([file("claude", "a", at: later), file("claude", "b"),
                  file("claude", "c", at: Date(timeIntervalSince1970: 3))], read: read) { _ in "" }
    check(reads == before + 1, "a reaped file that is still there is read again, not trusted")
    _ = board.tick(now: now + 6, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })

    // A file gone from disk takes its session with it.
    board.reload([file("claude", "c", at: Date(timeIntervalSince1970: 3))], read: read) { _ in "" }
    check(board.sessions.keys.sorted() == ["claude:c"] && board.fileCount == 1,
          "a deleted file drops its session")

    // No pid (a pre-upgrade file): pruned by idle age instead, and only when the rule is on.
    disk["/claude/old.json"] = ["state": "idle", "project": "p", "ts": now - 1000]
    board.reload([file("claude", "c", at: Date(timeIntervalSince1970: 3)), file("claude", "old")],
                 read: read) { _ in "" }
    rules.stalePruneAge = 0
    check(board.tick(now: now, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
            .reaped.isEmpty, "with the idle prune off, a pid-less session stays")
    rules.stalePruneAge = 900
    check(board.tick(now: now, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
            .reaped.map(\.id) == ["old"], "past the idle age, a pid-less session is pruned")

    // Sessions without a cwd do not force a qualifier onto a genuinely unique name.
    disk["/claude/n1.json"] = ["state": "idle", "project": "solo", "cwd": "/a/solo", "pid": 13, "ts": now]
    disk["/claude/n2.json"] = ["state": "idle", "project": "solo", "pid": 13, "ts": now]
    board.reload([file("claude", "n1"), file("claude", "n2")], read: read) { _ in "" }
    _ = board.tick(now: now, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
    check(board.sessions["claude:n1"]?.displayName == "solo",
          "a session with no cwd is not a second location")

    let questionPath = NSTemporaryDirectory() + "ccb-board-question.jsonl"
    try! [questionCall, questionAccepted].joined(separator: "\n")
        .write(toFile: questionPath, atomically: true, encoding: .utf8)
    let questionBoard = SessionBoard(engine: SessionEngine())
    disk["/codex/q.json"] = ["state": "tool", "transcript": questionPath, "pid": 13,
                             "ts": now, "term_bundle": "com.apple.Terminal"]
    questionBoard.reload([file("codex", "q")], read: read) { _ in "" }
    let asked = questionBoard.tick(now: now, rules: rules,
                                  pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
    check(asked.needsYou && asked.lead?.eff == "permission",
          "a Codex Question cues and leads while the raw hook state is tool")
    check(!questionBoard.tick(now: now + 1, rules: rules,
                              pidAlive: { alive.contains($0) }, frontmost: { "com.other" }).needsYou,
          "a pending Codex Question does not cue again on the next tick")
    disk["/codex/q.json"]?["state"] = "thinking"
    questionBoard.reload([file("codex", "q", at: Date(timeIntervalSince1970: 4))],
                         read: read) { _ in "" }
    check(!questionBoard.tick(now: now + 2, rules: rules,
                              pidAlive: { alive.contains($0) }, frontmost: { "com.other" }).needsYou,
          "a new hook event does not replay the sound while the Question remains open")
    appendCodexLine(codexQuestionReply(0), to: questionPath)
    appendCodexLine(codexQuestionReply(1), to: questionPath)
    check(questionBoard.tick(now: now + 3, rules: rules,
                             pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
            .lead?.eff == "thinking", "answering the Question restores the working state")
    try? FileManager.default.removeItem(atPath: questionPath)
}

// Which provider's limits the icon and the strip show. These rules used to be written three times
// outside the model — the icon, the strip and the height reserved for it — and the two fixes in
// this area were both on those seams, not in the windows themselves.
do {
    let now = 1_800_000_000.0
    func win(_ key: String, _ used: Int, minutes: Int?, resets: Double?) -> NamedWindow {
        NamedWindow(key: key, title: key, badge: nil, minutes: minutes,
                    window: LimitWindow(used: used, resets: resets))
    }
    let claude = LimitsSet(provider: "claude", windows: [
        win("five_hour", 40, minutes: 300, resets: now + 3600),
        win("seven_day", 70, minutes: 10080, resets: now + 86400),
    ], source: "oauth", ts: now - 60, plan: nil)
    let codex = LimitsSet(provider: "codex", windows: [
        win("primary", 10, minutes: 300, resets: now + 600),
        win("secondary", 20, minutes: 10080, resets: now + 9000),
        win("unlabelled", 99, minutes: nil, resets: now + 100),
    ], source: "rollout", ts: now - 60, plan: "plus")
    let fableOnly = LimitsSet(provider: "claude", windows: [
        win("seven_day_fable", 55, minutes: 10080, resets: now + 5000),
    ], source: "oauth", ts: now - 60, plan: nil)
    let codexGone = LimitsSet(provider: "codex", windows: [
        win("undated", 30, minutes: nil, resets: nil),
    ], source: "rollout", ts: now - 60, plan: nil)

    let both = LimitsBoard(claude: claude, codex: codex)
    check(both.shown(at: now).map(\.set.provider) == ["claude", "codex"],
          "both providers with figures are shown, Claude first")
    check(LimitsBoard(claude: nil, codex: codexGone).shown(at: now).isEmpty,
          "a provider with nothing drawable is not a group — the strip and its height agree")
    check(LimitsBoard(claude: nil, codex: nil).shown(at: now).isEmpty, "no figures, no groups")

    let icon = both.gauge(at: now)
    check(icon.fiveHour == 0.4 && icon.sevenDay == 0.7 && icon.labels == ("5h", "7d"),
          "the icon draws Claude's pair when Claude has one")
    let codexIcon = LimitsBoard(claude: fableOnly, codex: codex).gauge(at: now)
    check(codexIcon.fiveHour == 0.1 && codexIcon.sevenDay == 0.2,
          "a Claude plan with only Fable leaves the icon to Codex rather than blank")
    check(codexIcon.labels.0 == "5h" && codexIcon.labels.1 == "7d",
          "and Codex's bars carry their own short labels: \(codexIcon.labels)")
    check(LimitsBoard(claude: nil, codex: codexGone).gauge(at: now).isEmpty,
          "a window with no length gets no bar: there is no honest label for it")
    let rolled = LimitsBoard(claude: LimitsSet(provider: "claude", windows: [
        win("five_hour", 94, minutes: 300, resets: now - 1),
    ], source: "oauth", ts: now - 600, plan: nil), codex: nil).gauge(at: now)
    check(rolled.fiveHour == 0, "a window past its reset draws empty in the icon too")

    check(LimitsBoard.showing("codex", among: ["claude", "codex"]) == "codex",
          "the switcher keeps the remembered provider")
    check(LimitsBoard.showing("codex", among: ["claude"]) == "claude",
          "a remembered provider with no figures falls back to the first")
    check(LimitsBoard.showing("claude", among: []) == nil, "nothing to show, nothing picked")
}

// What tells the two agents apart. The reap deletes files by stateDir, so a wrong directory here
// deletes another agent's sessions — which is why the paths are pinned rather than trusted.
check(Provider.all.map(\.id) == ["claude", "codex"], "both agents, Claude first")
check(Provider.named("codex").stateDir(home: "/h") == "/h/.claude/control-bar/codex/state.d",
      "Codex sessions live in their own directory")
check(Provider.named("claude").stateDir(home: "/h") == "/h/.claude/control-bar/state.d",
      "Claude's stay where the hooks always wrote them")
check(Provider.named("").id == "claude" && Provider.named("other").id == "claude",
      "a file without a known provider is Claude's, as every pre-Codex file is")
check(Provider.named("codex").configFile(home: "/h") == "/h/.codex/config.toml"
        && Provider.claude.configFile(home: "/h") == "/h/.claude/settings.json",
      "each agent's servers open in its own config file")
check(Provider.codex.title == "Codex" && Provider.claude.glyph == "sparkle",
      "names and glyphs come from one place")

// The Swift → mcpbar.py command line. main() in mcpbar.py reads these words positionally, and an
// older script reads the tool rule as its only argument — so the spelling is the contract, pinned
// word for word rather than rebuilt from the same code that produced it.
let backendGolden: [(BackendCommand, [String])] = [
    (.mcpRefresh(provider: "claude"), ["refresh"]),
    (.limits(provider: "claude"), ["limits"]),
    (.limits(provider: "codex"), ["codex-limits"]),
    (.mcpRefresh(provider: "codex"), ["codex-mcp", "refresh"]),
    (.codexHooks, ["codex-hooks"]),
    (.codexHooksApprove, ["codex-hooks", "approve"]),
    (.toggleServer(provider: "claude", name: "wiki", on: false), ["toggle-server", "wiki", "--off"]),
    (.toggleServer(provider: "codex", name: "wiki", on: true),
     ["codex-mcp", "toggle-server", "wiki", "--on"]),
    (.toggleTool(provider: "claude", server: "wiki", tool: "Read", prefix: "wiki", on: false),
     ["toggle-tool", "mcp__wiki__Read", "--server", "wiki", "--tool", "Read", "--off"]),
    (.toggleTool(provider: "codex", server: "wiki", tool: "Read", prefix: "wiki", on: true),
     ["codex-mcp", "toggle-tool", "--server", "wiki", "--tool", "Read", "--on"]),
]
for (command, words) in backendGolden {
    check(command.arguments == words, "backend \(words.joined(separator: " ")): \(command.arguments)")
}


print(failures == 0 ? "\nall model checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
