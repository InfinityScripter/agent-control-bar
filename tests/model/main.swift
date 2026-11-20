import Cocoa

// Checks on the MCP model, the transcript reader and the desktop-session lookup:
//   swiftc -O Sources/Model/*.swift tests/model/main.swift -o /tmp/t -framework Cocoa && /tmp/t
// There is no test target in this project (it builds with a bare swiftc, no Xcode project), so
// this is a plain executable that exits non-zero on the first failure.
//
// Top-level code runs in order: a check that names a global declared further down reads memory
// that is not initialised yet and dies with a bare segfault, no message. Declare before use.

if CommandLine.arguments.contains("--owner-fixture") { sleep(2); exit(0) }

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

// What the row's right-hand column says. The spinner and a word must not share the slot, and the
// flag is the same one the spinner draws from — handed in, so the two cannot be asked of
// different agents' models (Claude's does not know a Codex server and answers "not checking").
let pendingWiki = model.servers.first { $0.name == "wiki" }!
check(pendingWiki.tail(checking: true).isEmpty && pendingWiki.tail(checking: false) == "next session",
      "a pending server leaves its column to the spinner, and names what it waits for once that stops")
check(model.servers.first { $0.name == "yt" }!.tail(checking: false) == "2/2"
      && MCPModel.parse(server: ["name": "n", "state": "ok", "tools": 7]).tail(checking: false) == "7"
      && MCPModel.parse(server: ["name": "n", "state": "off"]).tail(checking: false) == "—",
      "a server that answered, or is switched off, shows its tool count in the best form known")
check(MCPModel.parse(server: ["name": "n", "state": "pending", "needsApproval": true])
        .tail(checking: true) == "approve in Claude Code",
      "a project server waiting to be trusted says so even while a check runs: no check resolves it")
check(MCPModel.parse(server: ["name": "n", "state": "unknown"]).tail(checking: false) == "not checked"
      && MCPModel.parse(server: ["name": "n", "state": "failed", "tools": 7]).tail(checking: false) == "failed",
      "an unprobed remote server and one that did not answer are told apart in words")

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
for id in ["gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol", "o3", "custom-model-v2"] {
    check(SessionFormat.prettyModel(id) == id,
          "a non-Claude model keeps its full identifier: \(id) -> \(SessionFormat.prettyModel(id))")
}
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
check(engine.effectiveState(codexQuestionSession, now: nowTs) == "tool",
      "an accepted async question cannot prove its locally dismissible card is still open")
func appendCodexLine(_ line: String, to path: String) {
    let file = FileHandle(forWritingAtPath: path)!
    try! file.seekToEnd()
    try! file.write(contentsOf: Data(("\n" + line).utf8))
    try! file.close()
}
appendCodexLine(codexQuestionReply(0), to: codexQuestionPath)
check(engine.effectiveState(codexQuestionSession, now: nowTs) == "tool",
      "an unanswered optional async question does not block the session")
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

let blockingQuestionCall = codexLine(["type": "function_call", "name": "request_user_input",
                                      "call_id": "blocking", "arguments": questionArguments])
let blockingQuestionAnswer = codexLine(["type": "function_call_output", "call_id": "blocking",
                                        "output": #"{"answers":{"first":"yes"}}"#])
let blockingQuestionPath = writeTranscript("codex-blocking-question.jsonl", lines: [blockingQuestionCall])
let blockingQuestionSession = Session(json: ["provider": "codex", "state": "tool",
                                              "transcript": blockingQuestionPath, "ts": nowTs,
                                              "pid": 1], id: "codex-blocking-question")
check(engine.effectiveState(blockingQuestionSession, now: nowTs) == "permission",
      "a blocking Codex input request still needs the user")
appendCodexLine(codexLine(["type": "function_call_output", "call_id": "another", "output": "ok"]),
                to: blockingQuestionPath)
check(engine.effectiveState(blockingQuestionSession, now: nowTs) == "permission",
      "another tool result does not clear a blocking input request")
appendCodexLine(blockingQuestionAnswer, to: blockingQuestionPath)
check(engine.effectiveState(blockingQuestionSession, now: nowTs) == "tool",
      "answering a blocking input request restores the working state")
for boundary in ["task_complete", "turn_complete", "turn_aborted", "task_started", "turn_started"] {
    let path = writeTranscript("codex-question-\(boundary).jsonl", lines: [blockingQuestionCall])
    var questions = CodexRollout.Questions()
    check(questions.pending(in: path), "a blocking input request is pending before \(boundary)")
    appendCodexLine(#"{"type":"event_msg","payload":{"type":""# + boundary + #""}}"#, to: path)
    check(!questions.pending(in: path), "\(boundary) clears a previous turn's blocking request")
}

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
check(codexSession.modelService == .openai && claudeShaped.modelService == .anthropic,
      "older hook files use the agent's original model service")
let zaiClaude = Session(json: ["provider": "claude", "modelService": "zai"], id: "glm")
let deepSeekCodex = Session(json: ["provider": "codex", "modelService": "deepseek"], id: "v4")
check(zaiClaude.modelService == .zai && zaiClaude.key == "claude:glm"
      && deepSeekCodex.modelService == .deepseek && deepSeekCodex.key == "codex:v4",
      "the model service changes independently of the agent and its session key")

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
// A session started from T3 Code. The app's own bundle id only brings its window forward, on
// whatever thread it was showing; T3 exports the thread id to the session, the hooks record it,
// and t3code://threads/<environment>/<thread> is the link the app itself parses.
let t3Home = NSTemporaryDirectory() + "ccb-t3-home/"
try? FileManager.default.removeItem(atPath: t3Home)
try! FileManager.default.createDirectory(atPath: t3Home + "userdata", withIntermediateDirectories: true)
try! "env-1\n".write(toFile: t3Home + "userdata/environment-id", atomically: true, encoding: .utf8)
check(Session(json: ["t3_thread": "th-1"], id: "s").t3Thread == "th-1"
      && Session(json: [:], id: "s").t3Thread.isEmpty,
      "the T3 Code thread id is read from the session file and is empty everywhere else")
check(T3Sessions.threadURL(threadID: "th-1", home: t3Home)?.absoluteString == "t3code://threads/env-1/th-1",
      "a T3 Code session opens its own thread: "
        + "\(T3Sessions.threadURL(threadID: "th-1", home: t3Home)?.absoluteString ?? "nil")")
check(T3Sessions.threadURL(threadID: "", home: t3Home) == nil, "no thread id, no link")
check(SessionFormat.surfaceTag(Session(json: ["entrypoint": "t3-code", "t3_thread": "th-1"], id: "x")) == "APP",
      "a Claude session T3 Code runs in one of its threads is an app session, not a terminal one")
// The thread id is inherited by everything started from a thread, so it alone decides nothing.
check(SessionFormat.surfaceTag(Session(json: ["provider": "codex", "surface": "exec", "t3_thread": "th-1"], id: "x")) == "EXEC"
      && SessionFormat.surfaceTag(Session(json: ["entrypoint": "claude-vscode", "t3_thread": "th-1"], id: "x")) == "IDE"
      && SessionFormat.surfaceTag(Session(json: ["entrypoint": "cli", "t3_thread": "th-1"], id: "x")) == "CLI",
      "a session that merely descends from a T3 Code thread keeps the surface it really runs on")
check(T3Sessions.threadURL(threadID: "th-1", home: t3Home + "missing/") == nil,
      "without T3 Code's environment id there is no thread link, and the click falls back to the app")
check(T3Sessions.threadURL(threadID: "a/b?x", home: t3Home)?.absoluteString == "t3code://threads/env-1/a%2Fb%3Fx",
      "an odd thread id is escaped rather than taken as a path")
check(SessionFormat.surfaceTag(Session(json: ["provider": "codex", "surface": "exec"], id: "x")) == "EXEC",
      "a non-interactive codex exec run says so")
check(SessionFormat.surfaceTag(Session(json: ["provider": "codex", "surface": ""], id: "x")).isEmpty
      && SessionFormat.surfaceTag(Session(json: ["provider": "codex", "surface": "web"], id: "x")).isEmpty,
      "an unnamed surface, or one this build has no word for, gets no badge instead of a guessed one")
check(SessionFormat.surfaceTag(Session(json: ["entrypoint": "claude-desktop"], id: "x")) == "APP",
      "Claude's own badges are untouched")
// Claude's terminal badge is for the one entrypoint that names a terminal. An SDK run or a host
// this build has never heard of gets no badge, the rule the Codex half already follows.
check(SessionFormat.surfaceTag(Session(json: ["entrypoint": "cli"], id: "x")) == "CLI",
      "Claude Code's terminal entrypoint is a CLI session")
check(SessionFormat.surfaceTag(Session(json: ["entrypoint": "sdk-ts"], id: "x")).isEmpty
      && SessionFormat.surfaceTag(Session(json: ["entrypoint": "some-future-host"], id: "x")).isEmpty,
      "an entrypoint this build does not know gets no badge instead of a guessed CLI")
// One dictionary for the Live rows and for Codex history, in the pill's short spelling.
check(["cli", "ide", "app", "exec", "t3"].map(SessionFormat.surfaceLabel) == ["CLI", "IDE", "APP", "EXEC", "T3"]
      && SessionFormat.surfaceLabel("").isEmpty && SessionFormat.surfaceLabel("web").isEmpty,
      "every surface has one short word, and a code nobody taught this build has none")

// Whether a click on the row has anywhere to go. A session can be alive with no window on
// record — a terminal whose environment named neither a program nor a bundle — and a click that
// closes the panel and raises nothing reads as a broken button.
check(!SessionFormat.canOpen(Session(json: ["entrypoint": "cli", "tty": "/dev/ttys004"], id: "x")),
      "a terminal session that recorded no terminal has no window to bring forward")
check(SessionFormat.canOpen(Session(json: ["entrypoint": "cli", "term_bundle": "com.apple.Terminal"], id: "x"))
      && SessionFormat.canOpen(Session(json: ["entrypoint": "cli", "term_program": "ghostty"], id: "x")),
      "a recorded hosting app or terminal program is somewhere to go")
check(SessionFormat.canOpen(Session(json: ["entrypoint": "claude-desktop"], id: "x"))
      && SessionFormat.canOpen(codexDesktop)
      && SessionFormat.canOpen(Session(json: ["entrypoint": "t3-code", "t3_thread": "th-1"], id: "x")),
      "a desktop conversation, a Codex thread and a T3 Code thread each open without a terminal")
check(!SessionFormat.canOpen(Session(json: ["entrypoint": "cli", "t3_thread": "th-1"], id: "x"))
      && !SessionFormat.canOpen(codexUnknown),
      "a thread id inherited from T3 Code, or a Codex session placed nowhere, is not a window")

// MARK: the tty a click focuses — normalised, and refused when it is not a device name

check(SessionFormat.ttyDevice("/dev/ttys004") == "/dev/ttys004", "the hook's own spelling passes")
check(SessionFormat.ttyDevice("ttys004") == "/dev/ttys004",
      "and the bare name `ps` prints is completed, because the dictionaries compare full paths")
check(SessionFormat.ttyDevice("") == nil, "no terminal, nothing to focus")

// The panel groups a blocking approval, then an async question, ahead of fresh activity.
check(SessionActivityGroup.allCases == [.needsYou, .working, .idle],
      "the panel presents attention before background work and idle sessions")
check(SessionActivityGroup(state: "permission", asyncQuestion: false) == .needsYou
      && SessionActivityGroup(state: "thinking", asyncQuestion: true) == .needsYou
      && SessionActivityGroup(state: "tool", asyncQuestion: false) == .working
      && SessionActivityGroup(state: "idle", asyncQuestion: false) == .idle,
      "the async question stays visible without claiming the agent is blocked")

// Which sessions the panel lists. Each rule answers a reported bug, and until now all of them
// lived in the controller where nothing checked them.
do {
    let now = 1_800_000_000.0
    func row(_ id: String, eff: String = "idle", age: Double = 0, _ extra: [String: Any] = [:]) -> Session {
        var s = Session(json: ["ts": now - age, "started": true].merging(extra) { $1 }, id: id)
        s.eff = eff
        return s
    }
    func keys(_ sessions: [Session], agents: AgentDisplay = .both,
              hiding: Set<ModelService> = [], prune: Double = 900) -> [String] {
        SessionRows.visible(sessions, now: now, agents: agents, hiding: hiding, stalePruneAge: prune)
    }
    check(keys([row("old", age: 30), row("b", age: 5), row("a", age: 5)]) == ["claude:a", "claude:b", "claude:old"],
          "rows run newest first, and two events of one second keep a stable order")
    let opened = row("d", ["entrypoint": "claude-desktop", "started": false])
    check(keys([opened, row("t")]) == ["claude:t"]
          && keys([row("d", eff: "thinking", ["entrypoint": "claude-desktop", "started": false])]) == ["claude:d"]
          && keys([row("c", ["entrypoint": "cli", "started": false])]) == ["claude:c"],
          "a desktop conversation that was only opened waits for real activity; a terminal one does not")
    check(keys([row("d", ["entrypoint": "claude-desktop"]), row("t", age: 1)]) == ["claude:d", "claude:t"],
          "once it has had a prompt, a desktop conversation stays listed while it rests")
    check(keys([opened]).isEmpty,
          "and it is not brought back as the one row kept so the panel is never empty")
    let resting = row("r", age: 1000)
    check(keys([row("w", eff: "tool", age: 1000), resting, row("n", age: 10)]) == ["claude:n", "claude:w"],
          "a session resting past the hide-idle age leaves the list; a working one that old stays")
    // Resting apart from its question: the question alone has to keep the row.
    var asking = row("q", age: 1000)
    asking.asyncQuestion = true
    check(keys([asking, row("p", eff: "permission", age: 1000)]) == ["claude:p", "claude:q"],
          "a session that needs the user is never hidden for its age")
    check(keys([resting, row("older", age: 2000)]) == ["claude:r"],
          "the most recent session stays when every one is resting, so the panel is never empty")
    check(keys([resting], prune: 0) == ["claude:r"] && keys([row("x", age: 5000), resting], prune: 0).count == 2,
          "hide-idle switched off hides nothing")
    let codexRow = row("c", ["provider": "codex"])
    check(keys([codexRow, row("a", age: 1)], agents: .claude) == ["claude:a"]
          && keys([codexRow], agents: .claude).isEmpty
          && keys([codexRow, row("a", age: 1)], agents: .hidden).count == 2,
          "an agent the setting leaves out is not listed, not even as the last row; Hidden is about the bar")
    check(keys([row("g", ["modelService": "zai"]), row("a", age: 1)], hiding: [.zai]) == ["claude:a"],
          "a hidden model service takes its sessions out of the list")

    check(SessionRows.offersOpenClaude(rows: 0, desktopRunning: true, agents: .both)
          && !SessionRows.offersOpenClaude(rows: 1, desktopRunning: true, agents: .both)
          && !SessionRows.offersOpenClaude(rows: 0, desktopRunning: false, agents: .both)
          && !SessionRows.offersOpenClaude(rows: 0, desktopRunning: true, agents: .codex),
          "Open Claude is offered only by an empty list, a running desktop app and a panel that shows Claude")
    // Asked of every session the app knows, not of the rows: a Codex session hidden for resting
    // too long still proves its hooks run, and "approve its hooks" would name the wrong cause.
    let hiddenCodex = row("h", age: 5000, ["provider": "codex"])
    check(keys([hiddenCodex, row("a")]) == ["claude:a"]
          && !SessionRows.codexHooksBlocked(untrusted: 2, agents: .both, sessions: [hiddenCodex, row("a")]),
          "a Codex session out of the list for its age still shows that Codex's hooks are running")
    check(SessionRows.codexHooksBlocked(untrusted: 2, agents: .both, sessions: [row("a")])
          && !SessionRows.codexHooksBlocked(untrusted: 0, agents: .both, sessions: [])
          && !SessionRows.codexHooksBlocked(untrusted: 2, agents: .claude, sessions: []),
          "unapproved Codex hooks are named only with no Codex session at all and Codex in the panel")
}

do {
    var board = ServiceUsageBoard()
    let now = Date(timeIntervalSince1970: 1000)
    let old = board.begin(.deepseek, at: now, minimumInterval: 60)!
    check(board.begin(.deepseek, at: now, minimumInterval: 0) == nil,
          "refresh clicks cannot stack requests for one key")
    board.reset(.deepseek)
    let replacement = board.begin(.deepseek, at: now, minimumInterval: 0)!
    check(!board.finish(.deepseek, request: old, result: .failure(.unauthorized), at: now),
          "a response for a removed or replaced key cannot overwrite the new result")
    check(board.finish(.deepseek, request: replacement, result: .failure(.keyMissing), at: now)
          && board[.deepseek].status == .notConfigured
          && board.begin(.deepseek, at: now.addingTimeInterval(59), minimumInterval: 60) == nil,
          "no key is distinct from failure and repeated panel opens respect the polling interval")
}

do {
    let json = """
    {"threads":[
        {"id":"11111111-1111-1111-1111-111111111111","name":"Réparer tests","cwd":"/tmp/O'Neil project",
         "updatedAt":1234,"branch":"feature/search","source":"cli","modelService":"deepseek"},
        {"id":"22222222-2222-2222-2222-222222222222","name":"","cwd":"/tmp/Other",
         "updatedAt":1000,"branch":"main","source":"vscode"}
    ],"hasMore":true,"codexHome":"/tmp/Codex account"}
    """
    let history = try JSONDecoder().decode(CodexHistory.self, from: Data(json.utf8))
    let first = history.threads[0]
    check(history.hasMore && history.threads[1].title == "Other",
          "history preserves the page boundary and uses the workspace for an unnamed chat")
    check(history.matching("reparer SEARCH", excluding: []).map(\.id) == [first.id]
          && history.matching("feature", excluding: [first.id]).isEmpty
          && history.matching("  ", excluding: []).count == 2,
          "history searches all words and keeps tracked live chats out of the resume list")
    check(history.matching("deepseek", excluding: []).map(\.id) == [first.id]
          && history.matching("", excluding: [], hiding: [.deepseek]).map(\.id) == [history.threads[1].id],
          "model services are searchable and hidden services stay out of history")
    // One tab, one word per surface: a terminal chat reads "CLI" in history exactly as the same
    // session read in Live a minute earlier, and is found by the word its row shows.
    check(first.sourceLabel == SessionFormat.surfaceTag(codexCLI) && first.sourceLabel == "CLI"
          && history.threads[1].sourceLabel.isEmpty
          && history.matching("cli", excluding: []).map(\.id) == [first.id],
          "history names a client with the Live badge's word, and an unknown client with none")
    check(first.resumeCommand(codexHome: history.codexHome)
          == "CODEX_HOME='/tmp/Codex account' codex resume --cd '/tmp/O'\"'\"'Neil project' \(first.id)",
          "resume copies the exact profile, workspace and thread id with shell-safe quoting")
    check(first.resumeCommand(codexHome: nil) == nil
          && first.resumeCommand(codexHome: "/tmp/injected\ncommand") == nil,
          "resume requires a known profile and rejects multiline shell input")
} catch {
    check(false, "Codex history payload decodes: \(error)")
}

do {
    let json = """
    {"threads":[
        {"id":"33333333-3333-4333-8333-333333333333","name":"Réparer limits","cwd":"/tmp/O'Neil project",
         "updatedAt":1234,"branch":"feature/search","source":"app"},
        {"id":"44444444-4444-4444-8444-444444444444","name":"","cwd":"/tmp/Other",
         "updatedAt":1000,"branch":"main","source":"future"},
        {"id":"not-a-session","name":"Broken","cwd":"","updatedAt":900,"branch":"","source":"cli"}
    ],"hasMore":true}
    """
    let history = try JSONDecoder().decode(ClaudeHistory.self, from: Data(json.utf8))
    let first = history.threads[0], second = history.threads[1]
    check(history.hasMore && second.title == "Other" && second.sourceLabel.isEmpty
          && first.sourceLabel == "APP" && first.opensInDesktop && !second.opensInDesktop,
          "Claude history keeps the page boundary, names an untitled chat by its folder and labels the client")
    check(history.matching("reparer SEARCH app", excluding: []).map(\.id) == [first.id]
          && history.matching("feature", excluding: [first.id]).isEmpty
          && history.matching("  ", excluding: []).count == 3,
          "Claude history searches every word and keeps live chats out of the list")
    check(first.resumeCommand == "cd '/tmp/O'\"'\"'Neil project' && claude --resume \(first.id)"
          && history.threads[2].resumeCommand == nil,
          "Claude resume enters the original folder with shell-safe quoting and needs a real session id")
    let homeless = try JSONDecoder().decode(ClaudeHistory.Thread.self, from: Data("""
    {"id":"55555555-5555-4555-8555-555555555555","name":"","cwd":"","updatedAt":1,"branch":"","source":"cli"}
    """.utf8))
    let injected = try JSONDecoder().decode(ClaudeHistory.Thread.self, from: Data("""
    {"id":"66666666-6666-4666-8666-666666666666","name":"","cwd":"/tmp/x\\ny","updatedAt":1,"branch":"","source":"cli"}
    """.utf8))
    check(homeless.resumeCommand == "claude --resume \(homeless.id)" && homeless.title == "Claude session"
          && injected.resumeCommand == nil,
          "Claude resume without a folder lets Claude find the chat, and a multiline folder is refused")
} catch {
    check(false, "Claude history payload decodes: \(error)")
}

// Both history lists and the Live rows name a client with one set of words, and a Claude chat is
// found by the word its row shows.
func claudeHistoryLabelChecks() {
    func thread(_ source: String) -> ClaudeHistory.Thread? {
        try? JSONDecoder().decode(ClaudeHistory.Thread.self, from: Data("""
        {"id":"chat","name":"","cwd":"","updatedAt":1,"branch":"","source":"\(source)"}
        """.utf8))
    }
    let live = ["cli": "cli", "app": "claude-desktop", "ide": "claude-vscode"]
    check(live.allSatisfy { source, entrypoint in
        let label = thread(source)?.sourceLabel
        return label != nil && label == SessionFormat.surfaceTag(Session(json: ["entrypoint": entrypoint], id: "x"))
    }, "Claude history names a terminal, app and editor chat with the Live row's word")
    check(thread("t3")?.sourceLabel == "T3" && thread("t3")?.sourceLabel == SessionFormat.surfaceLabel("t3"),
          "Claude history names a T3 Code chat as the Codex history does")
    let history = ClaudeHistory(threads: ["cli", "ide", "t3"].compactMap(thread), hasMore: false)
    check(history.matching("cli", excluding: []).map(\.source) == ["cli"]
          && history.matching("ide", excluding: []).map(\.source) == ["ide"]
          && history.matching("t3", excluding: []).map(\.source) == ["t3"]
          && history.matching("terminal", excluding: []).isEmpty,
          "Claude history search finds a chat by its client's short word")
}
claudeHistoryLabelChecks()
check(Session(json: ["entrypoint": "claude-desktop"], id: "d").hasFocusTarget
      && Session(json: ["entrypoint": "t3-code", "t3_thread": "thread"], id: "t").hasFocusTarget
      && Session(json: ["term_bundle": "com.apple.Terminal"], id: "b").hasFocusTarget
      && Session(json: ["term_program": "iTerm.app"], id: "p").hasFocusTarget
      && !Session(json: ["entrypoint": "cli"], id: "c").hasFocusTarget,
      "a running chat offers focus from history only when its row click has somewhere to go")
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
func codexEvent(ts: Double, _ type: String, turn: String = "", error: Any? = nil) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = iso.string(from: Date(timeIntervalSince1970: ts))
    let id = turn.isEmpty ? "" : ",\"turn_id\":\"\(turn)\""
    let failure = error.map {
        ",\"error\":" + String(decoding: try! JSONSerialization.data(withJSONObject: $0,
                                                                     options: [.fragmentsAllowed]), as: UTF8.self)
    } ?? ""
    return "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"\(id)\(failure)}}"
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
check(CodexRollout.boundary(Data(rolloutLine.utf8))?.ends == true,
      "and the Codex parser reads the same line as the end of a turn")

let terminalError: [String: Any] = [
    "message": "exceeded retry limit, last status: 429 Too Many Requests",
    "codex_error_info": ["response_too_many_failed_attempts": ["http_status_code": 429]],
]
let failedTurn = writeTranscript("codex-failed-turn.jsonl", lines: [
    codexEvent(ts: nowTs - 90, "task_started", turn: "t1"),
    codexEvent(ts: nowTs - 30, "task_complete", turn: "t1", error: terminalError),
])
for state in ["thinking", "tool", "done", "idle", "permission"] {
    check(engine.effectiveState(makeCodex(state: state, ts: nowTs - 60,
                                          transcript: failedTurn, turn: "t1"), now: nowTs) == "permission",
          "a terminal Codex error needs attention while the hook says \(state)")
}
check(engine.effectiveState(makeCodex(state: "tool", ts: nowTs - 7_200,
                                      transcript: failedTurn, turn: "t1"), now: nowTs) == "permission",
      "a terminal Codex error survives the age cap and repeated polling")

let alternateFailure = writeTranscript("codex-turn-failed.jsonl", lines: [
    codexEvent(ts: nowTs - 30, "turn_complete", turn: "t1", error: "authentication failed"),
])
check(engine.effectiveState(makeCodex(state: "idle", ts: nowTs - 60,
                                      transcript: alternateFailure, turn: "t1"), now: nowTs) == "permission",
      "turn_complete with a non-429 error also needs attention")
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60,
                                      transcript: failedTurn, turn: "t2"), now: nowTs) == "thinking",
      "a terminal error from a different turn does not request attention")
check(SessionEngine().effectiveState(makeSession(state: "thinking", ts: nowTs - 60,
                                                  transcript: failedTurn), now: nowTs) == "thinking",
      "a Codex terminal error does not change a Claude session")
let clockFailure = writeTranscript("codex-clock-failed.jsonl", lines: [
    codexEvent(ts: nowTs - 30, "task_complete", error: terminalError),
])
check(engine.effectiveState(makeCodex(state: "done", ts: nowTs - 60,
                                      transcript: clockFailure), now: nowTs) == "permission",
      "a terminal error matches by time when turn ids are unavailable")
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 20,
                                      transcript: clockFailure), now: nowTs) == "thinking",
      "a terminal error older than the current hook does not match without turn ids")

for emptyError: Any in [NSNull(), "", " \n\t", [String: Any](), [Any](), false, 0] {
    let emptyFailure = writeTranscript("codex-empty-error.jsonl", lines: [
        codexEvent(ts: nowTs - 30, "task_complete", turn: "t1", error: emptyError),
    ])
    check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60,
                                          transcript: emptyFailure, turn: "t1"), now: nowTs) == "idle",
          "an empty or non-error terminal value does not request attention: \(emptyError)")
}
let abortedFailure = writeTranscript("codex-aborted-error.jsonl", lines: [
    codexEvent(ts: nowTs - 30, "turn_aborted", turn: "t1", error: terminalError),
])
check(engine.effectiveState(makeCodex(state: "thinking", ts: nowTs - 60,
                                      transcript: abortedFailure, turn: "t1"), now: nowTs) == "idle",
      "an abort stays idle even if it carries an error")
let retriableFailure = writeTranscript("codex-retrying.jsonl", lines: [
    codexEvent(ts: nowTs - 60, "task_started", turn: "t1", error: terminalError),
    codexEvent(ts: nowTs - 30, "error", turn: "t1", error: terminalError),
    codexLine(["type": "function_call_output", "call_id": "quoted-failure",
               "output": codexEvent(ts: nowTs - 10, "task_complete", turn: "t1", error: terminalError)]),
])
check(engine.effectiveState(makeCodex(state: "tool", ts: nowTs - 60,
                                      transcript: retriableFailure, turn: "t1"), now: nowTs) == "tool",
      "a retriable error and quoted terminal output do not request attention")

do {
    let failurePath = writeTranscript("codex-failure-board.jsonl", lines: [
        codexEvent(ts: nowTs - 60, "task_started", turn: "t1"),
    ])
    let failureBoard = SessionBoard(engine: SessionEngine())
    var hook: [String: Any] = ["state": "idle", "ts": nowTs - 7_200, "turn_id": "t1",
                               "transcript": failurePath, "pid": 0]
    var failureFile = SessionBoard.File(key: "codex:failure", path: "/codex/failure.json",
                                       provider: "codex", id: "failure", mtime: Date())
    let failureRules = SessionBoard.Rules(soundThreshold: 0, stalePruneAge: 900,
                                        thinkingWords: [], needsYou: true)
    appendCodexLine(codexEvent(ts: nowTs - 30, "task_complete", turn: "t1",
                               error: terminalError), to: failurePath)
    failureBoard.reload([failureFile], read: { _ in hook }, branch: { _ in "" })
    let firstFailure = failureBoard.tick(now: nowTs, rules: failureRules,
                                        pidAlive: { _ in true }, frontmost: { "com.other" })
    check(firstFailure.needsYou && firstFailure.lead?.eff == "permission"
            && firstFailure.reaped.isEmpty,
          "a terminal error cues Needs you and keeps an old session visible")
    check(!failureBoard.tick(now: nowTs + 1, rules: failureRules,
                             pidAlive: { _ in true }, frontmost: { "com.other" }).needsYou,
          "a terminal error cues only once while attention remains")
    appendCodexLine(codexEvent(ts: nowTs + 2, "task_started", turn: "t2"), to: failurePath)
    hook["state"] = "thinking"; hook["turn_id"] = "t2"; hook["ts"] = nowTs + 2
    failureFile = SessionBoard.File(key: "codex:failure", path: "/codex/failure.json",
                                    provider: "codex", id: "failure",
                                    mtime: Date(timeIntervalSince1970: nowTs + 2))
    failureBoard.reload([failureFile], read: { _ in hook }, branch: { _ in "" })
    let retry = failureBoard.tick(now: nowTs + 2, rules: failureRules,
                                 pidAlive: { _ in true }, frontmost: { "com.other" })
    check(retry.lead?.eff == "thinking" && !retry.needsYou,
          "a new turn clears terminal attention and resumes work")
    appendCodexLine(codexEvent(ts: nowTs + 3, "task_complete", turn: "t1",
                               error: terminalError), to: failurePath)
    let late = failureBoard.tick(now: nowTs + 3, rules: failureRules,
                                pidAlive: { _ in true }, frontmost: { "com.other" })
    check(late.lead?.eff == "thinking" && !late.needsYou,
          "a late old-turn failure cannot raise attention during a retry")
    appendCodexLine(codexEvent(ts: nowTs + 4, "turn_complete", turn: "t2",
                               error: terminalError), to: failurePath)
    let nextFailure = failureBoard.tick(now: nowTs + 4, rules: failureRules,
                                       pidAlive: { _ in true }, frontmost: { "com.other" })
    check(nextFailure.lead?.eff == "permission" && nextFailure.needsYou,
          "a retry that fails cues one new Needs you transition")
    check(!failureBoard.tick(now: nowTs + 5, rules: failureRules,
                             pidAlive: { _ in true }, frontmost: { "com.other" }).needsYou,
          "the retry failure also cues only once")
    appendCodexLine(codexEvent(ts: nowTs + 6, "turn_started", turn: "t3"), to: failurePath)
    hook["turn_id"] = "t3"; hook["ts"] = nowTs + 6
    failureFile = SessionBoard.File(key: "codex:failure", path: "/codex/failure.json",
                                    provider: "codex", id: "failure",
                                    mtime: Date(timeIntervalSince1970: nowTs + 6))
    failureBoard.reload([failureFile], read: { _ in hook }, branch: { _ in "" })
    let resumed = failureBoard.tick(now: nowTs + 6, rules: failureRules,
                                   pidAlive: { _ in true }, frontmost: { "com.other" })
    check(resumed.lead?.eff == "thinking" && !resumed.needsYou,
          "turn_started also clears the previous failure")
    appendCodexLine(codexEvent(ts: nowTs + 7, "task_complete", turn: "t3"), to: failurePath)
    let succeeded = failureBoard.tick(now: nowTs + 7, rules: failureRules,
                                     pidAlive: { _ in true }, frontmost: { "com.other" })
    check(succeeded.lead?.eff == "idle" && !succeeded.needsYou,
          "a successful retry ends idle without an attention cue")
}

do {
    let start = 1_800_000_000.0
    let error = ["message": "synthetic failure"]
    for (startType, endType) in [("task_started", "task_complete"), ("turn_started", "turn_complete")] {
        for raw in ["done", "thinking"] {
            let path = writeTranscript("codex-late-boundary-\(endType)-\(raw).jsonl", lines: [
                codexEvent(ts: start - 120, startType, turn: "t1"),
                codexEvent(ts: start, startType, turn: "t2"),
                codexEvent(ts: start + 120, endType, turn: "t2", error: error),
            ])
            let currentEngine = SessionEngine()
            var session = makeCodex(state: raw, ts: start + 120, transcript: path, turn: "t2")
            check(currentEngine.effectiveState(session, now: start + 120) == "permission",
                  "\(endType) needs attention before an old completion while raw \(raw)")
            appendCodexLine(codexEvent(ts: start + 121, endType, turn: "t1"), to: path)
            check(currentEngine.effectiveState(session, now: start + 122) == "permission",
                  "a late old \(endType) preserves the current failure while raw \(raw)")
            check(currentEngine.effectiveState(session, now: start + 123) == "permission",
                  "an unchanged transcript retains the current failure while raw \(raw)")
            check(SessionEngine().effectiveState(session, now: start + 123) == "permission",
                  "a fresh engine also ignores the late old \(endType) while raw \(raw)")
            appendCodexLine(codexEvent(ts: start + 124, endType, turn: "t2"), to: path)
            check(currentEngine.effectiveState(session, now: start + 124) == "idle",
                  "the current successful \(endType) clears its failure while raw \(raw)")
            appendCodexLine(codexEvent(ts: start + 125, endType, turn: "t1"), to: path)
            check(currentEngine.effectiveState(session, now: start + 125) == "idle",
                  "a late old \(endType) preserves the current success while raw \(raw)")
            appendCodexLine(codexEvent(ts: start + 126, endType, turn: "t1", error: error), to: path)
            check(currentEngine.effectiveState(session, now: start + 126) == "idle",
                  "a late old failure cannot replace current success while raw \(raw)")
            appendCodexLine(codexEvent(ts: start + 127, startType, turn: "t3"), to: path)
            session = makeCodex(state: "thinking", ts: start + 127, transcript: path, turn: "t3")
            check(currentEngine.effectiveState(session, now: start + 127) == "thinking",
                  "a new \(startType) replaces the completed current turn")
        }
    }

    for raw in ["done", "thinking"] {
        let path = writeTranscript("codex-late-boundary-board-\(raw).jsonl", lines: [
            codexEvent(ts: start - 120, "task_started", turn: "t1"),
            codexEvent(ts: start, "task_started", turn: "t2"),
        ])
        let board = SessionBoard(engine: SessionEngine())
        var hook: [String: Any] = ["state": "thinking", "ts": start, "startedAt": start,
                                   "turn_id": "t2", "transcript": path, "pid": 1,
                                   "term_bundle": "com.apple.Terminal"]
        var file = SessionBoard.File(key: "codex:late", path: "/codex/late.json",
                                     provider: "codex", id: "late", mtime: Date(timeIntervalSince1970: start))
        let rules = SessionBoard.Rules(soundThreshold: 60, stalePruneAge: 900,
                                      thinkingWords: [], needsYou: true)
        board.reload([file], read: { _ in hook }, branch: { _ in "" })
        _ = board.tick(now: start, rules: rules, pidAlive: { _ in true }, frontmost: { "com.other" })
        appendCodexLine(codexEvent(ts: start + 120, "task_complete", turn: "t2", error: error), to: path)
        hook["state"] = raw; hook["ts"] = start + 120
        file = SessionBoard.File(key: "codex:late", path: "/codex/late.json", provider: "codex",
                                 id: "late", mtime: Date(timeIntervalSince1970: start + 120))
        board.reload([file], read: { _ in hook }, branch: { _ in "" })
        let failed = board.tick(now: start + 120, rules: rules,
                                pidAlive: { _ in true }, frontmost: { "com.other" })
        check(failed.lead?.eff == "permission" && failed.needsYou && !failed.chime,
              "the current failure cues only Needs you before the late old completion while raw \(raw)")
        appendCodexLine(codexEvent(ts: start + 121, "task_complete", turn: "t1"), to: path)
        let late = board.tick(now: start + 122, rules: rules,
                              pidAlive: { _ in true }, frontmost: { "com.other" })
        check(late.lead?.eff == "permission" && !late.needsYou && !late.chime,
              "the board retains current attention without a cue after the late old completion while raw \(raw)")
        let repeated = board.tick(now: start + 123, rules: rules,
                                  pidAlive: { _ in true }, frontmost: { "com.other" })
        check(repeated.lead?.eff == "permission" && !repeated.needsYou && !repeated.chime,
              "the board keeps attention quietly on the next tick while raw \(raw)")
    }
}

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

let unicodeOutput = codexLine(["type": "function_call_output", "call_id": "build",
                               "output": String(repeating: "日本語🦀e\u{301}", count: 20_000)])
let unicodeTail = writeTranscript("codex-unicode-tail.jsonl", lines: [rolloutLine, unicodeOutput])
let unicodeSession = makeCodex(state: "tool", ts: nowTs - 60, transcript: unicodeTail, turn: "t1")
check(engine.effectiveState(unicodeSession, now: nowTs) == "idle",
      "a completion behind large Unicode output is found in the larger tail window")
check(engine.effectiveState(unicodeSession, now: nowTs) == "idle",
      "the unchanged transcript keeps the cached completion")
appendCodexLine(codexEvent(ts: nowTs, "task_started", turn: "t1"), to: unicodeTail)
check(engine.effectiveState(unicodeSession, now: nowTs) == "tool",
      "an append invalidates the cache and the newest start outranks the older completion")
appendCodexLine(codexEvent(ts: nowTs, "turn_complete", turn: "t1"), to: unicodeTail)
check(engine.effectiveState(unicodeSession, now: nowTs) == "idle",
      "a subsequent completion ends the turn without a final newline")

let cutPath = sessionsDir + "codex-cut-utf8.jsonl"
var cutBytes = Data((codexLine(["type": "function_call_output", "call_id": "unicode",
                                "output": String(repeating: "🦀", count: 10_000)])
                     + "\n" + rolloutLine).utf8)
while cutBytes[cutBytes.count - 8_192] & 0xc0 != 0x80 { cutBytes.append(32) }
try! cutBytes.write(to: URL(fileURLWithPath: cutPath))
check(engine.effectiveState(makeCodex(state: "tool", ts: nowTs - 60, transcript: cutPath,
                                     turn: "t1"), now: nowTs) == "idle",
      "a tail window starting inside a UTF-8 code point still finds the later completion")

for invalid in [
    #"{"type":"response_item","note":"task_complete","payload":{"type":"task_complete"}}"#,
    #"{"timestamp":"bad","type":"event_msg","payload":{"type":"task_complete"}}"#,
    #"{"timestamp":"2026-10-14T00:00:00Z","type":"event_msg","note":"task_complete","payload":[]}"#,
    #"{"type":"event_msg","payload":{"type":"task_complete"}"#,
] {
    let invalidPath = writeTranscript("codex-invalid-boundary.jsonl", lines: [invalid])
    check(SessionEngine().effectiveState(makeCodex(state: "tool", ts: nowTs,
                                                  transcript: invalidPath), now: nowTs) == "tool",
          "a successful ASCII gate still requires a valid boundary envelope and timestamp")
}

let malformedClaude = writeTranscript("claude-malformed-newest.jsonl", lines: [
    turnRecord(ts: nowTs - 30, content: "[Request interrupted by user]"),
    #"{"type":"assistant","message":{"content":"unfinished"#,
])
check(engine.effectiveState(makeSession(state: "thinking", ts: nowTs - 60,
                                        transcript: malformedClaude), now: nowTs) == "thinking",
      "a malformed newest Claude candidate does not fall back to an older interrupt")

let repairedPath = sessionsDir + "codex-invalid-utf8.jsonl"
var repairedBytes = Data(#"{"note":""#.utf8)
repairedBytes.append(0xff)
repairedBytes.append(Data((#"","timestamp":"2026-10-14T00:00:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#).utf8))
try! repairedBytes.write(to: URL(fileURLWithPath: repairedPath))
check(engine.effectiveState(makeCodex(state: "tool", ts: nowTs - 60, transcript: repairedPath,
                                     turn: "t1"), now: nowTs) == "idle",
      "invalid UTF-8 in an otherwise valid candidate is repaired as before")

let crlfPath = writeTranscript("codex-crlf.jsonl", lines: [
    codexEvent(ts: nowTs - 60, "task_started", turn: "t1") + "\r\n" + rolloutLine + "\r\n",
])
check(engine.effectiveState(makeCodex(state: "tool", ts: nowTs - 30, transcript: crlfPath,
                                     turn: "t1"), now: nowTs) == "idle",
      "CRLF-delimited rollout records are separate JSON lines")
check(engine.effectiveState(makeSession(state: "thinking", ts: nowTs - 60,
                                        transcript: codexShapedForClaude), now: nowTs) == "thinking",
      "a Claude session is unmoved by a Codex boundary record")

// The optional desktop Question is a current-turn notice, independent of the working state.
do {
    let now = 1_800_000_000.0
    func item(_ value: [String: Any], turn: String = "notice-turn", at: Double = now + 1,
              pretty: Bool = false) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let root: [String: Any] = ["timestamp": iso.string(from: Date(timeIntervalSince1970: at)),
            "type": "event_msg", "payload": ["type": "item_completed", "turn_id": turn, "item": value]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: root,
            options: pretty ? [.prettyPrinted] : []), as: UTF8.self)
    }
    let question: [String: Any] = ["type": "AgentMessage", "id": "notice-item", "delivery": "async",
        "questions": [["title": "First", "options": []], ["title": "Second", "options": []]]]
    let askedLine = item(question)
    func reply(_ index: Any, id: String = "notice-item", prefix: String = "request_user_input_async") -> String {
        let questionID = String(decoding: try! JSONSerialization.data(withJSONObject: [prefix, id, index]), as: UTF8.self)
        let answer = String(decoding: try! JSONSerialization.data(withJSONObject:
            ["questionItemId": questionID, "question": "First", "answer": "Yes"]), as: UTF8.self)
        return "<send_user_message_question_reply>\n\(answer)\n</send_user_message_question_reply>"
    }
    func user(_ text: String, steering: String? = nil, turn: String = "notice-turn") -> String {
        let content: [[String: Any]] = [["type": "text", "text": text]]
        if let steering {
            return item(["type": "SteeringUserMessage", "id": "reply", "status": steering,
                         "input": content], turn: turn, at: now + 2)
        }
        return item(["type": "UserMessage", "id": "reply", "content": content], turn: turn, at: now + 2)
    }
    let start = codexEvent(ts: now, "task_started", turn: "notice-turn")
    let noticePath = writeTranscript("codex-async-notice.jsonl", lines: [start])
    let noticeEngine = SessionEngine()
    let noticeBoard = SessionBoard(engine: noticeEngine)
    let file = SessionBoard.File(key: "codex:notice", path: "/notice.json", provider: "codex",
                                 id: "notice", mtime: Date(timeIntervalSince1970: 1))
    var json: [String: Any] = ["state": "thinking", "provider": "codex", "transcript": noticePath,
        "turn_id": "notice-turn", "ts": now, "startedAt": now - 120, "pid": 1]
    let rules = SessionBoard.Rules(soundThreshold: 60, stalePruneAge: 900, thinkingWords: [], needsYou: true)
    func tick() -> SessionBoard.Tick {
        noticeBoard.tick(now: now + 3, rules: rules, pidAlive: { _ in true }, frontmost: { "com.other" })
    }
    func bar() -> MenuBarAgent {
        MenuBarAgent.shown(.codex, board: noticeBoard, claude: nil, claudeStatus: nil,
                          oauthLimits: true, codex: nil, now: now + 3)[0]
    }
    noticeBoard.reload([file], read: { _ in json }) { _ in "" }
    _ = tick()
    let before = bar()
    check(!Session(json: ["asyncQuestion": true], id: "empty").asyncQuestion,
          "the async notice defaults to false and is not trusted from a hook file")
    appendCodexLine(askedLine, to: noticePath)
    let asked = tick()
    check(asked.lead?.asyncQuestion == true,
          "a real async AgentMessage creates a separate current-turn Question notice")
    check(asked.lead?.eff == "thinking" && asked.lead?.startedAt == now - 120 && !asked.needsYou && !asked.chime,
          "the Question leaves Thinking and its live clock running without either sound")
    let marked = bar()
    check(marked.asyncQuestion && !marked.badge && marked.signature != before.signature,
          "the Codex question fact changes the icon cache signature without a permission badge")
    check(marked.timer(show: true, now: now + 3) == before.timer(show: true, now: now + 3)
          && marked.animates(.pet("codex")) == before.animates(.pet("codex")),
          "the Question preserves the working timer and companion animation")
    let symbol = NSImage(systemSymbolName: Provider.codex.glyph, accessibilityDescription: "Codex")!
    symbol.isTemplate = true
    let questionIcon = marked.markedIcon(symbol, fallback: false, permissionColor: .systemOrange)
    check(questionIcon !== symbol && questionIcon.accessibilityDescription?.contains("Вопрос") == true,
          "the async marker draws and names a quiet question mark beside the Codex icon")
    let blank = NSImage(size: NSSize(width: 18, height: 18))
    blank.isTemplate = true
    let drawnMark = marked.markedIcon(blank, fallback: false, permissionColor: .systemOrange)
    check(drawnMark.isTemplate && crabHasPixel(drawnMark) { $0.alphaComponent > 0.5 },
          "the Question marker has visible adaptive pixels without a permission colour")
    json["state"] = "tool"
    noticeBoard.reload([SessionBoard.File(key: file.key, path: file.path, provider: file.provider,
        id: file.id, mtime: Date(timeIntervalSince1970: 2))], read: { _ in json }) { _ in "" }
    let working = tick()
    check(working.lead?.asyncQuestion == true && working.lead?.eff == "tool" && !working.needsYou && !working.chime,
          "the same quiet Question survives a real hook transition from Thinking to Working")

    appendCodexLine(codexLine(["type": "function_call_output", "call_id": "notice-item",
                              "output": #"{"accepted":true}"#]), to: noticePath)
    check(tick().lead?.asyncQuestion == true, "accepted:true acknowledges the tool and does not answer its Question")
    for status in ["pending", "rejected"] {
        appendCodexLine(user(reply(0), steering: status), to: noticePath)
        check(tick().lead?.asyncQuestion == true, "a \(status) steering reply does not clear the notice")
    }
    for index in [true, 0.5, -1, 9] as [Any] {
        appendCodexLine(user(reply(index)), to: noticePath)
        check(tick().lead?.asyncQuestion == true, "an invalid question index \(index) cannot clear the notice")
    }
    appendCodexLine(user(reply(0, id: "another-item")), to: noticePath)
    appendCodexLine(user(reply(0, prefix: "request_user_input")), to: noticePath)
    appendCodexLine(user("<send_user_message_question_reply>broken</send_user_message_question_reply>"), to: noticePath)
    check(tick().lead?.asyncQuestion == true, "unknown IDs, another request type and malformed replies keep the notice")
    appendCodexLine(user(reply(0), steering: "accepted"), to: noticePath)
    check(tick().lead?.asyncQuestion == true, "an accepted partial reply leaves the other Question index visible")
    appendCodexLine(askedLine, to: noticePath)
    appendCodexLine(user(reply(1)), to: noticePath)
    check(tick().lead?.asyncQuestion == false, "a duplicate item does not revive an answered index; the last reply clears it")
    check(bar().signature == before.signature, "clearing the Question also clears its render cache signature")
    try! (start + "\n" + askedLine).write(toFile: noticePath, atomically: true, encoding: .utf8)
    _ = tick()
    let responseReply = String(decoding: try! JSONSerialization.data(withJSONObject: [
        "timestamp": "2027-01-15T08:00:02.000Z", "type": "response_item", "payload": [
            "type": "message", "role": "user", "content": [["type": "input_text", "text": reply(0)]]]]), as: UTF8.self)
    appendCodexLine(responseReply, to: noticePath)
    check(tick().lead?.asyncQuestion == true, "the accepted response_item reply clears only its matching index")
    appendCodexLine(user(reply(1)), to: noticePath)
    check(tick().lead?.asyncQuestion == false, "a following accepted UserMessage clears the last index across both wire forms")

    for boundary in ["task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted"] {
        try! (start + "\n" + askedLine).write(toFile: noticePath, atomically: true, encoding: .utf8)
        check(tick().lead?.asyncQuestion == true, "the notice exists before \(boundary)")
        appendCodexLine(codexEvent(ts: now + 2, boundary,
            turn: CodexRollout.startTypes.contains(boundary) ? "next-turn" : "notice-turn"), to: noticePath)
        check(tick().lead?.asyncQuestion == false, "\(boundary) clears the current-turn notice")
    }
    try! (start + "\n" + askedLine).write(toFile: noticePath, atomically: true, encoding: .utf8)
    _ = tick()
    appendCodexLine(item(question, turn: "old-turn"), to: noticePath)
    appendCodexLine(codexEvent(ts: now + 2, "turn_complete", turn: "old-turn"), to: noticePath)
    appendCodexLine(user(reply(0), turn: "old-turn"), to: noticePath)
    appendCodexLine(user(reply(1), turn: "old-turn"), to: noticePath)
    check(tick().lead?.asyncQuestion == true, "late records from another turn neither create nor clear this turn's notice")
    appendCodexLine(user("Continue with the current task"), to: noticePath)
    check(tick().lead?.asyncQuestion == false, "a new actual user message clears the informational notice")

    let invalidItems: [[String: Any]] = [
        ["type": "AgentMessage", "id": "notice-item", "delivery": "async", "questions": []],
        ["type": "AgentMessage", "id": "notice-item", "delivery": "sync", "questions": question["questions"]!],
        ["type": "AgentMessage", "delivery": "async", "questions": question["questions"]!],
        ["type": "AgentMessage", "id": "notice-item", "delivery": "async", "questions": [[:]]],
        ["type": "ToolResult", "id": "notice-item", "delivery": "async", "questions": question["questions"]!],
    ]
    for invalid in invalidItems {
        try! (start + "\n" + item(invalid)).write(toFile: noticePath, atomically: true, encoding: .utf8)
        check(tick().lead?.asyncQuestion == false, "an incomplete or non-async item creates no Question notice")
    }
    let quote = codexLine(["type": "function_call_output", "call_id": "quote", "output": askedLine])
    try! (start + "\n" + quote + "\n" + questionCall + "\n" + questionAccepted)
        .write(toFile: noticePath, atomically: true, encoding: .utf8)
    check(tick().lead?.asyncQuestion == false, "quoted Question events and accepted async calls alone create no notice")
    try! (start + "\n" + item(question, turn: "old-turn") + "\n" + item(question, at: now - 1))
        .write(toFile: noticePath, atomically: true, encoding: .utf8)
    check(tick().lead?.asyncQuestion == false, "another turn or a pre-start timestamp cannot create this turn's Question")
    try! (start + "\n" + codexEvent(ts: now + 2, "task_complete", turn: "notice-turn") + "\n" + askedLine)
        .write(toFile: noticePath, atomically: true, encoding: .utf8)
    check(tick().lead?.asyncQuestion == false, "a late Question after turn completion stays cleared")

    let prettyLine = item(question, pretty: true).replacingOccurrences(of: "\n", with: " ")
    try! (start + "\n" + String(prettyLine.dropLast())).write(toFile: noticePath, atomically: true, encoding: .utf8)
    check(tick().lead?.asyncQuestion == false, "an incomplete final JSON record is deferred")
    let tail = FileHandle(forWritingAtPath: noticePath)!
    tail.seekToEndOfFile(); tail.write(Data("}".utf8)); tail.closeFile()
    check(tick().lead?.asyncQuestion == true, "the completed whitespace-formatted record creates the notice once")
    check(tick().lead?.asyncQuestion == true && !tick().needsYou, "an unchanged transcript keeps the notice quietly on later ticks")
    try! start.write(toFile: noticePath, atomically: false, encoding: .utf8)
    check(tick().lead?.asyncQuestion == false, "shrinking the transcript clears cached Questions")
    try! (start + "\n" + askedLine).write(toFile: noticePath, atomically: true, encoding: .utf8)
    check(tick().lead?.asyncQuestion == true, "a replacement transcript is parsed from its beginning")
    try! (start + "\n" + quote).write(toFile: noticePath, atomically: true, encoding: .utf8)
    check(tick().lead?.asyncQuestion == false, "replacing the transcript cannot retain the old Question")
    try! (start + "\n" + askedLine).write(toFile: noticePath, atomically: true, encoding: .utf8)
    _ = tick()
    try! FileManager.default.removeItem(atPath: noticePath)
    noticeEngine.dropCache(forTranscript: noticePath)
    check(tick().lead?.asyncQuestion == false, "deletion and cache reset remove the current-turn notice")

    try! (start + "\n" + askedLine + "\n" + blockingQuestionCall)
        .write(toFile: noticePath, atomically: true, encoding: .utf8)
    let blocked = tick()
    let permissionBar = bar()
    check(blocked.lead?.asyncQuestion == true && blocked.lead?.eff == "permission" && blocked.needsYou,
          "a real blocking request keeps permission priority over the separate async notice")
    check(permissionBar.badge && permissionBar.signature != marked.signature
          && permissionBar.markedIcon(symbol, fallback: false, permissionColor: .systemOrange)
                .accessibilityDescription?.contains("Вопрос") != true,
          "permission changes the cache and replaces the quiet question marker")
    try! (start + "\n" + askedLine + "\n" + codexEvent(ts: now + 2, "task_complete",
            turn: "notice-turn", error: ["message": "synthetic failure"]))
        .write(toFile: noticePath, atomically: true, encoding: .utf8)
    let failed = tick()
    check(failed.lead?.asyncQuestion == false && failed.lead?.eff == "permission" && !failed.chime,
          "a terminal error clears Question and preserves the established Needs you path")
    json["turn_id"] = "another-turn"
    noticeBoard.reload([SessionBoard.File(key: file.key, path: file.path, provider: file.provider,
        id: file.id, mtime: Date(timeIntervalSince1970: 3))], read: { _ in json }) { _ in "" }
    try! (start + "\n" + askedLine).write(toFile: noticePath, atomically: true, encoding: .utf8)
    check(tick().lead?.asyncQuestion == false, "a session state for another turn never inherits the notice")
    let claudeBoard = SessionBoard(engine: SessionEngine())
    claudeBoard.reload([SessionBoard.File(key: "claude:notice", path: file.path, provider: "claude",
        id: "notice", mtime: file.mtime)], read: { _ in json }) { _ in "" }
    let claude = claudeBoard.tick(now: now + 3, rules: rules, pidAlive: { _ in true }, frontmost: { nil })
    check(claude.lead?.asyncQuestion == false && claude.lead?.eff == "tool" && !claude.needsYou,
          "Codex Question records do not change a Claude session")
}

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

do {
    let now = 1_000_000.0
    let failed = LimitsStatus(json: ["state": "failed", "ts": now, "detail": "timeout"])
    let codex = LimitsStatus.notice(failed, oauthLimits: true, figuresTs: now - 7_200, now: now, provider: "codex")
    check(codex?.title == "Codex limits update failed: request timed out" && codex?.offerSignIn == false,
          "Codex has its own safe error and never offers Claude sign-in")
    check(codex?.hint.contains("2h ago") == true,
          "the Codex error preserves the actual age of cached figures")
    let claude = LimitsStatus.notice(failed, oauthLimits: true, figuresTs: nil, now: now)
    check([claude, codex].compactMap { $0 }.count == 2,
          "independent Claude and Codex failures both produce notices")
    check(LimitsStatus.notice(failed, oauthLimits: false, figuresTs: nil, now: now, provider: "codex") == nil,
          "the Codex switch hides its stale failure")
    let empty = LimitsStatus(json: ["state": "empty", "ts": now, "detail": "no_windows"])
    check(LimitsStatus.notice(empty, oauthLimits: true, figuresTs: nil, now: now, provider: "codex")?.title
          == "Codex returned no limit windows", "empty API data is explained without inventing zeros")
    var poll = CodexLimitsPoll()
    check(poll.begin(now: now), "the first Codex limits request starts immediately")
    check(!poll.begin(now: now + 300), "one Codex limits request can be in flight")
    poll.finish()
    check(!poll.begin(now: now + 59.9), "panel and settings requests share a sixty-second debounce")
    check(poll.begin(now: now + 60), "Codex limits can refresh at the debounce boundary")
    poll.finish()
    check(poll.begin(now: now + 360), "the five-minute background poll can refresh Codex")
}

// MARK: LimitsStatus — why the last poll brought no figures
// limits-status.json is written by mcpbar.py on every poll, including the ones that leave
// limits.json alone. The app reads the state as a string, like every other status from the
// scripts, and only ever decides three things from it: what the block over the strip says, what
// the empty strip says, and what the Settings line says.
let failedStatus = LimitsStatus(json: ["state": "failed", "ts": 1_791_921_000, "detail": "HTTPError"])
check(failedStatus?.state == "failed" && failedStatus?.detail == "HTTPError",
      "state and detail read as strings")
check(failedStatus?.ts == 1_791_921_000, "an integer ts reads as the stamp, not as zero")
check(LimitsStatus(json: ["ts": 1.0, "detail": "x"]) == nil, "no state, no status")
check(LimitsStatus(json: ["state": "ok"])?.detail == "" && LimitsStatus(json: ["state": "ok"])?.ts == 0,
      "a bare state has safe defaults for the rest")

let limitsStatusSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/limits-status.json"
if let data = FileManager.default.contents(atPath: limitsStatusSeamPath),
   let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    let seamStatus = LimitsStatus(json: root)
    check(seamStatus?.state == "no-login", "the signed-out poll crosses over as no-login")
    check((seamStatus?.ts ?? 0) > 0 && seamStatus?.detail == "no token",
          "the stamp and the short reason cross over")
} else {
    check(false, "limits-status seam fixture missing at \(limitsStatusSeamPath) — run the python "
        + "suite first (/usr/bin/python3 -m unittest discover -s tests), it writes "
        + "build/seam/limits-status.json")
}

let polledAt = 1_000_000.0
let signedOut = LimitsStatus(json: ["state": "no-login", "ts": 1_000_000, "detail": "no token"])
let pollFailed = LimitsStatus(json: ["state": "failed", "ts": 1_000_000, "detail": "HTTPError"])
let pollEmpty = LimitsStatus(json: ["state": "empty", "ts": 1_000_000, "detail": "no windows"])
let pollOK = LimitsStatus(json: ["state": "ok", "ts": 1_000_000, "detail": ""])
check(LimitsStatus.notice(pollOK, oauthLimits: true, figuresTs: polledAt - 240, now: polledAt) == nil,
      "a successful poll has nothing to say")
check(LimitsStatus.notice(signedOut, oauthLimits: false, figuresTs: polledAt - 86_400, now: polledAt) == nil,
      "with the API poll switched off, no block whatever the file says")
check(LimitsStatus.notice(nil, oauthLimits: true, figuresTs: polledAt - 86_400, now: polledAt) == nil,
      "no status file (an older backend) means the panel behaves as before")
check(LimitsStatus.notice(signedOut, oauthLimits: true, figuresTs: polledAt - 86_400, now: polledAt)
        == LimitsNotice(title: "Claude Code is not signed in",
                        hint: "Limits stopped updating 1d ago. Sign in to resume.",
                        offerSignIn: true),
      "signed out, with old figures: the block names the cause and how old the figures are")
check(LimitsStatus.notice(signedOut, oauthLimits: true, figuresTs: nil, now: polledAt)
        == LimitsNotice(title: "Claude Code is not signed in",
                        hint: "Sign in to see limits.", offerSignIn: true),
      "signed out with no figures at all: no age is invented")
check(LimitsStatus.notice(pollFailed, oauthLimits: true, figuresTs: polledAt - 7_200, now: polledAt)
        == LimitsNotice(title: "Limits poll failed: HTTPError",
                        hint: "Showing figures from 2h ago. The next poll is a few minutes away.",
                        offerSignIn: false),
      "a failed poll names the exception and offers no sign-in")
check(LimitsStatus.notice(pollEmpty, oauthLimits: true, figuresTs: nil, now: polledAt)
        == LimitsNotice(title: "The usage endpoint returned no limit windows",
                        hint: "No figures yet. The next poll is a few minutes away.",
                        offerSignIn: false),
      "an empty answer is its own cause, not a sign-in problem")
// limits.json has a second writer, the statusLine capture. While it keeps the figures moving
// and only the API poll fails, the block would sit over live figures saying they stopped.
check(LimitsStatus.notice(pollFailed, oauthLimits: true, figuresTs: polledAt + 60, now: polledAt + 120) == nil,
      "figures written after the failed poll: nothing to explain, the figures are live")
check(LimitsStatus.notice(signedOut, oauthLimits: true, figuresTs: polledAt + 1, now: polledAt + 120) == nil,
      "the same for a sign-out: fresher figures mean another source is still feeding the strip")
check(LimitsStatus.notice(pollFailed, oauthLimits: true, figuresTs: polledAt - 60, now: polledAt + 120)
        == LimitsNotice(title: "Limits poll failed: HTTPError",
                        hint: "Showing figures from 3 min ago. The next poll is a few minutes away.",
                        offerSignIn: false),
      "figures older than the failed poll: the block stays, dated from the figures")
check(LimitsStatus.notice(pollFailed, oauthLimits: true, figuresTs: polledAt, now: polledAt + 120) != nil,
      "figures and poll stamped the same second: the poll's own verdict stands")

// The one signed-out banner. The first tick reads whatever limits-status.json was left from the
// previous run, before this launch's own poll has answered; a banner off that file announces a
// sign-out that may be a day old and already over.
check(LimitsStatus.signedOutBannerDue(signedOut, oauthLimits: true, figuresTs: nil, launchedAt: polledAt + 1) == false,
      "a no-login file from before this launch is not news")
check(LimitsStatus.signedOutBannerDue(signedOut, oauthLimits: true, figuresTs: nil, launchedAt: polledAt - 10) == true,
      "a poll made since launch that found no login: the banner goes out")
check(LimitsStatus.signedOutBannerDue(signedOut, oauthLimits: true, figuresTs: nil, launchedAt: polledAt + 0.4) == true,
      "the script stamps whole seconds: a poll answered within the launch second still counts")
check(LimitsStatus.signedOutBannerDue(signedOut, oauthLimits: true, figuresTs: polledAt + 30, launchedAt: polledAt - 10) == false,
      "figures refreshed by the other writer since the poll: no banner, as there is no block")
check(LimitsStatus.signedOutBannerDue(signedOut, oauthLimits: true, figuresTs: polledAt - 86_400, launchedAt: polledAt - 10) == true,
      "old figures do not hold the banner back")
check(LimitsStatus.signedOutBannerDue(pollFailed, oauthLimits: true, figuresTs: nil, launchedAt: polledAt - 10) == false,
      "only a sign-out is announced; a failed poll is the panel's business")
check(LimitsStatus.signedOutBannerDue(signedOut, oauthLimits: false, figuresTs: nil, launchedAt: polledAt - 10) == false,
      "with the API poll switched off, no banner whatever the file says")
check(LimitsStatus.signedOutBannerDue(nil, oauthLimits: true, figuresTs: nil, launchedAt: polledAt - 10) == false,
      "no status file, no banner")

// The menu bar sign: the same rule as the panel block, so the icon never says what the panel
// does not show.
check(LimitsStatus.menuBarTip == "Claude Code is not signed in — open the panel to sign in",
      "the icon tip names the cause and the way out")
check(LimitsStatus.signedOutShown(signedOut, oauthLimits: true, figuresTs: nil) == true,
      "signed out with no figures at all shows the sign")
check(LimitsStatus.signedOutShown(signedOut, oauthLimits: true, figuresTs: polledAt - 86_400) == true,
      "signed out with day-old figures shows the sign")
check(LimitsStatus.signedOutShown(signedOut, oauthLimits: true, figuresTs: polledAt + 1) == false,
      "figures newer than the poll hide the sign: the other writer keeps them moving")
check(LimitsStatus.signedOutShown(signedOut, oauthLimits: false, figuresTs: nil) == false,
      "with the API poll switched off there is no sign whatever the file says")
check(LimitsStatus.signedOutShown(pollFailed, oauthLimits: true, figuresTs: nil) == false
      && LimitsStatus.signedOutShown(pollEmpty, oauthLimits: true, figuresTs: nil) == false,
      "a failed or empty poll is not a sign-out")
check(LimitsStatus.signedOutShown(pollOK, oauthLimits: true, figuresTs: nil) == false
      && LimitsStatus.signedOutShown(nil, oauthLimits: true, figuresTs: nil) == false,
      "ok and no status file show no sign")

check(LimitsStatus.emptyStripText(signedOut, oauthLimits: false) == "Limits are switched off in Settings",
      "switched off wins over whatever the file says")
check(LimitsStatus.emptyStripText(nil, oauthLimits: true) == "No data yet — is Claude Code signed in?",
      "no status file: the strip's old wording")
check(LimitsStatus.emptyStripText(pollFailed, oauthLimits: true) == "No figures yet",
      "a failed poll does not ask about sign-in; the block above carries the cause")
check(LimitsStatus.emptyStripText(pollEmpty, oauthLimits: true) == "No figures yet",
      "an empty answer does not ask about sign-in either")
check(LimitsStatus.emptyStripText(signedOut, oauthLimits: true)
        == "Claude Code is not signed in — sign in to see limits",
      "signed out: the strip says so instead of guessing")

check(LimitsStatus.pollLine(nil, polledAge: "4 min ago", figuresAge: nil) == "",
      "no status file: Settings shows no line")
check(LimitsStatus.pollLine(pollOK, polledAge: "4 min ago", figuresAge: "4 min ago")
        == "Last poll: ok · 4 min ago", "ok: when the poll ran")
check(LimitsStatus.pollLine(signedOut, polledAge: "4 min ago", figuresAge: "1d ago")
        == "Last poll: not signed in · figures from 1d ago", "signed out: how old the figures are")
check(LimitsStatus.pollLine(signedOut, polledAge: "4 min ago", figuresAge: nil)
        == "Last poll: not signed in", "signed out with no figures: no age is invented")
check(LimitsStatus.pollLine(pollFailed, polledAge: "4 min ago", figuresAge: "1d ago")
        == "Last poll: failed (HTTPError) · figures from 1d ago", "failed: the exception, in brackets")
check(LimitsStatus.pollLine(pollEmpty, polledAge: "4 min ago", figuresAge: nil)
        == "Last poll: no limit windows", "empty: worded, not the raw state")

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
// Half a percent is the one sanctioned deviation from pure rounding: round(0.005 × 64px) = 0,
// but the battery gauge never draws "empty" for a non-zero charge, so anything above zero keeps
// a one-device-pixel sliver.
for (pct, px) in [(0.005, 1.0), (0.05, 3.0), (0.18, 12.0), (0.50, 32.0), (0.95, 61.0), (1.00, 64.0)] {
    check(Gauge.fillWidth(pct) * 2 == CGFloat(px),
          "fillWidth(\(pct * 100)%) is \(Gauge.fillWidth(pct) * 2)px, expected \(px)px")
}
check(Gauge.fillWidth(-0.5) == 0, "a negative value clamps to empty")
check(Gauge.fillWidth(3.0) == Gauge.barW, "an absurd value clamps to full")

// And the same width must survive the actual drawing code: rasterise image(icon:) at 2x and
// read the alpha along the bar's centre row. A pure function can be honest while the bezier
// path lies (that is exactly what happened).
func gaugeRowAlphas(_ gauge: Gauge) -> [CGFloat] {
    let image = gauge.image(icon: nil)
    let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
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
    return (barX..<(barX + Int(Gauge.barW * 2))).map { rep.colorAt(x: $0, y: row)?.alphaComponent ?? 0 }
}

// The bar is drawn the way the panel's is, and the way T3 Code draws it: the solid part is what
// is LEFT of the window, counted from the left edge. So 18% used is a bar 82% solid.
func measuredLeftPx(used: Double) -> Int {
    gaugeRowAlphas(Gauge(fiveHour: used, sevenDay: nil)).filter { $0 > 0.6 }.count
}
for (used, px) in [(0.05, 61), (0.18, 52), (0.50, 32), (0.95, 3), (0.0, 64)] {
    let got = measuredLeftPx(used: used)
    check(abs(got - px) <= 1,
          "at \(Int(used * 100))% used the solid part is \(got)px of 64, expected \(px)±1 (antialiasing)")
}
let sliver = measuredLeftPx(used: 0.995)
check(sliver >= 1 && sliver <= 2, "half a percent left draws a \(sliver)px sliver, not an empty bar")
check(measuredLeftPx(used: 1.0) == 0, "and a spent window draws no solid part at all")

// A window with a clock also gets the line where even spending would be, in a slot cut out of the
// bar, and its spent part is hatched: hatching says "this comes back at the reset".
do {
    let half = Gauge(fiveHour: 0.5, sevenDay: nil, timeLeft: (0.75, nil))
    let alphas = gaugeRowAlphas(half)
    let at = Int(Gauge.barW * 2 * 0.75)
    check(alphas.count == Int(Gauge.barW * 2) && alphas[at] > 0.6, "the line is drawn at the time left")
    check(alphas[at - 3] < 0.1 && alphas[at + 2] < 0.1, "with a clear slot on either side of it")
    // Past the slot, to the end: hatch lines on a bare track, so some pixels are inked and some not.
    let spent = alphas[(at + 6)...]
    let inked = spent.filter { $0 > 0.6 }.count
    check(inked > 0 && inked < spent.count / 2, "the spent part is hatched, not solid and not bare")
    let plain = gaugeRowAlphas(Gauge(fiveHour: 0.5, sevenDay: nil))
    check(plain[(at - 3)...].allSatisfy { $0 > 0.1 && $0 < 0.6 },
          "a window with no clock keeps a bare track: no line, no slot, no hatch")
    check(half.signature != Gauge(fiveHour: 0.5, sevenDay: nil).signature
            && half.signature != Gauge(fiveHour: 0.5, sevenDay: nil, timeLeft: (0.5, nil)).signature,
          "the line is part of what the cached icon is keyed by")
    check(Gauge(fiveHour: 0.34, sevenDay: nil).image(icon: nil).accessibilityDescription
            == "5 hour limit 66% left",
          "and VoiceOver hears what is left, as the bar shows, not what is used")

    // A few percent left with the window nearly over: the line sits at the bar's left end, and a
    // slot cut around it there would wipe the remainder — "nearly out" drawn as "out".
    for used in [0.90, 0.92, 0.95, 0.99] {
        let nearlyOut = gaugeRowAlphas(Gauge(fiveHour: used, sevenDay: nil, timeLeft: (0.03, nil)))
        // One device pixel at 1% left, two from 2% up: a point of the bar is all the slot spares.
        check(nearlyOut[0] > 0.6,
              "with \(Int((100 - used * 100).rounded()))% left at the end of a window a sliver of it stays in front of the slot")
    }
    let nothingLeft = gaugeRowAlphas(Gauge(fiveHour: 1.0, sevenDay: nil, timeLeft: (0.03, nil)))
    check(nothingLeft[0] < 0.1, "while a spent window shows none")
    check(Gauge.markPosition(0.5, width: 32, solid: 20) == 16 && Gauge.markPosition(0.5, width: 32, solid: 0) == 16,
          "away from the ends the line is exactly at the time left")
    check(Gauge.markPosition(0, width: 32, solid: 0) == Gauge.markSlot
            && Gauge.markPosition(0, width: 32, solid: 3) == Gauge.markSlot + 1
            && Gauge.markPosition(0, width: 32, solid: 0.5) == Gauge.markSlot + 0.5
            && Gauge.markPosition(1, width: 32, solid: 32) == 32 - Gauge.markSlot,
          "at the left end it keeps up to a point further in while anything is left, and no more")

    // The line for a bar is found by the bar's own window, not by its place in the pair.
    let weekOnly = Gauge(fiveHour: nil, sevenDay: 0.3, timeLeft: (nil, 0.6))
    check(weekOnly.signature == "7d30|60" && gaugeRowAlphas(weekOnly)[Int(Gauge.barW * 2 * 0.6)] > 0.6,
          "a lone weekly bar gets the weekly window's line")
    check(Gauge.leftPercent(1.4) == 0 && Gauge.leftPercent(-0.2) == 100,
          "what is left is held to 0…100 like the bar itself")
}

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
    check(mainSource.contains("if d.object(forKey: \"codexPetID\") == nil { d.set(codexPetID, forKey: \"codexPetID\") }"),
          "and that first answer is saved, so later launches stop deriving it from Claude's pet")
    check(mainSource.contains("\"Needs you\"") && !mainSource.contains("Awaiting permission"),
          "permission uses the short Needs you status-bar label")
    check(mainSource.contains(".markedIcon(") && !mainSource.contains("dot: true"),
          "permission renders a badge over the mascot instead of replacing it with a dot")
    check(mainSource.contains("MenuBarAgent.shown("),
          "the status-bar mood is selected with the permission-aware display model")
    // The one-click update deletes the running copy's bundle before the new one first starts,
    // so "can this bundle start here" has to be answered before the move aside, not after it.
    let swapSource = mainSource.range(of: "private func mountAndSwap(").map { mainSource[$0.upperBound...] } ?? ""
    let beforeMoveAside = swapSource.range(of: "moveItem(atPath: target, toPath: aside)")
        .map { swapSource[..<$0.lowerBound] } ?? ""
    check(beforeMoveAside.contains("[\"--verify\", \"--deep\", \"--strict\", stage.path]")
            && beforeMoveAside.contains("UpdateFeed.systemProblem(minimum: minimum"),
          "a staged update's signature and minimum macOS are checked before the running copy is moved aside")
    // UpdateOffer's rules are checked further down; these hold the places that have to ask it.
    let checkSource = mainSource.range(of: "func checkForUpdate(force: Bool = false) {")
        .map { mainSource[$0.upperBound...] } ?? ""
    let checkBody = checkSource.range(of: "func updateCheckFinished(").map { checkSource[..<$0.lowerBound] } ?? ""
    check(checkBody.components(separatedBy: "self?.announceUpdateOffer()").count == 3
            && !checkBody.contains("updateNotifiedVersion"),
          "both answers of the update check, GitHub's and the cask's, ask whether there is an update to announce")
    check(mainSource.contains("if case .restart = updateOffer() { return restartIntoInstalledCopy() }"),
          "Install with a newer copy already on disk restarts into it instead of downloading it again")
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
        ["name": "claude-control-bar.dmg.sig",
         "browser_download_url": "https://github.com/x/releases/download/v0.8.0/claude-control-bar.dmg.sig",
         "size": 89],
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
check(asset?.signatureURL?.absoluteString.hasSuffix("/claude-control-bar.dmg.sig") == true,
      "the .sig published next to the image is picked up")
let ghDMG = "https://github.com/x/releases/download/v1/a.dmg"
let okDigest = "sha256:" + String(repeating: "ab", count: 32)
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": ghDMG, "size": 5,
                                           "digest": okDigest]]])?.signatureURL == nil,
      "a release without a .sig offers the image without a signature URL")
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": ghDMG, "size": 5]]]) == nil,
      "a release that carries no digest is refused: nothing would prove the download is that file")
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": ghDMG]]]) == nil,
      "a size-less asset is refused: without it a truncated download cannot be told apart")
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": ghDMG,
                                           "size": 5, "digest": "md5:abc"]]]) == nil,
      "a digest of another algorithm is not mistaken for sha256")
check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": ghDMG,
                                           "size": 5, "digest": "sha256:abc"]]]) == nil,
      "a truncated sha256 is refused")
for foreign in ["https://evil.example/releases/download/v1/a.dmg", "http://github.com/x/releases/download/v1/a.dmg",
                "https://github.com.evil.example/x/releases/download/v1/a.dmg", "https://github.com/x/archive/a.dmg"] {
    check(UpdateFeed.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": foreign, "size": 5,
                                               "digest": okDigest]]]) == nil,
          "an image outside GitHub's https release downloads is refused: \(foreign)")
}
check(UpdateFeed.dmgAsset(in: ["assets": [
        ["name": "a.dmg.sig", "browser_download_url": "https://evil.example/releases/download/v1/a.dmg.sig", "size": 89],
        ["name": "a.dmg", "browser_download_url": ghDMG, "size": 5, "digest": okDigest]]])?.signatureURL == nil,
      "a signature hosted outside GitHub is not taken")
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
check(UpdateFeed.verify(file: dmgTmp, against: UpdateFeed.ReleaseAsset(url: good.url, size: 3, sha256: nil)) != nil,
      "no digest advertised: the size alone does not pass")
// Ed25519, RFC 8032 §7.1 TEST 2 (message 0x72) — the same vector tests/update-signing.test.js
// checks on the Node side that signs releases, so the two halves agree on the encodings.
let rfcPub = Data([0x3d, 0x40, 0x17, 0xc3, 0xe8, 0x43, 0x89, 0x5a, 0x92, 0xb7, 0x0a, 0xa7, 0x4d, 0x1b, 0x7e, 0xbc,
                   0x9c, 0x98, 0x2c, 0xcf, 0x2e, 0xc4, 0x96, 0x8c, 0xc0, 0xcd, 0x55, 0xf1, 0x2a, 0xf4, 0x66, 0x0c] as [UInt8])
    .base64EncodedString()
let rfcSig = Data([0x92, 0xa0, 0x09, 0xa9, 0xf0, 0xd4, 0xca, 0xb8, 0x72, 0x0e, 0x82, 0x0b, 0x5f, 0x64, 0x25, 0x40,
                   0xa2, 0xb2, 0x7b, 0x54, 0x16, 0x50, 0x3f, 0x8f, 0xb3, 0x76, 0x22, 0x23, 0xeb, 0xdb, 0x69, 0xda,
                   0x08, 0x5a, 0xc1, 0xe4, 0x3e, 0x15, 0x99, 0x6e, 0x45, 0x8f, 0x36, 0x13, 0xd0, 0xf1, 0x1d, 0x8c,
                   0x38, 0x7b, 0x2e, 0xae, 0xb4, 0x30, 0x2a, 0xee, 0xb0, 0x0d, 0x29, 0x16, 0x12, 0xbb, 0x0c, 0x00] as [UInt8])
    .base64EncodedString()
let signedTmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccb-signed-test.dmg")
try! Data([0x72]).write(to: signedTmp)
check(UpdateFeed.verifySignature(file: signedTmp, signature: rfcSig + "\n", publicKey: rfcPub) == nil,
      "the RFC 8032 vector verifies, trailing newline of the .sig file included")
check(UpdateFeed.verifySignature(file: dmgTmp, signature: rfcSig, publicKey: rfcPub) != nil,
      "a signature over other bytes is refused")
check(UpdateFeed.verifySignature(file: signedTmp, signature: rfcSig,
                                 publicKey: Data(repeating: 9, count: 32).base64EncodedString()) != nil,
      "a signature by another key is refused")
check(UpdateFeed.verifySignature(file: signedTmp, signature: "AAAA", publicKey: rfcPub) != nil,
      "a malformed signature is refused")
check(UpdateFeed.verifySignature(file: signedTmp, signature: rfcSig, publicKey: "short") != nil,
      "a malformed key is refused")
check(UpdateFeed.signingKey.isEmpty || Data(base64Encoded: UpdateFeed.signingKey)?.count == 32,
      "the built-in update key, once set, is 32 raw bytes in base64")
try? FileManager.default.removeItem(at: signedTmp)
try? FileManager.default.removeItem(at: dmgTmp)

// The staged bundle's LSMinimumSystemVersion against this Mac, asked before the old copy is moved.
let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)
check(UpdateFeed.systemProblem(minimum: "13.0", system: ventura) == nil,
      "a bundle that asks for an older macOS than this one may be swapped in")
check(UpdateFeed.systemProblem(minimum: "13.5", system: ventura) == nil,
      "a bundle that asks for exactly this macOS may be swapped in")
check(UpdateFeed.systemProblem(minimum: "13.5.1", system: ventura) != nil,
      "a newer patch release than this macOS is refused")
let tooNew = UpdateFeed.systemProblem(minimum: "14.0", system: ventura)
check(tooNew?.contains("14.0") == true && tooNew?.contains("13.5") == true,
      "a bundle that needs a newer macOS is refused, naming both versions: \(tooNew ?? "nil")")
check(UpdateFeed.systemProblem(minimum: nil, system: ventura) == nil,
      "a bundle that names no minimum is not held back: macOS reads that as no requirement")

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
// A launcher wrapped around the hosting app leaves ITS bundle id in the session file, so the
// comparison above never matches the app actually in front. The process tree still knows who
// started the session. It is a second reason for silence and not a replacement: iTerm's shells
// hang off a detached server and tmux's off its own, so their tree never reaches the window.
check(!NeedsYouSound.shouldCue(prevState: "tool", effective: "permission",
                               hostBundle: "local.t3.auto-launcher", frontmost: "com.t3tools.t3code",
                               frontmostHosts: true),
      "no cue when the app in front started the session, whatever bundle a launcher recorded")
check(NeedsYouSound.shouldCue(prevState: "tool", effective: "permission",
                              hostBundle: "local.t3.auto-launcher", frontmost: "com.apple.Safari",
                              frontmostHosts: false),
      "the same session behind an unrelated app still cues")
check(!NeedsYouSound.shouldCue(prevState: "tool", effective: "permission",
                               hostBundle: "com.googlecode.iterm2", frontmost: "com.googlecode.iterm2",
                               frontmostHosts: false),
      "the recorded bundle still silences a terminal whose process tree does not reach its window")
do {
    let parents: [pid_t: pid_t] = [40: 30, 30: 20, 20: 1, 50: 1, 60: 61, 61: 60]
    check(RunningProcesses.descends(40, from: 20) { parents[$0] }
          && RunningProcesses.descends(40, from: 40) { parents[$0] },
          "a session's process descends from the app two levels up, and from itself")
    check(!RunningProcesses.descends(40, from: 50) { parents[$0] }
          && !RunningProcesses.descends(20, from: 40) { parents[$0] },
          "an unrelated app is not an ancestor, and a parent does not descend from its child")
    check(!RunningProcesses.descends(40, from: 1) { parents[$0] }
          && !RunningProcesses.descends(0, from: 20) { parents[$0] },
          "launchd hosts nobody although everything hangs off it, and a file without a pid has no tree")
    check(!RunningProcesses.descends(60, from: 20) { parents[$0] }
          && !RunningProcesses.descends(40, from: 99) { _ in nil },
          "a loop in the table ends the walk, and so does a process that has already gone")
    check(RunningProcesses.parentPid(getpid()) == getppid()
          && RunningProcesses.descends(getpid(), from: getppid()),
          "the real process table agrees: this check descends from whatever launched it")
    // Terminal's shells hang off `login`, which runs as root. A lookup that is refused for
    // another user's process would stop the walk one step short of the terminal window.
    check(RunningProcesses.parentPid(1) == 0, "a root-owned process still names its parent")

    let board = SessionBoard(engine: SessionEngine())
    let rules = SessionBoard.Rules(soundThreshold: 60, stalePruneAge: 900, thinkingWords: [], needsYou: true)
    func wait(_ id: String) -> SessionBoard.File {
        SessionBoard.File(key: "claude:" + id, path: "/" + id, provider: "claude", id: id,
                          mtime: Date(timeIntervalSince1970: 1))
    }
    func read(_ path: String) -> [String: Any]? {
        ["state": "permission", "pid": path == "/hosted" ? 21 : 22, "ts": 1_800_000_000.0,
         "term_bundle": "local.t3.auto-launcher"]
    }
    board.reload([wait("hosted")], read: read) { _ in "" }
    check(!board.tick(now: 1_800_000_000, rules: rules, pidAlive: { _ in true },
                      frontmost: { "com.t3tools.t3code" }, frontmostHosts: { $0.pid == 21 }).needsYou,
          "the board asks the process tree about the session that started waiting, and stays silent")
    board.reload([wait("hosted"), wait("elsewhere")], read: read) { _ in "" }
    check(board.tick(now: 1_800_000_001, rules: rules, pidAlive: { _ in true },
                     frontmost: { "com.t3tools.t3code" }, frontmostHosts: { $0.pid == 21 }).needsYou,
          "while a session the app in front did not start cues as before")
}
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

// MARK: Gauge.signedOutLayout — the signed-out mark keeps the block's width and spares the bars

do {
    let strip = Gauge.labelW + Gauge.labelGap + Gauge.barW
    let withBars = NSSize(width: Gauge.sideInset * 2 + 18 + Gauge.iconGap + strip, height: 18)
    let (stripX, mark) = Gauge.signedOutLayout(size: withBars, bars: true)
    check(mark.minX >= 0 && mark.maxX <= withBars.width && mark.minY >= 0 && mark.maxY <= withBars.height,
          "the mark stays inside the block: a wider item is parked behind the overflow chevron")
    check(mark.maxX <= stripX, "the mark does not cover the bars (it hid half of the top bar)")
    check(stripX == withBars.width - Gauge.sideInset - strip, "the dimmed part is exactly the strip")
    let iconOnly = NSSize(width: 18, height: 18)
    let (noStrip, iconMark) = Gauge.signedOutLayout(size: iconOnly, bars: false)
    check(noStrip == iconOnly.width, "without bars nothing is dimmed")
    check(iconMark.maxX <= iconOnly.width && iconMark.minX >= 0, "without bars the mark sits on the icon")
    let tiny = NSSize(width: 4, height: 4)
    let (_, tinyMark) = Gauge.signedOutLayout(size: tiny, bars: true)
    check(tinyMark.minX >= 0 && tinyMark.minY >= 0, "a degenerate size never yields a negative origin")
}

// MARK: LimitsNote — how old each provider's figures are, said once per provider

// The footer used to quote the oldest stamp for everybody: a Claude poll that stopped a day ago
// made live Codex figures read "1d ago" too. The wording is pinned literally, because the line
// shares 300pt with two buttons and "measured 4 minutes ago" once truncated to nothing.
check(LimitsNote.age(of: 1_000, now: 1_000) == "just now", "the same second is just now")
check(LimitsNote.age(of: 1_000, now: 1_059) == "just now", "under a minute is still just now")
check(LimitsNote.age(of: 1_000, now: 1_060) == "1 min ago", "a minute is the first minute count")
check(LimitsNote.age(of: 1_000, now: 1_000 + 59 * 60 + 59) == "59 min ago",
      "minutes run up to the hour")
check(LimitsNote.age(of: 1_000, now: 1_000 + 3_600) == "1h ago", "an hour rolls minutes into hours")
check(LimitsNote.age(of: 1_000, now: 1_000 + 23 * 3_600 + 3_599) == "23h ago",
      "hours run up to the day")
check(LimitsNote.age(of: 1_000, now: 1_000 + 24 * 3_600) == "1d ago", "a day rolls hours into days")
check(LimitsNote.age(of: 1_000, now: 1_000 + 28 * 24 * 3_600) == "28d ago",
      "and a month-old stamp reads in days, not as 40320 minutes")
check(LimitsNote.age(of: 5_000, now: 1_000) == "just now",
      "a stamp from the future (clock skew) reads as just now rather than a negative age")
check(LimitsNote.age(of: 0, now: .nan) == "just now", "a NaN clock cannot trap the conversion")

check(LimitsNote.footer([]) == "", "no provider, no footer")
check(LimitsNote.footer([(title: "Claude", age: "4 min ago")]) == "Limits · 4 min ago",
      "one provider keeps the line the panel always had")
check(LimitsNote.footer([(title: "Codex", age: "just now")]) == "Limits · just now",
      "and a lone Codex strip names no provider either: there is nothing to tell it from")
check(LimitsNote.footer([(title: "Claude", age: "1d ago"), (title: "Codex", age: "just now")])
        == "Claude 1d ago · Codex just now",
      "two providers each carry their own age")
check(LimitsNote.footer([(title: "A", age: "1h ago"), (title: "B", age: "2h ago"),
                         (title: "C", age: "3h ago")]) == "A 1h ago · B 2h ago · C 3h ago",
      "and a third one is joined the same way")

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

// MARK: pace — where even spending would be by now
//
// A percentage alone does not say whether it is a lot: 33% of the week gone on its second day is
// trouble, on its sixth it is nothing. The window's own clock answers that — how much of its
// time has passed — and the panel draws it as a line on the bar. The thresholds are T3 Code's,
// so the same account reads the same way in both.
let paceNow = 1_800_000_000.0
func weekWindow(used: Int, daysLeft: Double?, minutes: Int? = 10080) -> NamedWindow {
    NamedWindow(key: "seven_day", title: "7 days", badge: nil, minutes: minutes,
                window: LimitWindow(used: used, resets: daysLeft.map { paceNow + $0 * 86400 }))
}
// Five and a half days left of seven: 78.6% of the week still to come.
check(weekWindow(used: 33, daysLeft: 5.5).timeLeftPercent(at: paceNow) == 79,
      "a week with five and a half days to go has 79% of its time left")
check(LimitWindow(used: 33, resets: nil).remaining == 67, "and 33% used leaves 67%")
check(LimitWindow(used: 140, resets: nil).remaining == 0 && LimitWindow(used: -5, resets: nil).remaining == 100,
      "a figure outside 0…100 cannot leave less than nothing or more than everything")
check(weekWindow(used: 33, daysLeft: 5.5).pace(at: paceNow) == .ahead,
      "33% used by then is ahead of even spending")
check(weekWindow(used: 24, daysLeft: 5.5).pace(at: paceNow) == .on,
      "within five points of the clock is on pace")
check(weekWindow(used: 10, daysLeft: 5.5).pace(at: paceNow) == .under,
      "and well behind it leaves headroom")
check(weekWindow(used: 16, daysLeft: 5.5).pace(at: paceNow) == .under
        && weekWindow(used: 17, daysLeft: 5.5).pace(at: paceNow) == .on,
      "the margin is the same five points on the slow side: 5.43 behind is under, 4.43 is on pace")
// The week is 21.43% gone. Against the rounded 21, 27% used and 26% used would be gaps of 6 and
// 5; against the clock itself they are 5.57 and 4.57, and that is what is compared.
check(weekWindow(used: 27, daysLeft: 5.5).pace(at: paceNow) == .ahead,
      "a gap of more than five points is ahead, measured against the unrounded clock")
check(weekWindow(used: 26, daysLeft: 5.5).pace(at: paceNow) == .on,
      "and one of less than five is not")
check(weekWindow(used: 50, daysLeft: nil).timeLeftPercent(at: paceNow) == nil
        && weekWindow(used: 50, daysLeft: nil).pace(at: paceNow) == nil,
      "a window that does not say when it resets has no clock to compare with")
check(weekWindow(used: 50, daysLeft: 3, minutes: nil).timeLeftPercent(at: paceNow) == nil
        && weekWindow(used: 50, daysLeft: 3, minutes: 0).timeLeftPercent(at: paceNow) == nil,
      "nor does one whose length is unknown or zero")
check(weekWindow(used: 50, daysLeft: 9).timeLeftPercent(at: paceNow) == 100,
      "a reset further off than the window is long is the very start, not more than all of it")
check(weekWindow(used: 50, daysLeft: -1).timeLeftPercent(at: paceNow) == 0,
      "and one already past has no time left")

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
let codexAPISeamPath = FileManager.default.currentDirectoryPath + "/build/seam/codex-limits-api.json"
if let data = FileManager.default.contents(atPath: codexAPISeamPath),
   let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let set = LimitsSet(codex: raw) {
    check(set.source == "app-server" && set.ts == 1_792_575_900 && set.plan == "pro",
          "the real API writer preserves source, measurement time and plan across Python and Swift")
    check(set.windows.map { $0.window.used } == [24] && set.windows.map(\.title) == ["7 days"],
          "the API window parses with its actual weekly duration and percentage")
    check(set.windows.first?.window.resets == 1_793_132_700,
          "the API reset time crosses the file boundary unchanged")
} else {
    check(false, "codex API seam fixture unreadable; run the Python tests first")
}

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
    // The reserve turn was measured an hour (3600 s) after the ordinary ones. The record's own age
    // is the ordinary pool's: a fresh reserve figure must not make the morning's windows look new.
    check(seamSet.ts == 1_789_120_800, "the record is as old as the ordinary pool: \(seamSet.ts)")
    check(seamSet.windows.compactMap { $0.ts } == [1_789_120_800, 1_789_120_800, 1_789_124_400],
          "while each window keeps the stamp it was measured at: \(seamSet.windows.map { $0.ts })")
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
// mcpbar.py answers through its files and explains a failure on stderr; its stdout is never data.
let hookErrorsOnly = HookInstall.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 10,
                                     errorsOnly: true)
check(hookErrorsOnly.end == .exited(3) && hookErrorsOnly.output == "err\n",
      "a backend run keeps what the child said on stderr and nothing from stdout: \(hookErrorsOnly.output)")

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
// What a pipe read to EOF could not do: the stopped script's own child still holds the write end.
let hookOrphanAt = Date()
let hookOrphan = HookInstall.run("/bin/sh", ["-c", "sleep 6 & sleep 30"], timeout: 0.5, errorsOnly: true)
check(hookOrphan.end == .timedOut && Date().timeIntervalSince(hookOrphanAt) < 5,
      "a child stopped at its deadline is not waited on for the grandchild it leaves behind")
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

// Claude's half worked and Codex's did not, which install.js says with an exit status of its own.
// Not a `problem`: that word puts "Session hooks aren't installed" in the panel and starts the
// retry timer, over hooks that are in place.
let hookCodexMissed = HookInstall.Run(end: .exited(73), output:
    "~/.codex/hooks.json does not parse — Codex hooks not installed.\nHooks already current in settings.json")
let hookCodexVerdict = HookInstall.health(rejected: [], installer: hookCodexMissed, runtime: nil)
check(hookCodexVerdict.problem == nil,
      "a Codex file that was not written is not a failed install of Claude's hooks: \(hookCodexVerdict)")
check(hookCodexVerdict
        == .codexNotWritten(reason: "~/.codex/hooks.json does not parse — Codex hooks not installed."),
      "and it is said in the installer's own first line: \(hookCodexVerdict)")
check(HookInstall.health(rejected: [hookDead], installer: hookCodexMissed,
                         runtime: "/opt/homebrew/bin/node", isHomebrew: hookBrew).problem?.title
        == "Session hooks can't run",
      "a node the hooks cannot start still outranks the Codex file")

// codex/hooks.json counted only the hooks waiting for trust, so zero meant both "all approved"
// and "Codex lists none of ours" — and Settings drew the tick for a Codex with no hooks in it.
check(CodexHookTrust(untrusted: nil, listed: nil) == .notAsked
        && CodexHookTrust(untrusted: nil, listed: 0) == .notAsked,
      "no answer from Codex is not an answer about its hooks")
check(CodexHookTrust(untrusted: 0, listed: 0) == .notInstalled,
      "none of our hooks in Codex's list is not \"approved\"")
check(CodexHookTrust(untrusted: 0, listed: 8) == .approved
        && CodexHookTrust(untrusted: 3, listed: 8) == .waiting(3),
      "listed hooks are approved or waiting, by Codex's own count")
check(CodexHookTrust(untrusted: 0, listed: nil) == .approved
        && CodexHookTrust(untrusted: 2, listed: nil) == .waiting(2),
      "a file from before the count was recorded reads as it always did")
check(CodexHookTrust.listed(in: ["untrusted": 2]) == nil
        && CodexHookTrust.listed(in: ["untrusted": 0, "ours": "8"]) == nil,
      "a missing or mistyped count is no count, not zero")
// The python→swift seam: the file the real fetch_codex_hooks() wrote during the python suite.
let codexHooksSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/codex-hooks.json"
if let data = FileManager.default.contents(atPath: codexHooksSeamPath),
   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    check(CodexHookTrust.listed(in: object) == 1, "the count the real backend wrote is read back")
} else {
    check(false, "codex hooks seam fixture missing at \(codexHooksSeamPath) — run the python suite "
        + "first (/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/codex-hooks.json")
}

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
check(PetRow.forSessionState("permission", provider: "codex") == .waving,
      "Codex attracts attention with a wave when it needs you")
check(PetRow.forSessionState("thinking", provider: "codex") == .running,
      "Codex resumes its working animation once the user answers")
check(PetRow.forSessionState("idle", provider: "codex") == .idle,
      "Codex rests once its turn ends")
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

// Deliberately different blocks: the widest is in the running row and the tallest in the
// idle one, so a trim taken from either row alone would be visibly wrong.
// Together they cover x 40…159 and y 70…129 — 120 across by 60 down, which is 2:1.
let iconDir = iconPetDir + "marked/"
try? FileManager.default.createDirectory(atPath: iconDir, withIntermediateDirectories: true)
try! petManifest("marked", name: "Marked").write(toFile: iconDir + "pet.json",
                                                 atomically: true, encoding: .utf8)
writeMarkedAtlas([(.idle, 70, 70, 40, 60), (.running, 40, 80, 120, 30), (.waiting, 80, 90, 20, 20),
                  (.waving, 100, 110, 20, 20)],
                 to: iconDir + "spritesheet.png")

/// Whether anything was drawn at that point of a finished icon, counted from the TOP left the way
/// a picture is read rather than the way it is drawn.
///
/// `x` and `y` are points, and an icon holds more than one pixel to the point, so the question is
/// asked of every pixel inside that point: an edge is reached when any of them is drawn on.
func iconHasInk(_ image: NSImage, x: Int, y: Int) -> Bool {
    guard let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
          x >= 0, y >= 0, image.size.width >= 1 else { return false }
    let scale = max(1, rep.pixelsWide / Int(image.size.width))
    return (0..<scale).contains { dx in
        (0..<scale).contains { dy in
            let px = x * scale + dx, py = y * scale + dy
            return px < rep.pixelsWide && py < rep.pixelsHigh
                && (rep.colorAt(x: px, y: py)?.alphaComponent ?? 0) > 0.1
        }
    }
}

let markedPet = Pet.load(directory: iconDir)
check(markedPet != nil, "the marked atlas loads as a pet at all")
let barFrames = PetIconFrames(markedPet!, height: 18, provider: "codex")
check(barFrames != nil, "a pet with art in it can be cut down to the bar")

if let barFrames {
    let idle = barFrames.frames(for: .idle)
    let running = barFrames.frames(for: .running)
    let waiting = barFrames.frames(for: .waiting)
    let waving = barFrames.frames(for: .waving)
    check(!waving.isEmpty, "the Codex Needs you gesture is available in the menu bar")
    check(waving.first.map { image in
        (0..<Int(image.size.width)).contains { x in
            (0..<Int(image.size.height)).contains { y in iconHasInk(image, x: x, y: y) }
        }
    } ?? false, "the Codex Needs you gesture contains visible mascot pixels")
    check(!idle.isEmpty && !running.isEmpty && !waiting.isEmpty,
          "every animation the bar can ask for was cut")
    let sizes = Set((idle + running + waiting + waving).map { "\($0.size)" })
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

// MARK: what a pet's frames keep alive
//
// A sheet is 14 MB once decoded, and a frame cut out of it is a window onto it: one frame kept
// anywhere keeps the whole sheet. Frames are kept in places nobody owns — the bar's used to be
// pictures that drew themselves from the sheet when shown, and a closed window still holds the
// last thing it drew: five pets were on screen when Settings closed, and five sheets stayed.
// So every frame handed out has to be pixels of its own.
check(barFrames?.frames(for: .idle).first?.representations.first?.pixelsHigh == 36,
      "a bar frame is finished pixels, two to the point, and not a drawing that holds the sheet")
let rowFrame = PetAtlas(markedPet!)?.loop(for: .idle).images.first?
    .cgImage(forProposedRect: nil, context: nil, hints: nil)
check(rowFrame?.width == PetFormat.v2.cellWidth && rowFrame?.bytesPerRow == PetFormat.v2.cellWidth * 4,
      "a row frame is a picture one cell wide, not a window onto rows as wide as the sheet")
// A frame cut straight from the file is one cell wide too, and it is the one that costs a decode
// of the whole sheet each time it is shown. This atlas is a PNG with plain alpha, so such a frame
// reports plain alpha; one drawn into our own bitmap reports the premultiplied alpha it was made with.
check(rowFrame?.alphaInfo == .premultipliedLast,
      "and it was drawn into a bitmap of ours rather than left to be decoded from the file")

// A pet whose rows are empty has no margin to measure, and dividing by that height is how an
// icon ends up infinitely wide. Nothing to draw has to come back as nothing to draw.
let blankDir = writePet("blank", in: iconPetDir, manifest: petManifest("blank", name: "Blank"),
                        atlas: (1536, 2288))
check(PetIconFrames(Pet.load(directory: blankDir)!, height: 18) == nil,
      "a pet with nothing drawn in it cannot become an icon")

try? FileManager.default.removeItem(atPath: iconPetDir)

// A Codex CLI hook may name its shared daemon, which outlives the terminal client.
do {
    let board = SessionBoard(engine: SessionEngine())
    let now = 1_800_000_000.0
    let file = SessionBoard.File(key: "codex:orphan", path: "/codex/orphan.json",
        provider: "codex", id: "orphan", mtime: Date(timeIntervalSince1970: now))
    board.reload([file], read: { _ in ["pid": 42, "provider": "codex", "surface": "cli",
        "tty": "/dev/ttys002", "state": "permission", "ts": now] }, branch: { _ in "" })
    let tick = board.tick(now: now, rules: .init(soundThreshold: 0, stalePruneAge: 900,
        thinkingWords: [], needsYou: true), pidAlive: { _ in true }, frontmost: { nil },
        owner: { _ in .dead })
    check(tick.reaped.map(\.key) == ["codex:orphan"] && board.sessions.isEmpty,
          "a closed CLI is reaped even while the shared daemon PID is alive")
    check(tick.lead == nil && !tick.needsYou, "the closed CLI cannot lead or cue Needs you")
}

// Automatic cleanup must survive restart even when a former PID belongs to a new process.
do {
    let folder = NSTemporaryDirectory() + "ccb-auto-reap-" + UUID().uuidString
    let marker = folder + "/dismissed.json"
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let files = ["claude", "codex"].map { provider in
        SessionBoard.File(key: provider + ":closed", path: "/" + provider, provider: provider,
            id: "closed", mtime: Date(timeIntervalSince1970: 100))
    }
    let json: [String: Any] = ["pid": 42, "state": "permission", "ts": 100,
                               "surface": "cli", "tty": "/dev/ttys002"]
    let rules = SessionBoard.Rules(soundThreshold: 0, stalePruneAge: 900,
                                  thinkingWords: [], needsYou: true)
    let board = SessionBoard(engine: SessionEngine())
    board.reload(files, read: { _ in json }, branch: { _ in "" })
    var saves = 0
    let closed = board.tick(now: 101, rules: rules, pidAlive: { _ in false }, frontmost: { nil },
        persistReaped: { saves += 1; try SessionDismissals.save($0, at: marker) })
    check(closed.reaped.count == 2 && saves == 1, "automatic cleanup persists all closed versions in one batch")
    let restarted = SessionBoard(engine: SessionEngine(), dismissals: try! SessionDismissals.load(at: marker))
    restarted.reload(files, read: { _ in json }, branch: { _ in "" })
    let reused = restarted.tick(now: 102, rules: rules, pidAlive: { _ in true }, frontmost: { nil },
        persistReaped: { _ in saves += 1 })
    check(restarted.sessions.isEmpty && restarted.fileCount == 0 && reused.lead == nil && !reused.needsYou,
          "previously reaped Claude and Codex stay absent and silent after restart with a reused PID")
    check(saves == 1, "an unchanged closed version causes no extra persistence")
    let fresh = SessionBoard.File(key: files[0].key, path: files[0].path, provider: "claude",
        id: "closed", mtime: Date(timeIntervalSince1970: 100.25))
    restarted.reload([fresh, files[1]], read: { _ in json }, branch: { _ in "" })
    check(restarted.sessions.keys.sorted() == [fresh.key], "a new hook restores only the updated automatically reaped session")

    var attempts = 0
    let failed = restarted.tick(now: 103, rules: rules, pidAlive: { _ in false }, frontmost: { nil },
        persistReaped: { _ in attempts += 1; throw CocoaError(.fileWriteNoPermission) })
    check(failed.reapError != nil && failed.reaped.isEmpty && restarted.sessions.count == 1,
          "automatic persistence failure is reported and leaves the row until saved")
    _ = restarted.tick(now: 104, rules: rules, pidAlive: { _ in false }, frontmost: { nil },
        persistReaped: { _ in attempts += 1 })
    check(attempts == 1, "failed automatic persistence is not retried every timer tick")
    let newest = SessionBoard.File(key: fresh.key, path: fresh.path, provider: "claude",
        id: "closed", mtime: Date(timeIntervalSince1970: 100.5))
    let raced = restarted.tick(now: 109, rules: rules, pidAlive: { _ in false }, frontmost: { nil },
        persistReaped: { versions in
            attempts += 1
            try SessionDismissals.save(versions, at: marker)
            restarted.reload([newest, files[1]], read: { _ in json }, branch: { _ in "" })
        })
    check(attempts == 2 && raced.reapError == nil && raced.reaped.isEmpty && restarted.sessions.count == 1,
          "a new hook delivered during automatic persistence survives the cleanup")
    let again = SessionBoard(engine: SessionEngine(), dismissals: try! SessionDismissals.load(at: marker))
    again.reload([newest, files[1]], read: { _ in json }, branch: { _ in "" })
    check(again.sessions.keys.sorted() == [newest.key], "the concurrent new hook also survives a restart")
}

// The native probe's decision distinguishes an old owner from a reused tty and unknown data.
do {
    let stamp = Date(timeIntervalSince1970: 100)
    let live = RunningProcesses.CodexSnapshot(takenAt: stamp,
        owners: [.init(terminal: 7, startedAt: 20)], complete: true)
    let reused = RunningProcesses.CodexSnapshot(takenAt: stamp,
        owners: [.init(terminal: 7, startedAt: 51)], complete: true)
    check(live.presence(on: 7, eventAt: 50) == .alive, "a long-lived CLI owner stays alive")
    check(reused.presence(on: 7, eventAt: 50) == .dead, "a reused tty cannot keep the previous session alive")
    check(live.presence(on: 8, eventAt: 50) == .dead, "a complete scan without the tty owner proves exit")
    check(RunningProcesses.CodexSnapshot(takenAt: stamp, owners: [], complete: false)
        .presence(on: 7, eventAt: 50) == .unknown, "an incomplete scan does not prove exit")
}

// A dismissal targets only the exact version the user saw, and must persist before hiding.
do {
    let board = SessionBoard(engine: SessionEngine())
    let stamp = Date(timeIntervalSince1970: 100)
    let file = SessionBoard.File(key: "codex:dismiss", path: "/codex/dismiss.json",
        provider: "codex", id: "dismiss", mtime: stamp)
    let json: [String: Any] = ["pid": 42, "state": "permission", "ts": 100]
    board.reload([file], read: { _ in json }, branch: { _ in "" })
    let version = board.sessions[file.key]!.version
    var saved: [String: String] = [:]
    let removed = try! board.dismiss(key: file.key, version: version) { saved = $0 }
    check(removed && board.sessions.isEmpty && saved[file.key] == version,
          "Remove from list persists the observed version and removes its row")
    check(board.lead() == nil, "a dismissed session cannot lead the menu bar")
}

// Dismissals survive a new board, separate providers, and do not swallow newer events or errors.
do {
    let folder = NSTemporaryDirectory() + "ccb-dismiss-" + UUID().uuidString
    let path = folder + "/dismissed.json"
    defer { try? FileManager.default.removeItem(atPath: folder) }
    check(try! SessionDismissals.load(at: path).isEmpty, "a new install has no dismissals")
    let json: [String: Any] = ["pid": 42, "state": "permission", "ts": 100]
    let file = SessionBoard.File(key: "codex:same", path: "/codex/same.json",
        provider: "codex", id: "same", mtime: Date(timeIntervalSince1970: 100))
    let other = SessionBoard.File(key: "claude:same", path: "/claude/same.json",
        provider: "claude", id: "same", mtime: file.mtime)
    let newer = SessionBoard.File(key: file.key, path: file.path, provider: file.provider,
        id: file.id, mtime: Date(timeIntervalSince1970: 100.25))
    let board = SessionBoard(engine: SessionEngine())
    board.reload([file, other], read: { _ in json }, branch: { _ in "" })
    let oldVersion = board.sessions[file.key]!.version
    try! board.dismiss(key: file.key, version: oldVersion) { try SessionDismissals.save($0, at: path) }
    check(board.sessions.keys.sorted() == [other.key] && board.fileCount == 1,
          "Remove from list affects only provider:id and removes its count")
    let attributes = try! FileManager.default.attributesOfItem(atPath: path)
    check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
          "dismissal fingerprints are readable only by their owner")
    let restarted = SessionBoard(engine: SessionEngine(), dismissals: try! SessionDismissals.load(at: path))
    restarted.reload([file, other], read: { _ in json }, branch: { _ in "" })
    check(restarted.sessions.keys.sorted() == [other.key] && restarted.fileCount == 1,
          "the removed version stays hidden after restart")
    restarted.reload([newer, other], read: { _ in json }, branch: { _ in "" })
    check(restarted.sessions.count == 2 && restarted.sessions[file.key]?.version != oldVersion,
          "an identical hook in the same second returns the session")
    var wroteStale = false
    check(try! !restarted.dismiss(key: file.key, version: oldVersion) { _ in wroteStale = true },
          "an old panel click refuses to dismiss newer activity")
    check(!wroteStale && restarted.sessions.count == 2, "a stale click does not persist a marker")
    let currentVersion = restarted.sessions[file.key]!.version
    var failed = false
    do {
        try restarted.dismiss(key: file.key, version: currentVersion) {
            try SessionDismissals.save($0, at: path + "/impossible.json")
        }
    } catch { failed = true }
    check(failed && restarted.sessions[file.key]?.version == currentVersion,
          "a real persistence failure propagates and keeps the row visible")
    check(restarted.dismissals[file.key] == oldVersion, "a failed save leaves the old marker intact")
    let newest = SessionBoard.File(key: file.key, path: file.path, provider: file.provider,
        id: file.id, mtime: Date(timeIntervalSince1970: 100.5))
    let raced = try! restarted.dismiss(key: file.key, version: currentVersion) { markers in
        try SessionDismissals.save(markers, at: path)
        restarted.reload([newest, other], read: { _ in json }, branch: { _ in "" })
    }
    check(!raced && restarted.sessions[file.key]?.version != currentVersion,
          "an event delivered while saving cannot be hidden by the old click")
    let again = SessionBoard(engine: SessionEngine(), dismissals: try! SessionDismissals.load(at: path))
    again.reload([newest, other], read: { _ in json }, branch: { _ in "" })
    check(again.sessions.count == 2, "a concurrent new event also survives restart")
}

// Scope of owner checks: uncertainty keeps existing PID behavior; only terminal Codex uses them.
for (provider, surface, tty) in [("codex", "cli", "/dev/ttys002"), ("codex", "app", ""),
    ("codex", "ide", "/dev/ttys002"), ("codex", "exec", "/dev/ttys002"),
    ("codex", "cli", ""), ("claude", "cli", "/dev/ttys002")] {
    for presence: RunningProcesses.Presence in [.alive, .dead, .unknown] {
        let board = SessionBoard(engine: SessionEngine())
        let file = SessionBoard.File(key: provider + ":scope", path: "/scope", provider: provider,
            id: "scope", mtime: Date(timeIntervalSince1970: 100))
        let json: [String: Any] = ["pid": 42, "state": "permission", "ts": 100,
                                  "surface": surface, "tty": tty]
        board.reload([file], read: { _ in json }, branch: { _ in "" })
        var asked = 0
        let tick = board.tick(now: 101, rules: .init(soundThreshold: 0, stalePruneAge: 1,
            thinkingWords: [], needsYou: true), pidAlive: { _ in true }, frontmost: { nil },
            owner: { _ in asked += 1; return presence })
        let applicable = provider == "codex" && surface == "cli" && !tty.isEmpty
        check(board.sessions.isEmpty == (applicable && presence == .dead),
              "owner \(presence) preserves liveness scope for \(provider)/\(surface)/\(tty.isEmpty ? "no tty" : "tty")")
        check(asked == (applicable ? 1 : 0), "only a known Codex CLI tty asks for ownership")
        if !tick.reaped.isEmpty {
            board.reload([file], read: { _ in json }, branch: { _ in "" })
            check(board.sessions.isEmpty && board.fileCount == 0, "a reaped version stays absent without deleting its file")
            let next = SessionBoard.File(key: file.key, path: file.path, provider: provider,
                id: file.id, mtime: Date(timeIntervalSince1970: 101))
            board.reload([next], read: { _ in json }, branch: { _ in "" })
            check(board.sessions.count == 1, "a new hook after owner reaping returns the row")
        }
    }
}

// Real libproc positive control: an owned fixture executable named codex on its own PTY.
// It exits by itself; neither the app nor this check signals a real agent process.
do {
    let folder = NSTemporaryDirectory() + "ccb-owner-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let executable = folder + "/codex"
    let terminalFile = folder + "/tty"
    try! FileManager.default.copyItem(atPath: CommandLine.arguments[0], toPath: executable)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    child.arguments = ["-q", "/dev/null", "/bin/sh", "-c", "tty > \"$1\"; exec \"$2\" --owner-fixture",
                       "fixture", terminalFile, executable]
    child.standardOutput = Pipe(); child.standardError = Pipe(); child.standardInput = FileHandle.nullDevice
    try! child.run()
    let deadline = Date().addingTimeInterval(1)
    while !FileManager.default.fileExists(atPath: terminalFile), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    Thread.sleep(forTimeInterval: 0.05)
    let tty = (try? String(contentsOfFile: terminalFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let live = RunningProcesses.codexSnapshot()
    var session = Session(json: ["provider": "codex", "surface": "cli", "tty": tty,
                                "ts": Date().timeIntervalSince1970], id: "native-fixture")
    check(!tty.isEmpty && live.presence(of: session) == .alive,
          "the real native snapshot finds a Codex-named owner on its controlling tty")
    session.fileMtime = live.takenAt.addingTimeInterval(1)
    check(live.presence(of: session) == .unknown, "a snapshot older than a new hook cannot reap it")
    child.waitUntilExit()
    check(child.terminationStatus == 0, "the native fixture exits normally: \(child.terminationStatus)")
    var terminalInfo = stat()
    let terminalGone = stat(tty, &terminalInfo) != 0 && errno == ENOENT
    check(terminalGone, "closing the fixture PTY removes its terminal device")
    let closed = RunningProcesses.codexSnapshot()
    session.fileMtime = .distantPast
    check(closed.complete && closed.presence(of: session) == .dead,
          "a complete native snapshot reaps a CLI after its terminal device disappears")
    let incomplete = RunningProcesses.CodexSnapshot(takenAt: closed.takenAt, owners: [], complete: false)
    check(incomplete.presence(of: session) == .unknown, "missing tty with an incomplete snapshot remains unknown")
    session.fileMtime = closed.takenAt.addingTimeInterval(1)
    check(closed.presence(of: session) == .unknown, "missing tty with a snapshot older than the hook remains unknown")
    session.fileMtime = .distantPast
    for invalid in [tty + "/../missing", "/dev/tty-not-a-terminal", "/dev/tty/not-a-terminal"] {
        session.tty = invalid
        check(closed.presence(of: session) == .unknown, "malformed tty paths and non-ENOENT errors remain unknown: \(invalid)")
    }
}

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
    check(reads == before, "a reaped version still on disk stays ignored until a new hook")
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

    // Two worktrees of one service share every folder between the worktree and the project, so
    // the parent alone ("services/svc" twice) tells nothing apart: the qualifier is the nearest
    // folder that actually differs.
    disk["/claude/w1.json"] = ["state": "idle", "project": "svc", "pid": 13, "ts": now,
                              "cwd": "/wt/wt-a/taxi/frontend/services/svc"]
    disk["/claude/w2.json"] = ["state": "idle", "project": "svc", "pid": 13, "ts": now,
                              "cwd": "/wt/wt-b/taxi/frontend/services/svc"]
    board.reload([file("claude", "w1"), file("claude", "w2")], read: read) { _ in "" }
    _ = board.tick(now: now, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
    check(board.sessions["claude:w1"]?.displayName == "wt-a/svc",
          "two worktrees with the same deep tail are told apart by the worktree folder: "
            + (board.sessions["claude:w1"]?.displayName ?? "nil"))
    check(board.sessions["claude:w2"]?.displayName == "wt-b/svc", "and so is the other one")
    // One clone sits shallower than the other: where its path has run out there is no folder to
    // name, and the bare project against a qualified one is still two different rows.
    disk["/claude/w2.json"]?["cwd"] = "/services/svc"
    board.reload([file("claude", "w1"), file("claude", "w2", at: Date(timeIntervalSince1970: 4))],
                 read: read) { _ in "" }
    _ = board.tick(now: now, rules: rules, pidAlive: { alive.contains($0) }, frontmost: { nil })
    check(board.sessions["claude:w1"]?.displayName == "frontend/svc"
            && board.sessions["claude:w2"]?.displayName == "svc",
          "a clone with no folder at the differing depth keeps its bare name")

    for provider in ["codex", "claude"] {
        let soundPath = NSTemporaryDirectory() + "ccb-\(provider)-completion-cue.jsonl"
        try! (codexEvent(ts: now, "task_started", turn: "t1") + "\n")
            .write(toFile: soundPath, atomically: true, encoding: .utf8)
        let soundBoard = SessionBoard(engine: SessionEngine())
        let hookPath = "/\(provider)/sound.json"
        disk[hookPath] = ["state": "thinking", "pid": 13, "ts": now, "startedAt": now,
                          "turn_id": "t1", "transcript": soundPath,
                          "term_bundle": "com.apple.Terminal"]
        soundBoard.reload([file(provider, "sound")], read: read) { _ in "" }
        let started = soundBoard.tick(now: now, rules: rules,
                                      pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
        check(started.lead?.eff == "thinking" && !started.chime && !started.needsYou,
              "\(provider) starts a long turn without a sound")

        appendCodexLine(codexEvent(ts: now + 120, "task_complete", turn: "t1",
                                   error: terminalError), to: soundPath)
        disk[hookPath]?["state"] = "done"; disk[hookPath]?["ts"] = now + 120
        soundBoard.reload([file(provider, "sound", at: Date(timeIntervalSince1970: 2))],
                          read: read) { _ in "" }
        let stopped = soundBoard.tick(now: now + 120, rules: rules,
                                      pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
        if provider == "codex" {
            check(stopped.lead?.eff == "permission" && stopped.needsYou,
                  "a failed Codex turn stopped as raw done cues Needs you")
            check(!stopped.chime,
                  "a failed Codex turn stopped as raw done does not play the completion chime")
        } else {
            check(stopped.lead?.eff == "idle" && stopped.chime && !stopped.needsYou,
                  "a Codex terminal error does not change the Claude completion cue")
        }
        let repeated = soundBoard.tick(now: now + 121, rules: rules,
                                       pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
        check(!repeated.chime && !repeated.needsYou,
              "\(provider) does not repeat a sound after the failed turn stops")

        appendCodexLine(codexEvent(ts: now + 122, "task_started", turn: "t2"), to: soundPath)
        disk[hookPath]?["state"] = "thinking"; disk[hookPath]?["ts"] = now + 122
        disk[hookPath]?["startedAt"] = now + 122; disk[hookPath]?["turn_id"] = "t2"
        soundBoard.reload([file(provider, "sound", at: Date(timeIntervalSince1970: 3))],
                          read: read) { _ in "" }
        let retryStarted = soundBoard.tick(now: now + 122, rules: rules,
                                           pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
        check(retryStarted.lead?.eff == "thinking" && !retryStarted.chime && !retryStarted.needsYou,
              "\(provider) starts a retry without a sound")
        appendCodexLine(codexEvent(ts: now + 242, "task_complete", turn: "t2"), to: soundPath)
        disk[hookPath]?["state"] = "done"; disk[hookPath]?["ts"] = now + 242
        soundBoard.reload([file(provider, "sound", at: Date(timeIntervalSince1970: 4))],
                          read: read) { _ in "" }
        let succeeded = soundBoard.tick(now: now + 242, rules: rules,
                                        pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
        check(succeeded.lead?.eff == "idle" && succeeded.chime && !succeeded.needsYou,
              "\(provider) plays the completion chime for a successful long retry")
        let successRepeated = soundBoard.tick(now: now + 243, rules: rules,
                                              pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
        check(!successRepeated.chime && !successRepeated.needsYou,
              "\(provider) does not repeat the successful completion chime")
        try? FileManager.default.removeItem(atPath: soundPath)
    }

    let questionPath = NSTemporaryDirectory() + "ccb-board-question.jsonl"
    try! blockingQuestionCall
        .write(toFile: questionPath, atomically: true, encoding: .utf8)
    let questionBoard = SessionBoard(engine: SessionEngine())
    disk["/codex/q.json"] = ["state": "tool", "transcript": questionPath, "pid": 13,
                             "ts": now, "term_bundle": "com.apple.Terminal"]
    questionBoard.reload([file("codex", "q")], read: read) { _ in "" }
    let asked = questionBoard.tick(now: now, rules: rules,
                                  pidAlive: { alive.contains($0) }, frontmost: { "com.other" })
    check(asked.needsYou && asked.lead?.eff == "permission",
          "a blocking Codex Question cues and leads while the raw hook state is tool")
    check(!questionBoard.tick(now: now + 1, rules: rules,
                              pidAlive: { alive.contains($0) }, frontmost: { "com.other" }).needsYou,
          "a pending Codex Question does not cue again on the next tick")
    disk["/codex/q.json"]?["state"] = "thinking"
    questionBoard.reload([file("codex", "q", at: Date(timeIntervalSince1970: 4))],
                         read: read) { _ in "" }
    check(!questionBoard.tick(now: now + 2, rules: rules,
                              pidAlive: { alive.contains($0) }, frontmost: { "com.other" }).needsYou,
          "a new hook event does not replay the sound while the Question remains open")
    appendCodexLine(blockingQuestionAnswer, to: questionPath)
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
    // The line on each bar comes from the window's own clock, so both have to arrive with it.
    let clocks = claude.windows.map { $0.timeLeftPercent(at: now).map { Double($0) / 100 } }
    check(clocks.count >= 2 && icon.timeLeft.0 == clocks[0] && icon.timeLeft.1 == clocks[1],
          "and each bar is handed the time left in its own window, for the line")
    let codexIcon = LimitsBoard(claude: fableOnly, codex: codex).gauge(at: now)
    check(codexIcon.fiveHour == 0.1 && codexIcon.sevenDay == 0.2,
          "a Claude plan with only Fable leaves the icon to Codex rather than blank")
    // 600 s left of 300 minutes, and 9000 s left of a week.
    check(codexIcon.timeLeft.0 == 0.03 && codexIcon.timeLeft.1 == 0.01,
          "and Codex's bars get their own windows' clocks too")
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

    // The agent setting takes figures away before LimitsBoard sees them, so its rules about who
    // gets the icon's bars run on exactly what may be shown.
    let codexOnly = AgentDisplay.codex.limits(claude: claude, codex: codex, forBar: true).gauge(at: now)
    check(codexOnly.fiveHour == 0.1 && codexOnly.sevenDay == 0.2,
          "Codex chosen: the icon draws Codex's bars even while Claude has figures")
    check(AgentDisplay.claude.limits(claude: claude, codex: codex, forBar: false)
            .shown(at: now).map(\.set.provider) == ["claude"],
          "Claude chosen: the strip lists Claude alone")
    check(AgentDisplay.hidden.limits(claude: claude, codex: codex, forBar: true).gauge(at: now).isEmpty,
          "Hidden: no limit bars on the icon")
    check(AgentDisplay.hidden.limits(claude: claude, codex: codex, forBar: false).shown(at: now).count == 2,
          "Hidden: the panel's strip still has both")
}

// Which agents the bar and the panel show. Never picked, it follows what the app showed before
// the setting existed — both agents where Codex is installed — so an update hides nothing.
check(AgentDisplay.resolve(saved: nil, codexInstalled: false) == .claude,
      "no pick, no Codex: Claude Code")
check(AgentDisplay.resolve(saved: nil, codexInstalled: true) == .both,
      "no pick, Codex installed: both, as before the setting")
check(AgentDisplay.resolve(saved: "codex", codexInstalled: false) == .codex,
      "a pick is kept whether or not Codex is installed")
check(AgentDisplay.resolve(saved: "garbage", codexInstalled: false) == .claude,
      "an unreadable pick falls back to the default")
check(AgentDisplay.allCases.map(\.rawValue) == ["claude", "codex", "both", "hidden"],
      "the saved spellings are pinned: a rename would forget everybody's pick")
check(AgentDisplay.hidden.barProviders.isEmpty && AgentDisplay.hidden.panelProviders.count == 2,
      "Hidden empties the bar and leaves the panel both agents")
check(AgentDisplay.codex.inBar("codex") && !AgentDisplay.codex.inPanel("claude"),
      "Codex chosen: Codex in the bar, Claude out of the panel")

// The agent setting reaches the session board as two sets: who may lead the menu bar, and whose
// turns make a sound. A session left out of both is still a session — still reaped, still counted.
do {
    let now = 1_800_000_000.0
    let mtime = Date(timeIntervalSince1970: 1)
    var disk: [String: [String: Any]] = [
        "/claude/a.json": ["state": "thinking", "project": "c", "cwd": "/c", "pid": 21, "ts": now,
                           "startedAt": now - 120],
        "/codex/b.json": ["state": "permission", "project": "x", "cwd": "/x", "pid": 22, "ts": now],
    ]
    let files = [
        SessionBoard.File(key: "claude:a", path: "/claude/a.json", provider: "claude", id: "a", mtime: mtime),
        SessionBoard.File(key: "codex:b", path: "/codex/b.json", provider: "codex", id: "b", mtime: mtime),
    ]
    let board = SessionBoard(engine: SessionEngine())
    board.reload(files, read: { disk[$0] }) { _ in "" }
    var rules = SessionBoard.Rules(soundThreshold: 60, stalePruneAge: 900, thinkingWords: ["Musing"],
                                   needsYou: true, leads: ["claude"], cues: ["claude"])
    var tick = board.tick(now: now, rules: rules, pidAlive: { _ in true }, frontmost: { nil })
    check(tick.lead?.provider == "claude",
          "Claude chosen: a Codex session asking for permission does not lead the bar")
    check(!tick.needsYou, "and its request makes no sound")
    check(board.sessions.count == 2, "but it is still on the board")

    rules.leads = []
    rules.cues = nil
    disk["/claude/a.json"]?["state"] = "done"
    disk["/claude/a.json"]?["ts"] = now + 1
    board.reload([SessionBoard.File(key: "claude:a", path: "/claude/a.json", provider: "claude",
                                    id: "a", mtime: Date(timeIntervalSince1970: 2)), files[1]],
                 read: { disk[$0] }) { _ in "" }
    tick = board.tick(now: now + 1, rules: rules, pidAlive: { _ in true }, frontmost: { nil })
    check(tick.lead == nil, "Hidden: nothing leads the bar")
    check(tick.chime, "and a long turn finishing still chimes")

    disk["/claude/a.json"]?["state"] = "permission"
    disk["/claude/a.json"]?["modelService"] = "zai"
    disk["/claude/a.json"]?["ts"] = now + 2
    board.reload([SessionBoard.File(key: "claude:a", path: "/claude/a.json", provider: "claude",
                                    id: "a", mtime: Date(timeIntervalSince1970: 3)), files[1]],
                 read: { disk[$0] }) { _ in "" }
    rules.leads = ["claude"]
    rules.cues = ["claude"]
    rules.hiddenModelServices = [.zai]
    tick = board.tick(now: now + 2, rules: rules, pidAlive: { _ in true }, frontmost: { nil })
    check(tick.lead == nil && !tick.needsYou && board.sessions["claude:a"]?.eff == "permission",
          "hiding Z.ai silences its session without losing its real state")
    let rendered = MenuBarAgent.shown(.claude, board: board, claude: nil, claudeStatus: nil,
                                     oauthLimits: true, codex: nil, now: now + 2, hiding: [.zai])
    check(rendered.first?.lead == nil, "a hidden service cannot drive the menu bar")
}

// Each menu bar block owns its sessions, limits and clock even while the other agent needs us.
do {
    let now = 1_800_000_000.0
    let board = SessionBoard(engine: SessionEngine())
    let questionPath = NSTemporaryDirectory() + "ccb-dual-question.jsonl"
    try! blockingQuestionCall.write(toFile: questionPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: questionPath) }
    let entries: [(String, String, String, Double)] = [
        ("claude", "old", "thinking", now - 10),
        ("claude", "new", "tool", now),
        ("codex", "wait", "permission", now - 20),
        ("codex", "work", "thinking", now),
    ]
    let files = entries.map { provider, id, _, _ in
        SessionBoard.File(key: provider + ":" + id, path: id, provider: provider, id: id,
                          mtime: Date(timeIntervalSince1970: 1))
    }
    board.reload(files, read: { id in
        let row = entries.first { $0.1 == id }!
        return ["state": row.2, "pid": 42, "ts": row.3, "startedAt": now - 120,
                "transcript": id == "wait" ? questionPath : ""]
    }) { _ in "" }
    let rules = SessionBoard.Rules(soundThreshold: 0, stalePruneAge: 900,
                                   thinkingWords: ["Musing"], needsYou: true)
    let tick = board.tick(now: now, rules: rules, pidAlive: { _ in true }, frontmost: { nil })
    let claude = LimitsSet(provider: "claude", windows: [
        NamedWindow(key: "five_hour", title: "5h", badge: nil, minutes: 300,
                    window: LimitWindow(used: 40, resets: now + 600)),
    ], source: "oauth", ts: now, plan: nil)
    let codex = LimitsSet(provider: "codex", windows: [
        NamedWindow(key: "primary", title: "1h", badge: nil, minutes: 60,
                    window: LimitWindow(used: 80, resets: now + 600)),
    ], source: "rollout", ts: now, plan: nil)
    let both = MenuBarAgent.shown(.both, board: board, claude: claude, claudeStatus: nil, oauthLimits: true, codex: codex, now: now)
    check(both.map(\.provider.id) == ["claude", "codex"], "Both draws two ordered provider blocks")
    check(both[0].lead?.id == "new" && both[1].lead?.id == "wait",
          "each provider picks its own priority and newest working session")
    check(both[0].mood == .walking && both[0].working == 2 && !both[0].badge,
          "a Codex permission prompt does not stop Claude's working mood")
    check(both[1].mood == .waitingPermission && both[1].working == 1 && both[1].badge,
          "Codex owns its permission badge and working count")
    check(both[0].startedAt == now - 120 && both[1].startedAt == 0,
          "each timer belongs to its working lead; permission gets no clock")
    check(both[0].gauge.fiveHour == 0.4 && both[1].gauge.fiveHour == 0.8
          && both[1].gauge.labels.0 == "1h", "each block draws its own labelled limits")
    check(tick.lead?.id == "wait" && board.word(for: "claude:old") == "Musing",
          "building provider blocks does not tick the board or change its edge state")
    for pick in [AgentDisplay.claude, .codex] {
        let only = MenuBarAgent.shown(pick, board: board, claude: claude, claudeStatus: nil, oauthLimits: true, codex: codex, now: now)
        check(only.count == 1 && only[0].provider.id == pick.rawValue, "single-agent mode draws only \(pick.rawValue)")
    }
    check(MenuBarAgent.shown(.hidden, board: board, claude: claude, claudeStatus: nil, oauthLimits: true, codex: codex, now: now).isEmpty,
          "Hidden has no status, clocks or bars to compose")
    let empty = SessionBoard(engine: SessionEngine())
    let resting = MenuBarAgent.shown(.both, board: empty, claude: claude, claudeStatus: nil, oauthLimits: true, codex: nil, now: now)
    check(resting.count == 2 && resting.allSatisfy { $0.lead == nil && $0.mood == .sleeping && $0.startedAt == 0 },
          "both icons remain present with no sessions")
    check(resting[0].gauge.fiveHour == 0.4 && resting[1].gauge.isEmpty,
          "missing Codex limits omit only Codex bars without borrowing Claude's")
    let reserve = NamedWindow(key: "reserve:primary", title: "Reserve", badge: "7d", minutes: 10080,
                              window: LimitWindow(used: 36, resets: now - 1))
    let mixed = LimitsSet(provider: "codex", windows: codex.windows + [reserve],
                          source: "rollout", ts: now - 60, plan: nil)
    let honest = MenuBarAgent.shown(.codex, board: board, claude: nil, claudeStatus: nil, oauthLimits: true, codex: mixed, now: now)[0]
    check(honest.gauge.fiveHour == 0.8 && honest.gauge.sevenDay == nil,
          "ordinary Codex windows do not borrow an expired reserve as a second bar")
    let reserveOnly = LimitsSet(provider: "codex", windows: [reserve], source: "rollout", ts: now - 60, plan: nil)
    let fallback = MenuBarAgent.shown(.codex, board: board, claude: nil, claudeStatus: nil, oauthLimits: true, codex: reserveOnly, now: now)[0]
    check(fallback.gauge.fiveHour == 0 && fallback.gauge.labels.0 == "7d" && fallback.reserve,
          "reserve-only fallback keeps its reported duration and reset behaviour")
    // Signed out: only Claude's block carries the sign, by the panel's rule, with its own signature
    // so the icon cache redraws exactly when the sign comes or goes.
    let noLogin = LimitsStatus(json: ["state": "no-login", "ts": now, "detail": "no token"])
    let signedOutAgents = MenuBarAgent.shown(.both, board: board, claude: claude, claudeStatus: noLogin,
                                             oauthLimits: true, codex: codex, now: now)
    check(signedOutAgents[0].signedOut && !signedOutAgents[1].signedOut,
          "a no-login poll marks Claude's block and never Codex's")
    check(!both[0].signedOut, "without a status file nobody is signed out")
    let okStatus = LimitsStatus(json: ["state": "ok", "ts": now, "detail": ""])
    check(!MenuBarAgent.shown(.both, board: board, claude: claude, claudeStatus: okStatus,
                              oauthLimits: true, codex: codex, now: now)[0].signedOut,
          "an ok poll shows no sign")
    check(!MenuBarAgent.shown(.both, board: board, claude: claude, claudeStatus: noLogin,
                              oauthLimits: false, codex: codex, now: now)[0].signedOut,
          "with the API poll switched off the sign stays away")
    let staleNoLogin = LimitsStatus(json: ["state": "no-login", "ts": now - 60, "detail": "no token"])
    check(!MenuBarAgent.shown(.both, board: board, claude: claude, claudeStatus: staleNoLogin,
                              oauthLimits: true, codex: codex, now: now)[0].signedOut,
          "figures newer than the poll hide the sign")
    let failed = LimitsStatus(json: ["state": "failed", "ts": now, "detail": "HTTPError"])
    check(!MenuBarAgent.shown(.both, board: board, claude: claude, claudeStatus: failed,
                              oauthLimits: true, codex: codex, now: now)[0].signedOut,
          "a failed poll is not a sign-out")
    check(MenuBarAgent.shown(.both, board: board, claude: nil, claudeStatus: noLogin,
                             oauthLimits: true, codex: codex, now: now)[0].signedOut,
          "no figures at all still shows the sign")
    check(signedOutAgents[0].signature != both[0].signature
          && signedOutAgents[0].signature.hasPrefix(both[0].gauge.signature),
          "the sign is part of the block's signature on top of the bars' own")
    check(both[0].timer(show: true, now: now) == "2m 0s"
          && both[1].timer(show: true, now: now).isEmpty
          && both[0].timer(show: false, now: now).isEmpty,
          "Show Timer controls each working clock without exposing a permission clock")
    check(both[0].timer(show: true, now: now - 121) == "0s"
          && both[0].timer(show: true, now: now + 100 * 3600) == "99h+",
          "timers clamp future starts and bound very long runs")
    var firstMotion = MenuBarMotion(), secondMotion = MenuBarMotion()
    firstMotion.update(key: "claude:walking", fps: 4, now: 100)
    secondMotion.update(key: "codex:running", fps: 10, now: 100)
    check(firstMotion.frame(at: 101, count: 12) == 4 && secondMotion.frame(at: 101, count: 12) == 10,
          "one shared timer samples each provider at its own frame rate")
    firstMotion.update(key: "claude:sleeping", fps: 2, now: 101)
    check(firstMotion.frame(at: 101, count: 12) == 0 && secondMotion.frame(at: 101, count: 12) == 10,
          "changing Claude's mood restarts only Claude's animation")
    secondMotion.update(key: "codex:running", fps: 20, now: 101)
    check(secondMotion.frame(at: 101, count: 12) == 10 && secondMotion.frame(at: 101.125, count: 12) == 0,
          "tempo changes preserve animation progress rather than restarting the provider")
    let left = NSImage(size: NSSize(width: 28, height: 18)), right = NSImage(size: NSSize(width: 28, height: 18))
    left.isTemplate = true; right.isTemplate = true
    let composed = MenuBarImage.compose([.init(image: left, label: "", timer: "", textWidth: 0),
                                         .init(image: right, label: "", timer: "", textWidth: 0)])
    check(composed.size.width > 56 && composed.size.width < 70 && composed.isTemplate,
          "two empty-status blocks retain two adaptive icons with a gap and no text column")
    let column = { (label: String, timer: String, working: Bool, previous: CGFloat) in
        MenuBarImage.textColumn(label: label, timer: timer, working: working, previous: previous)
    }
    let fitted = column("Needs you", "", false, MenuBarImage.maxTextWidth)
    check(fitted > 30 && fitted < 70,
          "a resting status takes the room its words need, leaving no blank before the next provider: \(fitted)")
    let oneLine = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    check(fitted == ("Needs you" as NSString).size(withAttributes: [.font: oneLine]).width.rounded(.up)
          && column("Needs you", "1s", false, 0) < fitted,
          "the column is measured in the font it is drawn in: 11pt for one line, the smaller 9pt for two")
    check(column("", "", true, MenuBarImage.maxTextWidth) == 0, "no words, no column")
    let narrow = column("Musing…", "3s", true, 0)
    check(column("Running tests…", "3s", true, narrow) > narrow
          && column("Running tests…", "3s", true, narrow) == column("Running tests…", "3s", false, 0),
          "a wider tool label widens a working column to its own width")
    let long = column(String(repeating: "x", count: 400), "99h+", true, 0)
    check(long == MenuBarImage.maxTextWidth && column("Musing…", "3s", true, long) == long
          && column("Musing…", "3s", true, 500) == long,
          "while a session works the column stays bounded and only grows, so tool labels and the clock move nothing")
    check(column("Musing…", "3s", true, 0) < long && column("Musing…", "3s", false, long) < long,
          "and it starts from the words, returning to them once the work is over")
    let wide = MenuBarImage.compose([.init(image: left, label: "Musing…", timer: "3s", textWidth: long)])
    check(wide.size.width > 100 && wide.size.width < 120, "the composed block is its icon plus the column it was given")
    let bare = NSImage(size: NSSize(width: 18, height: 18))
    check(Gauge().image(icon: bare) === bare, "an empty gauge returns the bare icon without a blank strip")
}

// Permission keeps the chosen drawn animation; absent Codex art still shows work with both texts off.
do {
    var permission = Session(json: ["state": "permission"], id: "claude-wait")
    permission.eff = "permission"
    let waiting = MenuBarAgent(provider: .claude, lead: permission, mood: .waitingPermission,
                               working: 0, gauge: Gauge())
    check(waiting.animates(.web) && waiting.animates(.code),
          "permission keeps Claude's selected spark and glyph animations running")
    let resting = MenuBarAgent(provider: .claude, lead: nil, mood: .sleeping, working: 0, gauge: Gauge())
    check(!resting.animates(.web) && !resting.animates(.code), "resting drawn styles remain still")
    var work = Session(json: ["state": "thinking", "provider": "codex"], id: "codex-work")
    work.eff = "thinking"
    let busy = MenuBarAgent(provider: .codex, lead: work, mood: .cigar, working: 1, gauge: Gauge())
    let idle = MenuBarAgent(provider: .codex, lead: nil, mood: .sleeping, working: 0, gauge: Gauge())
    let symbol = NSImage(systemSymbolName: Provider.codex.glyph, accessibilityDescription: "Codex")!
    symbol.isTemplate = true
    let busySymbol = busy.markedIcon(symbol, fallback: true, permissionColor: badgeAmber)
    let idleSymbol = idle.markedIcon(symbol, fallback: true, permissionColor: badgeAmber)
    check(busySymbol.size.width > idleSymbol.size.width && idleSymbol === symbol,
          "missing-art Codex has a visible working marker which disappears at idle")
    check(crabHasPixel(busySymbol) { $0.alphaComponent > 0.5 }, "the busy fallback still draws its provider symbol")
    check(busy.markedIcon(symbol, fallback: false, permissionColor: badgeAmber) === symbol,
          "a real companion keeps its own animation without an extra busy marker")
    let permissionSymbol = waiting.markedIcon(symbol, fallback: true, permissionColor: badgeAmber)
    check(crabHasPixel(permissionSymbol) { $0.redComponent > 0.8 && $0.greenComponent > 0.55 && $0.blueComponent < 0.35 },
          "a waiting fallback retains the distinct amber permission badge")
}

// Command approval uses one live sidecar and the existing effective state and cue path.
do {
    try! FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: sessionsDir) }
    let clock = 1_789_200_000.0
    let threadID = "00000000-0000-7000-8000-000000000001"
    var session = Session(json: ["provider": "codex", "state": "thinking", "started": true,
                                "pid": 42, "turn_id": "approval-turn", "ts": clock - 2], id: threadID)
    let approvalEngine = SessionEngine()
    func signal(_ waiting: Bool = true, at stamp: Double = 1_789_200_000) -> [String: Any] {
        ["version": 1, "status": "ok", "sessions": [["thread_id": threadID, "pid": 42,
            "turn_id": "approval-turn", "awaiting_approval": waiting, "observed_at": stamp]]]
    }
    approvalEngine.codexAttention = CodexAttention(json: signal())
    for raw in ["thinking", "tool", "permission", "idle", "done"] {
        session.state = raw
        check(approvalEngine.effectiveState(session, now: clock) == "permission",
              "fresh live command approval overrides raw \(raw)")
    }
    session.state = "thinking"
    session.ts = clock + 3
    check(approvalEngine.effectiveState(session, now: clock + 3) == "permission",
          "regular post-tool activity does not clear a live approval")
    session.state = "tool"
    check(approvalEngine.effectiveState(session, now: clock + 3) == "permission",
          "another parallel tool does not clear a live approval")
    session.state = "thinking"
    check(approvalEngine.effectiveState(session, now: clock + 10) == "permission",
          "a command signal is fresh through its ten-second lifetime")
    check(approvalEngine.effectiveState(session, now: clock + 10.001) == "thinking",
          "an unchanged cached sidecar expires without a new mtime")
    approvalEngine.codexAttention = CodexAttention(json: signal(false, at: clock + 1))
    check(approvalEngine.effectiveState(session, now: clock + 1) == "thinking",
          "a fresh allow or deny removes only the command overlay")
    approvalEngine.codexAttention = nil
    check(approvalEngine.effectiveState(session, now: clock) == "thinking",
          "a missing sidecar keeps local working state")
    approvalEngine.codexAttention = CodexAttention(json: ["version": 1, "status": "unavailable",
                                                         "error": "timeout", "sessions": signal()["sessions"]!])
    check(approvalEngine.effectiveState(session, now: clock) == "thinking",
          "an unavailable sidecar cannot keep a previous true alive")
    for invalid: Any in ["bad-time", true, Double.nan, Double.infinity, clock + 1] {
        var value = signal()
        var records = value["sessions"] as! [[String: Any]]
        records[0]["observed_at"] = invalid
        value["sessions"] = records
        approvalEngine.codexAttention = CodexAttention(json: value)
        check(approvalEngine.effectiveState(session, now: clock) == "thinking",
              "invalid or future approval timestamps fall back to local state: \(invalid)")
    }
    for (field, invalid) in [("pid", 0 as Any), ("pid", true as Any), ("awaiting_approval", 1 as Any),
                              ("awaiting_approval", "true" as Any), ("turn_id", "" as Any)] {
        var value = signal()
        var records = value["sessions"] as! [[String: Any]]
        records[0][field] = invalid
        value["sessions"] = records
        approvalEngine.codexAttention = CodexAttention(json: value)
        check(approvalEngine.effectiveState(session, now: clock) == "thinking",
              "corrupt approval \(field) cannot create attention: \(invalid)")
    }
    approvalEngine.codexAttention = CodexAttention(json: signal())
    session.pid = 43
    check(approvalEngine.effectiveState(session, now: clock) == "thinking", "a replaced PID rejects its old approval")
    session.pid = 42; session.turnID = "another-turn"
    check(approvalEngine.effectiveState(session, now: clock) == "thinking", "another turn rejects an old approval")
    session.turnID = "approval-turn"; session.id = "another-thread"
    check(approvalEngine.effectiveState(session, now: clock) == "thinking", "the full thread ID must match")
    session.id = threadID; session.provider = "claude"
    check(approvalEngine.effectiveState(session, now: clock) == "thinking", "a Codex approval cannot alter Claude")
    session.provider = "codex"; session.ts = clock - 2
    for endType in ["task_complete", "turn_complete", "turn_aborted"] {
        session.transcript = writeTranscript("approval-\(endType).jsonl", lines: [
            codexEvent(ts: clock - 2, "task_started", turn: "approval-turn"),
            codexEvent(ts: clock + 1, endType, turn: "approval-turn"),
        ])
        check(approvalEngine.effectiveState(session, now: clock + 1) == "idle",
              "\(endType) excludes an old live approval")
    }
    for startType in ["task_started", "turn_started"] {
        for nextTurn in ["approval-turn", "next-turn"] {
            session.transcript = writeTranscript("approval-\(startType)-\(nextTurn).jsonl", lines: [
                codexEvent(ts: clock - 2, "task_started", turn: "approval-turn"),
                codexEvent(ts: clock + 1, startType, turn: nextTurn),
            ])
            check(approvalEngine.effectiveState(session, now: clock + 1) == "thinking",
                  "a newer \(startType) excludes a stale approval before hook state catches up: \(nextTurn)")
        }
    }
    for (startType, endType) in [("task_started", "task_complete"), ("turn_started", "turn_complete"),
                                ("task_started", "turn_aborted")] {
        let staleEngine = SessionEngine()
        staleEngine.codexAttention = CodexAttention(json: signal())
        var staleHook = session
        staleHook.transcript = writeTranscript("approval-stale-hook-\(endType).jsonl", lines: [
            codexEvent(ts: clock - 2, startType, turn: "approval-turn"),
        ])
        check(staleEngine.effectiveState(staleHook, now: clock) == "permission",
              "the old approval waits before the next \(startType)")
        appendCodexLine(codexEvent(ts: clock + 1, startType, turn: "next-turn"), to: staleHook.transcript)
        check(staleEngine.effectiveState(staleHook, now: clock + 1) == "thinking",
              "the new \(startType) rejects approval from an unchanged old hook")
        appendCodexLine(codexEvent(ts: clock + 2, endType, turn: "next-turn"), to: staleHook.transcript)
        check(staleEngine.effectiveState(staleHook, now: clock + 2) == "thinking",
              "the next \(endType) cannot restore approval from an unchanged old hook")
        check(staleEngine.effectiveState(staleHook, now: clock + 3) == "thinking",
              "cached completion of the next turn cannot restore an old approval: \(endType)")
        let freshEngine = SessionEngine()
        freshEngine.codexAttention = CodexAttention(json: signal())
        check(freshEngine.effectiveState(staleHook, now: clock + 3) == "thinking",
              "a fresh parser after the next \(endType) cannot restore an old approval")
    }
    session.transcript = writeTranscript("approval-late-old-completion.jsonl", lines: [
        codexEvent(ts: clock - 2, "task_started", turn: "approval-turn"),
        codexEvent(ts: clock + 1, "task_complete", turn: "old-turn"),
    ])
    check(approvalEngine.effectiveState(session, now: clock + 1) == "permission",
          "a late completion of another turn does not clear the current live approval")
    session.transcript = writeTranscript("approval-local-error.jsonl", lines: [
        codexEvent(ts: clock - 2, "task_started", turn: "approval-turn"),
        codexEvent(ts: clock + 1, "task_complete", turn: "approval-turn", error: terminalError),
    ])
    for source: [String: Any]? in [signal(false, at: clock + 1), nil,
                                   ["version": 1, "status": "unavailable", "sessions": []]] {
        approvalEngine.codexAttention = source.map(CodexAttention.init(json:))
        check(approvalEngine.effectiveState(session, now: clock + 1) == "permission",
              "a live negative or unavailable answer preserves terminal error attention")
    }
    session.transcript = writeTranscript("approval-local-input.jsonl", lines: [
        codexEvent(ts: clock - 2, "task_started", turn: "approval-turn"),
        codexLine(["type": "function_call", "name": "request_user_input", "call_id": "blocking",
            "arguments": #"{"questions":[{"id":"confirm"}]}"#]),
    ])
    for source: [String: Any]? in [signal(false), nil, ["version": 1, "status": "unavailable", "sessions": []]] {
        approvalEngine.codexAttention = source.map(CodexAttention.init(json:))
        check(approvalEngine.effectiveState(session, now: clock) == "permission",
              "a live negative or unavailable answer preserves blocking input")
    }
    for endType in ["task_complete", "turn_complete", "turn_aborted"] {
        let blockingPath = writeTranscript("approval-blocking-late-\(endType).jsonl", lines: [
            codexEvent(ts: clock - 2, "task_started", turn: "approval-turn"),
            blockingQuestionCall,
        ])
        var questions = CodexRollout.Questions()
        check(questions.pending(in: blockingPath), "blocking input waits before a late \(endType)")
        appendCodexLine(codexEvent(ts: clock + 1, endType, turn: "old-turn"), to: blockingPath)
        check(questions.pending(in: blockingPath), "a late old-turn \(endType) preserves current blocking input")
        check(questions.pending(in: blockingPath), "cached old-turn \(endType) still preserves current blocking input")
        appendCodexLine(codexEvent(ts: clock + 2, endType, turn: "approval-turn"), to: blockingPath)
        check(!questions.pending(in: blockingPath), "a matching \(endType) still clears current blocking input")
        let noTimestamp = writeTranscript("approval-blocking-no-time-\(endType).jsonl", lines: [
            codexEvent(ts: clock - 2, "task_started", turn: "approval-turn"), blockingQuestionCall,
        ])
        var legacyQuestions = CodexRollout.Questions()
        check(legacyQuestions.pending(in: noTimestamp), "current blocking input waits before an untimed \(endType)")
        appendCodexLine(#"{"type":"event_msg","payload":{"type":""# + endType
            + #"","turn_id":"old-turn"}}"#, to: noTimestamp)
        check(legacyQuestions.pending(in: noTimestamp), "an untimed \(endType) with a different turn ID preserves current input")
        appendCodexLine(#"{"type":"event_msg","payload":{"type":""# + endType
            + #"","turn_id":"approval-turn"}}"#, to: noTimestamp)
        check(!legacyQuestions.pending(in: noTimestamp), "an untimed matching \(endType) still clears current input")
    }
    for boundary in ["task_complete", "turn_complete", "turn_aborted", "task_started", "turn_started"] {
        let legacyPath = writeTranscript("approval-blocking-legacy-\(boundary).jsonl", lines: [
            codexEvent(ts: clock - 2, "task_started", turn: "approval-turn"), blockingQuestionCall,
        ])
        var questions = CodexRollout.Questions()
        check(questions.pending(in: legacyPath), "a legacy blocking input waits before \(boundary)")
        appendCodexLine(#"{"type":"event_msg","payload":{"type":""# + boundary + #""}}"#, to: legacyPath)
        check(!questions.pending(in: legacyPath), "a boundary without timestamp or turn ID retains legacy cleanup: \(boundary)")
    }
    let board = SessionBoard(engine: SessionEngine())
    board.engine.codexAttention = CodexAttention(json: signal())
    let hook: [String: Any] = ["state": "thinking", "pid": 42, "turn_id": "approval-turn",
                               "started": true, "startedAt": clock - 3, "ts": clock - 2]
    let file = SessionBoard.File(key: "codex:" + threadID, path: "/synthetic/approval.json",
                                 provider: "codex", id: threadID, mtime: Date())
    board.reload([file], read: { _ in hook }, branch: { _ in "" })
    let rules = SessionBoard.Rules(soundThreshold: 0, stalePruneAge: 0, thinkingWords: [], needsYou: true)
    let first = board.tick(now: clock, rules: rules, pidAlive: { _ in true }, frontmost: { "other.app" })
    check(first.lead?.eff == "permission" && first.needsYou,
          "one effective command approval drives the board and its Needs you cue")
    check(!board.tick(now: clock + 1, rules: rules, pidAlive: { _ in true }, frontmost: { "other.app" }).needsYou,
          "a second unchanged approval tick does not repeat the cue")
    board.engine.codexAttention = CodexAttention(json: signal(false, at: clock + 2))
    let cleared = board.tick(now: clock + 2, rules: rules, pidAlive: { _ in true }, frontmost: { "other.app" })
    check(cleared.lead?.eff == "thinking" && !cleared.needsYou, "resolved approval restores the working board state")
    board.engine.codexAttention = CodexAttention(json: signal(true, at: clock + 3))
    check(board.tick(now: clock + 3, rules: rules, pidAlive: { _ in true }, frontmost: { "other.app" }).needsYou,
          "a later separate approval creates one new cue")
    let seamPath = FileManager.default.currentDirectoryPath + "/build/evidence/command-approval/python-attention.json"
    if let data = FileManager.default.contents(atPath: seamPath),
       let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let records = raw["sessions"] as? [[String: Any]], records.count == 2 {
        approvalEngine.codexAttention = CodexAttention(json: raw)
        let waiting = Session(json: ["provider": "codex", "state": "thinking", "started": true,
            "pid": records[0]["pid"]!, "turn_id": "turn-one", "ts": clock], id: threadID)
        let working = Session(json: ["provider": "codex", "state": "thinking", "started": true,
            "pid": records[1]["pid"]!, "turn_id": "turn-one", "ts": clock],
            id: "00000000-0000-7000-8000-000000000002")
        check(approvalEngine.effectiveState(waiting, now: clock) == "permission"
                && approvalEngine.effectiveState(working, now: clock) == "thinking",
              "the real Python sidecar reaches Swift and distinguishes waiting from the root")
        check(approvalEngine.effectiveState(waiting, now: clock + 11) == "thinking",
              "the real Python sidecar expires in Swift without another file write")
    } else { check(false, "Python attention seam fixture missing or unreadable; run the Python suite") }
#if !COMMAND_APPROVAL_BASELINE
    let attentionFile = sessionsDir + "attention.json"
    var attentionGate: Date?
    try! JSONSerialization.data(withJSONObject: signal()).write(to: URL(fileURLWithPath: attentionFile))
    var cached = CodexAttention.read(at: attentionFile, gate: &attentionGate, previous: nil)
    let fileEngine = SessionEngine()
    fileEngine.codexAttention = cached
    session.transcript = ""
    check(fileEngine.effectiveState(session, now: clock) == "permission",
          "the attention reader loads a valid file into the model")
    cached = CodexAttention.read(at: attentionFile, gate: &attentionGate, previous: cached)
    fileEngine.codexAttention = cached
    check(fileEngine.effectiveState(session, now: clock + 11) == "thinking",
          "the mtime reader does not prolong an unchanged signal")
    try! "{incomplete".write(toFile: attentionFile, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: clock + 2)],
                                           ofItemAtPath: attentionFile)
    cached = CodexAttention.read(at: attentionFile, gate: &attentionGate, previous: cached)
    fileEngine.codexAttention = cached
    check(fileEngine.effectiveState(session, now: clock + 2) == "thinking",
          "corrupt JSON drops the approval immediately instead of reusing the last parse")
    try! FileManager.default.removeItem(atPath: attentionFile)
    fileEngine.codexAttention = CodexAttention.read(at: attentionFile, gate: &attentionGate, previous: cached)
    check(fileEngine.effectiveState(session, now: clock) == "thinking" && attentionGate == nil,
          "a missing attention file drops the signal and its mtime gate")
    session.transcript = ""; session.state = "idle"
    var poll = CodexAttentionPoll()
    check(poll.begin(now: clock, sessions: [session], socketExists: { true }, pidAlive: { _ in true }),
          "a live started parent is polled even if its raw state rests")
    check(!poll.begin(now: clock + 6, sessions: [session], socketExists: { true }, pidAlive: { _ in true }),
          "attention polling has only one in-flight batch")
    poll.finish()
    var earlyPoll = poll
    check(!earlyPoll.begin(now: clock + 2, sessions: [session], socketExists: { true }, pidAlive: { _ in true }),
          "attention polling does not reuse the old two-second cadence")
    check(!poll.begin(now: clock + 4.9, sessions: [session], socketExists: { true }, pidAlive: { _ in true }),
          "attention polling waits five seconds between starts")
    poll.finish()
    check(poll.begin(now: clock + 5, sessions: [session], socketExists: { true }, pidAlive: { _ in true }),
          "attention polling can start again at the five-second boundary")
    poll.finish()
    check(!poll.begin(now: clock + 10, sessions: [session], socketExists: { true }, pidAlive: { _ in false }),
          "a dead parent does not cause an attention poll")
    session.started = false
    check(!poll.begin(now: clock + 10, sessions: [session], socketExists: { true }, pidAlive: { _ in true }),
          "an unopened parent does not cause an attention poll")
    session.started = true; session.provider = "claude"
    check(!poll.begin(now: clock + 10, sessions: [session], socketExists: { true }, pidAlive: { _ in true }),
          "a Claude parent does not cause a Codex attention poll")
    session.provider = "codex"
    var socketStats = 0
    check(!poll.begin(now: clock + 10, sessions: [session], socketExists: { socketStats += 1; return false },
                      pidAlive: { _ in true }) && socketStats == 1,
          "no control socket, no attention poll: the script could only answer that there is none")
    check(poll.begin(now: clock + 10.4, sessions: [session], socketExists: { true }, pidAlive: { _ in true }),
          "a missing socket does not spend the five-second cadence: the poll starts once it appears")
    poll.finish()
    check(!poll.begin(now: clock + 11, sessions: [session], socketExists: { socketStats += 1; return true },
                      pidAlive: { _ in true })
            && !poll.begin(now: clock + 16, sessions: [], socketExists: { socketStats += 1; return true },
                           pidAlive: { _ in true }) && socketStats == 1,
          "the socket is looked for only when a poll would otherwise start")
    check(BackendCommand.codexAttention.arguments == ["codex-attention"],
          "the live attention request uses the existing backend command protocol")
    // Which mcpbar.py every command runs. The copy inside the app is the one built with this
    // binary; paths.json names the plugin's, whose folder carries a version and goes away with the
    // next plugin update — so it is the fallback for a bundle without a script, not the first choice.
    let pluginPaths: [String: Any] = ["python": "/old/plugin/python3", "script": "/old/plugin/mcpbar.py"]
    let bundleScript = "/current/app/scripts/mcpbar.py"
    var pathsReads = 0
    let bundledBackend = BackendCommand.backend(bundledScript: bundleScript,
                                                paths: { pathsReads += 1; return pluginPaths },
                                                exists: { _ in true })
    check(bundledBackend.python == "/usr/bin/python3" && bundledBackend.script == bundleScript && pathsReads == 0,
          "the script inside the app runs even when paths.json names a plugin copy, which is not even read")
    for missing: String? in [bundleScript, nil] {
        let fallback = BackendCommand.backend(bundledScript: missing, paths: { pluginPaths },
                                              exists: { $0 != bundleScript })
        check(fallback.python == "/old/plugin/python3" && fallback.script == "/old/plugin/mcpbar.py",
              "a bundle without the script falls back to the plugin copy from paths.json")
    }
    check(BackendCommand.backend(bundledScript: nil, paths: { ["script": "/old/plugin/mcpbar.py"] },
                                 exists: { _ in true }).python == "/usr/bin/python3",
          "a paths.json without an interpreter runs the system python")
    check(BackendCommand.backend(bundledScript: nil, paths: { pluginPaths }, exists: { _ in false }).script.isEmpty
            && BackendCommand.backend(bundledScript: nil, paths: { nil }, exists: { _ in true }).script.isEmpty,
          "a plugin copy that is gone, or no paths.json at all, leaves nothing to run")
#endif
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
    (.statuslineHeal, ["statusline", "--heal"]),
    (.claudeLogin, ["claude-login"]),
    (.claudeHistory, ["claude-history"]),
    (.toggleServer(provider: "claude", name: "wiki", on: false), ["toggle-server", "wiki", "--off"]),
    (.toggleServer(provider: "codex", name: "wiki", on: true),
     ["codex-mcp", "toggle-server", "wiki", "--on"]),
    (.toggleTool(provider: "claude", server: "wiki", tool: "Read", prefix: "wiki", on: false),
     ["toggle-tool", "mcp__wiki__Read", "--server", "wiki", "--tool", "Read", "--off"]),
    (.toggleTool(provider: "codex", server: "wiki", tool: "Read", prefix: "wiki", on: true),
     ["codex-mcp", "toggle-tool", "--server", "wiki", "--tool", "Read", "--on"]),
    (.usage(refresh: false), ["usage"]),
    (.usage(refresh: true), ["usage", "--refresh"]),
    (.resetCredit(provider: "claude", creditId: "grant_abc"), ["claude-reset-credit", "grant_abc"]),
    (.resetCredit(provider: "codex", creditId: nil), ["codex-reset-credit"]),
    // Codex's backend picks the next credit itself; an id handed over by mistake must not become
    // a word the script would read as something else.
    (.resetCredit(provider: "codex", creditId: "grant_abc"), ["codex-reset-credit"]),
    // Without an id the Claude command has nothing to redeem; the script refuses the bare word.
    (.resetCredit(provider: "claude", creditId: nil), ["claude-reset-credit"]),
]
for (command, words) in backendGolden {
    check(command.arguments == words, "backend \(words.joined(separator: " ")): \(command.arguments)")
}

// How long the app waits before stopping the script itself. A second net ABOVE the script's own
// budgets, never below them: a full check runs `claude mcp list` once per root and per project at
// 120 s each, and every Codex re-read waits up to 60 s for app-server plus 30 s per `codex mcp`
// call — which a Codex switch repeats in full after its write.
let deadlineGolden: [(BackendCommand, TimeInterval)] = [
    (.mcpRefresh(provider: "claude"), 600),
    (.mcpRefresh(provider: "codex"), 600),
    (.toggleServer(provider: "codex", name: "wiki", on: true), 600),
    (.toggleTool(provider: "codex", server: "wiki", tool: "Read", prefix: "wiki", on: true), 600),
    (.toggleServer(provider: "claude", name: "wiki", on: false), 120),
    (.toggleTool(provider: "claude", server: "wiki", tool: "Read", prefix: "wiki", on: false), 120),
    (.limits(provider: "claude"), 120),
    (.limits(provider: "codex"), 120),
    (.codexHooks, 120),
    (.codexHooksApprove, 120),
    (.codexHistory, 120),
    (.statuslineHeal, 120),
    (.claudeLogin, 120),
    (.codexAttention, 3),
]
for (command, seconds) in deadlineGolden {
    check(command.deadline == seconds,
          "deadline of \(command.arguments.joined(separator: " ")): \(command.deadline)")
}

// Why a switch bounced. The script says it on stderr as `refused: <reason>` and exits 2; the row
// flipping back on its own with the reason only in the system log read as a broken button.
let refusedSwitch = BackendCommand.toggleServer(provider: "codex", name: "wiki", on: false)
let refusedRun = HookInstall.Run(end: .exited(2),
                                 output: "refused: settings.json changed underneath the switch; nothing written\n")
check(refusedSwitch.refusal(refusedRun)
        == SwitchRefusal(provider: "codex", reason: "settings.json changed underneath the switch; nothing written"),
      "a refused switch carries the script's own reason and the agent whose config it was")
check(BackendCommand.toggleTool(provider: "claude", server: "wiki", tool: "Read", prefix: "wiki", on: true)
        .refusal(HookInstall.Run(end: .exited(2), output: "note\nrefused: first\nrefused: last\n"))
        == SwitchRefusal(provider: "claude", reason: "last"),
      "the last refusal on stderr is the one that ended the run")
check(refusedSwitch.refusal(HookInstall.Run(end: .exited(0), output: "refused: stale\n")) == nil,
      "a switch that was applied has nothing to explain")
check(BackendCommand.mcpRefresh(provider: "claude").refusal(refusedRun) == nil
        && BackendCommand.limits(provider: "codex").refusal(refusedRun) == nil,
      "only a switch can be refused: a failed check has its own line in the tab")
check(refusedSwitch.refusal(HookInstall.Run(end: .exited(1), output: """
        Traceback (most recent call last):
          File "mcpbar.py", line 2230, in <module>
        NameError: name 'codex' is not defined
        """))?.reason == "NameError: name 'codex' is not defined",
      "a script that died on a traceback is explained by the line that names the error")
check(refusedSwitch.refusal(HookInstall.Run(end: .timedOut, output: ""))?.reason == "did not finish in time"
        && refusedSwitch.refusal(HookInstall.Run(end: .exited(1), output: ""))?.reason == "exited with code 1",
      "and one that said nothing, by how it ended")

// Full MCP checks coalesce per agent. One flag for both used to mean a click on a Claude server
// started every Codex server as well, half a minute of spinner for a file the click never touched.
var mcpRefresh = MCPRefreshPoll()
check(mcpRefresh.begin(["claude", "codex"]) == ["claude", "codex"],
      "the timer and an opened panel check both agents")
check(mcpRefresh.begin(["claude"]).isEmpty, "a second check of an agent still being checked is not started")
check(!mcpRefresh.finish("codex"), "an agent nobody asked about again is left alone when its check lands")
check(mcpRefresh.begin(["claude", "codex"]) == ["codex"],
      "one agent's running check does not hold the other's back")
check(mcpRefresh.finish("claude"), "the check asked for meanwhile is remembered and runs once the first lands")
check(mcpRefresh.begin(["claude"]) == ["claude"] && !mcpRefresh.finish("claude"), "once, not for ever after")
// A switch written while that agent's check is out: the check read the config before the write
// (or, for Codex, holds the lock the switch's own re-read then finds busy), so its picture is stale.
mcpRefresh.switchStarted("claude")
_ = mcpRefresh.switchLanded("claude")
check(mcpRefresh.begin(["claude"]) == ["claude"] && !mcpRefresh.finish("claude"),
      "a switch with no check in flight orders nothing: the command leaves its own file current")
mcpRefresh.switchStarted("codex")
// What the controller does with a switch's own re-read it cannot believe: refreshMCP(of:).
check(!mcpRefresh.switchLanded("codex") && mcpRefresh.begin(["codex"]).isEmpty && mcpRefresh.finish("codex"),
      "a switch during its agent's check has that agent checked once more")
check(mcpRefresh.begin(["codex", "claude"]) == ["codex", "claude"], "and both are free again afterwards")
mcpRefresh.switchStarted("claude")
check(!mcpRefresh.switchLanded("claude") && mcpRefresh.begin(["claude"]).isEmpty
        && !mcpRefresh.finish("codex") && mcpRefresh.finish("claude"),
      "the re-check follows the agent whose config was written, not the other one")

// Whether a switch's own re-read can be believed: only when no check of its agent ran beside it.
// A check out at the click, one started while the switch was on its way, and one still out when it
// lands may each have read the config before the write. The switch then orders its agent checked
// again once, as it lands: false from switchLanded, which the controller answers with refreshMCP(of:).
func mcpSwitchReadChecks() {
    var poll = MCPRefreshPoll()
    poll.switchStarted("codex")
    check(poll.switchLanded("codex") && poll.begin(["codex"]) == ["codex"] && !poll.finish("codex"),
          "a switch alone: its own re-read is the truth, and no check is ordered for it")
    _ = poll.begin(["codex"])
    poll.switchStarted("codex")
    check(!poll.switchLanded("codex") && poll.begin(["codex"]).isEmpty && poll.finish("codex"),
          "a check out at the click makes the switch's own re-read suspect, and is followed by another")
    poll = MCPRefreshPoll()
    _ = poll.begin(["codex"])
    poll.switchStarted("codex")
    check(!poll.finish("codex") && !poll.switchLanded("codex") && poll.begin(["codex"]) == ["codex"]
            && !poll.finish("codex"),
          "a check out at the click and back before the switch: the switch's own re-read may have met "
            + "its lock, so the switch orders one more as it lands")
    poll = MCPRefreshPoll()
    poll.switchStarted("codex")
    _ = poll.begin(["codex"])
    check(!poll.finish("codex"), "a check started while a switch is on its way orders nothing itself")
    check(!poll.switchLanded("codex") && poll.begin(["codex"]) == ["codex"],
          "the switch orders it as it lands, its own re-read being suspect")
    poll = MCPRefreshPoll()
    poll.switchStarted("claude")
    _ = poll.begin(["codex"])
    check(poll.switchLanded("claude") && !poll.finish("codex"),
          "a check of the other agent has nothing to do with this switch")
    poll.switchStarted("codex")
    poll.switchStarted("codex")
    _ = poll.begin(["codex"])
    check(!poll.switchLanded("codex"), "two switches in a row: the crossing check spoils the first")
    _ = poll.finish("codex")
    _ = poll.finish("codex")
    check(!poll.switchLanded("codex"), "and the second, whose re-read may have met the same check")
    poll.switchStarted("codex")
    check(poll.switchLanded("codex"), "once both have landed the next switch starts clean")

    // Codex's switch holds codex/refresh.lock for its own re-read, and a check started meanwhile
    // finds it busy and exits at once. When each of those ordered another, one click spun dozens of
    // `codex-mcp refresh` runs until the switch came back (and Claude repeated 34 s checks while its
    // switch queued behind a slow Codex one). Here the controller runs whatever the poll orders.
    poll = MCPRefreshPoll()
    var extra = 0
    _ = poll.begin(["codex"])            // the panel opened
    poll.switchStarted("codex")          // the click, while that check is out
    for _ in 0..<50 {
        while poll.finish("codex") && extra <= 50 { extra += poll.begin(["codex"]).count }
        _ = poll.begin(["codex"])        // the ten-minute timer, the panel opened again
    }
    if !poll.switchLanded("codex") { extra += poll.begin(["codex"]).count }
    while poll.finish("codex") && extra <= 50 { extra += poll.begin(["codex"]).count }
    check(extra == 1, "checks coming and going while one switch is on its way order one more check, "
            + "not one each (got \(extra))")
}
mcpSwitchReadChecks()

// A switch clicked in the panel shows its new position at once and keeps it until a re-read that
// began after the write has landed. In 0.30.0 the row flipped back to the old state as soon as a
// check that had read the config before the click wrote its file, and stayed there until the
// check after it finished: half a minute of a switch that looked as if it had not taken.
func mcpClickChecks() {
    let folder = NSTemporaryDirectory() + "ccb-mcp-clicks-\(getpid())/"
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let file = folder + "codex.json"
    func write(serverState: String, denied: [String] = []) {
        let data = try! JSONSerialization.data(withJSONObject: ["checked_at": 1.0, "servers": [
            ["name": "ctx", "state": serverState, "source": "codex", "provider": "codex",
             "toolNames": ["a", "b"], "deniedTools": denied],
            ["name": "other", "state": "ok", "source": "codex", "provider": "codex"],
        ]])
        try! data.write(to: URL(fileURLWithPath: file))
    }
    func ctx(_ model: MCPModel) -> MCPServer { model.servers.first { $0.name == "ctx" }! }
    let off = BackendCommand.toggleServer(provider: "codex", name: "ctx", on: false)
    let on = BackendCommand.toggleServer(provider: "codex", name: "ctx", on: true)

    write(serverState: "ok")
    let model = MCPModel(path: file)
    model.reloadIfChanged()
    model.setServerLocally("ctx", enabled: false)
    check(ctx(model).state == "off", "a click shows the new position at once")
    model.reloadIfChanged(force: true)
    check(ctx(model).state == "off", "a check that read the config before the click does not flip it back")
    model.switchLanded(off, applied: true, ownRead: false, at: 10)
    model.reloadIfChanged(force: true)
    check(ctx(model).state == "off", "nor does the stale file the switch lands on")
    check(!model.forgetClicks(readStartedAt: 9) && ctx(model).state == "off",
          "a check that started before the write landed settles nothing")
    write(serverState: "off")
    check(model.forgetClicks(readStartedAt: 11), "a check started after the write settles the click")
    model.reloadIfChanged(force: true)
    check(ctx(model).state == "off", "and its file, which agrees, is what the row shows")

    model.setServerLocally("ctx", enabled: true)
    check(ctx(model).state == "pending", "switched back on, the row waits for a new session")
    model.reloadIfChanged(force: true)
    check(ctx(model).state == "pending", "an older read of it switched off does not undo the click")
    model.switchLanded(on, applied: true, ownRead: false, at: 20)
    check(model.forgetClicks(readStartedAt: 21), "a fresh check settles it")
    model.reloadIfChanged(force: true)
    check(ctx(model).state == "off",
          "and when it says the server is off after all, the row believes it: a later change is not hidden")

    write(serverState: "ok")
    model.reloadIfChanged(force: true)
    model.setServerLocally("ctx", enabled: false)
    let refusal = off.refusal(HookInstall.Run(end: .exited(2), output: "refused: no codex\n"))
    model.switchLanded(off, applied: false, ownRead: false, at: 30)
    model.reloadIfChanged(force: true)
    check(ctx(model).state == "ok" && refusal?.reason == "no codex",
          "a switch that was not applied goes back to the real state, beside its reason")

    model.setServerLocally("ctx", enabled: false)
    write(serverState: "ok")
    model.switchLanded(off, applied: true, ownRead: true, at: 40)
    model.reloadIfChanged(force: true)
    check(ctx(model).state == "ok",
          "a switch whose own re-read met no check is settled by it, even when that read disagrees")

    model.setServerLocally("ctx", enabled: false)
    model.setServerLocally("ctx", enabled: true)
    model.switchLanded(off, applied: true, ownRead: true, at: 50)
    write(serverState: "off")
    model.reloadIfChanged(force: true)
    check(ctx(model).state == "pending", "the first of two quick clicks landing does not settle the second")
    model.switchLanded(on, applied: true, ownRead: false, at: 51)
    check(!model.forgetClicks(readStartedAt: 50.5) && model.forgetClicks(readStartedAt: 52),
          "the second is settled by a read that began after its own write")

    write(serverState: "ok")
    model.reloadIfChanged(force: true)
    model.setToolLocally(server: "ctx", tool: "a", enabled: false)
    model.reloadIfChanged(force: true)
    check(ctx(model).tools.first { $0.name == "a" }?.enabled == false && ctx(model).enabledTools == 1,
          "a tool click survives a stale re-read too")
    let tool = BackendCommand.toggleTool(provider: "codex", server: "ctx", tool: "a", prefix: "ctx", on: false)
    model.switchLanded(tool, applied: true, ownRead: false, at: 60)
    check(model.forgetClicks(readStartedAt: 61), "and is settled by a fresh check")
    model.reloadIfChanged(force: true)
    check(ctx(model).tools.first { $0.name == "a" }?.enabled == true,
          "whose answer the row then shows as it is")
    check(model.servers.first { $0.name == "other" }?.state == "ok", "servers nobody clicked are untouched")

    // Claude's servers go through the same model and the same calls: one code path for both agents.
    let claudeFile = folder + "claude.json"
    try! JSONSerialization.data(withJSONObject: ["servers": [["name": "wiki", "state": "ok"]]])
        .write(to: URL(fileURLWithPath: claudeFile))
    let claude = MCPModel(path: claudeFile)
    claude.reloadIfChanged()
    claude.setServerLocally("wiki", enabled: false)
    claude.switchLanded(.toggleServer(provider: "claude", name: "wiki", on: false),
                        applied: true, ownRead: false, at: 70)
    claude.reloadIfChanged(force: true)
    check(claude.servers.first?.state == "off", "a Claude server click is held the same way")
    try? FileManager.default.removeItem(atPath: folder)
}
mcpClickChecks()


// Version order, used both to offer an update and to pick the newest nvm node.
check(ReleaseVersion.isNewer("0.0.10", than: "0.0.9"), "versions compare per component, not as text")
check(ReleaseVersion.isNewer("v20.19.0", than: "v9.11.2"), "a leading v is tolerated")
check(!ReleaseVersion.isNewer("0.6.0-rc.1", than: "0.6.0"),
      "a release candidate is never newer than the release it precedes")
check(!ReleaseVersion.isNewer("1.0", than: "1.0.0") && !ReleaseVersion.isNewer("1.0.0", than: "1.0"),
      "a missing component counts as zero")

// What an out-of-date copy is offered: the one answer the panel banner, the About page, the
// notification and the Install button all read.
check(UpdateOffer.resolve(current: "0.27.0", latest: "0.28.0", onDisk: "0.27.0",
                          brewManaged: false, caskVersion: nil) == .available(version: "0.28.0"),
      "a newer release and nothing on disk yet: the release is offered")
check(UpdateOffer.resolve(current: "0.27.0", latest: "0.28.0", onDisk: "0.28.0",
                          brewManaged: false, caskVersion: nil) == .restart(version: "0.28.0"),
      "a newer copy already on disk is a restart, not a second download")
check(UpdateOffer.resolve(current: "0.27.0", latest: "0.28.0", onDisk: "0.28.0",
                          brewManaged: true, caskVersion: "0.28.0") == .restart(version: "0.28.0"),
      "after brew replaced the bundle the answer is a restart, not the command again")
check(UpdateOffer.resolve(current: "0.27.0", latest: "0.28.0", onDisk: "0.27.0",
                          brewManaged: true, caskVersion: "0.28.0") == .brew(version: "0.28.0"),
      "a Homebrew install whose cask has the release gets the brew command")
check(UpdateOffer.resolve(current: "0.27.0", latest: "0.28.0", onDisk: "0.27.0",
                          brewManaged: true, caskVersion: "0.27.0") == .brewPending(version: "0.28.0"),
      "a Homebrew install whose cask lags the release is told to wait, never handed a command")
check(UpdateOffer.resolve(current: "0.27.0", latest: "0.28.0", onDisk: "0.27.0",
                          brewManaged: true, caskVersion: nil) == .brewPending(version: "0.28.0"),
      "a cask nobody has answered about yet counts as lagging")
check(UpdateOffer.resolve(current: "0.28.0", latest: "0.28.0", onDisk: "0.28.0",
                          brewManaged: false, caskVersion: nil) == UpdateOffer.none,
      "a current copy is offered nothing")
check(UpdateOffer.resolve(current: "0.28.0", latest: nil, onDisk: "0.28.0",
                          brewManaged: true, caskVersion: "0.29.0") == UpdateOffer.none,
      "no release seen yet: nothing is offered, whatever the cask says")
var diskReads = 0
func countedDiskVersion() -> String? { diskReads += 1; return "0.28.0" }
_ = UpdateOffer.resolve(current: "0.28.0", latest: "0.28.0", onDisk: countedDiskVersion(),
                        brewManaged: false, caskVersion: nil)
check(diskReads == 0, "a current copy answers without reading the bundle on disk: \(diskReads)")
check(UpdateOffer.available(version: "0.28.0").announcedVersion == "0.28.0"
        && UpdateOffer.brew(version: "0.28.0").announcedVersion == "0.28.0",
      "an update the panel can act on is announced")
check(UpdateOffer.brewPending(version: "0.28.0").announcedVersion == nil
        && UpdateOffer.restart(version: "0.28.0").announcedVersion == nil
        && UpdateOffer.none.announcedVersion == nil,
      "nothing is announced while the panel has no update to show for it")

// Where the app looks for a node: the hooks' own two first, then the fixed spots, then nvm newest
// first — as text "v9" sorts above "v20", which picked the oldest node on the machine.
let nodeList = HookInstall.nodeCandidates(home: "/h", nvmVersions: ["v9.11.2", "v20.19.0", "v18.0.0"])
check(nodeList == ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
                   "/h/.volta/bin/node", "/h/.asdf/shims/node",
                   "/h/.nvm/versions/node/v20.19.0/bin/node", "/h/.nvm/versions/node/v18.0.0/bin/node",
                   "/h/.nvm/versions/node/v9.11.2/bin/node"],
      "node candidates in order: \(nodeList)")
check(HookInstall.shellAnswer("/usr/local/bin/node\nbye from .zlogout\n", isExecutable: { _ in true })
        == "/usr/local/bin/node", "a shell's answer survives a .zlogout printing after it")
check(HookInstall.shellAnswer("/a/node\n/b/node\n", isExecutable: { $0 == "/a/node" }) == "/a/node",
      "and a node that cannot run is passed over")
check(HookInstall.shellAnswer("node not found\n", isExecutable: { _ in true }) == nil,
      "no path, no answer")

// Session files: both agents' directories, keyed so their ids cannot mix, and a reaped session's
// path computed from its own provider.
let listedFiles = Provider.stateFiles(home: "/h") { dir in
    dir.hasSuffix("/codex/state.d") ? ["abc.json", "abc.json.77.tmp"] : ["1.json", "2.tmp"]
}
check(listedFiles.map(\.key) == ["claude:1", "codex:abc"], "state files keyed by provider: \(listedFiles.map(\.key))")
check(listedFiles.last?.path == "/h/.claude/control-bar/codex/state.d/abc.json"
        && listedFiles.last?.id == "abc", "a Codex file keeps its own directory and id")
check(Provider.statePath(provider: "codex", id: "abc", home: "/h") == "/h/.claude/control-bar/codex/state.d/abc.json"
        && Provider.statePath(provider: "", id: "1", home: "/h") == "/h/.claude/control-bar/state.d/1.json",
      "a session is reaped from its own agent's directory; no provider means Claude")

// The banners an MCP change posts.
let banners = MCPChange(at: Date(), up: ["claude.ai Figma"], down: ["wiki", "plugin:figma:figma"],
                        appeared: [], vanished: [], toolDelta: 0).notifications
check(banners.map { $0.title } == ["MCP: 2 servers went down", "MCP: Figma is back"]
        && banners.map { $0.body } == ["wiki, figma", "Figma"],
      "down before up, one by name, several by count: \(banners)")
check(MCPChange(at: Date(), up: [], down: [], appeared: ["x"], vanished: [], toolDelta: 3)
        .notifications.isEmpty, "a server appearing or a tool count moving posts nothing")

// The mtime gate in front of codex/limits.json and codex/hooks.json.
// A directory of their own: an earlier check removes `dir` once it is done with it.
let splitDir = NSTemporaryDirectory() + "ccb-model-split-test/"
try? FileManager.default.removeItem(atPath: splitDir)
try! FileManager.default.createDirectory(atPath: splitDir, withIntermediateDirectories: true)
let gateFile = splitDir + "gate.json"
try? FileManager.default.removeItem(atPath: gateFile)
var gate: Date? = Date()
if case .missing = StateFileLook.at(gateFile, gate: &gate) { check(gate == nil, "no file is an answer, and clears the gate") }
else { check(false, "no file reads as missing") }
func writeGated(_ text: String, at stamp: Double) {
    try! text.write(toFile: gateFile, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: stamp)],
                                           ofItemAtPath: gateFile)
}
writeGated(#"{"untrusted": 2}"#, at: 1_785_000_000)
if case .changed(let object) = StateFileLook.at(gateFile, gate: &gate) {
    check((object["untrusted"] as? NSNumber)?.intValue == 2, "a new file is parsed")
} else { check(false, "a new file reads as changed") }
if case .unchanged = StateFileLook.at(gateFile, gate: &gate) { check(true, "the same mtime is a stat and no parse") }
else { check(false, "the same mtime reads as unchanged") }
writeGated("{half a rewr", at: 1_785_000_100)
if case .unchanged = StateFileLook.at(gateFile, gate: &gate) {
    check(gate == Date(timeIntervalSince1970: 1_785_000_000), "a half-written file keeps the last parse")
} else { check(false, "a half-written file reads as unchanged") }

// When the app may quit on its own.
let quitT0 = Date(timeIntervalSince1970: 1_785_000_000)
var idle = IdleQuit(launchedAt: quitT0)
check(idle.step(now: quitT0 + 1, inUse: false, needed: false) == .stay && idle.notNeededSince == nil,
      "nothing is decided inside the launch grace")
check(idle.step(now: quitT0 + 6, inUse: false, needed: false) == .stay && idle.notNeededSince == quitT0 + 6,
      "the first idle look only starts the clock")
check(idle.step(now: quitT0 + 8, inUse: false, needed: false) == .stay, "idle for less than the delay stays")
check(idle.step(now: quitT0 + 9, inUse: false, needed: false) == .confirm, "idle past the delay asks the probes")
check(idle.step(now: quitT0 + 10, inUse: true, needed: false) == .stay && idle.notNeededSince == nil,
      "an open window resets the clock")
_ = idle.step(now: quitT0 + 11, inUse: false, needed: false)
check(idle.step(now: quitT0 + 20, inUse: false, needed: true) == .stay && idle.notNeededSince == nil,
      "a session resets it too")
_ = idle.step(now: quitT0 + 21, inUse: false, needed: false)
idle.reset()
check(idle.step(now: quitT0 + 30, inUse: false, needed: false) == .stay,
      "a probe that found the app needed starts the clock over")

// When closing the panel gives the keyboard back to the app it was opened over.
check(PanelFocus.handsBack(appActive: true, previousRunning: true, settingsVisible: false),
      "Esc over a running app gives it the keyboard back")
check(!PanelFocus.handsBack(appActive: false, previousRunning: true, settingsVisible: false),
      "someone who already switched to another app keeps the one they chose")
check(!PanelFocus.handsBack(appActive: true, previousRunning: false, settingsVisible: false),
      "an app that has quit since, or none remembered, is not brought back")
check(!PanelFocus.handsBack(appActive: true, previousRunning: true, settingsVisible: true),
      "an open Settings window keeps the keyboard")

// The branch a session row shows, read out of .git/HEAD.
let gitRoot = splitDir + "git/"
try? FileManager.default.removeItem(atPath: gitRoot)
func gitWrite(_ path: String, _ text: String) {
    let full = gitRoot + path
    try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try! text.write(toFile: full, atomically: true, encoding: .utf8)
}
gitWrite("repo/.git/HEAD", "ref: refs/heads/main\n")
try! FileManager.default.createDirectory(atPath: gitRoot + "repo/sub/deeper", withIntermediateDirectories: true)
gitWrite("repo/.git/worktrees/wt/HEAD", "ref: refs/heads/feature/x\n")
gitWrite("wt/.git", "gitdir: ../repo/.git/worktrees/wt\n")
gitWrite("det/.git/HEAD", String(repeating: "ab12", count: 10) + "\n")
try! FileManager.default.createDirectory(atPath: gitRoot + "plain", withIntermediateDirectories: true)
let branches = GitBranches()
check(branches.branch(gitRoot + "repo/sub/deeper") == "main", "a cwd inside a repo finds its HEAD upward")
check(branches.branch(gitRoot + "wt") == "feature/x", "a worktree's relative gitdir is followed")
check(branches.branch(gitRoot + "det") == "ab12ab1", "a detached HEAD shows a short SHA")
check(branches.branch("") == "", "no cwd, no branch")
let plainBranch = branches.branch(gitRoot + "plain")
gitWrite("plain/.git/HEAD", "ref: refs/heads/dev\n")
if plainBranch == "" {   // only if the temp directory is not itself inside a repository
    check(branches.branch(gitRoot + "plain") == "", "a confirmed non-git directory is cached")
    check(branches.fresh(gitRoot + "plain") == "dev", "a hook event re-reads a directory that just became a repo")
}
try! FileManager.default.removeItem(atPath: gitRoot + "det/.git/HEAD")
check(branches.branch(gitRoot + "det") == "" && branches.headCache[gitRoot + "det"] == nil,
      "a HEAD that went away drops its cached resolution")
branches.keep(only: [gitRoot + "wt"])
check(Array(branches.headCache.keys) == [gitRoot + "wt"], "only directories still in use stay cached")
check(GitBranches.branch(fromHead: "ref: refs/tags/v1") == "v1", "any other ref shows its last component")
check(GitBranches.branch(fromHead: String(repeating: "AB12", count: 10)) == "",
      "uppercase hex is not a commit id git writes")


// MARK: ResetOdds — whenreset.app's odds and counts, and nothing invented where it says nothing

// A cut-down copy of a real answer from /api/v1/resets.json (14 Oct 2026): every field the panel
// reads, one event per product to show the long list is ignored, and the fields nobody reads kept
// so the parser is seen tolerating them.
let whenresetAnswer = #"""
{"schema":"whenreset/v1","generated_at":"2026-10-14T05:32:40Z","source":"https://whenreset.app/api/",
 "products":{
  "codex":{"name":"Codex","vendor":"OpenAI","sources":["thsottiaux","OpenAIDevs"],
   "stats":{"total":53,"last_date":"2026-10-13","last30d":5,"median_gap":3,"max_gap":68,
            "last_regular_date":"2026-10-13","last_banked_date":"2026-10-07","banked_count":8},
   "next_estimate":"2026-10-16","scheduled":null,
   "odds":{"result":{"1":0.1346,"2":0.3077,"7":0.7115,"n":52},"reason":null,"model":"climatology"},
   "events":[{"id":"2109812216212099456","date":"2026-10-13","type":"reset","kind":"regular",
              "scope":"all","page":"https://whenreset.app/codex/2026-10-13/"}]},
  "claude":{"name":"Claude","vendor":"Anthropic","sources":["ClaudeDevs","lydiahallie"],
   "stats":{"total":13,"last_date":"2026-09-04","last30d":0,"median_gap":8,"max_gap":47,
            "last_regular_date":"2026-09-04","last_banked_date":"2026-09-22","banked_count":1},
   "next_estimate":"2026-09-12","scheduled":null,
   "odds":{"result":{"1":0.0833,"2":0.0833,"7":0.5,"n":12},"reason":null,"model":"climatology"},
   "events":[{"id":"2102438800836489554","date":"2026-09-22","type":"reset","kind":"banked",
              "scope":"Pro+Max+Team","page":"https://whenreset.app/claude/2026-09-22/"}]}}}
"""#
let realOdds = ResetOdds(data: Data(whenresetAnswer.utf8))
check(realOdds?.products.map(\.id) == ["claude", "codex"],
      "both products are read, Claude first whatever order the answer has them in")
let realCodex = realOdds?.product("codex")
check(realCodex == ResetOddsProduct(id: "codex", name: "Codex", p24: 13, p48: 31, p7d: 71, total: 53,
                                    last30d: 5, lastRegular: "2026-10-13", lastBanked: "2026-10-07"),
      "Codex: 0.1346 / 0.3077 / 0.7115 read as 13% / 31% / 71%, 53 resets, 5 in 30 days")
let realClaude = realOdds?.product("claude")
check(realClaude?.p24 == 8 && realClaude?.p48 == 8 && realClaude?.p7d == 50 && realClaude?.total == 13
      && realClaude?.last30d == 0 && realClaude?.lastBanked == "2026-09-22",
      "Claude: 8% / 8% / 50%, 13 resets — and a real zero in last30d stays a zero")
check(realOdds?.product("gemini") == nil, "a product the answer does not carry is nil, not an empty row")

func oddsProduct(_ product: [String: Any]) -> ResetOddsProduct? {
    ResetOdds(json: ["products": ["codex": product]])?.product("codex")
}
let noResult = oddsProduct(["name": "Codex", "stats": ["total": 2], "odds": ["result": NSNull(),
                                                                             "reason": "too few resets"]])
check(noResult != nil && noResult?.p24 == nil && noResult?.p48 == nil && noResult?.p7d == nil
      && noResult?.total == 2,
      "odds.result null (too little history): no percentages at all, the counts still read")
let wrongTypes = oddsProduct(["name": 7, "stats": ["total": "53", "last30d": true, "last_regular_date": 20261013],
                              "odds": ["result": ["1": "0.13", "2": Double.nan, "7": 1e30]]])
check(wrongTypes?.name == "codex", "a name that is not a string falls back to the id")
check(wrongTypes?.p24 == nil && wrongTypes?.p48 == nil && wrongTypes?.p7d == nil,
      "a string, NaN and 1e30 are not percentages: nil, never 0 and never a crash")
check(wrongTypes?.total == nil && wrongTypes?.last30d == nil && wrongTypes?.lastRegular == nil,
      "a string count, a boolean count and a numeric date are unknown, not zero")
check(oddsProduct(["stats": ["total": 1e30, "last30d": -3]])?.total == nil
      && oddsProduct(["stats": ["total": 1e30, "last30d": -3]])?.last30d == nil,
      "an absurd or negative count is unknown rather than clamped into a believable number")
check(oddsProduct(["stats": ["last_date": "2026-09-01"]])?.lastRegular == "2026-09-01",
      "without last_regular_date the last reset of any kind stands in")
check(oddsProduct(["stats": "broken", "odds": 3]) != nil, "stats and odds of the wrong shape are skipped, not fatal")
check(ResetOdds(json: ["products": [:] as [String: Any]]) == nil, "no products at all is no answer")
check(ResetOdds(json: ["products": ["codex": "nope"]]) == nil, "a product that is not an object is not a product")
check(ResetOdds(json: [:]) == nil, "an answer without products is no answer")
check(ResetOdds(data: Data("<html>Cloudflare</html>".utf8)) == nil, "an HTML error page is no answer")
check(ResetOdds(data: Data("[1,2]".utf8)) == nil, "JSON that is not an object is no answer")
check(ResetOdds(json: ["products": ["zeta": [:] as [String: Any], "codex": [:] as [String: Any],
                                    "alpha": [:] as [String: Any], "claude": [:] as [String: Any]]])?
          .products.map(\.id) == ["claude", "codex", "alpha", "zeta"],
      "Claude, then Codex, then anything new alphabetically")

check(ResetOddsFeed.percent(NSNumber(value: 0.1346)) == 13, "0.1346 is 13%")
check(ResetOddsFeed.percent(NSNumber(value: 0.3077)) == 31, "0.3077 rounds to 31%, not down to 30%")
check(ResetOddsFeed.percent(NSNumber(value: 0)) == 0, "a real 0 stays 0")
check(ResetOddsFeed.percent(NSNumber(value: 1)) == 100, "certainty is 100%")
check(ResetOddsFeed.percent(NSNumber(value: 1.0004)) == 100, "rounding noise just over 1 clamps to 100")
check(ResetOddsFeed.percent(NSNumber(value: -0.2)) == nil, "a negative share is not a probability")
check(ResetOddsFeed.percent(NSNumber(value: 1e30)) == nil, "1e30 is not a probability")
check(ResetOddsFeed.percent(NSNumber(value: Double.infinity)) == nil, "infinity is not a probability")
check(ResetOddsFeed.percent(Double.nan) == nil, "NaN is not a probability")
check(ResetOddsFeed.percent("0.5") == nil, "a string is not a number")
check(ResetOddsFeed.percent(true) == nil, "a boolean is not a share")
check(ResetOddsFeed.percent(nil) == nil, "missing is missing")

let oddsNow = 1_791_000_000.0   // 2026-10-03 04:00 UTC
check(ResetOddsFeed.due(now: oddsNow, lastAttempt: 0), "never tried: due")
check(!ResetOddsFeed.due(now: oddsNow, lastAttempt: oddsNow - 899), "tried 14m59s ago: not yet")
check(ResetOddsFeed.due(now: oddsNow, lastAttempt: oddsNow - 900), "tried 15 minutes ago: due")
check(ResetOddsFeed.due(now: oddsNow, lastAttempt: oddsNow + 3600),
      "an attempt stamped in the future (the clock went back) does not stall the feed")

check(ResetOddsFeed.daysSince("2026-10-03", now: oddsNow) == 0, "a reset today is 0 days ago")
check(ResetOddsFeed.daysSince("2026-10-02", now: oddsNow) == 1, "yesterday is 1 day ago")
check(ResetOddsFeed.daysSince("2026-09-04", now: oddsNow) == 29, "4 Sep to 3 Oct is 29 days")
check(ResetOddsFeed.daysSince("2026-10-05", now: oddsNow) == 0, "a date ahead of this clock is today, not negative")
check(ResetOddsFeed.daysSince("2026-02-31", now: oddsNow) == nil, "31 February is not a date")
check(ResetOddsFeed.daysSince("13/10/2026", now: oddsNow) == nil, "another date format is not guessed at")
check(ResetOddsFeed.daysSince("", now: oddsNow) == nil && ResetOddsFeed.daysSince(nil, now: oddsNow) == nil,
      "no date, no age")
check(ResetOddsFeed.monthDay("2026-09-22") == "Sep 22", "a date is said as month and day")
check(ResetOddsFeed.monthDay("2026-9-2x") == nil, "a broken date is not said at all")

struct OddsTestError: LocalizedError { var errorDescription: String? { "The request timed out." } }
check(ResetOddsFeed.problem(status: nil, error: OddsTestError()) == "whenreset.app didn't answer",
      "no answer at all says so")
check(ResetOddsFeed.problem(status: 403, error: nil) == "whenreset.app refused the request (403)",
      "a refusal says so, with its code")
check(ResetOddsFeed.problem(status: 503, error: nil) == "whenreset.app answered 503",
      "any other status is named")
check(ResetOddsFeed.problem(status: 200, error: nil) == "whenreset.app sent an answer this app can't read",
      "a 200 that did not parse is a format problem, not a network one")

// MARK: ResetOdds size — an answer far past the real one's ~53 KB is not read at all

check(ResetOddsFeed.readable(byteCount: 53_000), "an answer the size of the real one is read")
check(ResetOddsFeed.readable(byteCount: 1_048_576), "exactly 1 MB is still read")
check(!ResetOddsFeed.readable(byteCount: 1_048_577), "one byte over 1 MB is not")
let hugeAnswer = "{\"pad\":\"" + String(repeating: "x", count: 1_100_000) + "\"," + whenresetAnswer.dropFirst()
check(ResetOdds(data: Data(whenresetAnswer.utf8)) != nil && ResetOdds(data: Data(hugeAnswer.utf8)) == nil,
      "a well-formed answer over 1 MB is not parsed, so it never reaches the cache")

// MARK: ResetOddsLook — what the card shows, from the figures on hand and the last attempt

let lookNow = oddsNow
let loadingLook = ResetOddsLook(odds: nil, fetchedAt: 0, problem: nil, now: lookNow)
check(loadingLook.state == "loading" && loadingLook.products.isEmpty && loadingLook.note == "",
      "no figures and no failure yet: loading")
let failedLook = ResetOddsLook(odds: nil, fetchedAt: 0, problem: "whenreset.app didn't answer", now: lookNow)
check(failedLook.state == "unavailable" && failedLook.products.isEmpty && failedLook.note == "whenreset.app didn't answer",
      "a failure with nothing cached is unavailable, and says why")
let strangerOnly = ResetOdds(json: ["products": ["gemini": ["name": "Gemini"]]])
let strangerLook = ResetOddsLook(odds: strangerOnly, fetchedAt: lookNow - 60, problem: nil, now: lookNow)
check(strangerLook.state == "unavailable" && strangerLook.products.isEmpty
      && strangerLook.note == "whenreset.app has no Claude or Codex figures",
      "an answer with no product this app knows is unavailable, not an empty card")
let freshLook = ResetOddsLook(odds: realOdds, fetchedAt: lookNow - 240, problem: nil, now: lookNow)
check(freshLook.state == "ok" && freshLook.products.map(\.id) == ["claude", "codex"] && !freshLook.stale
      && freshLook.note == "estimate from past resets, not official · updated 4 min ago",
      "fresh figures: ok, both providers, the estimate caveat with their age")
let cachedLook = ResetOddsLook(odds: realOdds, fetchedAt: lookNow - 3 * 3600, problem: "whenreset.app answered 503",
                               now: lookNow)
check(cachedLook.state == "ok" && cachedLook.products.count == 2
      && cachedLook.note == "couldn't refresh — showing data from 3h ago",
      "a failed refresh over cached figures keeps them and says how old they are")
check(!ResetOddsLook(odds: realOdds, fetchedAt: lookNow - 21600, problem: nil, now: lookNow).stale,
      "figures exactly 6 hours old are not stale yet")
check(ResetOddsLook(odds: realOdds, fetchedAt: lookNow - 21601, problem: nil, now: lookNow).stale,
      "6 hours and a second is stale")

check(ResetOddsFeed.bankedLine(banked: "2026-09-22", regular: "2026-09-04") == "Banked reset handed out Sep 22",
      "a banked reset newer than the last regular one gets its line")
check(ResetOddsFeed.bankedLine(banked: "2026-10-07", regular: "2026-10-13") == nil,
      "a banked reset older than the last regular one is not worth a line")
check(ResetOddsFeed.bankedLine(banked: "2026-09-22", regular: nil) == "Banked reset handed out Sep 22",
      "with no regular reset known, the banked one is the newest")
check(ResetOddsFeed.bankedLine(banked: nil, regular: "2026-09-04") == nil, "no banked reset, no line")
check(ResetOddsFeed.countsLine(total: 1, last30d: nil) == "1 reset tracked", "one reset is singular")
check(ResetOddsFeed.countsLine(total: 53, last30d: 5) == "53 resets tracked · 5 in last 30 days",
      "both counts, joined")
check(ResetOddsFeed.countsLine(total: nil, last30d: 0) == "0 in last 30 days", "a real zero is said")
check(ResetOddsFeed.countsLine(total: nil, last30d: nil) == nil, "no counts, no line")
check(ResetOddsFeed.lastReset("2026-10-03", now: oddsNow) == "today", "a reset today is said as today")
check(ResetOddsFeed.lastReset("2026-10-02", now: oddsNow) == "1d ago", "yesterday is 1d ago")
check(ResetOddsFeed.lastReset(nil, now: oddsNow) == nil, "no date, no age")

// MARK: Public reset announcements — events, never ordinary limit-window expiry

let resetEventNow = 1_792_000_000.0
func resetEvent(_ id: String, _ at: Double, kind: String = "regular", type: String = "reset") -> [String: Any] {
    ["id": id, "ts": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at)),
     "type": type, "kind": kind]
}
func resetAnswer(_ events: [String: [[String: Any]]]) -> ResetOdds {
    ResetOdds(json: ["products": events.mapValues { ["events": $0] }])!
}
let parsedAnnouncements = ResetOdds(json: ["products": [
    "claude": ["events": [resetEvent("c", resetEventNow), resetEvent("bank", resetEventNow, kind: "banked"),
                           resetEvent("unknown", resetEventNow, kind: "mystery"),
                           resetEvent("scheduled", resetEventNow, type: "scheduled"),
                           ["id": "bad", "ts": "2026-02-31T12:00:00Z", "type": "reset", "kind": "regular"],
                           resetEvent(" ", resetEventNow),
                           ["id": "missing-ts", "type": "reset", "kind": "regular"]]],
    "codex": [:] as [String: Any], "unknown": ["events": [resetEvent("x", resetEventNow)]]]])!
check(parsedAnnouncements.announcements["claude"] == [ResetAnnouncement(provider: "claude", id: "c", at: resetEventNow)]
      && parsedAnnouncements.announcements["codex"] == nil && parsedAnnouncements.announcements["unknown"] == nil,
      "announcements accept only known-provider regular reset identities with valid timestamps; omitted events stay absent")

var announcementTracker = ResetAnnouncementTracker()
let baselineAnnouncements = announcementTracker.consume(resetAnswer(["claude": [resetEvent("old", resetEventNow - 100)]]), now: resetEventNow)
let missingAnnouncements = announcementTracker.consume(ResetOdds(json: ["products": ["claude": [:] as [String: Any]]])!, now: resetEventNow)
let freshAnnouncements = announcementTracker.consume(resetAnswer([
    "claude": [resetEvent("old", resetEventNow - 100), resetEvent("new", resetEventNow - 10)],
    "codex": [resetEvent("codex-history", resetEventNow - 5)]]), now: resetEventNow)
check(baselineAnnouncements.isEmpty && missingAnnouncements.isEmpty
      && freshAnnouncements == [ResetAnnouncement(provider: "claude", id: "new", at: resetEventNow - 10)],
      "first snapshot and each new provider baseline silently; a later regular reset emits once after missing events")

let savedAnnouncementJSON = try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: announcementTracker.json)) as! [String: Any]
var restartedAnnouncements = ResetAnnouncementTracker(json: savedAnnouncementJSON)
let afterRestart = restartedAnnouncements.consume(resetAnswer(["claude": [
    resetEvent("later", resetEventNow - 1), resetEvent("new", resetEventNow - 10), resetEvent("old", resetEventNow - 100)]]), now: resetEventNow)
let correctedReplay = restartedAnnouncements.consume(resetAnswer(["claude": [
    resetEvent("old", resetEventNow), resetEvent("later", resetEventNow - 1), resetEvent("new", resetEventNow - 10),
    resetEvent("later", resetEventNow - 1)]]), now: resetEventNow)
let independentIdentity = restartedAnnouncements.consume(resetAnswer(["codex": [
    resetEvent("new", resetEventNow - 1), resetEvent("codex-history", resetEventNow - 5)]]), now: resetEventNow)
check(afterRestart.map(\.id) == ["later"] && correctedReplay.isEmpty
      && independentIdentity.map(\.provider) == ["codex"],
      "persisted provider plus id survives restart, reordering, duplicate rows and timestamp correction without suppressing another provider")

var timedAnnouncements = ResetAnnouncementTracker()
_ = timedAnnouncements.consume(resetAnswer(["claude": [resetEvent("baseline", resetEventNow - 100),
                                                        resetEvent("future", resetEventNow + 20)]]), now: resetEventNow)
let timedBatch = timedAnnouncements.consume(resetAnswer(["claude": [
    resetEvent("backfill", resetEventNow - 200), resetEvent("same-a", resetEventNow - 100),
    resetEvent("same-b", resetEventNow - 100), resetEvent("newest", resetEventNow - 1),
    resetEvent("future", resetEventNow + 20)]]), now: resetEventNow)
_ = timedAnnouncements.consume(resetAnswer(["claude": []]), now: resetEventNow)
_ = timedAnnouncements.consume(resetAnswer(["claude": [resetEvent("regressed", resetEventNow - 150)]]), now: resetEventNow)
var timedRestart = ResetAnnouncementTracker(json: timedAnnouncements.json)
let futureArrives = timedRestart.consume(resetAnswer(["claude": [resetEvent("future", resetEventNow + 20)]]), now: resetEventNow + 30)
let correctedBackfill = timedRestart.consume(resetAnswer(["claude": [resetEvent("backfill", resetEventNow + 25),
    resetEvent("twin-a", resetEventNow + 20), resetEvent("twin-b", resetEventNow + 20)]]), now: resetEventNow + 30)
check(timedBatch.map(\.id) == ["same-a", "same-b", "newest"]
      && futureArrives.map(\.id) == ["future"] && correctedBackfill.map(\.id) == ["twin-a", "twin-b"],
      "watermark survives empty/regressed responses and restart; backfill stays silent, future remains unconsumed, equal timestamps keep separate ids")

let migrationRawCache = try! JSONSerialization.data(withJSONObject: ["products": ["claude": ["events": [resetEvent("cache-old", resetEventNow - 100)]]]])
var migratedAnnouncements = ResetAnnouncementTracker()
let migrationBaseline = migratedAnnouncements.consume(ResetOdds(data: migrationRawCache)!, now: resetEventNow)
let mixedEvents: [Any] = [NSNull(), "bad row", resetEvent("cache-old", resetEventNow - 100),
    resetEvent("after-cache", resetEventNow - 10),
    ["id": "numeric-time", "ts": resetEventNow, "type": "reset", "kind": "regular"],
    ["id": "boolean-time", "ts": true, "type": "reset", "kind": "regular"],
    resetEvent("banked", resetEventNow, kind: "banked"), resetEvent("unknown-kind", resetEventNow, kind: "other")]
let mixedAnswer = ResetOdds(json: ["products": ["claude": ["events": mixedEvents]]])!
let afterMigration = migratedAnnouncements.consume(mixedAnswer, now: resetEventNow)
let beforeOmission = NSDictionary(dictionary: migratedAnnouncements.json)
_ = migratedAnnouncements.consume(ResetOdds(json: ["products": ["claude": ["events": "malformed"]]])!, now: resetEventNow)
let stateSurvived = beforeOmission.isEqual(to: migratedAnnouncements.json)
var switchedOnAgain = ResetAnnouncementTracker()
let newBaselineAfterOff = switchedOnAgain.consume(mixedAnswer, now: resetEventNow)
var invalidClockTracker = ResetAnnouncementTracker(json: ["version": 1, "providers": ["claude": ["ids": ["cache-old"], "newest": true]]])
let invalidClock = invalidClockTracker.consume(mixedAnswer, now: .nan)
let clockRecovers = invalidClockTracker.consume(mixedAnswer, now: resetEventNow)
check(migrationBaseline.isEmpty && afterMigration.map(\.id) == ["after-cache"] && stateSurvived
      && newBaselineAfterOff.isEmpty && invalidClock.isEmpty && clockRecovers.isEmpty,
      "raw-cache migration, opt-out baseline and malformed/partial inputs stay silent without discarding valid sibling events or the ledger")

var malformedFirstTracker = ResetAnnouncementTracker()
let malformedFirst = ResetOdds(json: ["products": ["claude": ["events": [["type": "reset", "kind": "regular", "id": "broken", "ts": "invalid"]]]]])!
_ = malformedFirstTracker.consume(malformedFirst, now: resetEventNow)
let historyAfterMalformed = malformedFirstTracker.consume(resetAnswer(["claude": [resetEvent("historical", resetEventNow - 100)]]), now: resetEventNow)
var bankedFirstTracker = ResetAnnouncementTracker()
_ = bankedFirstTracker.consume(resetAnswer(["claude": [resetEvent("valid-banked", resetEventNow - 100, kind: "banked")]]), now: resetEventNow)
let afterBankedBaseline = bankedFirstTracker.consume(resetAnswer(["claude": [resetEvent("reported-later", resetEventNow - 10)]]), now: resetEventNow)
check(historyAfterMalformed.isEmpty && afterBankedBaseline.map(\.id) == ["reported-later"],
      "only malformed records cannot establish a first baseline; a valid banked history can establish an empty regular baseline")

var futureFirstTracker = ResetAnnouncementTracker()
_ = futureFirstTracker.consume(resetAnswer(["claude": [resetEvent("future-first", resetEventNow + 20)]]), now: resetEventNow)
let historyAfterFutureOnly = futureFirstTracker.consume(resetAnswer(["claude": [resetEvent("history-first", resetEventNow - 100), resetEvent("future-first", resetEventNow + 20)]]), now: resetEventNow)
let afterValidBaseline = futureFirstTracker.consume(resetAnswer(["claude": [resetEvent("future-first", resetEventNow + 20)]]), now: resetEventNow + 30)
let repeatFuture = futureFirstTracker.consume(resetAnswer(["claude": [resetEvent("future-first", resetEventNow + 20)]]), now: resetEventNow + 30)
check(historyAfterFutureOnly.isEmpty && afterValidBaseline.map(\.id) == ["future-first"] && repeatFuture.isEmpty,
      "future-only first response defers baseline; historical recovery is silent and the future event later emits exactly once")

let visibilitySuite = "panel-visibility-check-" + UUID().uuidString
let visibilityDefaults = UserDefaults(suiteName: visibilitySuite)!
check(PanelVisibility(defaults: visibilityDefaults) == PanelVisibility(),
      "missing visibility preferences preserve all four blocks")
visibilityDefaults.set(false, forKey: "oauthLimits")
visibilityDefaults.set(false, forKey: "resetOdds")
var visibilityCombinationsOK = true
for mask in 0..<16 {
    let visibility = PanelVisibility(limits: mask & 1 != 0, chance: mask & 2 != 0,
                                     sessions: mask & 4 != 0, mcp: mask & 8 != 0)
    visibility.save(to: visibilityDefaults)
    let reloaded = PanelVisibility(defaults: visibilityDefaults)
    let expectedTabs: [PanelTab] = (mask & 4 != 0 ? [.sessions] : []) + (mask & 8 != 0 ? [.mcp] : [])
    visibilityCombinationsOK = visibilityCombinationsOK && reloaded == visibility && visibility.tabs == expectedTabs
    for selected in PanelTab.allCases {
        let expected = expectedTabs.contains(selected) ? selected : expectedTabs.first
        visibilityCombinationsOK = visibilityCombinationsOK && visibility.selectedTab(selected) == expected
    }
}
check(visibilityCombinationsOK, "all 16 visibility combinations persist and never select a hidden tab")
PanelVisibility().save(to: visibilityDefaults)
check(PanelVisibility(defaults: visibilityDefaults) == PanelVisibility()
      && visibilityDefaults.object(forKey: "oauthLimits") as? Bool == false
      && visibilityDefaults.object(forKey: "resetOdds") as? Bool == false,
      "show all restores only panel visibility, preserving data and reset opt-outs")
visibilityDefaults.removePersistentDomain(forName: visibilitySuite)

// Provider balance and quota parsing use synthetic responses and no credentials.
do {
    let balance = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.30"}]}"#.utf8)
    let deepSeek = try ModelServiceUsage.decode(balance, for: .deepseek)
    check(deepSeek.metrics == [.init(title: "Balance", value: "12.30 USD", resetAt: nil)],
          "DeepSeek balance preserves the displayed currency and amount")
    let blocked = try ModelServiceUsage.decode(Data(#"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"12.30"}]}"#.utf8), for: .deepseek)
    check(blocked.metrics == [.init(title: "Balance", value: "12.30 USD", resetAt: nil),
                              .init(title: "API calls", value: "Unavailable", resetAt: nil)],
          "DeepSeek can report available credit while its API calls are disabled")
    let quota = Data(#"""
    {"code":200,"success":true,"data":{"limits":[
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":20,"nextResetTime":1786624439633},
        {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":0},
        {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":100},
        {"type":"TOKENS_LIMIT","unit":5,"number":1,"percentage":2},
        {"type":"CREDIT_LIMIT","unit":6,"number":7,"usage":1000,"remaining":765,"currentValue":230,"percentage":10},
        {"type":"CREDIT_LIMIT","unit":1,"number":2,"percentage":30},
        {"type":"TOKENS_LIMIT","percentage":5}
    ]}}
    """#.utf8)
    let zai = try ModelServiceUsage.decode(quota, for: .zai)
    check(zai.metrics.map(\.title) == ["Credits · 5 h", "Tokens · 7 d", "MCP calls · 1 month",
                                     "Tokens · 1 min", "Credits · 7 wk", "Credits · 2 d", "Tokens"]
          && zai.metrics.map(\.value) == ["20% used", "0% used", "100% used", "2% used",
                                         "24% used", "30% used", "5% used"]
          && zai.metrics[0].resetAt == Date(timeIntervalSince1970: 1786624439.633),
          "Z.ai uses the window reported by the service, supports credit plans, and reads reset milliseconds")
    do {
        _ = try ModelServiceUsage.decode(Data(#"{"code":401,"success":false}"#.utf8), for: .zai)
        check(false, "an HTTP-200 authentication failure stays a failure")
    } catch {
        check(error as? ModelServiceUsageError == .unauthorized,
              "a rejected Z.ai key is distinguished from an empty quota")
    }
    do {
        let invalid = Data(#"{"code":500,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":5}]}}"#.utf8)
        _ = try ModelServiceUsage.decode(invalid, for: .zai)
        check(false, "a Z.ai error envelope cannot supply a quota")
    } catch {
        check(error as? ModelServiceUsageError == .invalidResponse,
              "unknown Z.ai errors stay distinct from valid quotas")
    }
} catch {
    check(false, "valid provider account payloads decode: \(error)")
}

// MARK: - The Usage window (Cost, Tokens, Limits)
// Ported from T3 Code (MIT, commit 803f21f); the vectors below are its own tests' where a
// comment names one.
//
// Every block is a function called on the next line, so its names stay its own. Not a bare
// `do`: top-level code is one function to the compiler, and the optimizer of the Swift on the CI
// runner (6.1, Intel) slows down far faster than that function grows. With these checks added
// as `do` blocks the `-O` build of this file did not finish in 28 minutes there; as functions
// it takes 7.5.

// Checks for Sources/Model/UsageLimitsModel.swift — the UI-free model behind the Limits tab.
// Fixture clock of T3's own tests: now = 2026-09-03T12:00:00Z; "14:00" below is now + 2 h.

func usageChecks01() {
    // Pace maths (spec 01 §4.7, examples E1-E3, D1, D8).
    let now = 1_788_436_800.0
    let share = UsageLimitMath.elapsedShare(resetsAt: now + 7200, windowMinutes: 300, now: now)
    check(share.map { abs($0 - 0.6) < 1e-9 } ?? false, "E1: a 5-hour window resetting in 2 h is 60% elapsed")
    check(UsageLimitMath.evenPacePercent(resetsAt: now + 7200, windowMinutes: 300, now: now) == 40,
          "E1: even pace leaves 40% of that window by now")
    check(UsageLimitMath.evenPacePercent(resetsAt: now + 3 * 86400, windowMinutes: 10080, now: now) == 43,
          "D1: a week resetting in exactly 3 days has 43% left at even pace")
    check(UsageLimitMath.elapsedShare(resetsAt: nil, windowMinutes: 300, now: now) == nil,
          "no reset time, no pace clock")
    check(UsageLimitMath.elapsedShare(resetsAt: now + 60, windowMinutes: nil, now: now) == nil,
          "no window length, no pace clock")
    check(UsageLimitMath.elapsedShare(resetsAt: now + 60, windowMinutes: 0, now: now) == nil,
          "a zero-length window has no pace clock")
    check(UsageLimitMath.evenPacePercent(resetsAt: now + 9 * 3600, windowMinutes: 300, now: now) == 100,
          "a reset further away than one window clamps to nothing elapsed")
    check(UsageLimitMath.evenPacePercent(resetsAt: now - 60, windowMinutes: 300, now: now) == 0,
          "a reset in the past clamps to fully elapsed")

    check(UsageLimitMath.paceClass(usedPercent: 40, elapsed: 0.6) == "under", "E1: 40% used at 60% elapsed is under pace")
    check(UsageLimitMath.paceClass(usedPercent: 62, elapsed: 0.6) == "on", "E2: 62% used at 60% elapsed is on pace")
    check(UsageLimitMath.paceClass(usedPercent: 80, elapsed: 0.6) == "ahead", "E3: 80% used at 60% elapsed is ahead")
    check(UsageLimitMath.paceClass(usedPercent: 65, elapsed: 0.6) == "on", "D8: a gap of exactly +5 is still on pace")
    check(UsageLimitMath.paceClass(usedPercent: 65.01, elapsed: 0.6) == "ahead", "D8: just past +5 is ahead")
    check(UsageLimitMath.paceClass(usedPercent: 55, elapsed: 0.6) == "on", "D8: a gap of exactly -5 is still on pace")
    check(UsageLimitMath.paceClass(usedPercent: 54.99, elapsed: 0.6) == "under", "D8: just past -5 is under")
}
usageChecks01()

func usageChecks02() {
    // Pace tick position (spec 01 §5.2): centre clamped 3 pt from either end, hidden under 6 pt.
    check(UsageLimitMath.tickX(percent: 40, width: 200) == 80, "the tick sits at its percent of the segment")
    check(UsageLimitMath.tickX(percent: 0, width: 200) == 3, "the tick never comes closer than 3 pt to the left end")
    check(UsageLimitMath.tickX(percent: 100, width: 200) == 197, "nor closer than 3 pt to the right end")
    check(UsageLimitMath.tickX(percent: 50, width: 6) == 3, "a 6 pt segment still draws its tick")
    check(UsageLimitMath.tickX(percent: 50, width: 5.9) == nil, "a segment narrower than 6 pt draws no tick")
    check(UsageLimitMath.tickX(percent: nil, width: 200) == nil, "no pace clock, no tick")
}
usageChecks02()

func usageChecks03() {
    // Codex kind from the window length, with T3's slot fallbacks (spec 08 §4.7).
    check(UsageLimitMath.codexKind(minutes: 300) == "session", "5 hours is a session window")
    check(UsageLimitMath.codexKind(minutes: 10079) == "session", "one minute short of a week is still a session")
    check(UsageLimitMath.codexKind(minutes: 10080) == "weekly", "a week is weekly")
    check(UsageLimitMath.codexKind(minutes: 43199) == "weekly", "one minute short of 30 days is still weekly")
    check(UsageLimitMath.codexKind(minutes: 43200) == "monthly", "30 days is monthly")
    check(UsageLimitMath.codexFallbackMinutes(slot: "primary", plan: "plus") == 300,
          "a paid plan's primary slot without a length is the 5-hour window")
    check(UsageLimitMath.codexFallbackMinutes(slot: "primary", plan: "free") == 43200,
          "the Free plan's primary slot without a length is monthly")
    check(UsageLimitMath.codexFallbackMinutes(slot: "primary", plan: "go") == 43200,
          "the Go plan's primary slot without a length is monthly")
    check(UsageLimitMath.codexFallbackMinutes(slot: "secondary", plan: "free") == 10080,
          "the secondary slot without a length is weekly on every plan")
}
usageChecks03()

func usageChecks04() {
    // One Claude account: plain rows, labels, order, rounding and the refill/hatch pair.
    let now = 1_788_436_800.0
    let claude = { (windows: [(String, Int, Double?)], ts: Double) -> LimitsSet in
        LimitsSet(provider: "claude",
                  windows: windows.map { NamedWindow(key: $0.0, title: "", badge: nil,
                                                     minutes: $0.0 == "five_hour" ? 300 : 10080,
                                                     window: LimitWindow(used: $0.1, resets: $0.2)) },
                  source: "api", ts: ts, plan: nil)
    }
    let alone = UsageProviderLimits(provider: "claude",
                                    set: claude([("five_hour", 40, now + 7200)], now - 3600),
                                    account: nil, now: now)
    let session = alone.rows.first
    check(alone.rows.count == 1 && session?.id == "five_hour" && session?.kind == "session"
          && session?.label == "Session", "Claude's 5-hour window is the Session row")
    check(session?.remainingPercent == 60, "D11: 40% used leaves 60%")
    check(session?.pace == "under" && session?.evenPacePercent == 40,
          "D11: the fill ends right of the tick, so the row is under pace")
    check(session?.refillPercent == 40 && session?.restoresPercent == 40,
          "an ordinary window gives back exactly what was used")
    check(session?.hatchPercent == 40, "D11: the hatch covers the whole empty part")
    check(alone.title == "Claude" && alone.plan == nil && alone.email == nil && alone.ticketCount == 0
          && alone.resetChoices(now: now).isEmpty && alone.accountRows.isEmpty,
          "without the account sidecar the rows still build and nothing about the account is claimed")

    let near = { (used: Int) -> String? in
        UsageProviderLimits(provider: "claude", set: claude([("five_hour", used, now + 7200)], now),
                            account: nil, now: now).rows.first?.pace
    }
    check(near(65) == "on" && near(66) == "ahead", "whole percents: 65 is on pace at 60% elapsed, 66 is ahead")
    check(near(55) == "on" && near(54) == "under", "whole percents: 55 is on pace at 60% elapsed, 54 is under")

    let three = UsageProviderLimits(
        provider: "claude",
        set: claude([("seven_day_fable", 20, now + 86400), ("seven_day", 99, now + 86400),
                     ("five_hour", 130, now + 7200)], now),
        account: nil, now: now)
    check(three.rows.map(\.id) == ["five_hour", "seven_day", "seven_day_fable"],
          "rows are ordered by kind, then by id, whatever order the file had")
    check(three.rows.map(\.label) == ["Session", "Weekly", "Weekly · Fable"], "Claude rows carry T3's labels")
    check(three.rows.first?.remainingPercent == 0 && three.rows.first?.usedPercent == 100,
          "a percentage past 100 on disk is clamped before any formula sees it")

    let unused = UsageProviderLimits(provider: "claude", set: claude([("five_hour", 0, now + 7200)], now),
                                     account: nil, now: now).rows.first
    check(unused?.remainingPercent == 100 && unused?.hatchPercent == 0 && unused?.restoresPercent == 0,
          "an untouched window has no hatch and restores nothing")
}
usageChecks04()

func usageChecks05() {
    // ACB's rule (spec 08 §4.6): a window whose reset has passed is drawn empty.
    let now = 1_788_436_800.0
    let set = LimitsSet(provider: "claude", windows: [
        NamedWindow(key: "five_hour", title: "", badge: nil, minutes: 300,
                    window: LimitWindow(used: 94, resets: now - 60)),
        NamedWindow(key: "seven_day", title: "", badge: nil, minutes: 10080,
                    window: LimitWindow(used: 100, resets: now - 60)),
    ], source: "api", ts: now - 600, plan: nil)
    let rows = UsageProviderLimits(provider: "claude", set: set, account: nil, now: now).rows
    let session = rows.first { $0.id == "five_hour" }
    check(session?.remainingPercent == 100 && session?.resetsAt == nil,
          "a window whose reset has passed reads as full with no reset time")
    check(session?.pace == nil && session?.evenPacePercent == nil && session?.hatchPercent == 0
          && session?.restoresPercent == nil,
          "an emptied window has no pace, no tick, no hatch and no restore entry")
    check(rows.first { $0.id == "seven_day" }?.remainingPercent == 100,
          "an exhausted week whose reset has passed is empty too, so it cannot block the session row")
    check(session.map { $0.details(now: now).map(\.label) == ["Left"] } ?? false,
          "the popover of an emptied window has only the Left row")
}
usageChecks05()

func usageChecks06() {
    // Weekly-exhausted suppression of the session row (spec 01 §4.5, examples E7-E8c, E11, D10).
    let now = 1_788_436_800.0
    let hour = 3600.0
    let claude = { (session: (Int, Double?), weekly: (Int, Double?), ts: Double) -> [UsageLimitRow] in
        UsageProviderLimits(provider: "claude", set: LimitsSet(provider: "claude", windows: [
            NamedWindow(key: "five_hour", title: "", badge: nil, minutes: 300,
                        window: LimitWindow(used: session.0, resets: session.1)),
            NamedWindow(key: "seven_day", title: "", badge: nil, minutes: 10080,
                        window: LimitWindow(used: weekly.0, resets: weekly.1)),
        ], source: "api", ts: ts, plan: nil), account: nil, now: now).rows
    }
    let codex = { (session: (Int, Double?), weekly: (Int, Double?)) -> [UsageLimitRow] in
        UsageProviderLimits(provider: "codex", set: LimitsSet(provider: "codex", windows: [
            NamedWindow(key: "primary", title: "", badge: nil, minutes: 300, ts: now - hour,
                        window: LimitWindow(used: session.0, resets: session.1)),
            NamedWindow(key: "secondary", title: "", badge: nil, minutes: 10080, ts: now - hour,
                        window: LimitWindow(used: weekly.0, resets: weekly.1)),
        ], source: "app-server", ts: now - hour, plan: "plus"), account: nil, now: now).rows
    }

    let e7 = claude((40, now + hour), (100, now + 2 * hour), now - hour).first
    check(e7?.remainingPercent == 0 && e7?.resetsAt == now + 2 * hour && e7?.restoresPercent == 100,
          "E7: a session that resets before the spent week comes back whole at the weekly reset")
    check(e7?.pace == nil && e7?.evenPacePercent == nil,
          "a suppressed session has no pace clock, so no trend icon and no tick")
    check(e7?.hatchPercent == 100, "E7: the whole suppressed bar is hatched")

    let e8 = codex((100, now + 2 * hour), (100, now + 2 * hour)).first
    check(e8?.remainingPercent == 0 && e8?.resetsAt == now + 2 * hour && e8?.restoresPercent == 100,
          "E8: Codex session and week resetting together restore a full session")

    let e8b = claude((100, now + 3 * hour), (100, now + 2 * hour), now - hour).first
    check(e8b?.resetsAt == now + 3 * hour && e8b?.restoresPercent == 100,
          "E8b: a spent session that outlives the week is usable only at its own reset")

    let e8c = codex((40, now + 3 * hour), (100, now + 2 * hour)).first
    check(e8c?.remainingPercent == 0 && e8c?.resetsAt == now + 2 * hour && e8c?.restoresPercent == 60,
          "E8c: a part-used session that outlives the week gives back its unspent 60% at the weekly reset")
    check(e8c?.hatchPercent == 60 && e8c?.evenPacePercent == nil,
          "D10: fill 0%, hatch on the right 60%, no tick")

    let weeklyRow = codex((40, now + 3 * hour), (100, now + 2 * hour)).last
    check(weeklyRow?.id == "secondary" && weeklyRow?.remainingPercent == 0 && weeklyRow?.pace != nil
          && weeklyRow?.restoresPercent == 100,
          "the spent weekly row itself keeps its own clock and restores 100%")

    let noSessionClock = claude((40, nil), (100, now + 2 * hour), now - hour).first
    check(noSessionClock?.remainingPercent == 0 && noSessionClock?.resetsAt == nil
          && noSessionClock?.pace == nil && noSessionClock?.restoresPercent == nil
          && noSessionClock?.hatchPercent == 0,
          "E11: without a session clock the blocked session is empty with no countdown and no hatch")
    let noWeeklyClock = claude((40, now + 2 * hour), (100, nil), now - hour).first
    check(noWeeklyClock?.remainingPercent == 0 && noWeeklyClock?.resetsAt == nil
          && noWeeklyClock?.restoresPercent == nil,
          "E11: without a weekly clock nobody can say when the blocked session comes back")
    let passedSession = claude((40, now - 1800), (100, now + 2 * hour), now - hour).first
    check(passedSession?.remainingPercent == 0 && passedSession?.resetsAt == nil,
          "E11: a session clock in the past leaves the blocked session without a countdown")
    let passedWeekly = claude((40, now + 2 * hour), (100, now - 1800), now - hour).first
    check(passedWeekly?.remainingPercent == 60 && passedWeekly?.pace == "under",
          "a spent week whose reset has passed no longer blocks the session row")

    let readLater = claude((40, now + hour), (100, now + 2 * hour), now + 3 * hour).first
    check(readLater?.remainingPercent == 0 && readLater?.resetsAt == nil && readLater?.restoresPercent == nil,
          "a reading stamped after both resets makes them stale: the cutoff is the later of now and the stamp")

    let lateWindow = UsageProviderLimits(provider: "codex", set: LimitsSet(provider: "codex", windows: [
        NamedWindow(key: "primary", title: "", badge: nil, minutes: 300, ts: now - hour,
                    window: LimitWindow(used: 40, resets: now + hour)),
        NamedWindow(key: "secondary", title: "", badge: nil, minutes: 10080, ts: now + 3 * hour,
                    window: LimitWindow(used: 100, resets: now + 2 * hour)),
    ], source: "rollout", ts: now - hour, plan: "plus"), account: nil, now: now).rows.first
    check(lateWindow?.resetsAt == nil && lateWindow?.restoresPercent == nil,
          "for Codex the cutoff takes the newer stamp of the two windows involved")
}
usageChecks06()

func usageChecks07() {
    // What does NOT trigger the suppression: a model's week, and the Reserve pool either way.
    let now = 1_788_436_800.0
    let fable = UsageProviderLimits(provider: "claude", set: LimitsSet(provider: "claude", windows: [
        NamedWindow(key: "five_hour", title: "", badge: nil, minutes: 300,
                    window: LimitWindow(used: 40, resets: now + 7200)),
        NamedWindow(key: "seven_day_fable", title: "", badge: nil, minutes: 10080,
                    window: LimitWindow(used: 100, resets: now + 86400)),
    ], source: "api", ts: now, plan: nil), account: nil, now: now).rows
    check(fable.first?.remainingPercent == 60, "a spent Fable week does not block the Session row")

    let reserve = UsageProviderLimits(provider: "codex", set: LimitsSet(provider: "codex", windows: [
        NamedWindow(key: "primary", title: "", badge: nil, minutes: 300, ts: now,
                    window: LimitWindow(used: 40, resets: now + 7200)),
        NamedWindow(key: "reserve:primary", title: "Reserve", badge: "7d", minutes: 10080, ts: now,
                    window: LimitWindow(used: 100, resets: now + 86400)),
    ], source: "app-server", ts: now, plan: "plus"), account: nil, now: now).rows
    check(reserve.map(\.id) == ["primary", "reserve:primary"] && reserve.last?.label == "Reserve",
          "the Reserve pool is its own row after the ordinary ones")
    check(reserve.first?.remainingPercent == 60, "a spent Reserve week does not block the ordinary Session row")
    check(reserve.last?.kind == "weekly" && reserve.last?.remainingPercent == 0 && reserve.last?.pace != nil,
          "the Reserve row is measured like any other window")

    let reserveSession = UsageProviderLimits(provider: "codex", set: LimitsSet(provider: "codex", windows: [
        NamedWindow(key: "secondary", title: "", badge: nil, minutes: 10080, ts: now,
                    window: LimitWindow(used: 100, resets: now + 86400)),
        NamedWindow(key: "reserve:primary", title: "Reserve", badge: "5h", minutes: 300, ts: now,
                    window: LimitWindow(used: 10, resets: now + 7200)),
    ], source: "app-server", ts: now, plan: "plus"), account: nil, now: now).rows
    check(reserveSession.last?.remainingPercent == 90,
          "a spent ordinary week does not zero the Reserve pool's session window")
}
usageChecks07()

func usageChecks08() {
    // Codex rows: kind and label from the length, slot fallbacks, and the sidecar's extra rows.
    let now = 1_788_436_800.0
    let codex = { (windows: [(String, Int?)], plan: String?) -> [UsageLimitRow] in
        UsageProviderLimits(provider: "codex", set: LimitsSet(provider: "codex", windows: windows.map {
            NamedWindow(key: $0.0, title: "", badge: nil, minutes: $0.1, ts: now,
                        window: LimitWindow(used: 30, resets: now + 3600))
        }, source: "app-server", ts: now, plan: plan), account: nil, now: now).rows
    }
    check(codex([("primary", 300), ("secondary", 10080)], "plus").map(\.label) == ["Session", "Weekly"],
          "a paid Codex plan shows Session and Weekly")
    check(codex([("primary", 10080)], "business").map(\.kind) == ["weekly"],
          "a plan that reports its week in the primary slot gets a Weekly row, not a Session one")
    check(codex([("primary", nil)], "free").map(\.label) == ["Monthly"],
          "the Free plan's primary slot without a length is the Monthly row")
    let fallback = codex([("primary", nil), ("secondary", nil)], "plus")
    check(fallback.map(\.kind) == ["session", "weekly"], "slots without a length fall back to 5 hours and a week")
    check(fallback.first?.evenPacePercent == nil && fallback.first?.pace == nil,
          "the fallback length only names the row: like the panel, no pace tick without a reported length")

    let extras = UsageAccount(json: [
        "ts": now, "provider": "codex", "planType": "promax", "email": " user@example.com ",
        "extraWindows": [["id": "individual", "kind": "monthly", "name": "Monthly credit limit",
                          "usedPercent": 30, "resetsAt": now + 5 * 86400] as [String: Any]],
        "resetCredits": ["availableCount": 1, "nextExpiresAt": now + 331_140] as [String: Any],
    ], provider: "codex")
    let full = UsageProviderLimits(provider: "codex", set: LimitsSet(provider: "codex", windows: [
        NamedWindow(key: "reserve:primary", title: "Reserve", badge: "7d", minutes: 10080, ts: now,
                    window: LimitWindow(used: 5, resets: now + 86400)),
        NamedWindow(key: "secondary", title: "", badge: nil, minutes: 10080, ts: now,
                    window: LimitWindow(used: 64, resets: now + 331_140)),
        NamedWindow(key: "primary", title: "", badge: nil, minutes: 300, ts: now,
                    window: LimitWindow(used: 10, resets: now + 7200)),
    ], source: "app-server", ts: now, plan: "unknown"), account: extras, now: now)
    check(full.rows.map(\.id) == ["primary", "secondary", "individual", "reserve:primary"],
          "Codex rows: session, weekly, the sidecar's monthly credit row, then Reserve")
    check(full.rows.map(\.label) == ["Session", "Weekly", "Monthly credit limit", "Reserve"],
          "the sidecar's row keeps the name it was given")
    let credit = full.rows.first { $0.id == "individual" }
    check(credit?.remainingPercent == 70 && credit?.pace == nil && credit?.restoresPercent == 30,
          "a row without a length has no pace but still restores at its reset")
    check(full.plan == "ChatGPT Pro 500 Subscription" && full.email == "user@example.com" && full.ticketCount == 1,
          "the popover gets the plan label, the trimmed e-mail and the ticket count from the sidecar")
    check(full.accountRows == [UsageDetailRow(label: "Plan", value: "ChatGPT Pro 500 Subscription")],
          "the account block is the Plan row")

    let onlyLimits = UsageProviderLimits(provider: "codex", set: LimitsSet(provider: "codex", windows: [
        NamedWindow(key: "primary", title: "", badge: nil, minutes: 300, ts: now,
                    window: LimitWindow(used: 10, resets: now + 7200)),
    ], source: "rollout", ts: now, plan: "plus"), account: nil, now: now)
    check(onlyLimits.plan == "ChatGPT Plus Subscription", "without a sidecar the Codex plan comes from the limits file")
}
usageChecks08()

func usageChecks09() {
    // Claude extras: scoped weeks and monthly spend from the sidecar; passed resets; duplicates.
    let now = 1_788_436_800.0
    let account = UsageAccount(json: [
        "ts": now - 60, "provider": "claude", "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_20x", "email": "user@example.com",
        "extraWindows": [
            ["id": "seven_day_orbit", "kind": "weekly", "name": "Orbit", "usedPercent": 12.5,
             "resetsAt": now + 86400, "windowMinutes": 10080] as [String: Any],
            ["id": "seven_day_nova", "kind": "weekly", "name": "Nova", "usedPercent": 99.5,
             "resetsAt": now - 5, "windowMinutes": 10080] as [String: Any],
            ["id": "seven_day_fable", "kind": "weekly", "name": "Fable", "usedPercent": 77] as [String: Any],
        ],
        "spend": ["enabled": true, "usedPercent": 40.0, "zeroCap": false] as [String: Any],
    ], provider: "claude")
    let set = LimitsSet(provider: "claude", windows: [
        NamedWindow(key: "five_hour", title: "", badge: nil, minutes: 300,
                    window: LimitWindow(used: 40, resets: now + 7200)),
        NamedWindow(key: "seven_day_fable", title: "", badge: nil, minutes: 10080,
                    window: LimitWindow(used: 20, resets: now + 86400)),
    ], source: "api", ts: now - 60, plan: nil)
    let built = UsageProviderLimits(provider: "claude", set: set, account: account, now: now)
    check(built.rows.map(\.id) == ["five_hour", "seven_day_fable", "seven_day_nova", "seven_day_orbit",
                                   "monthly_spend"],
          "sidecar rows join the panel's rows in T3's order, and a row the panel already has is not doubled")
    check(built.rows.map(\.label) == ["Session", "Weekly · Fable", "Weekly · Nova", "Weekly · Orbit",
                                      "Monthly spend"], "a scoped week is labelled by its model")
    check(built.rows.first { $0.id == "seven_day_fable" }?.remainingPercent == 80,
          "the panel's own Fable figure wins over a duplicate in the sidecar")
    let orbit = built.rows.first { $0.id == "seven_day_orbit" }
    check(orbit?.remainingPercent == 88 && orbit?.usedPercent == 13 && orbit?.evenPacePercent == 14,
          "a fractional percentage rounds half up on both sides: 12.5% used reads 13% used, 88% left")
    let nova = built.rows.first { $0.id == "seven_day_nova" }
    check(nova?.remainingPercent == 100 && nova?.resetsAt == nil,
          "a sidecar row whose reset has passed is drawn empty like the panel's rows")
    let spend = built.rows.last
    check(spend?.kind == "monthly" && spend?.remainingPercent == 60 && spend?.resetsAt == nil
          && spend?.pace == nil && spend?.hatchPercent == 0 && spend?.restoresPercent == nil,
          "monthly spend has no reset, so no countdown, no pace and no hatch")
    check(built.plan == "Claude Max Subscription", "the Claude plan label is T3's")

    let half = UsageProviderLimits(provider: "claude", set: nil, account: UsageAccount(json: [
        "extraWindows": [["id": "seven_day_orbit", "kind": "weekly", "name": "Orbit",
                          "usedPercent": 99.5, "resetsAt": now + 86400] as [String: Any]],
        "spend": ["enabled": false, "usedPercent": 40] as [String: Any],
    ], provider: "claude"), now: now)
    check(half.rows.map(\.id) == ["seven_day_orbit"], "spend that is switched off is not a row")
    check(half.rows.first?.remainingPercent == 1 && half.rows.first?.usedPercent == 100,
          "E9: 99.5% used leaves 1%, used and remaining are rounded independently")
}
usageChecks09()

func usageChecks10() {
    // Sidecar parsing: every key optional, wrong types are "unknown", never an error.
    let text = """
    {"ts": 1795112308, "provider": "claude", "subscriptionType": "max",
     "rateLimitTier": "default_claude_max_20x", "email": "user@example.com",
     "extraWindows": [{"id": "seven_day_orbit", "kind": "weekly", "name": "Orbit",
                       "usedPercent": 12.5, "resetsAt": 1795500000, "windowMinutes": 10080}],
     "spend": {"enabled": true, "usedPercent": 40.0, "zeroCap": false},
     "resetCredits": {"eligible": true, "availableCount": 2, "nextExpiresAt": 1796000000,
                      "nextCreditId": "grant_abc",
                      "options": [{"creditId": "grant_abc", "kind": "weekly", "availableCount": 1,
                                   "expiresAt": 1796000000}]}}
    """
    let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    let account = UsageAccount(json: root, provider: "claude")
    check(account.ts == 1_795_112_308 && account.subscriptionType == "max" && account.email == "user@example.com",
          "the brief's Claude sidecar parses")
    check(account.extraWindows == [UsageExtraWindow(id: "seven_day_orbit", kind: "weekly", name: "Orbit",
                                                    usedPercent: 12.5, resetsAt: 1_795_500_000,
                                                    windowMinutes: 10080)],
          "an extra window keeps its id, kind, name, percentage, reset and length")
    check(account.spend == UsageSpend(enabled: true, usedPercent: 40), "spend keeps its switch and percentage")
    check(account.resetCredits?.availableCount == 2 && account.resetCredits?.nextExpiresAt == 1_796_000_000
          && account.resetCredits?.options == [UsageResetOption(creditId: "grant_abc", kind: "weekly",
                                                                availableCount: 1, expiresAt: 1_796_000_000)],
          "reset credits keep the count, the expiry and the typed options")

    let empty = UsageAccount(json: [:], provider: "codex")
    check(empty.provider == "codex" && empty.ts == 0 && empty.email == nil && empty.planType == nil
          && empty.extraWindows.isEmpty && empty.spend == nil && empty.resetCredits == nil,
          "an empty sidecar is an account nothing is known about")

    let mangled = UsageAccount(json: [
        "ts": "soon", "email": "   ", "planType": 7, "subscriptionType": ["max"],
        "extraWindows": [["kind": "weekly", "usedPercent": 5] as [String: Any],
                         ["id": "x", "usedPercent": "many"] as [String: Any],
                         ["id": "odd", "kind": "hourly", "usedPercent": true] as [String: Any],
                         ["id": "ok", "kind": "hourly", "usedPercent": 250, "resetsAt": 0,
                          "windowMinutes": -5] as [String: Any],
                         "nonsense"] as [Any],
        "spend": "yes",
        "resetCredits": ["availableCount": -3, "nextExpiresAt": "tomorrow", "nextCreditId": "",
                         "options": [["creditId": "", "kind": "weekly", "availableCount": 1] as [String: Any],
                                     ["creditId": "g1", "kind": "weekly", "availableCount": 2.0,
                                      "expiresAt": -1] as [String: Any], 5] as [Any]] as [String: Any],
    ], provider: "claude")
    check(mangled.ts == 0 && mangled.email == nil && mangled.planType == nil && mangled.subscriptionType == nil,
          "wrong types in the account fields read as unknown")
    check(mangled.extraWindows == [UsageExtraWindow(id: "ok", kind: "other", name: "", usedPercent: 100,
                                                    resetsAt: nil, windowMinutes: nil)],
          "a window needs an id and a numeric percentage; the rest degrades to safe values")
    check(mangled.spend == nil, "a spend block of the wrong type is no spend")
    check(mangled.resetCredits?.availableCount == 0 && mangled.resetCredits?.nextExpiresAt == nil
          && mangled.resetCredits?.options == [UsageResetOption(creditId: "g1", kind: "weekly",
                                                                availableCount: 2, expiresAt: nil)],
          "a negative count is zero, an option needs a credit id, a bad expiry is no expiry")

    let ineligible = UsageAccount(json: ["resetCredits": ["eligible": false, "availableCount": 2] as [String: Any]],
                                  provider: "claude")
    check(ineligible.resetCredits == nil, "an account that is not eligible for resets has no credits block")
    let none = UsageAccount(json: ["resetCredits": ["availableCount": 0] as [String: Any]], provider: "codex")
    check(none.resetCredits?.availableCount == 0 && none.resetCredits?.options == nil,
          "a count of zero is known to have none, which is not the same as no information")
    let integers = UsageAccount(json: ["extraWindows": [["id": "individual", "kind": "monthly",
                                                         "usedPercent": 30, "windowMinutes": 43200.0]
                                                        as [String: Any]]], provider: "codex")
    check(integers.extraWindows.first?.usedPercent == 30 && integers.extraWindows.first?.windowMinutes == 43200,
          "whole numbers and fractions are both accepted wherever a number is expected")
}
usageChecks10()

func usageChecks11() {
    // Plan labels (ClaudeProvider.ts:114-179, CodexProvider.ts:211-245).
    let claude = UsagePlan.claudeLabel
    check(claude("max") == "Claude Max Subscription", "max is Claude Max")
    check(claude("max5") == "Claude Max Subscription" && claude("Max Plan") == "Claude Max Subscription",
          "max5 and Max Plan are Claude Max")
    check(claude("max20") == "Claude Ultra Subscription", "max20 is Claude Ultra")
    check(claude("Claude Max 20x Subscription") == "Claude Ultra Subscription", "the long 20x name is Claude Ultra")
    check(claude("pro") == "Claude Pro Subscription" && claude("team") == "Claude Team Subscription"
          && claude("enterprise") == "Claude Enterprise Subscription" && claude("free") == "Claude Free Subscription",
          "pro, team, enterprise and free keep their names")
    check(claude("some_new-tier") == "Claude Some New Tier Subscription",
          "an unknown tier is shown in title case rather than dropped")
    check(claude("claude_foo") == "Claude Foo Subscription", "a name that already starts with Claude is not doubled")
    check(claude("foo subscription") == "Claude Foo Subscription",
          "a name that already ends with Subscription is not doubled")
    check(claude(nil) == nil && claude("") == nil && claude(" _ ") == nil, "no subscription type, no plan label")

    let codex = UsagePlan.codexLabel(_:)
    check(codex("free") == "ChatGPT Free Subscription" && codex("go") == "ChatGPT Go Subscription"
          && codex("plus") == "ChatGPT Plus Subscription", "free, go and plus")
    check(codex("pro") == "ChatGPT Pro 200 Subscription" && codex("prolite") == "ChatGPT Pro 100 Subscription"
          && codex("promax") == "ChatGPT Pro 500 Subscription", "the three Pro tiers")
    check(codex("self_serve_business_prolite") == "ChatGPT Business Premium Subscription"
          && codex("team") == "ChatGPT Business Subscription"
          && codex("self_serve_business_usage_based") == "ChatGPT Business Subscription"
          && codex("business") == "ChatGPT Business Subscription", "the business plans")
    check(codex("ent26") == "ChatGPT Enterprise Subscription"
          && codex("enterprise_cbp_automation") == "ChatGPT Enterprise Subscription"
          && codex("enterprise_cbp_usage_based") == "ChatGPT Enterprise Subscription"
          && codex("enterprise") == "ChatGPT Enterprise Subscription", "the enterprise plans")
    check(codex("edu") == "ChatGPT Edu Subscription" && codex("edu_plus") == "ChatGPT Edu Subscription"
          && codex("edu_pro") == "ChatGPT Edu Subscription", "the education plans")
    check(codex("unknown") == "ChatGPT Subscription", "an unknown plan is still a ChatGPT subscription")
    check(codex("Plus") == nil && codex("mystery") == nil && codex(nil) == nil,
          "a plan type outside the table has no label")
    check(UsagePlan.codexLabel(limitsPlan: "unknown", accountPlan: "promax") == "ChatGPT Pro 500 Subscription",
          "an unknown plan in the limits answer yields to the account's")
    check(UsagePlan.codexLabel(limitsPlan: "plus", accountPlan: "promax") == "ChatGPT Plus Subscription",
          "otherwise the limits answer names the plan")
    check(UsagePlan.codexLabel(limitsPlan: "unknown", accountPlan: nil) == "ChatGPT Subscription",
          "unknown everywhere is the bare ChatGPT subscription")
}
usageChecks11()

func usageChecks12() {
    // Durations and countdowns (spec 01 §6.1-6.3, examples D2-D7).
    let now = 1_788_436_800.0
    check(UsageLimitText.duration(331_140) == "3d 19h", "D2: 3 d 19 h 59 min reads 3d 19h")
    check(UsageLimitText.duration(7500) == "2h 5m", "D3: 7500 s reads 2h 5m")
    check(UsageLimitText.duration(3599.999) == "59m", "D4: just under an hour floors to 59m")
    check(UsageLimitText.duration(86400) == "1d 0h" && UsageLimitText.duration(3600) == "1h 0m",
          "D5: the smaller unit is printed even when zero")
    check(UsageLimitText.duration(59.999) == "0m" && UsageLimitText.duration(0) == "0m"
          && UsageLimitText.duration(-5) == "0m" && UsageLimitText.duration(.nan) == "0m",
          "D6: under a minute, zero, negative and NaN all read 0m")

    let at = now + 331_140
    check(UsageLimitText.resetsIn(at, now: now, style: .full) == "resets in 3d 19h", "D2: the full style")
    check(UsageLimitText.resetsIn(at, now: now, style: .short) == "in 3d 19h", "D2: the short style")
    check(UsageLimitText.resetsIn(at, now: now, style: .refill) == "↻ 3d 19h", "D2: the refill style")
    check(UsageLimitText.resetsIn(nil, now: now, style: .full) == nil, "no reset time, no countdown")
    check(UsageLimitText.resetsIn(now, now: now, style: .refill) == "resets now",
          "D7: a reset at this very moment reads resets now in every style")
    check(UsageLimitText.resetsIn(now - 60, now: now, style: .short) == "resets now", "a past reset reads resets now")
    check(UsageLimitText.resetsIn(now + 59.999, now: now, style: .short) == "Resets momentarily",
          "D7: under a minute away reads Resets momentarily in every style")
    check(UsageLimitText.resetsIn(now + 60, now: now, style: .full) == "resets in 1m",
          "D7: exactly a minute away is a countdown")

    check(UsageLimitText.paceLabel("ahead") == "Ahead of pace: spending faster than the window elapses"
          && UsageLimitText.paceLabel("on") == "On pace with the window"
          && UsageLimitText.paceLabel("under") == "Under pace: headroom left for the rest of the window",
          "the trend icon's tooltip is T3's sentence")
}
usageChecks12()

func usageChecks13() {
    // Absolute reset time (spec 01 §6.4, example D12). The formats follow the supplied locale.
    let us = Locale(identifier: "en_US"), ru = Locale(identifier: "ru_RU")
    let berlin = TimeZone(identifier: "Europe/Berlin")!, tokyo = TimeZone(identifier: "Asia/Tokyo")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = berlin
    let at = { (year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Double in
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
            .timeIntervalSince1970
    }
    // Modern ICU separates the time from AM/PM with a narrow no-break space; the layout is the
    // locale's business, the wording is ours.
    let plain = { (text: String) -> String in
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
    let now = at(2026, 11, 19, 10, 0)
    let time = { (reset: Double, now: Double, locale: Locale, zone: TimeZone) -> String in
        plain(UsageLimitText.resetTime(reset, now: now, locale: locale, timeZone: zone))
    }
    check(time(at(2026, 11, 23, 14, 40), now, us, berlin) == "11/23 2:40 PM", "D12: later this year is month/day and time")
    check(time(at(2026, 11, 20, 14, 40), now, us, berlin) == "tomorrow at 2:40 PM", "D12: the next day reads tomorrow at")
    check(time(at(2026, 11, 19, 14, 40), now, us, berlin) == "2:40 PM", "D12: the same day is the time alone")
    check(time(at(2027, 1, 2, 14, 40), now, us, berlin) == "1/2/2027 2:40 PM", "another year adds the year")
    check(time(at(2026, 11, 23, 14, 40), now, ru, berlin) == "23.11 14:40", "a Russian region reads 23.11 14:40")
    check(time(at(2026, 11, 20, 14, 40), now, ru, berlin) == "tomorrow at 14:40",
          "the words stay English, only the time follows the region")
    check(time(at(2026, 11, 20, 0, 30), at(2026, 11, 19, 23, 30), us, berlin) == "tomorrow at 12:30 AM",
          "tomorrow is the next calendar day, even one hour away")
    check(time(at(2026, 11, 20, 23, 0), at(2026, 11, 19, 0, 30), us, berlin) == "tomorrow at 11:00 PM",
          "and still tomorrow 46 hours away")
    check(time(at(2026, 11, 19, 20, 0), now, us, tokyo) == "tomorrow at 4:00 AM",
          "the calendar day is the supplied time zone's")
    check(time(at(2026, 11, 18, 14, 40), now, us, berlin) == "yesterday at 2:40 PM", "a reset a day back reads yesterday at")
    check(time(at(2026, 11, 15, 14, 40), now, us, berlin) == "11/15 2:40 PM", "an older reset is month/day and time")
    check(time(at(2026, 11, 19, 9, 0), now, us, berlin) == "9:00 AM", "earlier the same day is the time alone")
    // Across the autumn clock change the two days are 25 hours apart and still one day apart.
    check(time(at(2026, 10, 25, 12, 0), at(2026, 10, 24, 12, 0), us, berlin) == "tomorrow at 12:00 PM",
          "a clock change between the two days does not shift the day count")
}
usageChecks13()

func usageChecks14() {
    // The popover's window rows (UsageLimitsPooled.tsx:199-215) and the segment's spoken label.
    let us = Locale(identifier: "en_US"), utc = TimeZone(identifier: "UTC")!
    let now = 1_788_436_800.0   // 2026-09-03 12:00 UTC
    let plain = { (text: String) -> String in text.replacingOccurrences(of: "\u{202F}", with: " ") }
    let row = { (used: Int, resets: Double?, minutes: Int) -> UsageLimitRow? in
        UsageProviderLimits(provider: "claude", set: LimitsSet(provider: "claude", windows: [
            NamedWindow(key: "seven_day", title: "", badge: nil, minutes: minutes,
                        window: LimitWindow(used: used, resets: resets)),
        ], source: "api", ts: now, plan: nil), account: nil, now: now).rows.first
    }
    let weekly = row(64, now + 331_140, 10080)
    let rows = weekly?.details(now: now, locale: us, timeZone: utc) ?? []
    check(rows.map(\.label) == ["Left", "Resets", "Even pace", "Restores"], "a running window has all four rows")
    check(rows.map { plain($0.value) } == ["36%", "9/7 7:59 AM · in 3d 19h", "55% left by now", "+64% of pool"],
          "the rows read like T3's popover: 36%, date · countdown, even pace, restore")
    let fresh = row(0, now + 7200, 300)?.details(now: now, locale: us, timeZone: utc) ?? []
    check(fresh.map(\.label) == ["Left", "Resets", "Even pace"] && plain(fresh[1].value) == "2:00 PM · in 2h 0m",
          "an untouched window restores nothing, so it has no Restores row")
    let soon = row(10, now + 30, 300)?.details(now: now, locale: us, timeZone: utc) ?? []
    check(soon.count > 1 && plain(soon[1].value) == "12:00 PM · Resets momentarily",
          "under a minute away the countdown reads Resets momentarily")
    let undated = row(10, nil, 300)?.details(now: now, locale: us, timeZone: utc) ?? []
    check(undated == [UsageDetailRow(label: "Left", value: "90%")], "without a reset time only Left is shown")

    check(weekly?.accessibilityLabel(name: "Codex", credits: 0, now: now)
          == "Codex: 36% left, resets in 3d 19h, 55% of the window left",
          "the segment is spoken as name, percent left, countdown and window share")
    check(weekly?.accessibilityLabel(name: "Codex", credits: 1, now: now)
          == "Codex: 36% left, resets in 3d 19h, 55% of the window left, 1 reset credit banked",
          "one banked credit is singular")
    check(row(10, nil, 300)?.accessibilityLabel(name: "Claude", credits: 2, now: now)
          == "Claude: 90% left, 2 reset credits banked", "missing parts are dropped, several credits are plural")
}
usageChecks14()

func usageChecks15() {
    // Reset-credit choices (usageLimitsCopy.ts:126-191), one machine.
    let now = 1_788_436_800.0
    let codex = { (count: Int, expires: Double?) -> UsageResetCredits in
        UsageResetCredits(availableCount: count, nextExpiresAt: expires, options: nil)
    }
    let compact = UsageResetCredit.choices(codex(1, now + 331_140), provider: "codex", now: now)
    check(compact.count == 1 && compact.first?.key == "next" && compact.first?.creditId == nil,
          "Codex has one choice, and it names no credit: the backend picks the next one")
    check(compact.first?.summary == "1 banked · expires in 3d 19h", "the popover's summary with an expiry")
    check(compact.first?.actionLabel == "Use reset" && compact.first?.redeemable == true, "its button reads Use reset")
    check(compact.first?.confirmDescription
          == "This redeems one credit on your account and clears the current rate-limit windows. It cannot be undone.",
          "its confirmation says what is spent")
    check(UsageResetCredit.choices(codex(3, nil), provider: "codex", now: now).first?.summary == "3 banked",
          "the popover's summary without an expiry")
    check(UsageResetCredit.choices(codex(1, nil), provider: "codex", now: now, compact: false).first?.summary
          == "1 reset credit banked", "the long summary, singular")
    check(UsageResetCredit.choices(codex(2, now + 331_140), provider: "codex", now: now, compact: false).first?.summary
          == "2 reset credits banked · next expires in 3d 19h", "the long summary, plural with an expiry")
    let zero = UsageResetCredit.choices(codex(0, now + 60), provider: "codex", now: now).first
    check(zero?.summary == "No reset credits banked" && zero?.redeemable == false && zero?.availableCount == 0,
          "no credits: the summary says so and there is nothing to press")
    check(UsageResetCredit.choices(codex(1, now - 60), provider: "codex", now: now).first?.summary
          == "1 banked · expires in 0m", "an expiry already in the past reads 0m")

    let claude = UsageResetCredits(availableCount: 5, nextExpiresAt: now + 3600, options: [
        UsageResetOption(creditId: "session_a", kind: "session", availableCount: 1, expiresAt: nil),
        UsageResetOption(creditId: "weekly_a", kind: "weekly", availableCount: 1, expiresAt: now + 331_140),
        UsageResetOption(creditId: "fable_a", kind: "fable", availableCount: 2, expiresAt: nil),
        UsageResetOption(creditId: "full_a", kind: "full", availableCount: 0, expiresAt: nil),
        UsageResetOption(creditId: "odd_a", kind: "galactic", availableCount: 1, expiresAt: nil),
    ])
    let options = UsageResetCredit.choices(claude, provider: "claude", now: now)
    check(options.map(\.key) == ["session_a", "weekly_a", "fable_a", "full_a"]
          && options.map(\.creditId) == ["session_a", "weekly_a", "fable_a", "full_a"],
          "Claude has one choice per kind of reset, each naming its credit; a kind nobody can describe is left out")
    check(options.map(\.summary) == ["5-hour reset · 1 left", "Weekly reset · 1 left · expires in 3d 19h",
                                     "Fable reset · 2 left", "Full reset · 0 left"],
          "each summary is label, count and expiry")
    check(options.allSatisfy { $0.actionLabel == "Use" }, "their buttons read Use")
    check(options.map(\.redeemable) == [true, true, true, false], "a kind with nothing left has no button")
    check(options.map(\.confirmDescription) == [
        "5-hour reset: Refills your 5-hour limit. This cannot be undone.",
        "Weekly reset: Refills your weekly limit. This cannot be undone.",
        "Fable reset: Refills your Fable allowance and gives back what Fable used on your weekly limit. "
            + "It doesn't reset your whole week. This cannot be undone.",
        "Full reset: Refills your 5-hour and weekly limits. This cannot be undone.",
    ], "each confirmation names what that reset refills")

    let bare = UsageResetCredit.choices(
        UsageResetCredits(availableCount: 1, nextExpiresAt: nil, options: nil),
        provider: "claude", now: now).first
    check(bare?.redeemable == false, "a Claude credit that names no grant cannot be redeemed from here")

    let gate = { (credits: UsageResetCredits?) -> UsageProviderLimits in
        var json: [String: Any] = [:]
        if let credits { json["resetCredits"] = ["availableCount": credits.availableCount] }
        return UsageProviderLimits(provider: "codex", set: nil,
                                   account: UsageAccount(json: json, provider: "codex"), now: now)
    }
    check(gate(codex(0, nil)).resetChoices(now: now).isEmpty && gate(codex(0, nil)).ticketCount == 0,
          "with no credit banked the popover has no reset block and the chip no ticket")
    check(gate(nil).resetChoices(now: now).isEmpty, "nor without any credit information")
    check(gate(codex(2, nil)).resetChoices(now: now).first?.summary == "2 banked" && gate(codex(2, nil)).ticketCount == 2,
          "with credits banked the popover offers the compact choice and the chip shows the count")

    check(UsageResetCredit.confirmTitle == "Use a reset credit?" && UsageResetCredit.confirmButton == "Use credit"
          && UsageResetCredit.cancelButton == "Cancel" && UsageResetCredit.busyButton == "Using…"
          && UsageResetCredit.busyStatus == "Using reset credit…", "the dialog and the progress line use T3's words")
}
usageChecks15()

func usageChecks16() {
    // reset-credit-result.json and the sentence each result is shown as.
    let result = { (provider: String, outcome: Any?, error: Any?, confirmed: Any?) -> UsageResetResult in
        var json: [String: Any] = ["ts": 1_795_112_308, "provider": provider, "creditId": "grant_abc"]
        json["outcome"] = outcome ?? NSNull()
        json["error"] = error ?? NSNull()
        if let confirmed { json["confirmed"] = confirmed }
        return UsageResetResult(json: json, provider: provider)
    }
    let parsed = result("claude", "reset", nil, true)
    check(parsed.ts == 1_795_112_308 && parsed.provider == "claude" && parsed.creditId == "grant_abc"
          && parsed.outcome == "reset" && parsed.error == nil && parsed.confirmed,
          "the result file parses, a null error is no error")
    check(parsed.message == "Reset applied. Your windows have cleared.", "a confirmed reset")
    check(result("claude", "reset", nil, false).message
          == "The reset was applied, but Claude could not confirm the new limits. Refresh to check.",
          "a Claude reset the re-poll could not confirm")
    check(result("codex", "reset", nil, false).message
          == "The reset was applied, but Codex could not confirm the new limits. Refresh to check.",
          "a Codex reset the re-poll could not confirm")
    check(result("codex", "nothingToReset", nil, false).message == "Nothing to reset right now.", "nothing to reset")
    check(result("codex", "noCredit", nil, true).message == "No reset credit left.", "no credit left")
    check(result("claude", "alreadyRedeemed", nil, true).message == "That credit was already redeemed.",
          "already redeemed")

    let claudeErrors = [
        "malformedCredit": "Claude returned a malformed reset credit.",
        "loginUnreadable": "Claude could not read its login.",
        "accountUnreadable": "Claude could not read its account.",
        "signedOut": "Sign in to Claude again to redeem resets.",
        "rateLimited": "Claude is rate limiting resets. Try again soon.",
        "coolingDown": "Claude resets are cooling down. Try again later.",
        "unconfirmed": "Claude could not confirm the reset. If you are still limited in a moment, try again.",
        "requestFailed": "Claude could not redeem the reset.",
    ]
    check(claudeErrors.allSatisfy { result("claude", nil, $0.key, false).message == $0.value },
          "each Claude failure category has T3's sentence")
    check(result("claude", nil, "somethingNew", false).message == "Claude could not redeem the reset.",
          "an unknown Claude failure is the generic Claude sentence")
    check(["timeout", "not_installed", "connection_unavailable", "connection_closed", "invalid_reply",
           "rpc_error", "somethingNew"].allSatisfy {
              result("codex", nil, $0, false).message == "Codex could not redeem the reset credit."
          }, "every Codex failure is T3's one sentence")
    check(result("codex", nil, "busy", false).message == result("claude", nil, "busy", false).message
          && result("codex", nil, "busy", false).message == "A reset is already in progress. Try again in a moment.",
          "a held lock says a reset is already running, for either provider")
    check(result("codex", nil, nil, false).message == "Could not use the reset credit."
          && result("codex", "exploded", nil, true).message == "Could not use the reset credit.",
          "neither an outcome nor an error, or an outcome nobody knows, is the generic failure")

    let mangled = UsageResetResult(json: ["ts": "x", "outcome": 5, "error": ["a"], "confirmed": "yes"],
                                   provider: "codex")
    check(mangled.ts == 0 && mangled.creditId == nil && mangled.outcome == nil && mangled.error == nil
          && !mangled.confirmed && mangled.message == "Could not use the reset credit.",
          "a mangled result file degrades to an unknown result")
}
usageChecks16()

// Independent verifier's vectors for Sources/Model/UsageLimitsModel.swift. Each block names the
// T3 file and lines its inputs and expectations were taken from.

func usageChecks17() {
    // apps/web/src/timestampFormat.test.ts:21-36 and :53-74 — the relative day is the calendar's
    // day in the given zone, and a past reset reads like any past timestamp.
    let us = Locale(identifier: "en_US")
    let iso = ISO8601DateFormatter()
    let at = { (text: String) -> Double in iso.date(from: text)?.timeIntervalSince1970 ?? .nan }
    let time = { (reset: Double, now: Double, zone: String) -> String in
        UsageLimitText.resetTime(reset, now: now, locale: us, timeZone: TimeZone(identifier: zone)!)
            .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
    let evening = at("2026-07-01T23:00:00Z")   // 7 PM on July 1 in New York
    check(time(at("2026-07-02T00:30:00Z"), evening, "America/New_York") == "8:30 PM",
          "timestampFormat.test.ts:27: 00:30 UTC on July 2 is still July 1 in New York, so no 'tomorrow'")
    check(time(at("2026-07-02T05:30:00Z"), evening, "America/New_York") == "tomorrow at 1:30 AM",
          "timestampFormat.test.ts:30: 05:30 UTC on July 2 is tomorrow in New York")
    check(time(at("2026-07-01T03:30:00Z"), evening, "America/New_York") == "yesterday at 11:30 PM",
          "timestampFormat.test.ts:33: 03:30 UTC on July 1 was yesterday in New York")
    let sameDay = at("2026-11-07T04:45:43Z") + 0.877, earlierInWeek = at("2026-11-04T20:00:00Z")
    check(time(sameDay, sameDay, "America/New_York") == "11:45 PM"
          && time(earlierInWeek, sameDay, "America/New_York") == "11/4 3:00 PM",
          "timestampFormat.test.ts:57-64: New York reads the same day as a time and three days back as 11/4")
    check(time(sameDay, sameDay, "Asia/Bangkok") == "11:45 AM"
          && time(earlierInWeek, sameDay, "Asia/Bangkok") == "11/5 3:00 AM",
          "timestampFormat.test.ts:66-73: Bangkok reads the same two instants as 11:45 AM and 11/5")
}
usageChecks17()

func usageChecks18() {
    // apps/web/src/timestampFormat.ts:204-217 — the day difference is between calendar DATES. In
    // zones whose clocks jump at midnight the day starts at 01:00 and is 23 hours long.
    let us = Locale(identifier: "en_US")
    let jumps = [("Africa/Cairo", 2026, 4, 24), ("America/Santiago", 2026, 9, 6),
                 ("America/Havana", 2026, 3, 8), ("Asia/Beirut", 2026, 3, 29)]
    for (zone, year, month, day) in jumps {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let at = { (offset: Int, hour: Int) -> Double in
            calendar.date(from: DateComponents(year: year, month: month, day: day + offset, hour: hour))!
                .timeIntervalSince1970
        }
        let time = { (reset: Double, now: Double) -> String in
            UsageLimitText.resetTime(reset, now: now, locale: us, timeZone: calendar.timeZone)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        check(time(at(1, 9), at(0, 10)) == "tomorrow at 9:00 AM",
              "timestampFormat.ts:204: \(zone), the day the clocks jump at midnight: the next date is tomorrow")
        check(time(at(2, 9), at(0, 10)).hasSuffix("/\(day + 2) 9:00 AM"),
              "timestampFormat.ts:204: \(zone), same day: two dates ahead is a date, not tomorrow")
        check(time(at(0, 9), at(-1, 10)) == "tomorrow at 9:00 AM" && time(at(-1, 9), at(0, 10)) == "yesterday at 9:00 AM",
              "timestampFormat.ts:204: \(zone): the 23-hour day is tomorrow from the day before and that day is yesterday from it")
    }
}
usageChecks18()

func usageChecks19() {
    // apps/server/src/provider/codexUsageLimits.test.ts:82-150 — T3's Codex fixtures, read through
    // the real codex/limits.json shape.
    let set = { (text: String) -> LimitsSet? in
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]).flatMap { LimitsSet(codex: $0) }
    }
    // 10 000 s before the primary reset of the fixture (1 784 000 000).
    let now = 1_783_990_000.0
    let plus = UsageProviderLimits(provider: "codex", set: set("""
        {"ts": 1783990000, "source": "app-server", "plan": "plus", "windows": [
          {"kind": "primary", "used_percentage": 12, "window_minutes": 300, "resets_at": 1784000000,
           "pool": "codex", "ts": 1783990000},
          {"kind": "secondary", "used_percentage": 47, "window_minutes": 10080, "resets_at": 1784500000,
           "pool": "codex", "ts": 1783990000}]}
        """), account: nil, now: now)
    check(plus.rows.map(\.id) == ["primary", "secondary"] && plus.rows.map(\.kind) == ["session", "weekly"]
          && plus.rows.map(\.label) == ["Session", "Weekly"] && plus.rows.map(\.remainingPercent) == [88, 53],
          "codexUsageLimits.test.ts:82: primary and secondary are the Session and Weekly rows, 12% and 47% used")
    check(plus.rows.map(\.evenPacePercent) == [56, 84] && plus.rows.map(\.pace) == ["under", "ahead"],
          "usageLimits.ts:710-739 on that fixture: even pace 56% and 84%, session under pace, week ahead")
    check(plus.rows.last.flatMap { UsageLimitText.resetsIn($0.resetsAt, now: now, style: .full) } == "resets in 5d 21h",
          "usageLimitsCopy.ts:115: 510 000 s to the weekly reset reads 5d 21h")
    check(plus.plan == "ChatGPT Plus Subscription", "CodexProvider.ts:216: plus is ChatGPT Plus")

    let free = UsageProviderLimits(provider: "codex", set: set("""
        {"ts": 1783990000, "source": "app-server", "plan": "free", "windows": [
          {"kind": "primary", "used_percentage": 80, "resets_at": null, "pool": "codex", "ts": 1783990000}]}
        """), account: nil, now: now)
    let monthly = free.rows.first
    check(free.rows.count == 1 && monthly?.kind == "monthly" && monthly?.label == "Monthly"
          && monthly?.remainingPercent == 20,
          "codexUsageLimits.test.ts:112: a lone primary without a length is the Monthly row on Free")
    check(monthly?.pace == nil && monthly?.evenPacePercent == nil && monthly?.hatchPercent == 0
          && monthly.map { $0.details(now: now) == [UsageDetailRow(label: "Left", value: "20%")] } == true,
          "that fixture has no reset time: no pace, no tick, no hatch, and only the Left row")

    let lone = UsageProviderLimits(provider: "codex", set: set("""
        {"ts": 1783990000, "source": "app-server", "windows": [
          {"kind": "secondary", "used_percentage": 42, "window_minutes": 10080, "resets_at": null,
           "pool": "codex", "ts": 1783990000}]}
        """), account: nil, now: now)
    check(lone.rows.map(\.id) == ["secondary"] && lone.rows.first?.label == "Weekly"
          && lone.rows.first?.remainingPercent == 58 && lone.plan == nil,
          "codexUsageLimits.test.ts:129: a lone secondary is one Weekly row, and no plan is claimed")
}
usageChecks19()

func usageChecks20() {
    // apps/server/src/provider/codexUsageLimits.test.ts:19-45 — the Enterprise monthly credit
    // allowance, as the sidecar carries it; checkedAt 2026-07-18T10:00Z.
    let us = Locale(identifier: "en_US"), utc = TimeZone(identifier: "UTC")!
    let now = 1_784_368_800.0
    let text = """
        {"ts": 1784368800, "provider": "codex", "planType": "enterprise_cbp_usage_based",
         "extraWindows": [{"id": "individual", "kind": "monthly", "name": "Monthly credit limit",
                           "usedPercent": 1, "resetsAt": 1784500000}]}
        """
    let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    let built = UsageProviderLimits(provider: "codex", set: nil,
                                    account: UsageAccount(json: root, provider: "codex"), now: now)
    let credit = built.rows.first
    check(built.rows.count == 1 && credit?.id == "individual" && credit?.kind == "monthly"
          && credit?.label == "Monthly credit limit" && credit?.usedPercent == 1 && credit?.remainingPercent == 99,
          "codexUsageLimits.test.ts:27-35: 99% of the monthly credit left is the Monthly credit limit row, 1% used")
    check(built.plan == "ChatGPT Enterprise Subscription",
          "CodexProvider.ts:228-232: enterprise_cbp_usage_based is ChatGPT Enterprise")
    let rows = credit?.details(now: now, locale: us, timeZone: utc) ?? []
    check(rows.map(\.label) == ["Left", "Resets", "Restores"]
          && rows.map { $0.value.replacingOccurrences(of: "\u{202F}", with: " ") }
              == ["99%", "tomorrow at 10:26 PM · in 1d 12h", "+1% of pool"],
          "UsageLimitsPooled.tsx:200-214: without a length there is no Even pace row; 2026-07-19T22:26:40Z is tomorrow")
}
usageChecks20()

func usageChecks21() {
    // apps/server/src/provider/claudeUsageLimits.test.ts:9-66, :87-105, :120-166, :202-216 — T3's
    // Claude fixtures through the real limits.json shape; checkedAt 2026-07-18T10:00Z.
    let now = 1_784_368_800.0
    let limits = { (text: String) -> LimitsSet? in
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
            .flatMap { Limits(json: $0) }?.set
    }
    let three = UsageProviderLimits(provider: "claude", set: limits("""
        {"five_hour": {"used_percentage": 54, "resets_at": 1784385540},
         "seven_day": {"used_percentage": 18, "resets_at": 1784883540},
         "seven_day_opus": {"used_percentage": 3},
         "seven_day_fable": {"used_percentage": 73, "resets_at": 1784883540},
         "source": "api", "ts": 1784368800}
        """), account: nil, now: now)
    check(three.rows.map(\.id) == ["five_hour", "seven_day", "seven_day_fable"]
          && three.rows.map(\.label) == ["Session", "Weekly", "Weekly · Fable"]
          && three.rows.map(\.remainingPercent) == [46, 82, 27],
          "claudeUsageLimits.test.ts:36-62: Session 54, Weekly 18, Weekly · Fable 73; the Opus window is no row")
    check(three.rows.map(\.evenPacePercent) == [93, 85, 85] && three.rows.map(\.pace) == ["ahead", "on", "ahead"],
          "usageLimits.ts:710-739 on that fixture: 14:39 and 2026-07-24T08:59Z give ticks at 93% and 85%")

    let clamped = UsageProviderLimits(provider: "claude", set: limits("""
        {"seven_day": {"used_percentage": 250}, "source": "api", "ts": 1784368800}
        """), account: nil, now: now)
    check(clamped.rows.map(\.id) == ["seven_day"] && clamped.rows.first?.usedPercent == 100
          && clamped.rows.first?.remainingPercent == 0 && clamped.rows.first?.restoresPercent == nil
          && clamped.rows.first?.hatchPercent == 0,
          "claudeUsageLimits.test.ts:87-105: a utilization of 250 is 100% used, and without a reset nothing is hatched")

    let spend = { (json: [String: Any]) -> [UsageLimitRow] in
        UsageProviderLimits(provider: "claude", set: limits("""
            {"five_hour": {"used_percentage": 12, "resets_at": 1784385540}, "source": "api", "ts": 1784368800}
            """), account: UsageAccount(json: ["spend": json], provider: "claude"), now: now).rows
    }
    let enterprise = spend(["enabled": true, "usedPercent": 9.262, "zeroCap": false])
    check(enterprise.map(\.id) == ["five_hour", "monthly_spend"] && enterprise.last?.label == "Monthly spend"
          && enterprise.last?.kind == "monthly" && enterprise.last?.usedPercent == 9
          && enterprise.last?.remainingPercent == 91,
          "claudeUsageLimits.test.ts:131-166: 4 631 of 50 000 spent is the Monthly spend row after Session, 91% left")
    check(spend(["enabled": true, "zeroCap": true]).map(\.id) == ["five_hour"],
          "claudeUsageLimits.test.ts:202-216: a $0 cap has no percentage, so it is no Monthly row")
}
usageChecks21()

func usageChecks22() {
    // packages/shared/src/usageLimits.test.ts:1256-1276 and :1321-1343, and usageLimits.ts:583-607 —
    // the blocked account of T3's pool tests, seen alone.
    let now = 1_788_436_800.0, hour = 3600.0
    let claude = { (windows: [(String, Int, Double?)], ts: Double) -> [UsageLimitRow] in
        UsageProviderLimits(provider: "claude", set: LimitsSet(provider: "claude", windows: windows.map {
            NamedWindow(key: $0.0, title: "", badge: nil, minutes: $0.0 == "five_hour" ? 300 : 10080,
                        window: LimitWindow(used: $0.1, resets: $0.2))
        }, source: "api", ts: ts, plan: nil), account: nil, now: now).rows
    }
    let e9 = claude([("five_hour", 40, now + 2 * hour), ("seven_day", 100, now + 2 * hour),
                     ("seven_day_fable", 20, now + 2 * hour)], now - hour)
    check(e9.map(\.remainingPercent) == [0, 0, 80],
          "usageLimits.test.ts:1257-1261: the blocked account alone reads 0, 0 and 80: the model's week is untouched")
    check(e9.first?.restoresPercent == 100 && e9.first?.hatchPercent == 100,
          "usageLimits.ts:583-607: a session resetting at the very moment the week does comes back whole")

    let blocked = claude([("five_hour", 40, now + hour), ("seven_day", 100, now + 3 * hour)], now - hour).first
    check(blocked?.remainingPercent == 0 && blocked?.resetsAt == now + 3 * hour && blocked?.restoresPercent == 100
          && blocked?.hatchPercent == 100,
          "usageLimits.test.ts:1322-1325: a session resetting at 13:00 under a week spent until 15:00 is usable at 15:00")
    let refreshed = claude([("five_hour", 40, now + hour), ("seven_day", 10, now + 2 * hour)], now).first
    check(refreshed?.remainingPercent == 60 && refreshed?.resetsAt == now + hour && refreshed?.restoresPercent == 40
          && refreshed?.pace == "under" && refreshed?.evenPacePercent == 20,
          "usageLimits.test.ts:1330-1342: a fresh weekly reading of 10% lifts the block: 60% left, reset at 13:00")

    let outlives = { (used: Int, ts: Double) -> UsageLimitRow? in
        claude([("five_hour", used, now + 3 * hour), ("seven_day", 100, now + 2 * hour)], ts).first
    }
    check(outlives(99, now - hour)?.resetsAt == now + 2 * hour && outlives(99, now - hour)?.restoresPercent == 1
          && outlives(99, now - hour)?.hatchPercent == 1,
          "usageLimits.ts:596-601: one point short of spent, the session gives back its last 1% at the weekly reset")
    check(outlives(40, now + 2 * hour)?.resetsAt == nil && outlives(40, now + 2 * hour)?.restoresPercent == nil,
          "usageLimits.ts:587-595: a reading stamped exactly at the weekly reset makes it stale: the comparison is strict")
    check(outlives(40, now + 2 * hour - 1)?.resetsAt == now + 2 * hour
          && outlives(40, now + 2 * hour - 1)?.restoresPercent == 60,
          "usageLimits.ts:587-595: one second earlier both clocks are still ahead of the reading")
}
usageChecks22()

func usageChecks23() {
    // apps/server/src/provider/claudeResetCredits.test.ts:41-128 — T3's grant fixtures as the
    // sidecar carries them; NOW 2026-09-22T12:00Z.
    let iso = ISO8601DateFormatter()
    let at = { (text: String) -> Double in iso.date(from: text)?.timeIntervalSince1970 ?? .nan }
    let now = at("2026-09-22T12:00:00Z")
    let built = { (credits: [String: Any]) -> UsageProviderLimits in
        UsageProviderLimits(provider: "claude", set: nil,
                            account: UsageAccount(json: ["resetCredits": credits], provider: "claude"), now: now)
    }
    let kinds = built(["eligible": true, "availableCount": 4, "nextCreditId": "weekly_a",
                       "nextExpiresAt": at("2026-12-10T22:00:00Z"), "options": [
        ["creditId": "session_a", "kind": "session", "availableCount": 1] as [String: Any],
        ["creditId": "weekly_a", "kind": "weekly", "availableCount": 1,
         "expiresAt": at("2026-12-10T22:00:00Z")] as [String: Any],
        ["creditId": "fable_a", "kind": "fable", "availableCount": 2,
         "expiresAt": at("2027-03-09T07:59:00Z")] as [String: Any],
    ]])
    let choices = kinds.resetChoices(now: now)
    check(kinds.ticketCount == 4 && choices.map(\.creditId) == ["session_a", "weekly_a", "fable_a"],
          "claudeResetCredits.test.ts:96-107: four banked resets in three kinds, each redeemed by its own grant")
    check(choices.map(\.summary) == ["5-hour reset · 1 left", "Weekly reset · 1 left · expires in 79d 10h",
                                     "Fable reset · 2 left · expires in 167d 19h"],
          "claudeResetCredits.test.ts:102-106 with usageLimitsCopy.ts:141-143: label, count and time to the expiry")

    let full = built(["eligible": true, "availableCount": 2, "nextCreditId": "grant_a",
                      "nextExpiresAt": at("2026-10-01T00:00:00Z"), "options": [
        ["creditId": "grant_a", "kind": "full", "availableCount": 2,
         "expiresAt": at("2026-10-01T00:00:00Z")] as [String: Any]]]).resetChoices(now: now)
    check(full.map(\.summary) == ["Full reset · 2 left · expires in 8d 12h"]
          && full.first?.confirmDescription == "Full reset: Refills your 5-hour and weekly limits. This cannot be undone.",
          "claudeResetCredits.test.ts:61-72: two full resets expiring 2026-10-01 read 8d 12h")

    let spent = built(["eligible": true, "availableCount": 0])
    check(spent.ticketCount == 0 && spent.resetChoices(now: now).isEmpty && spent.credits?.availableCount == 0,
          "claudeResetCredits.test.ts:111-116: without a usable next grant nothing is offered, and zero is known")
    let ineligible = built(["eligible": false, "availableCount": 0])
    check(ineligible.credits == nil && ineligible.ticketCount == 0,
          "claudeResetCredits.test.ts:122-127: an ineligible account has no credits at all")
}
usageChecks23()

func usageChecks24() {
    // apps/server/src/provider/ClaudeProvider.ts:105-179 and CodexProvider.ts:199-218 — the plan
    // label rules, on inputs the tables do not list one by one.
    let claude = UsagePlan.claudeLabel
    check(claude("MAX") == "Claude Max Subscription" && claude("Max-20") == "Claude Ultra Subscription"
          && claude("MAX_PLAN") == "Claude Max Subscription",
          "ClaudeProvider.ts:115: the match ignores case, spaces, underscores and dashes")
    check(claude("claude_max_5x_subscription") == "Claude Max Subscription"
          && claude("Claude Pro Subscription") == "Claude Pro Subscription"
          && claude("claude team subscription") == "Claude Team Subscription",
          "ClaudeProvider.ts:119-129: the long names map to their short label and are wrapped once")
    check(claude("PRO-PLUS") == "Claude Pro Plus Subscription",
          "ClaudeProvider.ts:104-111: an unknown tier is title-cased word by word")
    check(claude("Claude Team Plan Subscription") == "Claude Team Plan Subscription"
          && claude("claude starter") == "Claude Starter Subscription"
          && claude("premium_subscription") == "Claude Premium Subscription",
          "ClaudeProvider.ts:169-178: Claude and Subscription are added only where the name lacks them")

    check(UsagePlan.codexLabel(limitsPlan: nil, accountPlan: "plus") == "ChatGPT Plus Subscription"
          && UsagePlan.codexLabel(limitsPlan: "mystery", accountPlan: "plus") == "ChatGPT Plus Subscription",
          "CodexProvider.ts:207-208: a limits plan without a label yields to the account's")
    check(UsagePlan.codexLabel(limitsPlan: "unknown", accountPlan: "unknown") == "ChatGPT Subscription"
          && UsagePlan.codexLabel(limitsPlan: "plus", accountPlan: nil) == "ChatGPT Plus Subscription"
          && UsagePlan.codexLabel(limitsPlan: nil, accountPlan: nil) == nil,
          "CodexProvider.ts:207-208, :241: unknown on both sides is the bare ChatGPT subscription; nothing known is no label")
}
usageChecks24()

func usageChecks25() {
    // packages/shared/src/usageLimitsCopy.ts:115-123, usageLimits.ts:700-716,
    // apps/web/src/components/usage/UsageLimits.tsx:89-91, UsageLimitsPooled.tsx:210-214, :418-427.
    check(UsageLimitText.duration(90061) == "1d 1h" && UsageLimitText.duration(172_799) == "1d 23h"
          && UsageLimitText.duration(7199) == "1h 59m",
          "usageLimitsCopy.ts:117-122: two units at most, each floored")
    check(UsageLimitMath.elapsedShare(resetsAt: 1060, windowMinutes: -300, now: 1000) == nil,
          "usageLimits.ts:714: a negative length has no pace clock")
    check(UsageLimitMath.remainingPercent(usedPercent: -20) == 100 && UsageLimitMath.remainingPercent(usedPercent: 140) == 0,
          "usageLimits.ts:701: the percentage is clamped to 0...100 before it is subtracted")
    check(UsageLimitMath.tickX(percent: 1, width: 200) == 3 && UsageLimitMath.tickX(percent: 2, width: 200) == 4
          && UsageLimitMath.tickX(percent: 99, width: 200) == 197,
          "UsageLimits.tsx:91: clamp(3px, percent, 100% - 3px) on a 200pt bar")

    let now = 1_788_436_800.0
    let row = { (used: Double) -> UsageLimitRow? in
        UsageProviderLimits(provider: "codex", set: nil, account: UsageAccount(json: [
            "extraWindows": [["id": "individual", "kind": "monthly", "name": "Monthly credit limit",
                              "usedPercent": used, "resetsAt": now + 86400] as [String: Any]],
        ], provider: "codex"), now: now).rows.first
    }
    let labels = { (used: Double) -> [String] in row(used)?.details(now: now).map(\.label) ?? [] }
    check(row(0.4)?.remainingPercent == 100 && row(0.4)?.restoresPercent == 0 && row(0.4)?.hatchPercent == 0
          && labels(0.4) == ["Left", "Resets"],
          "UsageLimitsPooled.tsx:210: 0.4% used restores a rounded 0%, so there is no Restores row and no hatch")
    check(row(0.5)?.remainingPercent == 100 && row(0.5)?.usedPercent == 1 && row(0.5)?.restoresPercent == 1
          && row(0.5)?.hatchPercent == 0 && labels(0.5) == ["Left", "Resets", "Restores"],
          "usageLimits.ts:701 and UsageLimitsPooled.tsx:418: 0.5% used still reads 100% left, restores 1%, draws no hatch")
    check(row(99.4)?.remainingPercent == 1 && row(99.4)?.usedPercent == 99 && row(99.4)?.hatchPercent == 99,
          "UsageLimitsPooled.tsx:423: the hatch is the smaller of the empty part (99) and the refill (99.4)")
}
usageChecks25()

// Checks for Sources/Model/UsageSummaryModel.swift — the model behind the Usage window's Cost and
// Tokens tabs. Vectors come from T3 Code (commit 803f21f): usageFormat.test.ts, usageMerge.test.ts,
// usageBreakdown.test.ts, UsageProviderChart.test.ts and the tables of spec 03. Values marked
// "oracle" were printed by T3's own formatter code under Node, not derived by hand.

// Currency, counts and percentages (spec 03 §10.1, §10.3, §10.4).
func usageChecks26() {
    let usd: [(Double, String)] = [
        (0, "$0.00"), (0.004, "$0.00"), (0.005, "$0.01"), (1234.567, "$1,234.57"),
        (-1.5, "-$1.50"), (41.2, "$41.20"),
        // oracle: Intl rounds the shortest decimal half away from zero, so these are not "$0.01",
        // "$1.00" and "$0.12" as a printf of the binary value would give.
        (0.015, "$0.02"), (1.005, "$1.01"), (0.125, "$0.13"), (1e9, "$1,000,000,000.00"),
    ]
    for (value, expected) in usd {
        let got = UsageFormat.usd(value)
        check(got == expected, "currency: \(value) prints \(expected), got \(got)")
    }
    check(UsageFormat.usd(1234.567, locale: Locale(identifier: "de_DE")).hasPrefix("1.234,57"),
          "currency: the locale is a parameter, a German one groups with dots")

    let counts: [(Double, String)] = [(0, "0"), (1, "1"), (1234, "1,234"), (7501, "7,501"),
                                      (1234.5, "1,235"), (2.5, "3"), (-1.5, "-1")]
    for (value, expected) in counts {
        let got = UsageFormat.count(value)
        check(got == expected, "count: \(value) prints \(expected), got \(got)")
    }

    let percents: [(Double, String)] = [
        (0, "0.0%"), (0.0005, "<0.1%"), (0.001, "0.1%"), (0.1234, "12.3%"), (1, "100.0%"),
        (0.624, "62.4%"), (0.45, "45.0%"), (0.9, "90.0%"),
        // oracle: 6.25 is an exact tie and JavaScript's toFixed rounds it up, printf would not.
        (0.0625, "6.3%"), (0.00125, "0.1%"),
    ]
    for (share, expected) in percents {
        let got = UsageFormat.percent(share)
        check(got == expected, "percent: \(share) prints \(expected), got \(got)")
    }
}
usageChecks26()

// Tokens (spec 03 §10.2 and usageFormat.test.ts "moves to the next unit when rounding reaches it").
func usageChecks27() {
    let vectors: [(Double, String)] = [
        (0, "0"), (999, "999"), (999.6, "1K"), (1000, "1K"), (1234, "1.23K"), (1500, "1.50K"),
        (12345, "12.3K"), (15000, "15K"), (15500, "15.5K"), (123_456, "123K"), (999_499, "999K"),
        (999_500, "1M"), (999_999, "1M"), (1_000_000, "1M"), (1_050_000, "1.05M"),
        (1_200_000, "1.20M"), (12_340_000, "12.3M"), (999_999_999, "1B"), (2.5e12, "2.50T"),
        (3e15, "3000T"), (-999_999, "-1M"), (-1500, "-1.50K"),
        // oracle: exact ties, where toFixed and printf disagree.
        (1125, "1.13K"), (12250, "12.3K"), (100_500, "101K"), (2500, "2.50K"), (999.5, "1K"),
        (1005, "1K"), (1160, "1.16K"), (1415, "1.42K"),
    ]
    for (value, expected) in vectors {
        let got = UsageFormat.tokens(value)
        check(got == expected, "tokens: \(value) prints \(expected), got \(got)")
    }
    // A corrupted figure must come out as text, whatever text, and not take the process down.
    let odd = [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300]
    let printed = odd.map { UsageFormat.tokens($0) + UsageFormat.usd($0) + UsageFormat.count($0) + UsageFormat.percent($0) }
    check(printed.count == odd.count, "formatters survive infinities, NaN and absurd magnitudes")
}
usageChecks27()

// Days and hours (spec 03 §10.5, usageFormat.test.ts "hourly usage formatting").
func usageChecks28() {
    let utc = TimeZone(identifier: "UTC")!
    let newYork = TimeZone(identifier: "America/New_York")!
    let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    check(UsageFormat.dayShort("2026-11-19") == "Nov 19", "day: 2026-11-19 reads Nov 19")
    check(UsageFormat.dayShort("2026-01-05") == "Jan 5", "day: no leading zero on the day")
    check(UsageFormat.dayShort("garbage") == "garbage", "day: an unreadable day is returned as it came")
    check(UsageFormat.dayShort("2026-13-01") == "2026-13-01", "day: a thirteenth month is returned as it came")

    let instant = "2026-08-11T12:37:00.000Z"
    check(UsageFormat.hourShort(instant, timeZone: utc, hour12: true) == "12 PM", "hour: noon UTC reads 12 PM")
    check(UsageFormat.hourShort(instant, timeZone: newYork, hour12: true) == "8 AM", "hour: the same instant in New York reads 8 AM")
    check(UsageFormat.hourShort(instant, timeZone: kathmandu, hour12: true) == "6 PM",
          "hour: a zone 5:45 ahead still names the whole hour")
    check(UsageFormat.hourShort(instant, timeZone: newYork, hour12: false) == "08:00", "hour: 24-hour form is HH:00")
    check(UsageFormat.hourShort("2026-11-18T23:10:00.000Z", timeZone: berlin, hour12: true) == "12 AM",
          "hour: midnight reads 12 AM")
    check(UsageFormat.hourShort("2026-11-18T23:10:00.000Z", timeZone: berlin, hour12: false) == "00:00",
          "hour: midnight reads 00:00 on a 24-hour clock")
    check(UsageFormat.hourShort("invalid", timeZone: utc, hour12: true) == "invalid",
          "hour: an unreadable instant is returned as it came")

    // The hour that happens twice when the clocks go back carries its zone name.
    check(UsageFormat.hourShort("2026-11-01T05:37:00.000Z", timeZone: newYork, hour12: true) == "1 AM EDT",
          "hour: the first 1 AM of a fall-back night is 1 AM EDT")
    check(UsageFormat.hourShort("2026-11-01T06:37:00.000Z", timeZone: newYork, hour12: true) == "1 AM EST",
          "hour: the second one is 1 AM EST")
    check(UsageFormat.hourShort("2026-11-01T05:37:00.000Z", timeZone: newYork, hour12: false) == "01:00 EDT",
          "hour: 24-hour form of the first is 01:00 EDT")
    check(UsageFormat.hourShort("2026-11-01T06:37:00.000Z", timeZone: newYork, hour12: false) == "01:00 EST",
          "hour: 24-hour form of the second is 01:00 EST")
    check(UsageFormat.hourShort("2026-11-01T04:37:00.000Z", timeZone: newYork, hour12: true) == "12 AM",
          "hour: the hour before the repeated one has no zone name")
    // oracle: Intl names Berlin's two 2 AMs by offset.
    check(UsageFormat.hourShort("2026-10-25T00:37:00.000Z", timeZone: berlin, hour12: true) == "2 AM GMT+2",
          "hour: a zone without a short name is told apart by offset")
    check(UsageFormat.hourShort("2026-10-25T01:37:00.000Z", timeZone: berlin, hour12: true) == "2 AM GMT+1",
          "hour: and the second by the other offset")

    check(UsageFormat.dateTimeShort("2026-11-18T12:37:00.000Z", timeZone: berlin, hour12: true) == "Nov 18, 1 PM",
          "date and hour: Nov 18, 1 PM")
    check(UsageFormat.dateTimeShort("2026-11-18T12:37:00.000Z", timeZone: berlin, hour12: false) == "Nov 18, 13:00",
          "date and hour: Nov 18, 13:00 on a 24-hour clock")
    check(UsageFormat.dateTimeShort("soon", timeZone: berlin, hour12: true) == "soon",
          "date and hour: an unreadable instant is returned as it came")

    let reference = "2026-11-19T12:37:00.000Z"
    check(UsageFormat.relativeHourShort("2026-11-19T11:37:00.000Z", relativeTo: reference, timeZone: berlin, hour12: true)
            == "12 PM today", "relative hour: the reference day reads today")
    check(UsageFormat.relativeHourShort("2026-11-18T12:37:00.000Z", relativeTo: reference, timeZone: berlin, hour12: true)
            == "1 PM yesterday", "relative hour: the day before reads yesterday")
    check(UsageFormat.relativeHourShort("2026-11-17T12:37:00.000Z", relativeTo: reference, timeZone: berlin, hour12: false)
            == "Nov 17, 13:00", "relative hour: anything older falls back to the date")
    // 23:10 UTC on the 18th is already the 19th in Berlin: the calendar day is the zone's, not UTC's.
    check(UsageFormat.relativeHourShort("2026-11-18T23:10:00.000Z", relativeTo: reference, timeZone: berlin, hour12: true)
            == "12 AM today", "relative hour: today is decided in the window's zone")
    check(UsageFormat.relativeHourShort("2026-11-18T12:37:00.000Z", relativeTo: "never", timeZone: berlin, hour12: true)
            == "Nov 18, 1 PM", "relative hour: without a readable reference it is the date form")

    check(UsageFormat.uses12HourClock(Locale(identifier: "en_US")), "clock: a US locale reads 12-hour")
    check(!UsageFormat.uses12HourClock(Locale(identifier: "en_GB")), "clock: a British locale reads 24-hour")
}
usageChecks28()

// Period lists (spec 03 §5.3, §17 item 1).
func usageChecks29() {
    let week = UsageFormat.enumerateDays(since: "2026-11-13", until: "2026-11-19")
    check(week.count == 7 && week.first == "2026-11-13" && week.last == "2026-11-19",
          "days: 7 days on 2026-11-19 list the 13th to the 19th")
    check(UsageFormat.enumerateDays(since: "2026-02-27", until: "2026-03-02")
            == ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"], "days: a month end is crossed by the calendar")
    check(UsageFormat.enumerateDays(since: "2026-10-24", until: "2026-10-26").count == 3,
          "days: a daylight-saving weekend is still one entry a day")
    check(UsageFormat.enumerateDays(since: "2026-11-19", until: "2026-11-19") == ["2026-11-19"], "days: one day is one entry")
    check(UsageFormat.enumerateDays(since: "2026-11-19", until: "2026-11-13").isEmpty, "days: reversed bounds list nothing")
    check(UsageFormat.enumerateDays(since: "today", until: "2026-11-19").isEmpty, "days: an unreadable bound lists nothing")
    check(UsageFormat.enumerateDays(since: "2026-02-30", until: "2026-03-02").isEmpty, "days: 30 February is not a day")
    check(UsageFormat.enumerateDays(since: "0001-01-01", until: "9999-12-31").isEmpty,
          "days: a corrupted bound does not allocate millions of labels")

    let hours = UsageFormat.enumerateHourStarts(since: "2026-08-10T12:37:00.000Z", until: "2026-08-11T12:37:00.000Z")
    check(hours.count == 24, "hours: Past 24h has 24 rolling-hour points, got \(hours.count)")
    check(hours.first == "2026-08-10T12:37:00.000Z", "hours: the first point is the window start, minute and all")
    check(hours.last == "2026-08-11T11:37:00.000Z", "hours: the last point starts an hour before the end")
    check(UsageFormat.enumerateHourStarts(since: "2026-08-10T12:37:00Z", until: "2026-08-10T14:00:00+00:00")
            == ["2026-08-10T12:37:00.000Z", "2026-08-10T13:37:00.000Z"], "hours: a part hour at the end still gets its point")
    check(UsageFormat.enumerateHourStarts(since: "2026-08-11T12:37:00.000Z", until: "2026-08-11T12:37:00.000Z").isEmpty,
          "hours: an empty window lists nothing")
    check(UsageFormat.enumerateHourStarts(since: "x", until: "2026-08-11T12:37:00.000Z").isEmpty,
          "hours: an unreadable bound lists nothing")
    check(UsageFormat.enumerateHourStarts(since: "1970-01-01T00:00:00.000Z", until: "2026-08-11T12:37:00.000Z").isEmpty,
          "hours: a corrupted bound does not allocate half a million labels")
}
usageChecks29()

// summary.json: the four periods, read and reduced.
func usageChecks30() {
    let near = { (a: Double, b: Double) in abs(a - b) < 1e-9 }
    let parse = { (text: String) -> [String: Any] in
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    let fixture = """
    {
      "version": 1, "readAt": 1795112308, "timeZone": "Europe/Berlin", "scanDurationMs": 1234,
      "pricing": {"status": "fresh", "source": "litellm", "fetchedAt": 1795100000, "knownModels": 812},
      "periods": {
        "1": {
          "resolution": "hour", "sinceDay": "2026-11-18", "untilDay": "2026-11-19",
          "sinceTime": "2026-11-18T12:37:00.000Z", "untilTime": "2026-11-19T12:37:00.000Z",
          "buckets": [
            {"day": "2026-11-18", "hourStart": "2026-11-18T12:37:00.000Z", "provider": "claude", "model": "claude-fable-5",
             "totals": {"uncachedInputTokens": 100, "cachedInputTokens": 1000, "cacheCreationTokens": 10, "outputTokens": 50, "reasoningTokens": 7},
             "costUsd": 3, "cacheSavingsUsd": 0.5, "costSource": "modelPriced",
             "records": 5, "unpricedRecords": 0, "unpricedTokens": 0, "sessions": 1},
            {"day": "2026-11-19", "hourStart": "2026-11-19T11:37:00.000Z", "provider": "codex", "model": "gpt-5.6-sol",
             "totals": {"uncachedInputTokens": 200, "cachedInputTokens": 0, "cacheCreationTokens": 0, "outputTokens": 40, "reasoningTokens": 0},
             "costUsd": 1, "cacheSavingsUsd": 0, "costSource": "providerReported",
             "records": 2, "unpricedRecords": 0, "unpricedTokens": 0, "sessions": 1},
            {"day": "2026-11-19", "hourStart": "2026-11-19T11:37:00Z", "provider": "claude", "model": "claude-fable-5",
             "totals": {"uncachedInputTokens": 10, "cachedInputTokens": 0, "cacheCreationTokens": 0, "outputTokens": 5, "reasoningTokens": 0},
             "costUsd": 0.25, "cacheSavingsUsd": 0, "costSource": "modelPriced",
             "records": 1, "unpricedRecords": 0, "unpricedTokens": 0, "sessions": 1}
          ],
          "sources": [
            {"provider": "claude", "status": "ok", "scannedFiles": 12, "skippedFiles": 3, "malformedRecords": 0, "distinctSessions": 2, "message": null},
            {"provider": "codex", "status": "ok", "scannedFiles": 4, "skippedFiles": 0, "malformedRecords": 0, "distinctSessions": 1, "message": null}
          ]
        },
        "7": {
          "resolution": "day", "sinceDay": "2026-11-13", "untilDay": "2026-11-19",
          "buckets": [
            {"day": "2026-11-18", "provider": "claude", "model": "claude-fable-5",
             "totals": {"uncachedInputTokens": 100, "cachedInputTokens": 1000, "cacheCreationTokens": 10, "outputTokens": 50, "reasoningTokens": 0},
             "costUsd": 10, "cacheSavingsUsd": 2, "categoryCostUsd": {"input": 1, "cacheRead": 2, "cacheWrite": 3, "output": 4},
             "fastCostUsd": 6, "speedPremiumUsd": 3, "costSource": "modelPriced", "records": 5, "unpricedRecords": 0, "sessions": 1},
            {"day": "2026-11-18", "provider": "codex", "model": "unknown-model",
             "totals": {"uncachedInputTokens": 100, "cachedInputTokens": 1000, "cacheCreationTokens": 10, "outputTokens": 50, "reasoningTokens": 0},
             "costUsd": 0, "cacheSavingsUsd": 2, "costSource": "unpriced", "records": 5, "unpricedRecords": 5, "sessions": 1},
            {"day": "2026-11-18", "provider": "codex", "model": "partly-reported",
             "totals": {"uncachedInputTokens": 100, "cachedInputTokens": 1000, "cacheCreationTokens": 10, "outputTokens": 50, "reasoningTokens": 0},
             "costUsd": 0, "cacheSavingsUsd": 2, "costSource": "modelPriced", "records": 5, "unpricedRecords": 4, "sessions": 1},
            {"day": "2026-11-19", "provider": "claude", "model": "claude-fable-5",
             "totals": {"uncachedInputTokens": 100, "cachedInputTokens": 1000, "cacheCreationTokens": 10, "outputTokens": 50, "reasoningTokens": 0},
             "costUsd": 5, "cacheSavingsUsd": 2, "costSource": "modelPriced", "records": 5, "unpricedRecords": 0, "sessions": 1}
          ],
          "sources": [
            {"provider": "claude", "status": "ok", "scannedFiles": 40, "skippedFiles": 0, "malformedRecords": 0, "distinctSessions": 2, "message": null},
            {"provider": "codex", "status": "ok", "scannedFiles": 9, "skippedFiles": 0, "malformedRecords": 0, "distinctSessions": 1, "message": null}
          ]
        },
        "30": {
          "resolution": "day", "sinceDay": "2026-10-21", "untilDay": "2026-11-19",
          "buckets": [
            {"day": "2026-11-02", "provider": "codex", "model": "mystery",
             "totals": {"uncachedInputTokens": 300, "cachedInputTokens": 200, "cacheCreationTokens": 0, "outputTokens": 100, "reasoningTokens": 0},
             "costUsd": 0, "cacheSavingsUsd": 0, "costSource": "unpriced",
             "records": 3, "unpricedRecords": 3, "unpricedTokens": 600, "sessions": 1}
          ],
          "sources": [
            {"provider": "claude", "status": "missing", "scannedFiles": 0, "skippedFiles": 0, "malformedRecords": 0, "distinctSessions": 0, "message": "no_history"},
            {"provider": "codex", "status": "partial", "scannedFiles": 5, "skippedFiles": 4, "malformedRecords": 2, "distinctSessions": 1, "message": "zstd_unavailable"}
          ]
        },
        "90": {"resolution": "day", "sinceDay": "2026-08-22", "untilDay": "2026-11-19", "buckets": [], "sources": []}
      }
    }
    """
    let summary = UsageSummary(json: parse(fixture))

    check(summary.version == 1, "summary: version is read")
    check(summary.readAt == 1_795_112_308, "summary: readAt is read")
    check(summary.timeZone == "Europe/Berlin" && summary.zone.identifier == "Europe/Berlin", "summary: the time zone is read")
    check(summary.scanDurationMs == 1234, "summary: the scan duration is read")
    check(summary.pricing.status == "fresh" && summary.pricing.source == "litellm"
            && summary.pricing.fetchedAt == 1_795_100_000 && summary.pricing.knownModels == 812, "summary: pricing is read")
    check(UsageSummary.periodDays == [1, 7, 30, 90], "summary: the four periods are 1, 7, 30 and 90 days")

    // Past 24h.
    let day = summary.period(1)
    check(day.isHourly && day.sinceTime == "2026-11-18T12:37:00.000Z" && day.untilTime == "2026-11-19T12:37:00.000Z",
          "24h: resolution and exact bounds are read")
    check(day.buckets.count == 3 && day.sources.count == 2, "24h: three buckets and two sources are read")
    check(day.buckets[2].hourStart == "2026-11-19T11:37:00.000Z",
          "24h: an hour written without milliseconds is the same hour as the one written with them")
    check(day.sources[0].scannedFiles == 12 && day.sources[0].skippedFiles == 3 && day.sources[0].message == nil,
          "24h: a source's file counts are read and a null message is no message")
    let dayTotals = UsageTotals(period: day)
    check(near(dayTotals.costUsd, 4.25), "24h: cost is the sum of the buckets")
    check(dayTotals.tokens.uncachedInputTokens == 310 && dayTotals.tokens.cachedInputTokens == 1000
            && dayTotals.tokens.cacheCreationTokens == 10 && dayTotals.tokens.outputTokens == 95
            && dayTotals.tokens.reasoningTokens == 7, "24h: each token kind is summed")
    check(dayTotals.totalTokens == 1415, "24h: processed tokens leave reasoning out, it is already inside output")
    check(dayTotals.records == 8 && dayTotals.sessions == 3, "24h: records come from buckets, sessions from the sources")
    check(near(dayTotals.costQuality.providerReportedShare, 0.25) && near(dayTotals.costQuality.modelPricedShare, 0.75)
            && dayTotals.costQuality.unpricedShare == 0, "24h: a provider-reported bucket counts all its records as reported")
    check(near(dayTotals.costQuality.cacheSavingsUsd, 0.5), "24h: cache savings are summed")
    check(dayTotals.hourly.count == 2, "24h: two rolling hours have data, got \(dayTotals.hourly.count)")
    check(dayTotals.hourly.first?.hourStart == "2026-11-18T12:37:00.000Z" && dayTotals.hourly.first?.costUsd == 3,
          "24h: hours are ordered oldest first")
    let lastHour = dayTotals.hourly.last
    check(lastHour.map { near($0.costUsd, 1.25) } == true && lastHour?.totalTokens == 255,
          "24h: two providers in one hour add up")
    check(lastHour?.byProvider["codex"]?.costUsd == 1 && lastHour?.byProvider["claude"]?.costUsd == 0.25,
          "24h: an hour keeps each provider's part")
    check(dayTotals.daily.map { $0.day } == ["2026-11-18", "2026-11-19"], "24h: the same buckets also add up by day")
    check(dayTotals.timeline(hourly: true).count == 2 && dayTotals.timeline(hourly: false).count == 2,
          "24h: the timeline is the hourly or the daily list")
    check(dayTotals.providers.map { $0.provider } == ["claude", "codex"], "24h: providers are ordered by cost")
    check(dayTotals.providers.first.map { near($0.costShare, 3.25 / 4.25) } == true, "24h: cost share is the provider's part of the total")
    check(day.periodKeys.count == 24 && day.periodKeys.first == day.sinceTime, "24h: the chart has all 24 hours, with or without data")

    let dayChart = UsageChartData(period: day, totals: dayTotals, metric: .cost, providers: dayTotals.activeProviders)
    check(dayChart.periods.count == 24 && dayChart.series.count == 2, "24h chart: 24 columns, one series a provider")
    check(dayChart.series[0].provider == "claude" && dayChart.series[0].values.count == 24
            && dayChart.series[0].values[0] == 3 && dayChart.series[0].values[23] == 0.25
            && dayChart.series[0].values[1] == 0, "24h chart: a point is matched to its bucket by hourStart, the rest are zero")
    check(dayChart.series[1].provider == "codex" && dayChart.series[1].values[23] == 1 && dayChart.series[1].values[0] == 0,
          "24h chart: values are each provider's own, not stacked on the one below")
    check(near(dayChart.series[0].total, 3.25) && dayChart.drawOrder.map { $0.provider } == ["claude", "codex"],
          "24h chart: the largest series is drawn first, so smaller ones end up on top")
    check(dayChart.scale.max == 3 && dayChart.scale.ticks == [0, 1, 2, 3] && dayChart.scale.labeled,
          "24h chart: the scale comes from the largest single provider value, not the column sum")
    check(near(dayChart.total(at: 23), 1.25) && dayChart.total(at: 1) == 0 && dayChart.total(at: 99) == 0,
          "24h chart: the tooltip total is the column sum, zero outside the columns")
    let claudePoints = dayChart.points(dayChart.series[0], width: 230, height: 260)
    check(claudePoints.count == 24 && claudePoints[0].x == 0 && near(claudePoints[23].x, 230),
          "24h chart: the first point is on the left edge, the last on the right")
    check(near(claudePoints[0].y, 8) && claudePoints[1].y == 260, "24h chart: the peak leaves the top inset, zero lies on the bottom")
    let tokenChart = UsageChartData(period: day, totals: dayTotals, metric: .tokens, providers: dayTotals.activeProviders)
    check(tokenChart.scale.max == 1500 && tokenChart.scale.ticks == [0, 500, 1000, 1500],
          "24h chart: tokens get their own scale")
    check(tokenChart.scale.ticks.map { UsageChart.tickLabel($0, metric: .tokens) } == ["0", "500", "1K", "1.50K"],
          "24h chart: token ticks are labelled like every other token figure")
    check(dayChart.scale.ticks.map { UsageChart.tickLabel($0, metric: .cost) } == ["0", "$1.00", "$2.00", "$3.00"],
          "24h chart: the zero tick is a bare 0, the others are dollars")
    check(UsageChart.axisLabels(day.periodKeys, hourly: true, timeZone: summary.zone, hour12: true) == ["1 PM", "1 AM", "12 PM"],
          "24h chart: the axis names the first, the middle and the last hour")
    check(UsageChart.axisLabels(day.periodKeys, hourly: true, timeZone: summary.zone, hour12: false) == ["13:00", "01:00", "12:00"],
          "24h chart: and in 24-hour form")
    check(UsageFormat.windowLabel(day, timeZone: summary.zone, hour12: true) == "Nov 18, 1 PM to Nov 19, 1 PM",
          "24h: the window label names both ends with their hour")
    check(UsageFormat.windowLabel(day, timeZone: summary.zone, hour12: false) == "Nov 18, 13:00 to Nov 19, 13:00",
          "24h: the window label follows the 24-hour clock")
    check(UsageFormat.tooltipPeriodLabel(day.periodKeys[0], in: day, timeZone: summary.zone, hour12: true) == "1 PM yesterday"
            && UsageFormat.tooltipPeriodLabel(day.periodKeys[23], in: day, timeZone: summary.zone, hour12: true) == "12 PM today",
          "24h chart: the tooltip tells an hour apart by its day, counted back from the end of the window")
    check(UsageFormat.periodLabel(day.periodKeys[0], hourly: true, timeZone: summary.zone, hour12: true) == "1 PM",
          "24h: a table row names the hour alone")

    // 7 days: T3's "splits cost by category and speed" vector, on one machine.
    let week = summary.period(7)
    check(!week.isHourly && week.sinceTime == nil, "7 days: a daily period has no exact bounds")
    check(week.buckets[0].categoryCost?.cacheWrite == 3 && week.buckets[1].categoryCost == nil,
          "7 days: a bucket without a category split has none, rather than a split of zeros")
    check(week.buckets[1].unpricedTokens == nil, "7 days: an absent unpricedTokens is absent, not zero")
    let weekTotals = UsageTotals(period: week)
    check(weekTotals.costUsd == 15 && weekTotals.totalTokens == 4640 && weekTotals.records == 20 && weekTotals.sessions == 3,
          "7 days: totals add up")
    check(weekTotals.categoryCost.input == 1 && weekTotals.categoryCost.cacheRead == 2 && weekTotals.categoryCost.cacheWrite == 3
            && weekTotals.categoryCost.output == 4 && weekTotals.categoryCost.unsplit == 5,
          "7 days: cost without a category split is counted as unsplit")
    check(weekTotals.speedCost.standard == 9 && weekTotals.speedCost.fast == 6 && weekTotals.speedCost.ultrafast == 0
            && weekTotals.speedCost.premium == 3, "7 days: standard cost is what fast and ultrafast leave")
    check(weekTotals.models.map { $0.model } == ["claude-fable-5", "unknown-model", "partly-reported"],
          "7 days: models are ordered by cost, then tokens, then first seen")
    check(weekTotals.models.map { $0.unpricedTokens } == [0, 1160, 928],
          "7 days: without a count, unpriced tokens are estimated from the unpriced share of records")
    check(weekTotals.models.filter { $0.isCostUnknown }.map { $0.model } == ["unknown-model"],
          "7 days: only a model with every record unpriced has an unknown cost")
    check(weekTotals.models[0].costUsd == 15 && weekTotals.models[0].totalTokens == 2320 && weekTotals.models[0].records == 10
            && weekTotals.models[0].provider == "claude" && weekTotals.models[0].id == "claude:claude-fable-5",
          "7 days: one model's buckets on two days are one row")
    check(weekTotals.models[0].costShare == 1 && weekTotals.models[1].tokenShare == 0.25,
          "7 days: model shares are against the page totals")
    check(near(weekTotals.costQuality.unpricedShare, 0.45) && near(weekTotals.costQuality.modelPricedShare, 0.55)
            && weekTotals.costQuality.providerReportedShare == 0 && weekTotals.costQuality.cacheSavingsUsd == 8,
          "7 days: unpriced share is unpriced records over all records")
    check(weekTotals.providers.map { $0.provider } == ["claude", "codex"]
            && weekTotals.providers.map { $0.sessions } == [2, 1] && weekTotals.providers.map { $0.records } == [10, 10]
            && weekTotals.providers.map { $0.costShare } == [1, 0] && weekTotals.providers.map { $0.tokenShare } == [0.5, 0.5],
          "7 days: each provider has its cost, tokens, records, sessions and shares")
    check(weekTotals.daily.map { $0.day } == ["2026-11-18", "2026-11-19"] && weekTotals.daily.map { $0.costUsd } == [10, 5]
            && weekTotals.daily.map { $0.totalTokens } == [3480, 1160] && weekTotals.hourly.isEmpty,
          "7 days: only days with data are listed, oldest first, and nothing is hourly")
    check(week.periodKeys.count == 7 && week.periodKeys.first == "2026-11-13", "7 days: the chart has every day of the window")
    check(weekTotals.models(by: .cost).map { $0.model } == ["claude-fable-5", "unknown-model", "partly-reported"]
            && weekTotals.models(by: .tokens).map { $0.model } == ["claude-fable-5", "unknown-model", "partly-reported"],
          "7 days: the Tokens tab orders models by tokens, then cost")
    check(weekTotals.models[1].share(.cost) == nil && weekTotals.models[1].share(.tokens) == 0.25
            && weekTotals.models[2].share(.cost) == 0, "7 days: an unknown cost has no cost share but still a token share")
    check(weekTotals.models[1].trendMetric(.cost) == .tokens && weekTotals.models[0].trendMetric(.cost) == .cost
            && weekTotals.models[0].trendMetric(.tokens) == .tokens,
          "7 days: an unpriced model's trend shows tokens, its cost is unknown rather than zero")
    check(weekTotals.activeProviders == ["claude", "codex"], "7 days: providers are listed Claude first, then Codex")
    check(weekTotals.rankedProviders(by: .cost).map { $0.provider } == ["claude", "codex"]
            && weekTotals.rankedProviders(by: .tokens).map { $0.provider } == ["claude", "codex"],
          "7 days: a tie in the metric keeps the provider order")
    check(UsageChart.axisLabels(week.periodKeys, hourly: false, timeZone: summary.zone, hour12: true) == ["NOV 13", "NOV 16", "NOV 19"],
          "7 days chart: the axis names the first, the middle and the last day in capitals")
    check(UsageFormat.windowLabel(week, timeZone: summary.zone, hour12: true) == "Nov 13 to Nov 19", "7 days: the window label names both days")
    check(UsageFormat.tooltipPeriodLabel("2026-11-18", in: week, timeZone: summary.zone, hour12: true) == "Nov 18",
          "7 days chart: the tooltip of a day is the day")
    let weekChart = UsageChartData(period: week, totals: weekTotals, metric: .cost, providers: weekTotals.activeProviders)
    check(weekChart.series[0].values == [0, 0, 0, 0, 0, 10, 5] && weekChart.series[1].values == [0, 0, 0, 0, 0, 0, 0],
          "7 days chart: days without data are zero, and so is a provider that cost nothing")
    check(weekChart.scale.max == 10 && weekChart.scale.ticks == [0, 5, 10], "7 days chart: a peak of 10 gets ticks at 0, 5 and 10")

    // Provider filter: hidden providers' buckets and sources leave before anything is added up.
    let codexOnly = UsageTotals(period: week, provider: "codex")
    check(codexOnly.costUsd == 0 && codexOnly.totalTokens == 2320 && codexOnly.sessions == 1 && codexOnly.records == 10,
          "filter: Codex alone has only Codex's tokens, records and sessions")
    check(codexOnly.models.map { $0.model } == ["unknown-model", "partly-reported"] && codexOnly.models[0].tokenShare == 0.5,
          "filter: shares are against the filtered totals")
    check(codexOnly.providers.map { $0.provider } == ["codex"] && codexOnly.activeProviders == ["codex"],
          "filter: the other provider is gone from the provider list")
    check(near(codexOnly.costQuality.unpricedShare, 0.9), "filter: cost quality follows the filter")
    let claudeOnly = UsageTotals(period: week, provider: "claude")
    check(claudeOnly.costUsd == 15 && claudeOnly.sessions == 2 && claudeOnly.categoryCost.unsplit == 5,
          "filter: Claude alone keeps Claude's cost and split")

    // The model dialog: the same reduction, kept to one model's buckets.
    let dialog = UsageTotals(period: week, model: weekTotals.models[0])
    check(dialog.costUsd == 15 && dialog.daily.map { $0.costUsd } == [10, 5] && dialog.models.count == 1,
          "dialog: the trend is the model's own buckets by day")
    check(dialog.categoryCost.unsplit == 5 && dialog.speedCost.fast == 6 && dialog.speedCost.premium == 3,
          "dialog: cost by type and by speed are the model's own")
    let unknownDialog = UsageTotals(period: week, model: weekTotals.models[1])
    check(unknownDialog.costUsd == 0 && unknownDialog.totalTokens == 1160 && unknownDialog.daily.count == 1,
          "dialog: an unpriced model still has its token trend")
    let dialogChart = UsageChartData(period: week, totals: dialog, metric: weekTotals.models[0].trendMetric(.cost),
                                     providers: [weekTotals.models[0].provider])
    check(dialogChart.series.count == 1 && dialogChart.series[0].values == [0, 0, 0, 0, 0, 10, 5],
          "dialog chart: one series, the model's provider")

    // 30 days: nothing priced, one provider without history, one read in part.
    let month = summary.period(30)
    let monthTotals = UsageTotals(period: month)
    check(monthTotals.costUsd == 0 && monthTotals.totalTokens == 600 && monthTotals.sessions == 1,
          "30 days: a source that is missing adds no sessions")
    check(monthTotals.costQuality.unpricedShare == 1 && monthTotals.costQuality.modelPricedShare == 0,
          "30 days: every record is unpriced")
    check(monthTotals.models.count == 1 && monthTotals.models[0].isCostUnknown && monthTotals.models[0].unpricedTokens == 600,
          "30 days: the only model has an unknown cost and the writer's own unpriced token count")
    check(monthTotals.models[0].costPerMillionTokens == nil && monthTotals.models[0].share(.cost) == nil
            && monthTotals.models[0].share(.tokens) == 1, "30 days: no price per million and no cost share without a price")
    check(monthTotals.models[0].cacheHitRate.map { near($0, 0.4) } == true, "30 days: cache hit rate needs no price")
    check(monthTotals.providers.map { $0.provider } == ["codex"] && monthTotals.activeProviders == ["codex"],
          "30 days: a provider without history is not listed")
    check(monthTotals.categoryCost.unsplit == 0 && monthTotals.speedCost.standard == 0,
          "30 days: no cost means nothing to split")
    check(month.warnings() == [
        "Compressed Codex session files were skipped because zstd is not installed; usage may be incomplete.",
        "2 malformed or inconsistent usage record(s) were skipped; usage may be incomplete.",
    ], "30 days: the warnings say what was skipped and why, got \(month.warnings())")
    check(month.warnings(provider: "claude").isEmpty, "30 days: a provider that simply has no history is not a warning")
    check(month.warnings(provider: "codex").count == 2, "30 days: warnings follow the provider filter")
    check(month.periodKeys.count == 30 && UsageFormat.windowLabel(month, timeZone: summary.zone, hour12: true) == "Oct 21 to Nov 19",
          "30 days: the window is today and the 29 days before")
    let monthChart = UsageChartData(period: month, totals: monthTotals, metric: monthTotals.models[0].trendMetric(.cost),
                                    providers: monthTotals.activeProviders)
    check(monthChart.series[0].values[12] == 600 && monthChart.scale.max == 600,
          "30 days chart: an unpriced window still draws its tokens")
    let monthCostChart = UsageChartData(period: month, totals: monthTotals, metric: .cost, providers: monthTotals.activeProviders)
    check(monthCostChart.scale.max == 0 && monthCostChart.scale.ticks == [0] && monthCostChart.scale.labeled,
          "30 days chart: no cost draws one grid line labelled 0")
    let flat = monthCostChart.points(monthCostChart.series[0], width: 300, height: 224)
    check(flat.count == 30 && flat.allSatisfy { $0.y == 224 }, "30 days chart: a series of zeros lies flat on the bottom")

    // 90 days: nothing at all.
    let quarter = summary.period(90)
    let quarterTotals = UsageTotals(period: quarter)
    check(quarter.buckets.isEmpty && quarter.sources.isEmpty && quarter.sinceDay == "2026-08-22", "90 days: an empty period is read as empty")
    check(quarterTotals.costUsd == 0 && quarterTotals.totalTokens == 0 && quarterTotals.records == 0 && quarterTotals.sessions == 0,
          "90 days: empty totals are zeros")
    check(quarterTotals.costQuality.unpricedShare == 0 && quarterTotals.costQuality.modelPricedShare == 0
            && quarterTotals.costQuality.providerReportedShare == 0, "90 days: shares of nothing are 0, not a division by zero")
    check(quarterTotals.providers.isEmpty && quarterTotals.models.isEmpty && quarterTotals.daily.isEmpty
            && quarterTotals.activeProviders.isEmpty, "90 days: no providers, models or days")
    check(quarter.periodKeys.count == 90 && quarter.warnings().isEmpty, "90 days: the chart still has its 90 days and nothing warns")
    let quarterChart = UsageChartData(period: quarter, totals: quarterTotals, metric: .cost, providers: [])
    check(quarterChart.series.isEmpty && quarterChart.scale.ticks == [0] && quarterChart.total(at: 0) == 0,
          "90 days chart: no series and a single zero line")
    let waiting = UsageChartData(period: quarter, totals: quarterTotals, metric: .cost, providers: ["claude"], loading: true)
    check(waiting.scale.max == 4 && waiting.scale.ticks == [0, 1, 2, 3, 4] && !waiting.scale.labeled,
          "90 days chart: while loading with nothing to show there are five unlabelled grid lines")
    check(summary.period(14).buckets.isEmpty && summary.period(14).periodKeys.isEmpty, "summary: a period nobody wrote is empty")
}
usageChecks30()

// T3 usageMerge.test.ts, the vectors that survive on one machine.
func usageChecks31() {
    let bucket = { (overrides: [String: Any]) -> [String: Any] in
        var base: [String: Any] = [
            "day": "2026-08-07", "provider": "claude", "model": "claude-fable-5",
            "totals": ["uncachedInputTokens": 100, "cachedInputTokens": 1000, "cacheCreationTokens": 10,
                       "outputTokens": 50, "reasoningTokens": 0],
            "costUsd": 10, "cacheSavingsUsd": 2, "costSource": "modelPriced",
            "records": 5, "unpricedRecords": 0, "sessions": 1,
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }
    let source = { (provider: String, sessions: Int) -> [String: Any] in
        ["provider": provider, "status": "ok", "scannedFiles": 1, "skippedFiles": 0, "malformedRecords": 0,
         "distinctSessions": sessions, "message": NSNull()]
    }
    let period = { (buckets: [[String: Any]], sources: [[String: Any]]) -> UsagePeriod in
        UsagePeriod(json: ["resolution": "day", "sinceDay": "2026-08-01", "untilDay": "2026-08-31",
                           "buckets": buckets, "sources": sources])
    }

    // "drops only the duplicated provider, keeping the environment's other one"
    let two = UsageTotals(period: period(
        [bucket([:]), bucket(["provider": "codex", "model": "gpt-5.6-sol", "costUsd": 4])],
        [source("claude", 1), source("codex", 1)]))
    check(two.costUsd == 14 && two.sessions == 2 && two.providers.map { $0.provider }.sorted() == ["claude", "codex"]
            && two.providers.allSatisfy { $0.sessions == 1 }, "merge: two providers add up and keep their own session counts")

    // "totals sessions from per-directory distinct counts, not per-bucket sums"
    let spanning = UsageTotals(period: period(
        [bucket(["day": "2026-08-06"]), bucket(["day": "2026-08-07"])], [source("claude", 1)]))
    check(spanning.sessions == 1 && spanning.providers.first?.sessions == 1,
          "merge: one session spanning two days is one session")
    check(spanning.daily.map { $0.day } == ["2026-08-06", "2026-08-07"], "merge: days come out oldest first")

    // "normalizes model names during decoding before grouping usage"
    let spaced = UsageTotals(period: period(
        [bucket(["provider": "codex", "model": " gpt-5 "]), bucket(["provider": "codex", "model": "gpt-5"])],
        [source("codex", 1)]))
    check(spaced.models.count == 1 && spaced.models.first?.model == "gpt-5" && spaced.models.first?.costUsd == 20
            && spaced.models.first?.totalTokens == 2320, "merge: a model name with stray spaces is the same model")

    // "keeps known usage when newer providers and bucket variants cannot be decoded"
    let future = UsageTotals(period: period(
        [bucket([:]), bucket(["provider": "future-provider", "costUsd": 100])],
        [source("claude", 1), source("future-provider", 1)]))
    check(future.costUsd == 10 && future.totalTokens == 1160 && future.sessions == 1,
          "merge: a provider this app does not know is left out, bucket and source")

    // "marks a model with no known rates as unpriced rather than free"
    let unpriced = UsageTotals(period: period(
        [bucket(["costUsd": 75]),
         bucket(["provider": "codex", "model": "unknown-model", "costUsd": 0, "costSource": "unpriced", "unpricedRecords": 5])],
        [source("claude", 1), source("codex", 1)]))
    check(unpriced.models.first { $0.model == "unknown-model" }?.unpricedRecords == 5
            && unpriced.models.filter { $0.isCostUnknown }.map { $0.model } == ["unknown-model"],
          "merge: a model with no known rates is unpriced, not free")

    // Sources decide what counts: a provider whose source is missing contributes nothing.
    var missing = source("codex", 7)
    missing["status"] = "missing"
    let gone = UsageTotals(period: period(
        [bucket([:]), bucket(["provider": "codex", "model": "gpt-5.6-sol", "costUsd": 4])], [source("claude", 1), missing]))
    check(gone.costUsd == 10 && gone.sessions == 1 && gone.providers.map { $0.provider } == ["claude"],
          "merge: a missing source's sessions and buckets are skipped")

    // Provider ranking (usageProviders.test.ts).
    let ranked = UsageTotals(period: period(
        [bucket(["provider": "codex", "model": "gpt-5.6-sol", "costUsd": 20,
                 "totals": ["uncachedInputTokens": 100, "cachedInputTokens": 0, "cacheCreationTokens": 0, "outputTokens": 0, "reasoningTokens": 0]]),
         bucket(["costUsd": 10,
                 "totals": ["uncachedInputTokens": 200, "cachedInputTokens": 0, "cacheCreationTokens": 0, "outputTokens": 0, "reasoningTokens": 0]])],
        [source("claude", 1), source("codex", 1)]))
    check(ranked.rankedProviders(by: .tokens).map { $0.provider } == ["claude", "codex"],
          "ranking: by tokens the provider with more tokens is first")
    check(ranked.rankedProviders(by: .cost).map { $0.provider } == ["codex", "claude"],
          "ranking: by cost the provider that cost more is first")
    check(ranked.models(by: .tokens).map { $0.provider } == ["claude", "codex"]
            && ranked.models(by: .cost).map { $0.provider } == ["codex", "claude"],
          "ranking: models follow the tab's metric the same way")
    check(ranked.providers.map { $0.provider } == ["codex", "claude"], "ranking: the provider totals themselves are by cost")
}
usageChecks31()

// Model dialog numbers (usageBreakdown.test.ts, UsageModelDialog.browser.test.tsx) and share bars.
func usageChecks32() {
    let mixedTokens = UsageTokenTotals(uncachedInputTokens: 1_000_000, cachedInputTokens: 1_000_000,
                                       cacheCreationTokens: 2_000_000, outputTokens: 0, reasoningTokens: 0)
    let mixed = UsageModelTotals(model: "mixed", provider: "codex", costUsd: 6, totalTokens: 4_000_000, tokens: mixedTokens,
                                 records: 4, unpricedRecords: 1, unpricedTokens: 1_000_000, costShare: 0, tokenShare: 0)
    check(mixed.cacheHitRate == 0.25, "dialog: cache writes count as misses")
    check(mixed.costPerMillionTokens == 2, "dialog: unpriced tokens stay out of the price per million")
    let allUnpriced = UsageModelTotals(model: "mixed", provider: "codex", costUsd: 6, totalTokens: 4_000_000, tokens: mixedTokens,
                                       records: 4, unpricedRecords: 4, unpricedTokens: 1_000_000, costShare: 0, tokenShare: 0)
    check(allUnpriced.costPerMillionTokens == nil && allUnpriced.isCostUnknown, "dialog: no price per million when every record is unpriced")

    let cached = UsageModelTotals(
        model: "m", provider: "claude", costUsd: 2, totalTokens: 1_000_000,
        tokens: UsageTokenTotals(uncachedInputTokens: 100_000, cachedInputTokens: 900_000, cacheCreationTokens: 0,
                                 outputTokens: 0, reasoningTokens: 0),
        records: 1, unpricedRecords: 0, unpricedTokens: 0, costShare: 1, tokenShare: 1)
    check(UsageFormat.usd(cached.costUsd) == "$2.00" && UsageFormat.tokens(cached.totalTokens) == "1M"
            && cached.costPerMillionTokens.map { UsageFormat.usd($0) } == "$2.00"
            && cached.cacheHitRate.map { UsageFormat.percent($0) } == "90.0%",
          "dialog: Cost $2.00, Tokens 1M, Per 1M tokens $2.00, Cache hit 90.0%")
    let outputOnly = UsageModelTotals(
        model: "m", provider: "claude", costUsd: 1, totalTokens: 10,
        tokens: UsageTokenTotals(uncachedInputTokens: 0, cachedInputTokens: 0, cacheCreationTokens: 0, outputTokens: 10, reasoningTokens: 0),
        records: 1, unpricedRecords: 0, unpricedTokens: 0, costShare: 1, tokenShare: 1)
    check(outputOnly.cacheHitRate == nil, "dialog: no cache hit rate without any input")
    let nothingPriced = UsageModelTotals(model: "m", provider: "claude", costUsd: 1, totalTokens: 10, tokens: UsageTokenTotals(),
                                         records: 2, unpricedRecords: 1, unpricedTokens: 10, costShare: 0, tokenShare: 0)
    check(nothingPriced.costPerMillionTokens == nil, "dialog: no price per million when no token was priced")
    check(!UsageModelTotals(model: "m", provider: "claude", costUsd: 0, totalTokens: 0, tokens: UsageTokenTotals(), records: 0,
                            unpricedRecords: 0, unpricedTokens: 0, costShare: 0, tokenShare: 0).isCostUnknown,
          "dialog: a model without records is not unpriced")

    let cost = UsageCategoryCost(input: 1, cacheRead: 2, cacheWrite: 3, output: 4, unsplit: 0.004)
    check(cost.segments.map { $0.label } == ["Input", "Cache read", "Cache write", "Output", "Other"]
            && cost.segments.map { $0.value } == [1, 2, 3, 4, 0], "share bar: unsplit cost under half a cent is rounding, not a segment")
    check(UsageCategoryCost(input: 1, cacheRead: 2, cacheWrite: 3, output: 4, unsplit: 0.005).segments.last?.value == 0.005,
          "share bar: from half a cent up it is shown as Other")
    check(mixedTokens.segments.map { $0.label } == ["Input", "Cache read", "Cache write", "Output"]
            && mixedTokens.segments.map { $0.value } == [1_000_000, 1_000_000, 2_000_000, 0],
          "share bar: tokens by type leave reasoning out")
    let speed = UsageSpeedCost(standard: 9, fast: 6, ultrafast: 0, premium: 3)
    check(speed.segments.map { $0.label } == ["Standard", "Fast", "Ultrafast"] && speed.segments.map { $0.value } == [9, 6, 0]
            && speed.hasFastTiers, "share bar: cost by speed is shown once anything ran fast")
    check(!UsageSpeedCost(standard: 9, fast: 0, ultrafast: 0, premium: 0).hasFastTiers,
          "share bar: cost by speed is hidden when nothing ran fast")
    let visible = UsageShareSegment.visible(speed.segments)
    check(visible.map { $0.label } == ["Standard", "Fast"], "share bar: a segment of zero is dropped")
    check(UsageShareSegment.visible(UsageTokenTotals().segments).isEmpty, "share bar: nothing at all draws no bar")
    check(visible.first.map { UsageShareSegment.tooltip($0, among: visible, metric: .cost) } == "Standard · $9.00 · 60.0%",
          "share bar: the tooltip is label, value and share")
    check(UsageShareSegment.visible(mixedTokens.segments).first.map { UsageShareSegment.tooltip($0, among: mixedTokens.segments, metric: .tokens) }
            == "Input · 1M · 25.0%", "share bar: token bars print tokens")
    check(cost.segments[0].ink.light == 0x69696c && cost.segments[0].ink.dark == 0x7b7b7b
            && cost.segments[4].ink.light == 0x8e8e90 && speed.segments[1].ink.dark == 0x8c8c8c,
          "share bar: segments carry T3's light and dark inks")
}
usageChecks32()

// Chart maths (UsageProviderChart.tsx, UsageProviderChart.test.ts, spec 03 §7).
func usageChecks33() {
    let near = { (a: Double, b: Double) in abs(a - b) < 1e-9 }

    // "keeps band values absolute rather than cumulative"
    let first = UsagePeriodTotals(day: "2026-08-01", hourStart: nil, costUsd: 30, totalTokens: 300,
                                  byProvider: ["codex": UsageAmount(costUsd: 10, totalTokens: 100),
                                               "claude": UsageAmount(costUsd: 20, totalTokens: 200)])
    let third = UsagePeriodTotals(day: "2026-08-03", hourStart: nil, costUsd: 5, totalTokens: 50,
                                  byProvider: ["claude": UsageAmount(costUsd: 5, totalTokens: 50)])
    let days = ["2026-08-01", "2026-08-02", "2026-08-03"]
    let chart = UsageChartData(periods: days, timeline: [first, third], metric: .cost, providers: ["claude", "codex"])
    check(chart.series.map { $0.provider } == ["claude", "codex"] && chart.series[0].values == [20, 0, 5]
            && chart.series[1].values == [10, 0, 0], "chart: band values are absolute, not cumulative")
    check(chart.scale.max == 20 && chart.total(at: 0) == 30, "chart: the peak is 20, the largest single value, though the column sums to 30")
    let tokens = UsageChartData(periods: days, timeline: [first, third], metric: .tokens, providers: ["codex"])
    check(tokens.series.count == 1 && tokens.series[0].values == [100, 0, 0], "chart: only the providers asked for get a series")

    // niceScale, spec examples and oracle values.
    let scales: [(Double, Double, [Double])] = [
        (37, 40, [0, 10, 20, 30, 40]), (100, 100, [0, 50, 100]), (0.8, 0.8, [0, 0.2, 0.4, 0.6, 0.8]),
        (3, 3, [0, 1, 2, 3]), (7, 8, [0, 2, 4, 6, 8]), (400, 400, [0, 100, 200, 300, 400]),
        (1160, 1500, [0, 500, 1000, 1500]), (2320, 3000, [0, 1000, 2000, 3000]), (41.2, 60, [0, 20, 40, 60]),
        (0.0375, 0.04, [0, 0.01, 0.02, 0.03, 0.04]), (1e-7, 1e-7, [0, 5e-8, 1e-7]),
    ]
    for (peak, top, ticks) in scales {
        let scale = UsageChart.niceScale(peak: peak)
        let same = scale.ticks.count == ticks.count && zip(scale.ticks, ticks).allSatisfy { abs($0 - $1) <= top * 1e-9 }
        check(abs(scale.max - top) <= top * 1e-9 && same && scale.labeled,
              "scale: a peak of \(peak) tops out at \(top) with ticks \(ticks), got \(scale.max) \(scale.ticks)")
    }
    check(UsageChart.niceScale(peak: 0).max == 0 && UsageChart.niceScale(peak: 0).ticks == [0], "scale: no peak is a single zero tick")
    check(UsageChart.niceScale(peak: -5).ticks == [0], "scale: a negative peak is no peak")
    let brokenPeaks = [Double.infinity, Double.nan, Double.leastNonzeroMagnitude]
    check(brokenPeaks.allSatisfy { UsageChart.niceScale(peak: $0).ticks.count <= 9 },
          "scale: an infinite, undefined or vanishing peak ends instead of looping")

    // valueToY and x positions; the plot keeps T3's 8-in-260 top inset at any height.
    check(UsageChart.y(40, max: 40, height: 260) == 8 && UsageChart.y(0, max: 40, height: 260) == 260
            && UsageChart.y(20, max: 40, height: 260) == 134, "plot: 260 high, the peak sits 8 from the top")
    check(near(UsageChart.y(40, max: 40, height: 224), 224 * 8 / 260), "plot: at 224 high the inset scales with it")
    check(UsageChart.y(5, max: 0, height: 224) == 224, "plot: without a scale everything lies on the bottom")
    check(UsageChart.x(0, count: 30, width: 290) == 0 && UsageChart.x(29, count: 30, width: 290) == 290
            && UsageChart.x(1, count: 30, width: 290) == 10, "plot: points run edge to edge in equal steps")
    check(UsageChart.x(0, count: 1, width: 290) == 0, "plot: a single point sits on the left edge")

    // Monotone curve.
    let point = { (x: Double, y: Double) in UsageChartPoint(x: x, y: y) }
    check(UsageChart.curve([]).isEmpty && UsageChart.curve([point(0, 0)]).isEmpty, "curve: fewer than two points draw nothing")
    let line = UsageChart.curve([point(0, 0), point(3, 3)])
    check(line.count == 1 && line[0].from == point(0, 0) && line[0].to == point(3, 3) && line[0].c1 == point(1, 1)
            && line[0].c2 == point(2, 2), "curve: two points are a straight segment")
    let peak = UsageChart.curve([point(0, 0), point(3, 3), point(6, 0)])
    check(peak.count == 2 && peak[0].c1 == point(1, 1) && peak[0].c2 == point(2, 3) && peak[1].c1 == point(4, 3)
            && peak[1].c2 == point(5, 1), "curve: a turning point gets a flat tangent, so the line never overshoots it")
    let flat = UsageChart.curve([point(0, 5), point(1, 5), point(2, 9)])
    check(flat[0].c1.y == 5 && flat[0].c2.y == 5 && flat[1].c1.y == 5, "curve: a flat stretch stays flat right up to its end")
    // A gentle slope followed by a steep one: the shared tangent is cut back so the first segment
    // stays between its ends (Fritsch-Carlson, a² + b² > 9).
    let steep = UsageChart.curve([point(0, 0), point(1, 0.1), point(2, 10)])
    let cut = 3 / (1.0 * 1.0 + 50.0 * 50.0).squareRoot()
    check(near(steep[0].c1.y, cut * 0.1 / 3) && near(steep[0].c2.y, 0.1 - cut * 50 * 0.1 / 3),
          "curve: an overlong tangent is scaled back onto the circle of radius 3")
    check(near(steep[1].c1.y, 0.1 + cut * 50 * 0.1 / 3) && near(steep[1].c2.y, 10 - 9.9 / 3),
          "curve: the next segment starts with the tangent the previous one settled on")
    check(steep.allSatisfy { $0.c1.y >= $0.from.y - 1e-9 && $0.c2.y <= $0.to.y + 1e-9 },
          "curve: control points of a rising series never leave the range of their segment")
    let stacked = UsageChart.curve([point(0, 0), point(0, 4)])
    check(stacked.count == 1 && stacked[0].c1 == point(0, 0) && stacked[0].c2 == point(0, 4),
          "curve: two points on one x do not divide by zero")

    // Hover and tooltip (spec 03 §7.6).
    check(UsageChart.hoverIndex(x: 0, width: 290, count: 30) == 0 && UsageChart.hoverIndex(x: 290, width: 290, count: 30) == 29
            && UsageChart.hoverIndex(x: 14, width: 290, count: 30) == 1 && UsageChart.hoverIndex(x: 16, width: 290, count: 30) == 2,
          "hover: the pointer picks the nearest column")
    check(UsageChart.hoverIndex(x: -40, width: 290, count: 30) == 0 && UsageChart.hoverIndex(x: 900, width: 290, count: 30) == 29,
          "hover: outside the plot it is the nearest edge")
    check(UsageChart.hoverIndex(x: 10, width: 290, count: 0) == nil && UsageChart.hoverIndex(x: 10, width: 0, count: 30) == nil
            && UsageChart.hoverIndex(x: .nan, width: 290, count: 30) == 0, "hover: no columns or no width is no hover")
    check(UsageChart.tooltipOrigin(pointer: point(100, 50), tooltipWidth: 144, tooltipHeight: 80, plotWidth: 600, plotHeight: 224)
            == point(112, 62), "tooltip: 12 right of and below the pointer when it fits")
    check(UsageChart.tooltipOrigin(pointer: point(500, 200), tooltipWidth: 144, tooltipHeight: 80, plotWidth: 600, plotHeight: 224)
            == point(344, 108), "tooltip: it flips left and above near the far corner")
    check(UsageChart.tooltipOrigin(pointer: point(50, 40), tooltipWidth: 144, tooltipHeight: 300, plotWidth: 120, plotHeight: 224)
            == point(0, 0), "tooltip: larger than the plot, it is pinned to the corner")
    check(UsageChart.axisLabels([], hourly: false, timeZone: TimeZone(identifier: "UTC")!, hour12: true).isEmpty
            && UsageChart.axisLabels(["2026-11-19"], hourly: false, timeZone: TimeZone(identifier: "UTC")!, hour12: true)
                == ["NOV 19", "NOV 19", "NOV 19"], "axis: one period fills all three labels, none has no labels")
}
usageChecks33()

// Source warnings (usageFormat.test.ts "usage source messages", reduced to one machine).
func usageChecks34() {
    let source = { (provider: String, status: String, malformed: Int, message: Any) -> [String: Any] in
        ["provider": provider, "status": status, "scannedFiles": 1, "skippedFiles": 3, "malformedRecords": malformed,
         "distinctSessions": 1, "message": message]
    }
    let warnings = { (sources: [[String: Any]]) -> [String] in
        UsagePeriod(json: ["resolution": "day", "sinceDay": "2026-11-13", "untilDay": "2026-11-19", "sources": sources]).warnings()
    }
    let none = NSNull()

    check(warnings([source("codex", "partial", 1, none), source("claude", "partial", 11, none)])
            == ["12 malformed or inconsistent usage record(s) were skipped; usage may be incomplete."],
          "warnings: skipped records of both providers are one warning with one count")
    check(warnings([source("codex", "missing", 0, "no_history"), source("claude", "ok", 1, none)]).isEmpty && warnings([]).isEmpty,
          "warnings: an empty missing source and a healthy one say nothing")
    check(warnings([source("codex", "partial", 1, none), source("claude", "missing", 2, "no_history")])
            == ["No Claude transcript directory was found on this Mac.",
                "3 malformed or inconsistent usage record(s) were skipped; usage may be incomplete."],
          "warnings: a missing source with skipped records keeps both facts")
    check(warnings([source("claude", "partial", 0, "read_failed")])
            == ["Some Claude transcripts could not be read; usage may be incomplete."],
          "warnings: unreadable transcripts are named with their provider")
    check(warnings([source("codex", "failed", 0, "read_failed")]) == ["Codex could not report usage."],
          "warnings: a failed source says the provider could not report")
    check(warnings([source("codex", "failed", 0, none)]) == ["Codex could not report usage."],
          "warnings: a failure without a reason is still a failure on screen")
    check(warnings([source("codex", "partial", 0, none)])
            == ["Some Codex transcripts could not be read; usage may be incomplete."],
          "warnings: a partial read without a reason is still reported")
    check(warnings([source("codex", "partial", 0, "Traceback (most recent call last)")])
            == ["Some Codex transcripts could not be read; usage may be incomplete."],
          "warnings: text that is not a known category is never shown raw")
    check(warnings([source("codex", "partial", 0, "zstd_unavailable"), source("codex", "partial", 0, "zstd_unavailable")]).count == 1,
          "warnings: the same sentence is said once")
    check(warnings([source("codex", "partial", 0, "zstd_unavailable")])
            == ["Compressed Codex session files were skipped because zstd is not installed; usage may be incomplete."],
          "warnings: skipped compressed files are not given a number, skippedFiles also counts files without usage")
    check(warnings([source("codex", "ok", 0, "zstd_unavailable")]).isEmpty, "warnings: a source that reports ok is not a warning")
}
usageChecks34()

// English copy with T3's quirks (spec 03 §6.1, §6.2, §8.3).
func usageChecks35() {
    check(UsageCopy.sessionsCaption(1, metric: .tokens) == "1 sessions", "copy: the headline caption reads sessions even for one, as T3's does")
    check(UsageCopy.sessionsCaption(1234, metric: .cost) == "1,234 sessions · API estimate", "copy: on the Cost tab the caption adds API estimate")
    check(UsageCopy.providerSessions(1) == "1 session" && UsageCopy.providerSessions(12) == "12 sessions"
            && UsageCopy.providerSessions(0) == "0 sessions", "copy: a provider row counts 1 session, 12 sessions")
    let provider = UsageProviderTotals(provider: "codex", costUsd: 41.2, totalTokens: 18_200_000, records: 40, sessions: 12,
                                       costShare: 0.624, tokenShare: 0.5)
    check(UsageCopy.providerDetail(provider, metric: .cost) == "62.4% of cost · 18.2M tokens", "copy: the Cost sub-line is share of cost and tokens")
    check(UsageCopy.providerDetail(provider, metric: .tokens) == "50.0% of tokens · $41.20", "copy: the Tokens sub-line is share of tokens and cost")
    check(UsageCopy.chartHeading(hourly: false, metric: .cost) == "Daily cost" && UsageCopy.chartHeading(hourly: false, metric: .tokens) == "Daily processed tokens"
            && UsageCopy.chartHeading(hourly: true, metric: .cost) == "Hourly cost"
            && UsageCopy.chartHeading(hourly: true, metric: .tokens) == "Hourly processed tokens", "copy: the four chart headings")
    check(UsageCopy.unpricedNotice(share: 0.45) == "API estimate excludes 45.0% unpriced records.", "copy: the unpriced notice names the share")
    check(UsageCopy.unpricedFooter(tokens: 1_000_000) == "1M tokens have no known price", "copy: the dialog footer names the unpriced tokens")
    check(UsageCopy.premium(3) == "Premium $3.00", "copy: the speed bar's aside is the premium")
    check(UsageCopy.unpriced == "Unpriced" && UsageCopy.noActivity == "No activity in this window.", "copy: the two fixed phrases")
    check(UsageCopy.providerName("claude") == "Claude" && UsageCopy.providerName("codex") == "Codex",
          "copy: providers are named Claude and Codex on every tab")
    check(UsagePalette.provider("claude").light == 0xd97757 && UsagePalette.provider("claude").dark == 0xd97757
            && UsagePalette.provider("codex").light == 0x18181b && UsagePalette.provider("codex").dark == 0xf5f5f5,
          "palette: Claude is T3's orange, Codex is the foreground colour of each appearance")
    let orange = UsagePalette.provider("claude").rgb(dark: false)
    check(abs(orange.red - 217.0 / 255) < 1e-12 && abs(orange.green - 119.0 / 255) < 1e-12 && abs(orange.blue - 87.0 / 255) < 1e-12,
          "palette: a colour is also available as three fractions")
    check(UsageTotals.providerOrder == ["claude", "codex"], "palette: the provider order is Claude, then Codex")
}
usageChecks35()

// status.json.
func usageChecks36() {
    let scanning = UsageScanStatus(json: ["ts": 1_795_112_308, "state": "scanning", "detail": "", "done": 120, "total": 7501])
    check(scanning.ts == 1_795_112_308 && scanning.state == "scanning" && scanning.detail.isEmpty && scanning.done == 120
            && scanning.total == 7501, "status: a scan in progress is read")
    check(scanning.progressText(busy: true, hasSummary: false) == "Scanning… 120 of 7,501 files",
          "status: a first scan reads Scanning with its progress")
    check(scanning.progressText(busy: true, hasSummary: true) == "Refreshing… 120 of 7,501 files",
          "status: a rescan over figures already on screen reads Refreshing")
    check(scanning.progressText(busy: false, hasSummary: true) == nil, "status: nothing running means no progress line, whatever the file says")
    check(scanning.failureText == nil, "status: a scan in progress has not failed")
    let done = UsageScanStatus(json: ["ts": 1_795_112_400, "state": "ok", "detail": "", "done": 7501, "total": 7501])
    check(done.progressText(busy: true, hasSummary: true) == "Refreshing…",
          "status: a finished file under a running command is the previous run's, so there are no numbers yet")
    let failed = UsageScanStatus(json: ["ts": 1_795_112_400, "state": "failed", "detail": "read_failed", "done": 3, "total": 9])
    check(failed.failureText == "Usage could not be read." && failed.detail == "read_failed", "status: a failed scan says so")
    let broken = UsageScanStatus(json: ["ts": "now", "state": 3, "detail": ["x"], "done": -5, "total": 1e30])
    check(broken.ts == 0 && broken.state.isEmpty && broken.detail.isEmpty && broken.done == 0 && broken.total == 0,
          "status: wrong types read as nothing known")
    check(broken.progressText(busy: true, hasSummary: false) == "Scanning…" && broken.failureText == nil,
          "status: an unreadable file still lets a running scan say Scanning")
    let none = UsageScanStatus(json: [:])
    check(none.state.isEmpty && none.done == 0 && none.total == 0, "status: an empty file is nothing known")
    let over = UsageScanStatus(json: ["state": "scanning", "done": 12, "total": 0])
    check(over.progressText(busy: true, hasSummary: false) == "Scanning…", "status: progress without a total has no numbers")
}
usageChecks36()

// Broken summary.json: wrong types degrade, nothing traps.
func usageChecks37() {
    let parse = { (text: String) -> [String: Any] in
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    let broken = UsageSummary(json: parse("""
    {
      "version": "one", "readAt": "soon", "timeZone": 5, "scanDurationMs": -3, "pricing": [],
      "periods": {
        "1": 7,
        "7": {"resolution": 3, "sinceDay": 20261113, "untilDay": null, "sinceTime": 12, "buckets": {"a": 1}, "sources": "none"},
        "30": {
          "resolution": "day", "sinceDay": "2026-10-21", "untilDay": "2026-11-19",
          "buckets": [
            5, "x", null, [],
            {"day": "2026-11-19", "provider": "claude", "model": "m", "totals": "many", "costUsd": "12",
             "cacheSavingsUsd": true, "categoryCostUsd": "none", "fastCostUsd": [1], "records": true, "unpricedRecords": -4,
             "unpricedTokens": "all", "costSource": 7},
            {"day": "2026-11-19", "provider": "future", "model": "m", "costUsd": 100, "records": 1},
            {"day": "19.11.2026", "provider": "claude", "model": "m", "costUsd": 100, "records": 1},
            {"day": "2026-11-19", "provider": "claude", "model": "   ", "costUsd": 100, "records": 1},
            {"provider": "claude", "model": "m", "costUsd": 100, "records": 1},
            {"day": "2026-11-19", "hourStart": "noon", "provider": "codex", "model": " gpt-5 ",
             "totals": {"uncachedInputTokens": -5, "cachedInputTokens": 1.9, "outputTokens": "7", "reasoningTokens": 1e300},
             "costUsd": 2, "cacheSavingsUsd": null, "categoryCostUsd": {"input": "x", "output": 2},
             "records": 1, "unpricedRecords": 0}
          ],
          "sources": [3, null, {"provider": "codex", "status": 5, "distinctSessions": "two", "message": 12},
                      {"provider": "future", "status": "ok", "distinctSessions": 9}, {"status": "ok"}]
        }
      }
    }
    """))
    check(broken.version == 0 && broken.readAt == 0 && broken.scanDurationMs == 0, "broken: unreadable numbers are zero")
    check(broken.timeZone == "UTC" && broken.zone.secondsFromGMT() == 0, "broken: an unreadable time zone is UTC")
    check(broken.pricing.status == "unavailable" && broken.pricing.source.isEmpty && broken.pricing.fetchedAt == nil
            && broken.pricing.knownModels == 0, "broken: unreadable pricing is unavailable")
    check(broken.period(1).buckets.isEmpty && !broken.period(1).isHourly && broken.period(1).periodKeys.isEmpty,
          "broken: a period that is not an object is empty")
    let week = broken.period(7)
    check(week.resolution == "day" && week.sinceDay.isEmpty && week.untilDay.isEmpty && week.sinceTime == nil
            && week.buckets.isEmpty && week.sources.isEmpty && week.periodKeys.isEmpty,
          "broken: wrong types inside a period are empty fields")
    check(UsageFormat.windowLabel(week, timeZone: broken.zone, hour12: true) == " to ", "broken: a window without bounds has an empty label, not a crash")

    let month = broken.period(30)
    check(month.buckets.count == 2, "broken: only buckets with a day, a known provider and a model survive, got \(month.buckets.count)")
    let zeros = month.buckets.first
    check(zeros?.costUsd == 0 && zeros?.cacheSavingsUsd == 0 && zeros?.records == 0 && zeros?.unpricedRecords == 0
            && zeros?.totals == UsageTokenTotals() && zeros?.categoryCost == nil && zeros?.fastCostUsd == 0
            && zeros?.unpricedTokens == nil && zeros?.costSource == "",
          "broken: a number given as text, as a flag or below zero reads as zero")
    let codex = month.buckets.last
    check(codex?.model == "gpt-5" && codex?.hourStart == "noon", "broken: a model name is trimmed, an unreadable hour is kept as it came")
    check(codex?.totals.uncachedInputTokens == 0 && codex?.totals.cachedInputTokens == 1 && codex?.totals.outputTokens == 0
            && codex?.totals.reasoningTokens == 0, "broken: a token count is whole, never negative and never absurd")
    check(codex?.categoryCost?.input == 0 && codex?.categoryCost?.output == 2, "broken: a half-readable category split keeps what it can")
    check(month.sources.count == 1 && month.sources.first?.status == "" && month.sources.first?.distinctSessions == 0
            && month.sources.first?.message == nil, "broken: only sources of a known provider survive, with empty fields")
    let totals = UsageTotals(period: month)
    check(totals.costUsd == 2 && totals.totalTokens == 1 && totals.sessions == 0 && totals.models.map { $0.model } == ["gpt-5"],
          "broken: a provider without any source of its own is not counted")
    check(totals.hourly.count == 1 && totals.hourly.first?.hourStart == "noon", "broken: the unreadable hour is still one row")
    check(month.warnings().isEmpty, "broken: an unknown status is not a warning")
    check(broken.period(90).buckets.isEmpty, "broken: a period that was never written is empty")
    check(UsageSummary(json: [:]).period(30).buckets.isEmpty && UsageSummary(json: ["periods": [1, 2]]).period(7).sources.isEmpty,
          "broken: no periods at all is four empty periods")

    // Values JSON cannot spell but a hand-built object can: nothing here may reach an Int conversion or a sum that traps.
    let huge: [String: Any] = [
        "day": "2026-11-19", "provider": "claude", "model": "m",
        "totals": ["uncachedInputTokens": Double.greatestFiniteMagnitude, "outputTokens": Double.infinity,
                   "cachedInputTokens": 9_007_199_254_740_992.0, "cacheCreationTokens": Double.nan],
        "costUsd": Double.nan, "cacheSavingsUsd": Double.infinity, "records": Double.infinity,
        "unpricedRecords": Int.max, "fastCostUsd": -Double.infinity,
    ]
    let hugeSource: [String: Any] = ["provider": "claude", "status": "partial", "distinctSessions": Int.max,
                                     "malformedRecords": Int.max, "skippedFiles": Int.max, "message": "zstd_unavailable"]
    let wild = UsagePeriod(json: ["resolution": "hour", "sinceDay": "2026-11-18", "untilDay": "2026-11-19",
                                  "sinceTime": "2026-11-18T12:37:00.000Z", "untilTime": "2026-11-19T12:37:00.000Z",
                                  "buckets": Array(repeating: huge, count: 2000), "sources": [hugeSource, hugeSource]])
    let wildTotals = UsageTotals(period: wild)
    check(wild.buckets.count == 2000 && wildTotals.costUsd == 0 && wildTotals.records == 0 && wildTotals.sessions == 0,
          "broken: non-finite and absurd numbers read as zero")
    check(wildTotals.tokens.cachedInputTokens == 2000 * 9_007_199_254_740_992.0 && wildTotals.totalTokens.isFinite,
          "broken: two thousand of the largest counts still add up without trapping")
    let wildChart = UsageChartData(period: wild, totals: wildTotals, metric: .tokens, providers: wildTotals.activeProviders)
    let wildText = UsageFormat.tokens(wildTotals.totalTokens) + UsageCopy.sessionsCaption(wildTotals.sessions, metric: .cost)
        + wild.warnings().joined() + wildChart.scale.ticks.map { UsageChart.tickLabel($0, metric: .tokens) }.joined()
    check(!wildText.isEmpty && wildChart.periods.count == 24, "broken: and they can be printed and charted")
}
usageChecks37()

// Added by the independent verifier. Every expected value below was printed by T3 Code's own
// sources (commit 803f21f) run under Node, not derived from this model; the T3 file and line of
// the rule is named in each check.
func usageChecks38() {
    let bucket = { (overrides: [String: Any]) -> [String: Any] in
        // usageMerge.test.ts:17-37, the fixture every merge test starts from.
        var base: [String: Any] = [
            "day": "2026-08-07", "provider": "claude", "model": "claude-fable-5",
            "totals": ["uncachedInputTokens": 100, "cachedInputTokens": 1000, "cacheCreationTokens": 10,
                       "outputTokens": 50, "reasoningTokens": 0],
            "costUsd": 10, "cacheSavingsUsd": 2, "costSource": "modelPriced",
            "records": 5, "unpricedRecords": 0, "sessions": 1,
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }
    let only = { (tokens: Int) -> [String: Any] in
        ["uncachedInputTokens": tokens, "cachedInputTokens": 0, "cacheCreationTokens": 0, "outputTokens": 0, "reasoningTokens": 0]
    }
    let source = { (provider: String, sessions: Int) -> [String: Any] in
        ["provider": provider, "status": "ok", "scannedFiles": 1, "skippedFiles": 0, "malformedRecords": 0,
         "distinctSessions": sessions, "message": NSNull()]
    }
    let period = { (buckets: [[String: Any]], sources: [[String: Any]]) -> UsagePeriod in
        UsagePeriod(json: ["resolution": "day", "sinceDay": "2026-08-01", "untilDay": "2026-08-31",
                           "buckets": buckets, "sources": sources])
    }
    let near = { (a: Double, b: Double) in abs(a - b) < 1e-12 }

    // usageMerge.ts:471 — a model row is keyed by provider and model, not by the name alone.
    let sharedPeriod = period([bucket(["model": "shared"]), bucket(["provider": "codex", "model": "shared", "costUsd": 4])],
                              [source("claude", 1), source("codex", 1)])
    let shared = UsageTotals(period: sharedPeriod)
    check(shared.models.map { $0.id } == ["claude:shared", "codex:shared"] && shared.models.map { $0.costUsd } == [10, 4]
            && shared.models.map { $0.totalTokens } == [1160, 1160]
            && shared.models.count == 2 && near(shared.models[0].costShare, 0.7142857142857143)
            && near(shared.models[1].costShare, 0.2857142857142857),
          "T3 usageMerge.ts:471: one model name under two providers is two rows, each with its own cost")
    // UsageModelDialog.tsx:54-57 — the dialog keeps buckets of this provider AND this model.
    if let codexShared = shared.models.first(where: { $0.provider == "codex" }) {
        let sharedDialog = UsageTotals(period: sharedPeriod, model: codexShared)
        check(sharedDialog.costUsd == 4 && sharedDialog.daily.map { $0.costUsd } == [4] && sharedDialog.models.count == 1,
              "T3 UsageModelDialog.tsx:54-57: the dialog of codex:shared leaves claude:shared out")
    } else {
        check(false, "T3 UsageModelDialog.tsx:54-57: codex:shared has a row of its own to open")
    }

    // usageMerge.ts:605-612 and :616 — the split is rounded to six decimals by the writer and can
    // add up to a hair more than the cost; neither remainder may go below zero.
    let rounded = UsageTotals(period: period(
        [bucket(["costUsd": 1, "categoryCostUsd": ["input": 0.4, "cacheRead": 0.3, "cacheWrite": 0.2, "output": 0.100001],
                 "fastCostUsd": 0.7, "ultrafastCostUsd": 0.300001])], [source("claude", 1)]))
    check(rounded.categoryCost.unsplit == 0 && rounded.categoryCost.output == 0.100001,
          "T3 usageMerge.ts:605-612: a split that rounds above the cost leaves no negative unsplit cost")
    check(rounded.speedCost.standard == 0 && rounded.speedCost.fast == 0.7 && rounded.speedCost.ultrafast == 0.300001
            && rounded.speedCost.premium == 0, "T3 usageMerge.ts:616: fast and ultrafast above the cost leave no negative standard cost")

    // usageMerge.ts:424-435 — sessions alone put a provider on the list, zero sessions do not.
    let idle = UsageTotals(period: period([bucket([:])], [source("claude", 1), source("codex", 0)]))
    check(idle.providers.map { $0.provider } == ["claude"] && idle.sessions == 1,
          "T3 usageMerge.ts:426: a provider with no sessions and no buckets is not listed")
    let sessionsOnly = UsageTotals(period: period([bucket([:])], [source("claude", 1), source("codex", 3)]))
    let listed = sessionsOnly.providers.first { $0.provider == "codex" }
    check(sessionsOnly.providers.map { $0.provider } == ["claude", "codex"] && sessionsOnly.sessions == 4
            && listed?.sessions == 3 && listed?.costUsd == 0 && listed?.records == 0 && listed?.costShare == 0
            && listed?.tokenShare == 0, "T3 usageMerge.ts:427-434: a provider with sessions but no buckets is listed with zeros")
    // usageProviders.ts:54-67 — but it gets no summary row and no chart series.
    check(sessionsOnly.activeProviders == ["claude"] && sessionsOnly.rankedProviders(by: .cost).map { $0.provider } == ["claude"],
          "T3 usageProviders.ts:63: a provider without tokens or cost is not an active provider")

    // usageMerge.ts:549-550, :564-565 — shares of a zero total are zero, not a division by zero.
    let free = UsageTotals(period: period([bucket(["costUsd": 0])], [source("claude", 1)]))
    check(free.providers.first?.costShare == 0 && free.providers.first?.tokenShare == 1 && free.models.first?.costShare == 0
            && free.models.first?.tokenShare == 1, "T3 usageMerge.ts:549, :564: with no cost at all every cost share is 0, never NaN")
    // usageMerge.ts:42-44 and usageBreakdown.ts:19-23, :31-37 — priced at zero is a known cost.
    check(free.models.first?.isCostUnknown == false && free.models.first?.share(.cost) == 0
            && free.models.first?.costPerMillionTokens == 0 && free.costQuality.modelPricedShare == 1
            && free.costQuality.unpricedShare == 0, "T3 usageMerge.ts:42-44: a model priced at zero is free, not unpriced")

    // usageMerge.ts:567 and usageBreakdown.ts:13-17 — the second sort key of each tab.
    let tied = UsageTotals(period: period(
        [bucket(["model": "a", "costUsd": 5, "totals": only(100)]), bucket(["model": "b", "costUsd": 5, "totals": only(300)]),
         bucket(["model": "c", "costUsd": 2, "totals": only(300)]), bucket(["model": "d", "costUsd": 9, "totals": only(50)])],
        [source("claude", 1)]))
    check(tied.models.map { $0.model } == ["d", "b", "a", "c"] && tied.models(by: .cost).map { $0.model } == ["d", "b", "a", "c"],
          "T3 usageMerge.ts:567: equal cost is ordered by tokens, larger first")
    check(tied.models(by: .tokens).map { $0.model } == ["b", "c", "a", "d"],
          "T3 usageBreakdown.ts:13-17: on the Tokens tab equal tokens are ordered by cost, larger first")
}
usageChecks38()

func usageChecks39() {
    // usageFormat.ts:106-110 — rounding can carry into the next digit count, and trim() then drops
    // the fraction that carry left behind ("100.0" reads "100").
    let tokens: [(Double, String)] = [
        (99_950, "100K"), (99_949, "99.9K"), (9995, "9.99K"), (9994, "9.99K"), (999_949, "1M"), (999_950, "1M"),
        (999_999_999_999, "1T"), (1e15, "1000T"),
        // usageFormat.ts:95 — Math.round sends a negative half up, towards zero.
        (-999.5, "-999"), (999.4, "999"),
    ]
    for (value, expected) in tokens {
        let got = UsageFormat.tokens(value)
        check(got == expected, "T3 usageFormat.ts:94-110: \(value) tokens print \(expected), got \(got)")
    }
    // usageFormat.ts:88-90
    check(UsageFormat.count(-2.5) == "-2" && UsageFormat.count(0.5) == "1" && UsageFormat.count(999.5) == "1,000"
            && UsageFormat.count(1_000_000) == "1,000,000", "T3 usageFormat.ts:88-90: counts round a half up and group thousands")
    // usageFormat.ts:9-14, :84-86
    let usd: [(Double, String)] = [(0.995, "$1.00"), (2.675, "$2.68"), (1e-7, "$0.00"), (-0.004, "-$0.00"),
                                   (123_456_789.125, "$123,456,789.13")]
    for (value, expected) in usd {
        let got = UsageFormat.usd(value)
        check(got == expected, "T3 usageFormat.ts:84-86: \(value) dollars print \(expected), got \(got)")
    }
    // usageFormat.ts:112-117 — the digits parameter moves both the rounding and the "<" floor.
    check(UsageFormat.percent(0.004, digits: 0) == "<1%" && UsageFormat.percent(0.025, digits: 0) == "3%"
            && UsageFormat.percent(0.5, digits: 0) == "50%" && UsageFormat.percent(0.005, digits: 0) == "<1%",
          "T3 usageFormat.ts:112-117: with no decimals the floor is <1% and 2.5 rounds up to 3%")
    check(UsageFormat.percent(0.12345, digits: 2) == "12.35%" && UsageFormat.percent(0.00004, digits: 2) == "<0.01%"
            && UsageFormat.percent(0.0001, digits: 2) == "0.01%" && UsageFormat.percent(1, digits: 2) == "100.00%",
          "T3 usageFormat.ts:112-117: with two decimals the floor is <0.01%")

    // usageFormat.ts:148-158
    check(UsageFormat.enumerateDays(since: "2028-02-27", until: "2028-03-01") == ["2028-02-27", "2028-02-28", "2028-02-29", "2028-03-01"],
          "T3 usageFormat.ts:148-158: a leap day is one of the days")
    check(UsageFormat.enumerateDays(since: "2026-12-30", until: "2027-01-02") == ["2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02"],
          "T3 usageFormat.ts:148-158: the list runs across a new year")

    // usageFormat.test.ts:131-139 "keeps requested zones separate when formatting repeated calls"
    let instant = "2026-08-11T12:37:00.000Z"
    let hours = ["UTC", "America/New_York", "Asia/Kathmandu", "UTC"].compactMap { TimeZone(identifier: $0) }
        .map { UsageFormat.hourShort(instant, timeZone: $0, hour12: true) }
    check(hours == ["12 PM", "8 AM", "6 PM", "12 PM"],
          "T3 usageFormat.test.ts:131-139: a zone asked for again reads as it did the first time, got \(hours)")

    // usageFormat.ts:282-288 — only the reference day and the day before are named.
    let reference = "2026-11-19T12:37:00.000Z"
    if let berlin = TimeZone(identifier: "Europe/Berlin"), let newYork = TimeZone(identifier: "America/New_York") {
        let relative = { (instant: String, hour12: Bool) in
            UsageFormat.relativeHourShort(instant, relativeTo: reference, timeZone: berlin, hour12: hour12)
        }
        check(relative("2026-11-20T12:37:00.000Z", true) == "Nov 20, 1 PM",
              "T3 usageFormat.ts:287: an hour on the day after the reference is a date, not today or yesterday")
        check(relative("2026-11-18T12:37:00.000Z", false) == "13:00 yesterday" && relative("2026-11-19T12:37:00.000Z", false) == "13:00 today",
              "T3 usageFormat.ts:285-287: the 24-hour form is named today and yesterday too")
        check(relative("2026-11-17T22:37:00.000Z", true) == "Nov 17, 11 PM" && relative("2026-11-17T23:37:00.000Z", true) == "12 AM yesterday",
              "T3 usageFormat.ts:282-284: yesterday begins at midnight in the zone, an hour earlier is a date")
        // usageFormat.ts:285 — the relative form is built on formatHourShort, zone name included.
        let fallBack = "2026-11-01T12:37:00.000Z"
        check(UsageFormat.relativeHourShort("2026-11-01T05:37:00.000Z", relativeTo: fallBack, timeZone: newYork, hour12: true) == "1 AM EDT today"
                && UsageFormat.relativeHourShort("2026-11-01T06:37:00.000Z", relativeTo: fallBack, timeZone: newYork, hour12: false) == "01:00 EST today",
              "T3 usageFormat.ts:285: a repeated hour keeps its zone name in the tooltip")
    } else {
        check(false, "the Berlin and New York time zones are known to this Mac")
    }
}
usageChecks39()

func usageChecks40() {
    // UsageProviderChart.tsx:165 — a step sitting exactly on 1, 2 or 5 keeps that step.
    let scales: [(Double, Double, [Double])] = [
        (4, 4, [0, 1, 2, 3, 4]), (8, 8, [0, 2, 4, 6, 8]), (20, 20, [0, 5, 10, 15, 20]), (1, 1, [0, 0.5, 1]),
        (5, 6, [0, 2, 4, 6]), (0.05, 0.06, [0, 0.02, 0.04, 0.06]), (2_500_000, 3_000_000, [0, 1_000_000, 2_000_000, 3_000_000]),
    ]
    for (peak, top, ticks) in scales {
        let scale = UsageChart.niceScale(peak: peak)
        let same = scale.ticks.count == ticks.count && zip(scale.ticks, ticks).allSatisfy { abs($0 - $1) <= top * 1e-9 }
        check(abs(scale.max - top) <= top * 1e-9 && same,
              "T3 UsageProviderChart.tsx:159-171: a peak of \(peak) tops out at \(top) with ticks \(ticks), got \(scale.max) \(scale.ticks)")
    }
    // UsageProviderChart.tsx:354-358 — Math.round: exactly between two columns is the later one.
    check(UsageChart.hoverIndex(x: 5, width: 290, count: 30) == 1 && UsageChart.hoverIndex(x: 4.9, width: 290, count: 30) == 0
            && UsageChart.hoverIndex(x: 285, width: 290, count: 30) == 29 && UsageChart.hoverIndex(x: 100, width: 290, count: 1) == 0,
          "T3 UsageProviderChart.tsx:354-358: half way between two columns picks the later one")
    // UsageProviderChart.tsx:321-328 — "<=": a tooltip that fits exactly stays on its preferred side.
    check(UsageChart.tooltipOrigin(pointer: UsageChartPoint(x: 444, y: 132), tooltipWidth: 144, tooltipHeight: 80,
                                   plotWidth: 600, plotHeight: 224) == UsageChartPoint(x: 456, y: 144),
          "T3 UsageProviderChart.tsx:321-328: a tooltip that fits to the pixel is not flipped")
    check(UsageChart.tooltipOrigin(pointer: UsageChartPoint(x: 444.5, y: 132.5), tooltipWidth: 144, tooltipHeight: 80,
                                   plotWidth: 600, plotHeight: 224) == UsageChartPoint(x: 288.5, y: 40.5),
          "T3 UsageProviderChart.tsx:321-328: half a point further it flips to the left and above")
    // UsageProviderChart.tsx:329-330 — a flip that would leave the plot is pinned to its edge.
    check(UsageChart.tooltipOrigin(pointer: UsageChartPoint(x: 100, y: 30), tooltipWidth: 144, tooltipHeight: 80,
                                   plotWidth: 200, plotHeight: 100) == UsageChartPoint(x: 0, y: 0),
          "T3 UsageProviderChart.tsx:329-330: a flipped tooltip never starts left of or above the plot")
}
usageChecks40()

func usageChecks41() {
    // usageFormat.test.ts "usage source messages". T3 passes the server text through; this app
    // maps a category word to its own sentence, so the wording differs and the selection must not.
    let source = { (provider: String, status: String, malformed: Int, message: Any) -> [String: Any] in
        ["provider": provider, "status": status, "scannedFiles": 1, "skippedFiles": 0, "malformedRecords": malformed,
         "distinctSessions": 1, "message": message]
    }
    let warnings = { (sources: [[String: Any]]) -> [String] in
        UsagePeriod(json: ["resolution": "day", "sinceDay": "2026-11-13", "untilDay": "2026-11-19", "sources": sources]).warnings()
    }
    let none = NSNull()
    // :71-77 "uses the largest count when connected environments report the same source"
    check(warnings([source("codex", "partial", 1, none), source("codex", "partial", 11, none), source("codex", "partial", 1, none)])
            == ["11 malformed or inconsistent usage record(s) were skipped; usage may be incomplete."],
          "T3 usageFormat.test.ts:71-77: one source reported three times counts its largest figure, not the sum")
    // :79-99 "retains other diagnostics beside the combined warning"
    check(warnings([source("codex", "partial", 1, "read_failed"), source("codex", "partial", 0, "read_failed")])
            == ["Some Codex transcripts could not be read; usage may be incomplete.",
                "1 malformed or inconsistent usage record(s) were skipped; usage may be incomplete."],
          "T3 usageFormat.test.ts:79-99: a read failure is kept beside the skipped-records warning, each said once")
    // :101-117 "includes cached diagnostics when a transcript directory is missing"
    check(warnings([source("codex", "partial", 1, none), source("claude", "missing", 2, "no_history"),
                    source("claude", "missing", 2, "no_history")])
            == ["No Claude transcript directory was found on this Mac.",
                "3 malformed or inconsistent usage record(s) were skipped; usage may be incomplete."],
          "T3 usageFormat.test.ts:101-117: a missing source listed twice is counted once")
}
usageChecks41()

// Added by the independent verifier after its own mutation probes: six rules of T3 that the model
// follows but no check above would have noticed breaking. Expected values are T3's own output.
func usageChecks42() {
    let bucket = { (overrides: [String: Any]) -> [String: Any] in
        var base: [String: Any] = [
            "day": "2026-08-07", "provider": "claude", "model": "claude-fable-5",
            "totals": ["uncachedInputTokens": 100, "cachedInputTokens": 1000, "cacheCreationTokens": 10,
                       "outputTokens": 50, "reasoningTokens": 0],
            "costUsd": 10, "cacheSavingsUsd": 2, "costSource": "modelPriced",
            "records": 5, "unpricedRecords": 0, "sessions": 1,
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }
    let source = { (provider: String) -> [String: Any] in
        ["provider": provider, "status": "ok", "scannedFiles": 1, "skippedFiles": 0, "malformedRecords": 0,
         "distinctSessions": 1, "message": NSNull()]
    }
    let period = { (resolution: String, buckets: [[String: Any]], sources: [[String: Any]]) -> UsagePeriod in
        UsagePeriod(json: ["resolution": resolution, "sinceDay": "2026-08-01", "untilDay": "2026-08-31",
                           "sinceTime": "2026-08-06T12:37:00.000Z", "untilTime": "2026-08-07T12:37:00.000Z",
                           "buckets": buckets, "sources": sources])
    }

    // usageMerge.ts:550, :565 — cost without a single token: token shares are 0, not 0/0.
    let noTokens: [String: Any] = ["uncachedInputTokens": 0, "cachedInputTokens": 0, "cacheCreationTokens": 0,
                                   "outputTokens": 0, "reasoningTokens": 0]
    let costOnly = UsageTotals(period: period("day", [bucket(["costUsd": 3, "totals": noTokens])], [source("claude")]))
    check(costOnly.totalTokens == 0 && costOnly.providers.first?.tokenShare == 0 && costOnly.providers.first?.costShare == 1
            && costOnly.models.first?.tokenShare == 0 && costOnly.models.first?.costShare == 1,
          "T3 usageMerge.ts:550, :565: with no tokens at all every token share is 0, never NaN")

    // usageMerge.ts:569-576 — days are sorted, whatever order the buckets came in.
    let shuffled = UsageTotals(period: period("day", [bucket(["day": "2026-08-09", "costUsd": 1]), bucket(["day": "2026-08-03", "costUsd": 2]),
                                                      bucket(["day": "2026-08-06", "costUsd": 3])], [source("claude")]))
    check(shuffled.daily.map { $0.day } == ["2026-08-03", "2026-08-06", "2026-08-09"] && shuffled.daily.map { $0.costUsd } == [2, 3, 1],
          "T3 usageMerge.ts:569-576: days come out oldest first even when the buckets do not")

    // usageMerge.ts:518-536, :578-580 — an hour row is keyed by its hour start, not by its day.
    let hours = UsageTotals(period: period("hour", [
        bucket(["hourStart": "2026-08-07T11:37:00.000Z", "costUsd": 1]),
        bucket(["hourStart": "2026-08-07T09:37:00.000Z", "costUsd": 2]),
        bucket(["provider": "codex", "model": "gpt-5.6-sol", "hourStart": "2026-08-07T09:37:00.000Z", "costUsd": 4]),
    ], [source("claude"), source("codex")]))
    check(hours.hourly.map { $0.hourStart } == ["2026-08-07T09:37:00.000Z", "2026-08-07T11:37:00.000Z"]
            && hours.hourly.map { $0.costUsd } == [6, 1] && hours.hourly.map { $0.totalTokens } == [2320, 1160]
            && hours.hourly.first?.byProvider["claude"]?.costUsd == 2 && hours.hourly.first?.byProvider["codex"]?.costUsd == 4
            && hours.hourly.last?.byProvider["codex"] == nil,
          "T3 usageMerge.ts:518-536: two hours of one day are two rows, oldest first, each with its own providers")
    check(hours.daily.map { $0.day } == ["2026-08-07"] && hours.daily.first?.costUsd == 7,
          "T3 usageMerge.ts:505-516: and the same buckets are one row of that day")

    // UsagePage.tsx:879 and UsageModelDialog.tsx:135 — ultrafast alone is enough for the speed bar.
    let ultrafast = UsageTotals(period: period("day", [bucket(["ultrafastCostUsd": 4, "speedPremiumUsd": 1.5])], [source("claude")]))
    check(ultrafast.speedCost.hasFastTiers && ultrafast.speedCost.fast == 0 && ultrafast.speedCost.ultrafast == 4
            && ultrafast.speedCost.standard == 6 && ultrafast.speedCost.premium == 1.5,
          "T3 UsagePage.tsx:879: cost by speed is shown when only the ultrafast tier was used")

    // UsageProviderChart.tsx:184-186 — the placeholder grid is for a loading chart with NO data.
    let chartPeriod = period("day", [bucket([:])], [source("claude")])
    let loadingWithData = UsageChartData(period: chartPeriod, totals: UsageTotals(period: chartPeriod), metric: .cost,
                                         providers: ["claude"], loading: true)
    check(loadingWithData.scale.labeled && loadingWithData.scale.max == 10 && loadingWithData.scale.ticks == [0, 5, 10],
          "T3 UsageProviderChart.tsx:184: a chart that is loading but already has figures keeps its real, labelled scale")
}
usageChecks42()

func usageChecks43() {
    // UsageProviderChart.tsx:92-96 — where the line turns, the tangent is flat even when the two
    // slopes are unequal (4 up, 1 down), so the curve does not rise past the turning point.
    let point = { (x: Double, y: Double) in UsageChartPoint(x: x, y: y) }
    let near = { (a: UsageChartPoint, b: UsageChartPoint) in abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }
    let turn = UsageChart.curve([point(0, 0), point(1, 4), point(2, 3)])
    check(turn.count == 2 && near(turn[0].c1, point(1.0 / 3, 4.0 / 3)) && near(turn[0].c2, point(2.0 / 3, 4))
            && near(turn[1].c1, point(4.0 / 3, 4)) && near(turn[1].c2, point(5.0 / 3, 10.0 / 3)),
          "T3 UsageProviderChart.tsx:95: an uneven turn still gets a flat tangent, got \(turn.map { [$0.c1, $0.c2] })")
    // The same in plot coordinates: a spike to the top of the plot between two days near zero.
    let spike = UsageChart.curve([point(0, 260), point(10, 8), point(20, 200), point(30, 260)])
    check(spike.count == 3 && near(spike[0].c1, point(10.0 / 3, 176)) && near(spike[0].c2, point(20.0 / 3, 8))
            && near(spike[1].c1, point(40.0 / 3, 8)) && near(spike[1].c2, point(50.0 / 3, 158))
            && near(spike[2].c1, point(70.0 / 3, 242)) && near(spike[2].c2, point(80.0 / 3, 240)),
          "T3 UsageProviderChart.tsx:78-143: a spike keeps T3's control points and never leaves the plot")
}
usageChecks43()

// Custom model prices and "Map to" (Sources/Model/UsagePricesModel.swift).
// Vectors come from T3 Code's usagePriceForm.test.ts, usagePriceTable.test.ts,
// usagePriceTargets.test.ts, settings.test.ts and usageAggregation.test.ts (commit 803f21f).

// usagePriceForm.test.ts: reading the four cells of one row.
func usageChecks44() {
    let parsed = UsagePrice(cells: [.input: "2", .output: "8", .cacheRead: "0", .cacheWrite: " "])
    check(parsed?.rates == [.input: 2, .output: 8, .cacheRead: 0],
          "prices: an explicit 0 is a free cache rate and a blank one is left out")

    let small = UsagePrice([.input: 0, .output: 8, .cacheRead: 0.0000001, .cacheWrite: 3.5])
    check(small?.cells == [.input: "0", .output: "8", .cacheRead: "1e-7", .cacheWrite: "3.5"],
          "prices: saved rates are shown the way T3 shows them")
    check(small != nil && UsagePrice(cells: small?.cells ?? [:]) == small,
          "prices: showing a price and reading it back keeps every rate, small ones too")

    let rejected = ["", " ", "-1", "Infinity", "NaN", "1e999", "$2", "0x10", "1,2,3", "1.2,3", "1,2.3"]
    check(rejected.allSatisfy { UsagePrice(cells: [.input: $0, .output: "8"]) == nil },
          "prices: a required price that is not a finite non-negative number is rejected")
    check(["٣", "+2", "2 5", "1e", "e5", ".", "1.2.3", "inf", "nan", "0x1p3"].allSatisfy {
        UsagePrice(cells: [.input: $0, .output: "8"]) == nil
    }, "prices: other digits, signs and unfinished numbers are not prices")

    check(UsagePrice(cells: [.input: "2,5", .output: "0,075"])?.rates == [.input: 2.5, .output: 0.075],
          "prices: a comma is read as the decimal point")
    check(UsagePrice(cells: [.input: " 2. ", .output: ".5", .cacheRead: "1E-7", .cacheWrite: "1.e3"])?.rates
            == [.input: 2, .output: 0.5, .cacheRead: 1e-7, .cacheWrite: 1000],
          "prices: every number shape JavaScript accepts is read the same way")
    check(UsagePrice(cells: [.input: "1e-999", .output: "8"])?.rates[.input] == 0,
          "prices: a number too small to store is zero, as in JavaScript")
    check(UsagePrice(cells: [.input: "2"]) == nil && UsagePrice(cells: [.output: "8"]) == nil,
          "prices: input and output are both required")
    // mcpbar_usage.py drops a custom price above its rate-table ceiling (100 USD per token).
    check(UsagePrice(cells: [.input: "1e8", .output: "100000000"])?.rates == [.input: 1e8, .output: 1e8]
            && ["100000001", "1e9", "1e308"].allSatisfy { UsagePrice(cells: [.input: "2", .output: "8", .cacheWrite: $0]) == nil },
          "prices: a rate above 100000000 per million tokens is rejected, as the usage script does")
}
usageChecks44()

// usagePriceForm.test.ts: what may be typed into a price cell.
func usageChecks45() {
    let edit = UsagePrice.acceptsEdit
    check(edit("", "2,5") && edit("", ",5"), "typing: a decimal comma is allowed")
    check(!edit("", "1,2,3") && !edit("1,2", "1,2.3"), "typing: a second decimal mark is refused")
    var everyPrefix = true
    for value in ["2,5", ",5", "0,075", "1,5e-7"] {
        let units = Array(value.utf16)
        for end in 1...units.count {
            let previous = String(decoding: units[..<(end - 1)], as: UTF16.self)
            let next = String(decoding: units[..<end], as: UTF16.self)
            if !edit(previous, next) { everyPrefix = false }
        }
    }
    check(everyPrefix, "typing: a number can be typed one character at a time")
    check(edit("1e-7", "e-7") && edit("1e-7", "1-7"), "typing: deleting part of a price is never blocked")
    check(!edit("1e-7", "a7") && !edit("2.5", "x") && !edit("123456", "1.2.3"),
          "typing: replacing a price with a non-number is blocked")
    check(edit("", " 2.5 ") && edit("2", "2E") && edit("2E", "2E+") && edit("2", ""),
          "typing: spaces around, a capital exponent and clearing the cell are allowed")
    check(!edit("", "٣") && !edit("2", "2٣") && !edit("", "-1") && !edit("", "$"),
          "typing: non-ASCII digits, signs and symbols are refused")
    check(!edit("12", "1x") && !edit("12", "x2") && edit("12", "1") && edit("12", "2"),
          "typing: a same-length or shorter replacement only passes when it is a pure deletion")
}
usageChecks45()

// The chosen normalisation: a rate is shown exactly as JavaScript's Number.prototype.toString
// prints it (values below were printed by node 26), so a cell nobody touched reads back as the
// saved value and the file carries the same number text T3's settings.json would.
func usageChecks46() {
    let vectors: [(Double, String)] = [
        (0, "0"), (2, "2"), (8, "8"), (3.5, "3.5"), (0.075, "0.075"), (2.5, "2.5"), (0.1, "0.1"),
        (0.1 + 0.2, "0.30000000000000004"), (1e-7, "1e-7"), (1.5e-7, "1.5e-7"), (0.000001, "0.000001"),
        (0.0000015, "0.0000015"), (0.00000123, "0.00000123"), (9.999999e-7, "9.999999e-7"),
        (1e21, "1e+21"), (1e20, "100000000000000000000"), (1.2345678901234568e20, "123456789012345680000"),
        (9.999999999999999e20, "999999999999999900000"), (1.2345678901234568e21, "1.2345678901234568e+21"),
        (1e22, "1e+22"), (1e16, "10000000000000000"), (9007199254740992.0, "9007199254740992"),
        (100, "100"), (1000000, "1000000"), (0.5, "0.5"), (15, "15"), (15.75, "15.75"),
        (1.0 / 3.0, "0.3333333333333333"), (4.35, "4.35"), (0.000001234, "0.000001234"),
        (123456.789, "123456.789"), (5e-324, "5e-324"), (2.2250738585072014e-308, "2.2250738585072014e-308"),
        (1.7976931348623157e308, "1.7976931348623157e+308"),
    ]
    let wrong = vectors.filter { UsagePrice.text($0.0) != $0.1 }.map { "\($0.1) came out as \(UsagePrice.text($0.0))" }
    check(wrong.isEmpty, "number text: rates print like JavaScript numbers \(wrong)")
    check(vectors.allSatisfy { UsagePrice.number(UsagePrice.text($0.0)) == $0.0 },
          "number text: the shown text reads back as the same number")
    check(UsagePrice.text(-0.0) == "0" && UsagePrice.text(-2.5) == "-2.5",
          "number text: negative zero is 0 and a sign is kept")
    check(UsagePrice.text(.nan) == "NaN" && UsagePrice.text(.infinity) == "Infinity"
            && UsagePrice.text(-.infinity) == "-Infinity",
          "number text: non-numbers print without a crash")
}
usageChecks46()

// usagePriceTable.test.ts: turning the edited rows into changes.
func usageChecks47() {
    let price = UsagePrice([.input: 2, .output: 8])!
    func settings(_ prices: [String: UsagePrice], _ aliases: [String: String] = [:]) -> UsagePriceSettings {
        var settings = UsagePriceSettings()
        settings.prices = prices
        settings.aliases = aliases
        return settings
    }
    func draft(_ values: [UsagePriceField: String]) -> UsagePriceDraft {
        UsagePriceDraft(id: "model:example", model: "example", isNew: false, values: values)
    }

    for model in ["constructor", "toString", "__proto__"] {
        let typed = UsagePriceDraft(id: "new:0", model: model, isNew: true, values: [.input: "2", .output: "8"])
        let plan = UsagePricePlan(saved: settings([:]), drafts: [typed])
        check(plan.changes == [.price(model, price)] && plan.errors.isEmpty,
              "plan: a model named \(model) is priced like any other")
        check(UsagePriceEditor(saved: settings([model: price])).rows.first?.prices[.input]?.value == "2",
              "plan: the saved price of a model named \(model) is shown")
    }

    let edits = [draft([.input: "3"])]
    let withCache = UsagePrice([.input: 2, .output: 8, .cacheRead: 0])!
    check(UsagePricePlan(saved: settings(["example": withCache, "untouched": price]), drafts: edits).changes
            == [.price("example", UsagePrice([.input: 3, .output: 8, .cacheRead: 0])!)],
          "plan: editing one column keeps the other columns and the other models")
    check(UsagePricePlan(saved: settings(["example": UsagePrice([.input: 2, .output: 10])!]), drafts: edits).changes
            == [.price("example", UsagePrice([.input: 3, .output: 10])!)],
          "plan: the untouched output rate is the saved one")

    var reset = draft([:])
    reset.removed = true
    let added = UsagePriceDraft(id: "new:1", model: "  vendor/Model  ", isNew: true,
                                values: [.input: "2", .output: "8", .cacheRead: "0", .cacheWrite: ""])
    let batch = UsagePricePlan(saved: settings(["example": price]), drafts: [reset, added])
    check(batch.errors.isEmpty && batch.changes == [.price("example", nil), .price("vendor/Model", withCache)],
          "plan: a reset and a new row go into one batch, with a blank cache rate left out")

    check(UsagePricePlan(saved: settings(["example": price]), drafts: edits).errors.isEmpty,
          "plan: one edited rate is enough on a model that already has a price")
    let missing = UsagePricePlan(saved: settings([:]), drafts: edits)
    check(missing.changes.isEmpty && missing.errors == ["model:example": "Output is required."],
          "plan: a model without a price needs both required rates")
    check(UsagePricePlan(saved: settings([:]), drafts: [draft([.output: "8"])]).errors
            == ["model:example": "Input is required."],
          "plan: the first missing required rate is named")
    check(UsagePricePlan(saved: settings([:]), drafts: [draft([.input: "x", .output: "8"])]).errors
            == ["model:example": "Use non-negative numbers up to 100000000 for prices."],
          "plan: a rate that is not a number is reported as such")
    check(UsagePricePlan(saved: settings([:]), drafts: [draft([.input: "1e9", .output: "8"])]).errors
            == ["model:example": "Use non-negative numbers up to 100000000 for prices."],
          "plan: a rate above the ceiling is reported with the same message")

    var mapping = draft([:])
    mapping.alias = " example-model "
    let mappedPlan = UsagePricePlan(saved: settings(["example": price]), drafts: [mapping])
    check(mappedPlan.changes == [.alias("example", "example-model"), .price("example", nil)] && mappedPlan.errors.isEmpty,
          "plan: mapping a model drops its own price")
    let mapped = settings([:], ["example": "example-model"])
    check(UsagePricePlan(saved: mapped, drafts: [reset]).changes == [.alias("example", nil)],
          "plan: resetting a mapped model removes the mapping")
    var selfMap = draft([:])
    selfMap.alias = "example"
    check(UsagePricePlan(saved: mapped, drafts: [selfMap]).errors == ["model:example": "Map to a different model."],
          "plan: a model cannot be mapped to itself")

    let priced = draft([.input: "3", .output: "8"])
    let blocked = UsagePricePlan(saved: mapped, drafts: [priced])
    check(blocked.changes.isEmpty && blocked.errors == ["model:example": "This model is mapped. Clear its mapping first."],
          "plan: a price edit on a model that is still mapped is refused")
    var cleared = priced
    cleared.alias = ""
    let next = UsagePrice([.input: 3, .output: 8])!
    let clearedPlan = UsagePricePlan(saved: mapped, drafts: [cleared])
    check(clearedPlan.errors.isEmpty && clearedPlan.changes == [.alias("example", nil), .price("example", next)],
          "plan: clearing the mapping and typing a price saves both")
    check(UsagePricePlan(saved: settings(["example": price]), drafts: [cleared]).changes == [.price("example", next)],
          "plan: a blank mapping on an unmapped model only changes the price")
    var onlyCleared = draft([:])
    onlyCleared.alias = " "
    let onlyClearedPlan = UsagePricePlan(saved: mapped, drafts: [onlyCleared])
    check(onlyClearedPlan.errors.isEmpty && onlyClearedPlan.changes == [.alias("example", nil)],
          "plan: clearing a mapping without typing a price returns the model to automatic pricing")

    var unchanged = draft([.input: "2.0", .output: "8e0"])
    check(UsagePricePlan(saved: settings(["example": price]), drafts: [unchanged]).changes.isEmpty,
          "plan: retyping the same rates in another spelling is not a change")
    unchanged.values = [.cacheRead: "2"]
    check(UsagePricePlan(saved: settings(["example": price]), drafts: [unchanged]).changes
            == [.price("example", UsagePrice([.input: 2, .output: 8, .cacheRead: 2])!)],
          "plan: a cache rate equal to the input rate is still an explicit rate")

    let blank = UsagePriceDraft(id: "new:2", model: " ", isNew: true, values: [.input: " "])
    check(blank.isEmpty && UsagePricePlan(saved: mapped, drafts: [blank]) == UsagePricePlan(saved: mapped, drafts: []),
          "plan: an untouched new row is ignored")
    let nameless = UsagePriceDraft(id: "new:3", model: " ", isNew: true, values: [.input: "2", .output: "8"])
    check(UsagePricePlan(saved: mapped, drafts: [nameless]).errors == ["new:3": "Enter a model ID."],
          "plan: prices without a model ID are refused")
    var namelessMapping = UsagePriceDraft(id: "new:4", model: "", isNew: true)
    namelessMapping.alias = "target"
    check(UsagePricePlan(saved: mapped, drafts: [namelessMapping]).errors == ["new:4": "Enter a model ID."],
          "plan: a mapping without a model ID is refused")
}
usageChecks47()

// usagePriceTable.test.ts: mappings must not form a cycle after the whole batch is applied.
func usageChecks48() {
    func settings(_ aliases: [String: String]) -> UsagePriceSettings {
        var settings = UsagePriceSettings()
        settings.aliases = aliases
        return settings
    }
    func mapping(_ model: String, _ alias: String) -> UsagePriceDraft {
        var draft = UsagePriceDraft(id: "model:\(model)", model: model, isNew: false)
        draft.alias = alias
        return draft
    }
    let cycle = "Model mappings cannot form a cycle."

    let ring = UsagePricePlan(saved: settings([:]), drafts: [mapping("a", "b"), mapping("b", "c"), mapping("c", "a")])
    check(ring.errors == ["model:a": cycle, "model:b": cycle, "model:c": cycle],
          "cycles: a ring typed in one save flags every row in it")

    let closing = [mapping("c", "a")]
    check(UsagePricePlan(saved: settings(["a": "b"]), drafts: closing).errors.isEmpty,
          "cycles: extending a saved chain is fine")
    check(UsagePricePlan(saved: settings(["a": "b", "b": "c"]), drafts: closing).errors == ["model:c": cycle],
          "cycles: a mapping that closes a saved chain is refused")

    let saved = settings(["constructor": "__proto__"])
    let clear = mapping("constructor", "")
    let reverse = mapping("__proto__", "constructor")
    for edits in [[reverse, clear], [clear, reverse]] {
        let plan = UsagePricePlan(saved: saved, drafts: edits)
        let expected = edits.map { UsagePriceChange.alias($0.model, ($0.alias ?? "").isEmpty ? nil : $0.alias) }
        check(plan.errors.isEmpty && plan.changes == expected,
              "cycles: a mapping can be reversed in one save when \(edits[0].model) comes first")
        check(saved.applying(plan.changes).resolvedAliases == ["__proto__": "constructor"],
              "cycles: the reversed mapping resolves after saving when \(edits[0].model) comes first")
    }

    // usageAggregation.test.ts: the same resolution Python applies while counting.
    let tangled = settings([
        "preview[1m]": "preview", "preview": "example-model", "shared": "preview",
        "intoLoop": "loop", "loop": "back", "back": "loop", "laterIntoLoop": "back",
        "deepIntoLoop": "intoLoop", "self": "self", "validAfterLoops": "shared",
    ])
    check(tangled.resolvedAliases == ["preview[1m]": "example-model", "preview": "example-model",
                                      "shared": "example-model", "validAfterLoops": "example-model"],
          "resolution: chains end at the final model, and anything that loops stays itself")
    check(settings([:]).resolvedAliases.isEmpty && settings(["a": "b"]).resolvedAliases == ["a": "b"],
          "resolution: no mappings and one mapping resolve as written")
    var long: [String: String] = [:]
    for step in 0..<20_000 { long["m\(step)"] = "m\(step + 1)" }
    let resolvedLong = settings(long).resolvedAliases
    check(resolvedLong.count == 20_000 && resolvedLong["m0"] == "m20000",
          "resolution: a very long chain resolves without slowing to a crawl")

    // Whatever the plan accepts must also survive resolution, or the UI would save a mapping
    // that the cost calculation then ignores.
    let accepted = UsagePricePlan(saved: settings(["a": "b", "x": "y"]), drafts: [mapping("b", "c"), mapping("y", "z")])
    let after = settings(["a": "b", "x": "y"]).applying(accepted.changes)
    check(accepted.errors.isEmpty && after.resolvedAliases == ["a": "c", "b": "c", "x": "z", "y": "z"],
          "resolution: every mapping the plan accepts is in effect after saving")
}
usageChecks48()

// usagePriceTargets.test.ts and serverSettings.test.ts, for the one file of this machine.
func usageChecks49() {
    let price = UsagePrice([.input: 2, .output: 8])!
    var saved = UsagePriceSettings()
    saved.prices = ["example": price]

    let batch = saved.applying([.price("new-model", price), .price("example", nil)])
    check(batch.prices == ["new-model": price] && batch.aliases.isEmpty,
          "apply: one batch adds a price and removes another")
    let mapped = saved.applying([.alias("example", "example-model"), .price("example", nil)])
    check(mapped.prices.isEmpty && mapped.aliases == ["example": "example-model"],
          "apply: a mapping is saved beside the price it replaces")
    check(saved.applying([]) == saved, "apply: no changes leave the settings as they were")

    var rich = UsagePriceSettings()
    rich.prices = ["a": UsagePrice([.input: 1, .output: 2, .cacheRead: 0.5])!, "b": price]
    rich.aliases = ["old": "a", "older": "old"]
    let merged = rich.applying([.price("a", price), .alias("old", nil), .alias("older", "b")])
    check(merged.prices == ["a": price, "b": price] && merged.aliases == ["older": "b"],
          "apply: a new price replaces the whole entry, a removal deletes it, the rest stays")
}
usageChecks49()

// Reading usage/prices.json with T3's schema rules.
func usageChecks50() {
    func parse(_ text: String) -> UsagePriceSettings { UsagePriceSettings(data: Data(text.utf8)) }
    let brief = parse("""
        {"usagePriceOverrides": {"glm-5.3": {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8,
        "cacheReadCostPerMillionTokens": 0, "cacheWriteCostPerMillionTokens": 1}},
        "usageModelAliases": {"drift-9": "orbit-1"}}
        """)
    check(brief.prices == ["glm-5.3": UsagePrice([.input: 2, .output: 8, .cacheRead: 0, .cacheWrite: 1])!]
            && brief.aliases == ["drift-9": "orbit-1"],
          "file: the contract example is read in full")

    let valid = #""ok": {"inputCostPerMillionTokens": 0.1, "outputCostPerMillionTokens": 8.5, "extra": "ignored"}"#
    let bad = [
        #"" ": {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8}"#,
        #""only-input": {"inputCostPerMillionTokens": 2}"#,
        #""only-output": {"outputCostPerMillionTokens": 8}"#,
        #""negative": {"inputCostPerMillionTokens": -1, "outputCostPerMillionTokens": 8}"#,
        #""text": {"inputCostPerMillionTokens": "2", "outputCostPerMillionTokens": 8}"#,
        #""flag": {"inputCostPerMillionTokens": true, "outputCostPerMillionTokens": 8}"#,
        #""null-rate": {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": null}"#,
        #""null-cache": {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8, "cacheReadCostPerMillionTokens": null}"#,
        #""bad-cache": {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8, "cacheWriteCostPerMillionTokens": -0.5}"#,
        #""list": [2, 8]"#,
        #""number": 2"#,
        #""nothing": null"#,
    ]
    let expected = ["ok": UsagePrice([.input: 0.1, .output: 8.5])!]
    for entry in bad {
        let model = entry.split(separator: "\"").first.map(String.init) ?? ""
        check(parse("{\"usagePriceOverrides\": {\(entry), \(valid)}}").prices == expected,
              "file: the invalid price entry '\(model)' is dropped and its valid neighbour is kept")
    }
    check(parse(#"{"usagePriceOverrides": {" vendor/example-model[1m] ": {"inputCostPerMillionTokens": 0, "outputCostPerMillionTokens": 0}}}"#)
            .prices == ["vendor/example-model[1m]": UsagePrice([.input: 0, .output: 0])!],
          "file: a model ID is trimmed and a zero price is kept")

    let aliases = parse(#"{"usageModelAliases": {" old ": " new ", "blank": " ", " ": "x", "n": 5, "l": ["a"], "o": {"a": "b"}, "z": null, "t": true}}"#)
    check(aliases.aliases == ["old": "new"] && aliases.prices.isEmpty,
          "file: mappings are trimmed, and blank or non-text ones are dropped")

    let empty = UsagePriceSettings()
    let hostile = [
        "", " ", "null", "true", "7", "\"text\"", "[]", "[{\"usagePriceOverrides\": {}}]", "{", "{\"usagePriceOverrides\":",
        "{\"usagePriceOverrides\": [], \"usageModelAliases\": \"x\"}", "{\"usagePriceOverrides\": null, \"usageModelAliases\": 3}",
        "{\"usagePriceOverrides\": {\"m\": {\"inputCostPerMillionTokens\": NaN, \"outputCostPerMillionTokens\": 8}}}",
        "{\"usagePriceOverrides\": {\"m\": {\"inputCostPerMillionTokens\": 1e400, \"outputCostPerMillionTokens\": 8}}}",
        "{\"usagePriceOverrides\": {\"m\": {\"inputCostPerMillionTokens\": Infinity, \"outputCostPerMillionTokens\": 8}}}",
        "\u{FEFF}\u{0}\u{1}garbage",
        String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000),
        String(repeating: "{\"usagePriceOverrides\":", count: 50_000),
    ]
    check(hostile.allSatisfy { parse($0) == empty }, "file: broken or wrongly shaped files mean no custom prices")
    check(UsagePriceSettings(data: nil) == empty && UsagePriceSettings(data: Data([0xFF, 0xFE, 0x00, 0xC3])) == empty
            && UsagePriceSettings(json: nil) == empty && UsagePriceSettings(json: ["usagePriceOverrides": ["m": NSNull()]]) == empty,
          "file: a missing file and bytes that are not text mean no custom prices")
    let huge = parse("{\"usagePriceOverrides\": {\"big\": {\"inputCostPerMillionTokens\": 123456789012345678901234567890, \"outputCostPerMillionTokens\": 1e308}}}")
    check(huge.prices["big"]?.rates == [.input: 1.2345678901234568e29, .output: 1e308],
          "file: very large finite numbers are kept as they are")
    let composed = parse("{\"usageModelAliases\": {\"caf\\u00e9\": \"a\", \"cafe\\u0301\": \"b\", \"plain\": \"c\"}}")
    check(composed.aliases["plain"] == "c" && composed.aliases.count == 2,
          "file: two spellings of one accented model ID do not crash the reader")
    var many = "{\"usagePriceOverrides\": {"
    many += (0..<20_000).map { "\"model-\($0)\": {\"inputCostPerMillionTokens\": \($0), \"outputCostPerMillionTokens\": 8}" }.joined(separator: ",")
    many += "}}"
    check(parse(many).prices.count == 20_000, "file: a very large table is read in full")
}
usageChecks50()

// Writing usage/prices.json: T3's key names, a fixed order, numbers as JavaScript prints them.
func usageChecks51() {
    var settings = UsagePriceSettings()
    settings.prices = [
        "glm-5.3": UsagePrice([.input: 2, .output: 8, .cacheRead: 0])!,
        "vendor/Model": UsagePrice([.input: 0.1, .output: 1e-7, .cacheRead: 3.5, .cacheWrite: 1e21])!,
    ]
    settings.aliases = ["old": "new"]
    let text = String(decoding: settings.serialized(), as: UTF8.self)
    let expected = #"{"usagePriceOverrides":{"glm-5.3":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":8,"# +
        #""cacheReadCostPerMillionTokens":0},"vendor/Model":{"inputCostPerMillionTokens":0.1,"# +
        #""outputCostPerMillionTokens":1e-7,"cacheReadCostPerMillionTokens":3.5,"cacheWriteCostPerMillionTokens":1e+21}},"# +
        #""usageModelAliases":{"old":"new"}}"#
    check(text == expected, "write: the file uses T3's key names and number text")
    check(String(decoding: UsagePriceSettings().serialized(), as: UTF8.self) == #"{"usagePriceOverrides":{},"usageModelAliases":{}}"#,
          "write: empty settings are two empty tables")

    var ordered = UsagePriceSettings()
    let price = UsagePrice([.input: 1, .output: 1])!
    for model in ["b", "a", "é", "B", "a10", "a9", "\u{1F600}", "\u{FF5E}"] { ordered.prices[model] = price }
    var reversed = UsagePriceSettings()
    for model in ["\u{FF5E}", "\u{1F600}", "a9", "a10", "B", "é", "a", "b"] { reversed.prices[model] = price }
    check(ordered.serialized() == reversed.serialized(), "write: the bytes do not depend on the order of insertion")
    // JavaScript sorts by UTF-16 code units: the emoji (a surrogate pair, D83D…) sorts before U+FF5E.
    check(ordered.customModels == ["B", "a", "a10", "a9", "b", "é", "\u{1F600}", "\u{FF5E}"],
          "write: model IDs are ordered like JavaScript's default sort")
    let positions = ordered.customModels.compactMap { String(decoding: ordered.serialized(), as: UTF8.self).range(of: "\"\($0)\":")?.lowerBound }
    check(positions.count == 8 && positions == positions.sorted(), "write: models are written in that order")

    var awkward = UsagePriceSettings()
    let rates: [Double] = [0, 0.1, 0.1 + 0.2, 1e-7, 5e-324, 1.7976931348623157e308, 1.0 / 3.0, 0.075, 1e21, 123456.789,
                           2.2250738585072014e-308, 9007199254740992.0, 4.35, 0.000001234]
    for (index, rate) in rates.enumerated() {
        awkward.prices["m\(index)"] = UsagePrice([.input: rate, .output: rate, .cacheRead: rate, .cacheWrite: rate])
    }
    for model in ["quote\"d", "back\\slash", "new\nline", "tab\tbed", "nul\u{0}x", "esc\u{1B}", "slash/es", "ünï©ödé", "日本語",
                  "\u{1F600}", "line\u{2028}sep", "constructor", "__proto__", "a b", "{\"x\":1}", "'", "del\u{7F}"] {
        awkward.prices[model] = UsagePrice([.input: 1, .output: 2])
        awkward.aliases[model + "-source"] = model
    }
    let once = awkward.serialized()
    let reread = UsagePriceSettings(data: once)
    check(awkward.prices.count == rates.count + 17 && reread == awkward,
          "round trip: awkward numbers and model IDs come back unchanged")
    check(reread.serialized() == once, "round trip: writing what was read gives the same bytes")
    check((try? JSONSerialization.jsonObject(with: once)) != nil && !String(decoding: once, as: UTF8.self).contains("\\/"),
          "round trip: the file is plain JSON and slashes are left alone")

    let folder = NSTemporaryDirectory() + "acb-usage-prices-\(ProcessInfo.processInfo.processIdentifier)/"
    try? FileManager.default.removeItem(atPath: folder)
    let path = folder + "usage/prices.json"
    check(UsagePriceSettings.load(at: path) == UsagePriceSettings(), "disk: a new install has no custom prices")
    check((try? awkward.save(at: path)) != nil && UsagePriceSettings.load(at: path) == awkward,
          "disk: saved settings are read back unchanged")
    let fileMode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
    let folderMode = (try? FileManager.default.attributesOfItem(atPath: folder + "usage"))?[.posixPermissions] as? NSNumber
    check(fileMode?.intValue == 0o600 && folderMode?.intValue == 0o700,
          "disk: the file is private to the user, and so is a folder it had to create")
    check((try? FileManager.default.contentsOfDirectory(atPath: folder + "usage")) == ["prices.json"],
          "disk: no temporary file is left behind")
    check((try? settings.save(at: path)) != nil && UsagePriceSettings.load(at: path) == settings,
          "disk: a second save replaces the file")
    check((try? settings.save(at: path + "/impossible.json")) == nil && UsagePriceSettings.load(at: path) == settings,
          "disk: a failed save reports the error and leaves the file alone")
    try? FileManager.default.removeItem(atPath: folder)
}
usageChecks51()

// The editor: rows, cells and entry points (spec 05 §13.2–13.5).
func usageChecks52() {
    let price = UsagePrice([.input: 2, .output: 8])!
    var saved = UsagePriceSettings()
    saved.prices = ["zeta": price, "Alpha": UsagePrice([.input: 0, .output: 8, .cacheRead: 1e-7])!]
    saved.aliases = ["drift-9": "orbit-1", "zeta": "Alpha"]

    var editor = UsagePriceEditor(saved: saved)
    check(editor.rows.map(\.id) == ["model:Alpha", "model:drift-9", "model:zeta"] && !editor.hasChanges && !editor.canSave,
          "editor: saved prices and mappings are one sorted list, and nothing is pending")
    let alpha = editor.rows[0]
    check(alpha.model == "Alpha" && !alpha.isNew && !alpha.removed && alpha.countedAs.isEmpty && alpha.error == nil,
          "editor: a saved row starts clean")
    check(alpha.alias == UsagePriceCell(value: "", placeholder: "None"),
          "editor: an unmapped saved row offers 'None' in Map to")
    check(alpha.prices == [.input: UsagePriceCell(value: "0", placeholder: "0.00"),
                           .output: UsagePriceCell(value: "8", placeholder: "0.00"),
                           .cacheRead: UsagePriceCell(value: "1e-7", placeholder: "Input rate"),
                           .cacheWrite: UsagePriceCell(value: "", placeholder: "Input rate")],
          "editor: saved rates are shown, and a blank cache rate says it uses the input rate")
    check(editor.rows[1].countedAs == "orbit-1" && editor.rows[1].alias.value == "orbit-1",
          "editor: a mapped model is shown as counted under its target")
    check(UsagePriceEditor(saved: UsagePriceSettings()).rows.isEmpty, "editor: no settings means an empty table")

    // A cell put back to what is saved is no edit at all.
    check(editor.setPrice("0.5", .input, row: "model:Alpha") && editor.hasChanges && editor.canSave,
          "editor: typing a new rate makes the row pending")
    check(editor.rows[0].prices[.input]?.value == "0.5" && editor.rows[0].prices[.output]?.value == "8",
          "editor: the typed rate is shown beside the saved ones")
    check(editor.plan.changes == [.price("Alpha", UsagePrice([.input: 0.5, .output: 8, .cacheRead: 1e-7])!)],
          "editor: an untouched tiny rate is saved back bit for bit")
    check(editor.setPrice("0", .input, row: "model:Alpha") && !editor.hasChanges && editor.drafts.isEmpty,
          "editor: typing the saved rate again makes the row clean")
    check(editor.setPrice("1e-", .cacheRead, row: "model:Alpha") && editor.setPrice("1e-7", .cacheRead, row: "model:Alpha")
            && !editor.hasChanges,
          "editor: retyping a tiny saved rate as it is shown makes the row clean")
    check(!editor.setPrice("abc", .input, row: "model:Alpha") && !editor.hasChanges
            && editor.rows[0].prices[.input]?.value == "0",
          "editor: text that is not a number is not accepted into a price cell")
    check(!editor.setPrice("2", .input, row: "model:missing") && !editor.setPrice("2", .input, row: "new:9") && !editor.hasChanges,
          "editor: an edit to a row that does not exist changes nothing")

    editor.setAlias("orbit-2", row: "model:drift-9")
    check(editor.rows[1].countedAs == "orbit-2" && editor.plan.changes == [.alias("drift-9", "orbit-2")],
          "editor: a retyped mapping is pending")
    editor.setAlias("orbit-1", row: "model:drift-9")
    check(!editor.hasChanges, "editor: typing the saved mapping again makes the row clean")
    editor.setAlias("", row: "model:drift-9")
    check(editor.rows[1].countedAs.isEmpty && editor.rows[1].prices[.input] == UsagePriceCell(value: "", placeholder: "Automatic")
            && editor.rows[1].prices[.cacheRead]?.placeholder == "Automatic",
          "editor: with the mapping cleared the price cells come back and say 'Automatic'")
    check(editor.canSave && editor.plan.changes == [.alias("drift-9", nil)],
          "editor: a cleared mapping can be saved on its own")

    // The guard that one machine can still reach: clear the mapping, type a price, type the mapping back.
    check(editor.setPrice("3", .input, row: "model:drift-9") && editor.setPrice("9", .output, row: "model:drift-9"),
          "editor: prices can be typed once the mapping is cleared")
    editor.setAlias("orbit-1", row: "model:drift-9")
    check(editor.rows[1].error == "This model is mapped. Clear its mapping first." && !editor.canSave,
          "editor: typing the mapping back over fresh prices is flagged")
    editor.discard()
    check(!editor.hasChanges && editor.rows == UsagePriceEditor(saved: saved).rows, "editor: discarding restores the saved table")

    // Reset to automatic and its undo.
    editor.toggleRow("model:zeta")
    check(editor.rows[2].removed && editor.hasChanges && editor.canSave
            && editor.plan.changes == [.price("zeta", nil), .alias("zeta", nil)],
          "editor: a reset row loses its price and its mapping on save")
    check(editor.afterSave.prices.keys.sorted() == ["Alpha"] && editor.afterSave.aliases == ["drift-9": "orbit-1"],
          "editor: after saving a reset, only the other models remain in the file")
    editor.toggleRow("model:zeta")
    check(!editor.rows[2].removed && !editor.hasChanges, "editor: undoing a reset leaves no pending change")
    check(editor.setPrice("0.25", .input, row: "model:Alpha"), "editor: a rate is typed before a reset")
    editor.toggleRow("model:Alpha")
    check(editor.plan.changes == [.price("Alpha", nil)], "editor: a reset wins over edits typed in the same row")
    editor.toggleRow("model:Alpha")
    check(!editor.rows[0].removed && editor.rows[0].prices[.input]?.value == "0.25",
          "editor: undoing a reset brings the typed rate back")
    editor.discard()

    // New rows.
    let first = editor.addRow()
    let second = editor.addRow()
    check(first == "new:0" && second == "new:1" && editor.rows.map(\.id).suffix(2) == ["new:0", "new:1"],
          "editor: new rows follow the saved ones in the order they were added")
    check(!editor.hasChanges && !editor.canSave && editor.rows[3].error == nil,
          "editor: untouched new rows are not a change and show no error")
    check(editor.rows[3].alias.placeholder == "Optional"
            && editor.rows[3].prices[.input] == UsagePriceCell(value: "", placeholder: "0.00")
            && editor.rows[3].prices[.cacheWrite] == UsagePriceCell(value: "", placeholder: "Input rate"),
          "editor: a new row shows T3's placeholders")
    editor.setModel("glm-5.3", row: first)
    check(editor.hasChanges && !editor.canSave && editor.rows[3].error == nil && !editor.rows[3].modelInvalid,
          "editor: a new model without a price blocks saving but is not flagged yet")
    check(editor.setPrice("2", .input, row: first) && editor.rows[3].error == "Output is required." && editor.rows[3].modelInvalid,
          "editor: once a price is typed the missing rate is named")
    check(editor.setPrice("8", .output, row: first) && editor.canSave && editor.rows[3].error == nil
            && editor.plan.changes == [.price("glm-5.3", price)],
          "editor: a complete new row can be saved")
    editor.setModel("Alpha", row: second)
    check(editor.rows[4].error == "This model already has a row. Edit its prices there." && editor.rows[4].modelInvalid && !editor.canSave,
          "editor: a new row for a model that already has one is refused")
    editor.setModel(" glm-5.3 ", row: second)
    let duplicate = "This model already has a row. Edit its prices there."
    check(editor.rows[3].error == duplicate && editor.rows[4].error == duplicate,
          "editor: two new rows for one model are both refused")
    editor.setModel("", row: second)
    check(editor.setPrice("4", .input, row: second) && editor.rows[4].error == "Enter a model ID." && !editor.rows[4].modelInvalid,
          "editor: prices typed without a model ID ask for one")
    check(editor.setPrice("", .input, row: second), "editor: the price can be cleared again")
    editor.setAlias("orbit-1", row: second)
    check(editor.rows[4].error == nil && !editor.canSave && editor.rows[4].countedAs == "orbit-1",
          "editor: a mapping typed before the model ID blocks saving without a message")
    editor.setModel("Alpha", row: "model:zeta")
    check(editor.rows[2].model == "zeta", "editor: the model ID of a saved row cannot be retyped")
    editor.toggleRow(second)
    check(editor.rows.map(\.id) == ["model:Alpha", "model:drift-9", "model:zeta", "new:0"] && editor.canSave,
          "editor: removing a new row drops it and its error")
    check(editor.addRow() == "new:2", "editor: row numbers are never reused")

    check(editor.modelSuggestions(seen: ["claude-fable-5", "zeta", "gpt-6", "gpt-6", "Alpha"]) == ["claude-fable-5", "gpt-6"],
          "editor: models seen in usage that have no row are suggested as model IDs")
    check(editor.aliasSuggestions(seen: ["claude-fable-5", "zeta", "gpt-6"]) == ["Alpha", "claude-fable-5", "gpt-6"],
          "editor: any known model that is not itself mapped away is suggested as a target")
}
usageChecks52()

// The editor: "Set price" from an unpriced model, and saving (spec 05 §13.2, §13.7).
func usageChecks53() {
    let price = UsagePrice([.input: 2, .output: 8])!
    let folder = NSTemporaryDirectory() + "acb-usage-editor-\(ProcessInfo.processInfo.processIdentifier)/"
    try? FileManager.default.removeItem(atPath: folder)
    let path = folder + "usage/prices.json"
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: folder + "blocker", contents: Data())

    var editor = UsagePriceEditor(saved: UsagePriceSettings.load(at: path), settingPriceFor: "glm-5.3")
    check(editor.rows.count == 1 && editor.rows[0].id == "new:initial" && editor.rows[0].model == "glm-5.3" && editor.rows[0].isNew,
          "set price: the unpriced model arrives as a new row with its ID filled in")
    check(editor.rows[0].error == nil && !editor.rows[0].modelInvalid && !editor.canSave,
          "set price: the row waits for a price without an error, and saving is off")
    check(editor.setPrice("2", .input, row: "new:initial") && editor.rows[0].error == "Output is required." && !editor.canSave,
          "set price: after the first rate the missing one is named")
    check((try? editor.save(at: path)) != nil && !FileManager.default.fileExists(atPath: path) && editor.hasChanges,
          "set price: saving an invalid table writes nothing")
    check(editor.setPrice("8", .output, row: "new:initial") && editor.canSave && editor.afterSave.prices == ["glm-5.3": price],
          "set price: with both rates the file would gain the model")

    check((try? editor.save(at: folder + "blocker/prices.json")) == nil && editor.hasChanges && editor.saved == UsagePriceSettings()
            && editor.rows[0].prices[.output]?.value == "8",
          "save: a failed write keeps every typed value so it can be tried again")
    check((try? editor.save(at: path)) != nil && !editor.hasChanges && editor.saved.prices == ["glm-5.3": price],
          "save: a successful write clears the pending changes")
    check(editor.rows.map(\.id) == ["model:glm-5.3"] && editor.rows[0].prices[.input]?.value == "2",
          "save: the new model is now a saved row")
    check(UsagePriceSettings.load(at: path) == editor.saved, "save: the file holds what the table shows")

    // Retyping the saved values is a pending row but not a change: T3 reports it saved without writing.
    let stamp = Date(timeIntervalSince1970: 1_000_000_000)
    try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path)
    check(editor.setPrice("2.0", .input, row: "model:glm-5.3") && editor.canSave && editor.plan.changes.isEmpty,
          "save: another spelling of the saved rate is pending but changes nothing")
    let untouched = (try? editor.save(at: path)) != nil
        && ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) == stamp
    check(untouched && !editor.hasChanges && editor.rows[0].prices[.input]?.value == "2",
          "save: a save without changes leaves the file untouched and clears the row")

    for known in ["glm-5.3"] {
        check(UsagePriceEditor(saved: editor.saved, settingPriceFor: known).drafts.isEmpty,
              "set price: a model that already has a price opens on its saved row")
    }
    var mappedAway = UsagePriceSettings()
    mappedAway.aliases = ["glm-5.3": "glm-5"]
    check(UsagePriceEditor(saved: mappedAway, settingPriceFor: "glm-5.3").drafts.isEmpty,
          "set price: a model that is mapped away opens on its saved row")

    // Mapping a priced model away, then saving, leaves one entry in each table.
    editor.setAlias(" glm-5 ", row: "model:glm-5.3")
    check(editor.canSave && (try? editor.save(at: path)) != nil
            && UsagePriceSettings.load(at: path).prices.isEmpty && UsagePriceSettings.load(at: path).aliases == ["glm-5.3": "glm-5"],
          "save: mapping a priced model stores the mapping and removes its price")
    check(editor.rows.count == 1 && editor.rows[0].countedAs == "glm-5" && editor.rows[0].alias.value == "glm-5",
          "save: the row now shows where the model is counted")
    editor.toggleRow("model:glm-5.3")
    check((try? editor.save(at: path)) != nil && editor.rows.isEmpty
            && String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
                == #"{"usagePriceOverrides":{},"usageModelAliases":{}}"#,
          "save: resetting the last row leaves an empty, valid file")
    try? FileManager.default.removeItem(atPath: folder)
}
usageChecks53()

// Verifier: a long number literal must come back from the file as the double that was written.
// JSONSerialization hands such literals over as NSDecimalNumber, whose doubleValue can be one
// unit in the last place off (found by writing and re-reading 85193 doubles printed by node).
func usageChecks54() {
    let rates: [Double] = [0.002251941003853357, 0.00004244548459430076, 0.000002658841935363292,
                           0.0002310239046594789, 0.00009278559843078256, 0.0013014852537543515]
    var settings = UsagePriceSettings()
    for (index, rate) in rates.enumerated() {
        settings.prices["m\(index)"] = UsagePrice([.input: rate, .output: rate, .cacheRead: rate, .cacheWrite: rate])
    }
    let once = settings.serialized()
    let reread = UsagePriceSettings(data: once)
    let drifted = rates.indices.filter { reread.prices["m\($0)"]?.rates[.input]?.bitPattern != rates[$0].bitPattern }
    check(drifted.isEmpty, "round trip: a rate with many digits is read back bit for bit \(drifted.map { UsagePrice.text(rates[$0]) })")
    check(reread == settings && reread.serialized() == once,
          "round trip: saving a file that holds long rates does not change them")
    let long = UsagePriceSettings(data: Data(#"{"usagePriceOverrides":{"m":{"inputCostPerMillionTokens":123456789012345678901,"outputCostPerMillionTokens":0.1000000000000000055511151231257827}}}"#.utf8))
    check(long.prices["m"]?.cells == [.input: "123456789012345680000", .output: "0.1"],
          "file: a literal longer than a double can hold is rounded to the nearest double, as JavaScript does")
}
usageChecks54()

// Verifier: branches of T3's usagePriceTableChanges (usagePriceTable.ts, commit 803f21f) that the
// vectors above do not reach. Every expected value was printed by T3's own function run under
// node and then reduced to one machine (no "on {target}").
func usageChecks55() {
    let price = UsagePrice([.input: 2, .output: 8])!
    func settings(_ prices: [String: UsagePrice], _ aliases: [String: String] = [:]) -> UsagePriceSettings {
        var settings = UsagePriceSettings()
        settings.prices = prices
        settings.aliases = aliases
        return settings
    }
    func draft(_ model: String = "example", values: [UsagePriceField: String] = [:], alias: String? = nil,
               removed: Bool = false) -> UsagePriceDraft {
        UsagePriceDraft(id: "model:\(model)", model: model, isNew: false, values: values, alias: alias, removed: removed)
    }
    func plan(_ saved: UsagePriceSettings, _ drafts: UsagePriceDraft...) -> UsagePricePlan {
        UsagePricePlan(saved: saved, drafts: drafts)
    }
    let mapped = settings([:], ["example": "example-model"])
    let both = settings(["example": price], ["example": "example-model"])
    let cycle = "Model mappings cannot form a cycle."

    // usagePriceTable.ts:98 — the guard counts the edited cells, not what is in them.
    let blankCell = plan(mapped, draft(values: [.input: ""]))
    check(blankCell.changes.isEmpty && blankCell.errors == ["model:example": "This model is mapped. Clear its mapping first."],
          "plan (usagePriceTable.ts:98): an emptied price cell on a model that is still mapped is refused too")
    // usagePriceTable.ts:117-123 — blank cells do not turn a cleared mapping into a price.
    let clearedBlank = plan(mapped, draft(values: [.input: " "], alias: ""))
    check(clearedBlank.changes == [.alias("example", nil)] && clearedBlank.errors.isEmpty,
          "plan (usagePriceTable.ts:117-123): a cleared mapping with only spaces in the price cells is just a cleared mapping")
    // usagePriceTable.ts:117-149 — a hand-edited file may hold a price and a mapping for one model.
    let clearedBoth = plan(both, draft(alias: ""))
    check(clearedBoth.changes == [.alias("example", nil)] && clearedBoth.errors.isEmpty,
          "plan (usagePriceTable.ts:117-149): clearing the mapping of a model that also has a price keeps that price")
    let clearedTyped = plan(both, draft(values: [.input: "3"], alias: ""))
    check(clearedTyped.changes == [.alias("example", nil), .price("example", UsagePrice([.input: 3, .output: 8])!)]
            && clearedTyped.errors.isEmpty,
          "plan (usagePriceTable.ts:117-149): clearing the mapping and editing the kept price saves both")
    // usagePriceTable.ts:91-94 — a reset looks at nothing else in the row.
    let resetNothing = plan(settings([:]), draft(removed: true))
    check(resetNothing.changes.isEmpty && resetNothing.errors.isEmpty,
          "plan (usagePriceTable.ts:91-94): resetting a model that has nothing saved changes nothing")
    let resetGarbage = plan(settings(["example": price]), draft(values: [.input: "x"], alias: "example", removed: true))
    check(resetGarbage.changes == [.price("example", nil)] && resetGarbage.errors.isEmpty,
          "plan (usagePriceTable.ts:91-94): a reset ignores an invalid price and a self-mapping typed before it")
    // usagePriceTable.ts:96,110 and 112-113 — the mapping is compared after trimming.
    check(plan(settings([:]), draft(alias: " example ")).errors == ["model:example": "Map to a different model."],
          "plan (usagePriceTable.ts:96,110): a self-mapping is caught through surrounding spaces")
    let sameAlias = plan(mapped, draft(alias: " example-model "))
    check(sameAlias.changes.isEmpty && sameAlias.errors.isEmpty,
          "plan (usagePriceTable.ts:112): the saved mapping retyped with spaces is not a change")
    check(plan(both, draft(alias: " example-model ")).changes == [.price("example", nil)],
          "plan (usagePriceTable.ts:113): confirming the mapping of a model that still has a price drops that price")
    // usagePriceTable.ts:128-145 — which message wins.
    check(plan(settings([:]), draft(values: [.cacheRead: "1"])).errors == ["model:example": "Input is required."],
          "plan (usagePriceTable.ts:129-143): with both required rates missing, Input is named first")
    check(plan(settings([:]), draft(values: [.input: "x"])).errors == ["model:example": "Output is required."],
          "plan (usagePriceTable.ts:129-143): a missing rate is reported before an invalid one")
    let nameless = UsagePriceDraft(id: "new:0", model: " ", isNew: true, values: [.input: "x"])
    check(plan(settings([:]), nameless).errors == ["new:0": "Enter a model ID."],
          "plan (usagePriceTable.ts:134-135): a missing model ID is reported before anything about the prices")
    check(plan(settings(["example": price]), draft(values: [.input: " "])).errors == ["model:example": "Input is required."],
          "plan (usagePriceTable.ts:125-131): emptying a saved required rate is refused")
    let withCache = UsagePrice([.input: 2, .output: 8, .cacheRead: 0])!
    check(plan(settings(["example": withCache]), draft(values: [.cacheRead: ""])).changes == [.price("example", price)],
          "plan (usagePriceTable.ts:147-149): emptying a saved cache rate returns it to the input rate")

    // usagePriceTable.ts:151-173 — a file that already holds a loop (it can only be hand-written).
    let loop = settings([:], ["a": "b", "b": "a"])
    let resetInLoop = plan(loop, draft("a", removed: true))
    check(resetInLoop.changes == [.alias("a", nil)] && resetInLoop.errors.isEmpty,
          "cycles (usagePriceTable.ts:159): a reset row is not checked, so a saved loop can be broken by a reset")
    let redirected = plan(loop, draft("b", alias: "c"))
    check(redirected.changes == [.alias("b", "c")] && redirected.errors.isEmpty,
          "cycles (usagePriceTable.ts:152-172): pointing one model of a saved loop elsewhere is accepted")
    let intoLoop = plan(loop, UsagePriceDraft(id: "new:0", model: "x", isNew: true, alias: "a"))
    check(intoLoop.changes == [.alias("x", "a")] && intoLoop.errors == ["new:0": cycle],
          "cycles (usagePriceTable.ts:160-171): a new mapping that leads into a saved loop is refused")
    let besideLoop = plan(loop, UsagePriceDraft(id: "new:0", model: "y", isNew: true, values: [.input: "2", .output: "8"]))
    check(besideLoop.changes == [.price("y", price)] && besideLoop.errors.isEmpty,
          "cycles (usagePriceTable.ts:158-162): a saved loop does not block a price for another model")
    let touchedLoop = plan(loop, draft("a", alias: " b"))
    check(touchedLoop.changes.isEmpty && touchedLoop.errors == ["model:a": cycle],
          "cycles (usagePriceTable.ts:158-171): touching a row inside a saved loop without fixing it is refused")
}
usageChecks55()

// Verifier: the two regular expressions and the deletion rule of usagePriceForm.ts, with answers
// printed by T3's own parseUsagePriceForm and isUsagePriceEdit under node.
func usageChecks56() {
    let read: [(String, Double?)] = [("1,", 1), (",5e2", 50), ("1,e3", 1000), (",", nil), (".", nil), ("1.", 1),
                                     ("5E+2", 500), ("0,0", 0), ("007", 7), ("1e0005", 100_000)]
    let misread = read.filter { UsagePrice(cells: [.input: $0.0, .output: "8"])?.rates[.input] != $0.1 }.map(\.0)
    check(misread.isEmpty, "prices (usagePriceForm.ts:44-52): a trailing or leading comma, leading zeros and a long exponent read like T3 \(misread)")

    let typed: [(String, Bool)] = [
        (".", true), (",", true), ("1e", true), ("1e+", true), ("1.e", true), ("1,5E-", true), ("  ", true),
        (" 1.5e-7 ", true), (".5e", true), ("", true), ("e", false), ("e5", false), (".e5", false), ("1e+-", false),
        ("1e5.5", false), ("1e5e", false), ("1 2", false), (".,", false), ("+1", false), ("1ee", false),
        ("1e 5", false), ("-", false), ("1.5,", false),
    ]
    let mistyped = typed.filter { UsagePrice.acceptsEdit(from: "", to: $0.0) != $0.1 }.map(\.0)
    check(mistyped.isEmpty, "typing (usagePriceForm.ts:29): unfinished numbers pass and malformed ones do not \(mistyped)")

    let pairs: [(String, String, Bool)] = [
        ("e-7", "e-", true), ("e-7", "e7", true), ("e-7", "-7", true), ("e-7", "e-71", false), ("e-7", "e-8", false),
        ("1-7", "1-", true), ("1-7", "1-78", false), ("1.2.3", "1..3", true), ("1.2.3", "1.3", true),
        ("1.2.3", "1.2.4", false), ("abc", "ac", true), ("abc", "ca", false), ("abc", "", true),
        ("aXbXc", "aXc", true), ("aab", "ab", true), ("x", "x", false), ("x", "xx", false),
    ]
    let wrongPairs = pairs.filter { UsagePrice.acceptsEdit(from: $0.0, to: $0.1) != $0.2 }.map { "\($0.0)>\($0.1)" }
    check(wrongPairs.isEmpty,
          "typing (usagePriceForm.ts:30-33): from a text that is not a number only the removal of one run is allowed \(wrongPairs)")
}
usageChecks56()

// Verifier: T3's settings tests for these two tables, on the one file of this machine.
func usageChecks57() {
    func parse(_ text: String) -> UsagePriceSettings { UsagePriceSettings(data: Data(text.utf8)) }
    func bytes(_ path: String) -> String { String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self) }
    let prices = UsagePrice([.input: 2, .output: 8])!

    // packages/shared/src/serverSettings.test.ts:704-723
    var current = UsagePriceSettings()
    current.prices = ["example-model": UsagePrice([.input: 2, .output: 8, .cacheRead: 0.5])!]
    let replaced = current.applying([.price("other-model", prices)]).applying([.price("example-model", prices)])
    check(replaced.prices == ["example-model": prices, "other-model": prices],
          "apply (serverSettings.test.ts:704-717): a replaced price loses its old cache rate and the other model stays")
    check(replaced.applying([.price("example-model", nil)]).prices == ["other-model": prices],
          "apply (serverSettings.test.ts:718-721): removing one model leaves the other")
    check(current.prices["example-model"]?.rates[.cacheRead] == 0.5,
          "apply (serverSettings.test.ts:722): the settings a change was applied to stay as they were")

    // apps/server/src/serverSettings.test.ts:625-662
    let folder = NSTemporaryDirectory() + "acb-usage-verify-\(ProcessInfo.processInfo.processIdentifier)/"
    try? FileManager.default.removeItem(atPath: folder)
    let path = folder + "usage/prices.json"
    let free = UsagePrice([.input: 2, .output: 8, .cacheRead: 0])!
    var persisted = UsagePriceSettings().applying([.price("example-model", free)])
    let first = (try? persisted.save(at: path)) != nil
    persisted = UsagePriceSettings.load(at: path).applying([.alias("example-preview", "example-model")])
    let second = (try? persisted.save(at: path)) != nil
    let stored = UsagePriceSettings.load(at: path)
    check(first && second && stored.prices == ["example-model": free] && stored.aliases == ["example-preview": "example-model"],
          "disk (apps/server serverSettings.test.ts:634-655): a mapping saved later sits beside the price saved before")
    let third = (try? stored.applying([.price("example-model", nil)]).save(at: path)) != nil
    check(third && bytes(path) == #"{"usagePriceOverrides":{},"usageModelAliases":{"example-preview":"example-model"}}"#,
          "disk (apps/server serverSettings.test.ts:657-659): removing the last price leaves an empty table and the mapping")

    // apps/server/src/usage/UsageService.test.ts:3088-3107 — set a price, edit it, reset it, here through the editor.
    try? FileManager.default.removeItem(atPath: path)
    var editor = UsagePriceEditor(saved: UsagePriceSettings.load(at: path), settingPriceFor: "example-model")
    let typedFirst = editor.setPrice("2", .input, row: "new:initial") && editor.setPrice("8", .output, row: "new:initial")
    check(typedFirst && (try? editor.save(at: path)) != nil
            && bytes(path) == #"{"usagePriceOverrides":{"example-model":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":8}},"usageModelAliases":{}}"#,
          "editor (UsageService.test.ts:3088-3092): the first custom price of a model reaches the file")
    let typedSecond = editor.setPrice("4", .input, row: "model:example-model") && editor.setPrice("16", .output, row: "model:example-model")
    check(typedSecond && (try? editor.save(at: path)) != nil
            && UsagePriceSettings.load(at: path).prices == ["example-model": UsagePrice([.input: 4, .output: 16])!],
          "editor (UsageService.test.ts:3099-3103): an edited price replaces the saved one")
    editor.toggleRow("model:example-model")
    check((try? editor.save(at: path)) != nil && UsagePriceSettings.load(at: path) == UsagePriceSettings() && editor.rows.isEmpty,
          "editor (UsageService.test.ts:3107): resetting the price returns the model to automatic pricing")
    try? FileManager.default.removeItem(atPath: folder)

    // packages/contracts/src/settings.test.ts:153-160
    let beside = parse(#"{"usageModelFilter": {"exclude": [{"model": ""}]}, "usagePriceOverrides": "broken", "usageModelAliases": {"drift-9": "orbit-1"}}"#)
    check(beside.aliases == ["drift-9": "orbit-1"] && beside.prices.isEmpty,
          "file (settings.test.ts:153-160): an invalid neighbouring setting does not drop the mappings")

    // packages/client-runtime/src/state/server.ts:1341-1371 — the same tables in another property order are no change.
    let one = parse(#"{"usageModelAliases":{"b":"x","a":"x"},"usagePriceOverrides":{"m2":{"outputCostPerMillionTokens":8,"inputCostPerMillionTokens":2},"m1":{"cacheReadCostPerMillionTokens":0,"outputCostPerMillionTokens":8,"inputCostPerMillionTokens":2}}}"#)
    let other = parse(#"{"usagePriceOverrides":{"m1":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":8,"cacheReadCostPerMillionTokens":0},"m2":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":8}},"usageModelAliases":{"a":"x","b":"x"}}"#)
    check(one.prices.count == 2 && one.aliases.count == 2 && one == other && one.serialized() == other.serialized(),
          "file (client-runtime server.ts:1341-1371): the same prices and mappings in another order compare and serialise the same")
    let different = parse(#"{"usagePriceOverrides":{"m1":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":8},"m2":{"inputCostPerMillionTokens":2,"outputCostPerMillionTokens":8}},"usageModelAliases":{"a":"x","b":"x"}}"#)
    check(one != different && one.serialized() != different.serialized(),
          "file (client-runtime server.ts:1351-1357): an explicit zero cache rate is a different price than a blank one")

    // apps/server/src/usage/UsageService.test.ts:1275
    let slashed = UsagePriceSettings().applying([.alias("anthropic/actual-model-preview", "anthropic/actual-model")])
    check(String(decoding: slashed.serialized(), as: UTF8.self)
            == #"{"usagePriceOverrides":{},"usageModelAliases":{"anthropic/actual-model-preview":"anthropic/actual-model"}}"#
            && UsagePriceSettings(data: slashed.serialized()) == slashed,
          "write (UsageService.test.ts:1275): model IDs with a vendor prefix are written as they are")
}
usageChecks57()

// Verifier: UsagePriceOverrides.tsx behaviour of the table that the vectors above do not reach.
func usageChecks58() {
    let price = UsagePrice([.input: 2, .output: 8])!

    // UsagePriceOverrides.tsx:464-466 — the message is gated on a model ID or any typed character.
    var nameless = UsagePriceEditor(saved: UsagePriceSettings())
    let row = nameless.addRow()
    nameless.setAlias("orbit-1", row: row)
    check(nameless.rows[0].error == nil && !nameless.canSave,
          "editor (UsagePriceOverrides.tsx:464-466): a mapping without a model ID blocks saving silently")
    check(nameless.setPrice(" ", .input, row: row) && nameless.rows[0].error == "Enter a model ID." && !nameless.rows[0].modelInvalid,
          "editor (UsagePriceOverrides.tsx:464-466): one space in a price cell is enough for the message to appear")

    // UsagePriceOverrides.tsx:177-181 — "waiting for a price" looks at trimmed cells and at the mapping.
    var waiting = UsagePriceEditor(saved: UsagePriceSettings(), settingPriceFor: "glm-5.3")
    check(waiting.setPrice(" ", .input, row: "new:initial") && waiting.rows[0].error == nil && !waiting.rows[0].modelInvalid
            && !waiting.canSave,
          "editor (UsagePriceOverrides.tsx:177-181): a new model with only a space typed is still waiting for a price")
    waiting.setAlias("glm-5", row: "new:initial")
    check(waiting.rows[0].error == nil && waiting.canSave && waiting.plan.changes == [.alias("glm-5.3", "glm-5")]
            && waiting.rows[0].countedAs == "glm-5",
          "editor (UsagePriceOverrides.tsx:177-181): a new model with only a mapping can be saved")

    // UsagePriceOverrides.tsx:556-563 — undoing a reset keeps a typed mapping.
    var saved = UsagePriceSettings()
    saved.prices = ["zeta": price]
    var undo = UsagePriceEditor(saved: saved)
    undo.setAlias("Alpha", row: "model:zeta")
    undo.toggleRow("model:zeta")
    check(undo.rows[0].removed && undo.plan.changes == [.price("zeta", nil)],
          "editor (UsagePriceOverrides.tsx:563): a reset wins over a mapping typed in the same row")
    undo.toggleRow("model:zeta")
    check(!undo.rows[0].removed && undo.hasChanges && undo.rows[0].countedAs == "Alpha"
            && undo.plan.changes == [.alias("zeta", "Alpha"), .price("zeta", nil)],
          "editor (UsagePriceOverrides.tsx:561-562): undoing the reset brings the typed mapping back")

    // UsagePriceOverrides.tsx:226-231 — a price typed and deleted again on a row without a saved price.
    var mappedOnly = UsagePriceSettings()
    mappedOnly.aliases = ["drift-9": "orbit-1"]
    var cleared = UsagePriceEditor(saved: mappedOnly)
    cleared.setAlias("", row: "model:drift-9")
    check(cleared.setPrice("3", .input, row: "model:drift-9") && cleared.rows[0].error == "Output is required." && !cleared.canSave,
          "editor (UsagePriceOverrides.tsx:226-231): one rate typed after clearing a mapping asks for the other")
    check(cleared.setPrice("", .input, row: "model:drift-9") && cleared.drafts.first?.values.isEmpty == true
            && cleared.rows[0].error == nil && cleared.canSave && cleared.plan.changes == [.alias("drift-9", nil)],
          "editor (UsagePriceOverrides.tsx:229): deleting that rate again leaves only the cleared mapping to save")

    // usagePriceTable.ts:151-173 through the table: a hand-written loop can be opened and repaired.
    var loop = UsagePriceSettings()
    loop.aliases = ["a": "b", "b": "a"]
    var repair = UsagePriceEditor(saved: loop)
    check(repair.rows.map(\.id) == ["model:a", "model:b"] && repair.rows.allSatisfy { $0.error == nil } && !repair.hasChanges
            && loop.resolvedAliases.isEmpty,
          "editor (usagePriceTable.ts:158-159): a saved loop opens without errors and maps nothing")
    repair.setAlias("c", row: "model:b")
    check(repair.canSave && repair.afterSave.resolvedAliases == ["a": "c", "b": "c"],
          "editor (usagePriceTable.ts:152-172): redirecting one model of the loop makes both mappings effective")
}
usageChecks58()

// MARK: Usage window — how long its commands may run, and the forced limits polls
// Which script runs them is not a question of the command any more: every command runs the copy
// inside the app, and an older plugin copy is only the fallback (BackendCommand.backend, above).
func usageChecks59() {
    check(BackendCommand.usage(refresh: false).deadline == 600 && BackendCommand.usage(refresh: true).deadline == 600,
          "a usage scan that hung is stopped, so it cannot hold the refresh button for ever")
    // The one command with no deadline: a redemption cut short would leave nobody knowing whether
    // the credit was spent, and its script bounds its own waits.
    for command: BackendCommand in [.resetCredit(provider: "claude", creditId: "grant_abc"),
                                    .resetCredit(provider: "codex", creditId: nil)] {
        check(command.deadline == .infinity,
              "a redemption is never stopped from outside: \(command.arguments)")
    }
    let unbounded = HookInstall.run("/bin/sleep", ["0.3"], timeout: .infinity)
    check(unbounded.end == .exited(0),
          "and a run without a deadline is waited for until it ends: \(unbounded.end)")
}
usageChecks59()

// The Usage window's refresh button asks for limits now, whatever the sixty-second debounce says —
// but never beside a request that is already on its way.
func usageChecks60() {
    let now = 1_795_112_308.0
    var poll = CodexLimitsPoll()
    check(poll.begin(now: now), "forced poll: the first request starts")
    check(!poll.begin(now: now + 1, force: true), "a forced request does not start beside one in flight")
    poll.finish()
    check(!poll.begin(now: now + 2), "an ordinary request still waits out the debounce")
    check(poll.begin(now: now + 2, force: true), "the refresh button's request skips the debounce")
    poll.finish()
    check(!poll.begin(now: now + 61), "a forced request restarts the debounce for the ordinary ones")
    check(poll.begin(now: now + 62), "and they resume sixty seconds after it")
}
usageChecks60()

// Claude has no poll object of its own (its debounce is the controller's lastLimitsPoll), so the
// rule the Usage window added to it is pinned here: one request at a time, whoever asks.
func usageChecks61() {
    let now = 1_795_112_308.0
    check(ClaudeLimitsPoll.mayStart(now: now, lastStart: 0, running: false, force: false),
          "claude poll: the first request starts")
    check(!ClaudeLimitsPoll.mayStart(now: now + 30, lastStart: now, running: false, force: false),
          "claude poll: an ordinary request waits out the minute")
    check(ClaudeLimitsPoll.mayStart(now: now + 30, lastStart: now, running: false, force: true),
          "claude poll: the refresh button skips the minute")
    check(!ClaudeLimitsPoll.mayStart(now: now + 2, lastStart: now, running: true, force: true),
          "claude poll: the refresh button never starts a second request beside one in flight")
    check(!ClaudeLimitsPoll.mayStart(now: now + 90, lastStart: now, running: true, force: false),
          "claude poll: nor does the timer, past its minute")
    check(ClaudeLimitsPoll.mayStart(now: now + 120, lastStart: now, running: true, force: false),
          "claude poll: a request unanswered for two minutes is given up on, so one hung process is not the end of polling")
    check(ClaudeLimitsPoll.inFlight(now: now + 5, lastStart: now, running: true)
            && !ClaudeLimitsPoll.inFlight(now: now + 5, lastStart: now, running: false)
            && !ClaudeLimitsPoll.inFlight(now: now + 120, lastStart: now, running: true),
          "claude poll: in flight is what the Usage window spins its refresh button on")

    var codex = CodexLimitsPoll()
    check(!codex.inFlight, "codex poll: nothing is in flight before the first request")
    _ = codex.begin(now: now)
    check(codex.inFlight, "codex poll: a started request is in flight")
    codex.finish()
    check(!codex.inFlight, "codex poll: and lands")
}
usageChecks61()

// MARK: Usage window — the rules that are not about a file format
// Sources/Model/UsageWindowModel.swift: what the window remembers, its keys, the picture it
// draws from plain inputs, and its two rules about time.

// The window's keys are matched by physical key and exact modifiers.
func usageChecks62() {
    let bare: NSEvent.ModifierFlags = []
    check(UsageShortcut.match(keyCode: 8, modifiers: bare) == .tab(.cost), "C selects Cost")
    check(UsageShortcut.match(keyCode: 17, modifiers: bare) == .tab(.tokens), "T selects Tokens")
    check(UsageShortcut.match(keyCode: 37, modifiers: bare) == .tab(.limits), "L selects Limits")
    check(UsageShortcut.match(keyCode: 53, modifiers: bare) == .dismiss, "Esc dismisses")
    check(UsageShortcut.match(keyCode: 8, modifiers: [.command]) == nil, "⌘C is not the Cost key")
    check(UsageShortcut.match(keyCode: 8, modifiers: [.shift]) == nil, "a shifted C is not the Cost key")
    check(UsageShortcut.match(keyCode: 8, modifiers: [.capsLock, .numericPad]) == .tab(.cost),
          "Caps Lock is not a modifier the match is exact about")
    check(UsageShortcut.match(keyCode: 15, modifiers: [.command]) == .refresh, "⌘R refreshes")
    check(UsageShortcut.match(keyCode: 15, modifiers: bare) == nil, "a bare R does nothing")
    let periods: [(UInt16, Int)] = [(18, 1), (19, 7), (20, 30), (21, 90)]
    for (key, days) in periods {
        check(UsageShortcut.match(keyCode: key, modifiers: [.command, .shift]) == .period(days),
              "⇧⌘ digit selects the \(days)-day period")
        check(UsageShortcut.match(keyCode: key, modifiers: [.command]) == nil,
              "the \(days)-day period needs Shift as well")
    }
    check(UsagePeriodOption.all.map(\.days) == UsageSummary.periodDays,
          "the period control offers exactly the periods the summary file carries")
    check(UsageTab.allCases.map(\.key) == ["C", "T", "L"] && UsageTab.limits.metric == nil,
          "the tabs name their keys, and Limits is not a metric")
}
usageChecks62()

// Preferences: T3's three fields, validated as one object.
func usageChecks63() {
    let suite = "usage-preferences-check-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fresh = UsagePreferences(defaults: defaults)
    check(fresh.tab == .limits && fresh.days == 30 && fresh.filter == .all,
          "nothing saved opens on Limits, 30 days, all providers")

    for filter in UsageProviderFilter.allCases {
        var saved = UsagePreferences()
        saved.tab = .tokens
        saved.days = 7
        saved.filter = filter
        saved.save(to: defaults)
        check(UsagePreferences(defaults: defaults) == saved, "preferences survive a save: \(filter.rawValue)")
    }
    check(defaults.stringArray(forKey: UsagePreferences.hiddenKey) == ["claude"],
          "the filter is stored as T3's list of hidden providers")

    defaults.set("charts", forKey: UsagePreferences.tabKey)
    check(UsagePreferences(defaults: defaults) == UsagePreferences(), "an unknown tab resets all three fields")
    defaults.set("cost", forKey: UsagePreferences.tabKey)
    defaults.set(14, forKey: UsagePreferences.daysKey)
    check(UsagePreferences(defaults: defaults) == UsagePreferences(), "a period the file has no key for resets all three")
    defaults.set(90, forKey: UsagePreferences.daysKey)
    defaults.set(["cursor"], forKey: UsagePreferences.hiddenKey)
    check(UsagePreferences(defaults: defaults) == UsagePreferences(), "an unknown hidden provider resets all three")
    defaults.set(["claude", "codex"], forKey: UsagePreferences.hiddenKey)
    let none = UsagePreferences(defaults: defaults)
    check(none.tab == .cost && none.days == 90 && none.filter == .all,
          "both providers hidden reads as all providers; the rest is kept")
    defaults.removeObject(forKey: UsagePreferences.hiddenKey)
    check(UsagePreferences(defaults: defaults).filter == .all, "a save from before the hidden list is valid")
}
usageChecks63()

// When the window rescans and when its frozen clock moves.
func usageChecks64() {
    let now = 1_795_091_862.0
    check(UsageClock.summaryIsStale(readAt: nil, now: now), "no summary is a stale one")
    check(!UsageClock.summaryIsStale(readAt: now - 299, now: now), "a summary under five minutes old is kept")
    check(UsageClock.summaryIsStale(readAt: now - 300, now: now), "at five minutes it is rescanned")
    check(!UsageClock.minuteChanged(frozen: 120, wall: 179.9), "the frozen clock stands still inside a minute")
    check(UsageClock.minuteChanged(frozen: 179.9, wall: 180), "and moves when the wall clock enters the next")
}
usageChecks64()

// The notices box: T3's sentences, shown when the panel's own rule says there is something to explain.
func usageChecks65() {
    let now = 1_795_091_862.0
    let status = { (state: String, ts: Double) in LimitsStatus(json: ["state": state, "ts": ts, "detail": "URLError"]) }
    let figures = LimitsSet(provider: "claude", windows: [], source: "oauth", ts: now - 600, plan: nil)
    let notice = { (provider: String, input: UsageLimitsInput, rows: Bool) in
        UsageProviderState.notice(provider: provider, input: input, hasRows: rows, now: now)
    }
    check(notice("claude", UsageLimitsInput(set: figures, status: status("failed", now - 60)), true)
            == "Claude: Could not read limits.", "a failed poll over old figures is named in T3's words")
    check(notice("codex", UsageLimitsInput(status: status("failed", now - 60)), false)
            == "Codex: Could not read limits.", "each provider gets its own line")
    check(notice("claude", UsageLimitsInput(status: status("no-login", now - 60)), false)
            == "Claude: Claude Code is not authenticated. Run `claude auth login` and try again.",
          "a signed-out Claude Code says how to sign in")
    check(notice("codex", UsageLimitsInput(status: status("empty", now - 60)), false)
            == "Codex: No limits reported.", "an answer without windows says so")
    check(notice("codex", UsageLimitsInput(status: status("empty", now - 60)), true) == nil,
          "but not beside a row the account sidecar did report")
    check(notice("claude", UsageLimitsInput(status: status("ok", now - 60)), true) == nil, "a good poll has no line")
    check(notice("claude", UsageLimitsInput(status: nil), false) == nil, "no status yet has no line")
    check(notice("claude", UsageLimitsInput(status: status("failed", now - 60), enabled: false), false) == nil,
          "a switched-off poll explains nothing, as in the panel")
    check(notice("claude", UsageLimitsInput(set: figures, status: status("failed", now - 3600)), true) == nil,
          "figures newer than the failure stand, as in the panel")
}
usageChecks65()

// The snapshot builder: the same picture for the app and the render mode.
func usageChecks66() {
    let now = 1_795_091_862.0
    var inputs = UsageInputs(now: now, providers: ["claude", "codex"])
    check(UsageSnapshot(inputs).usagePhase == .unavailable, "no summary and no scan is neither loading nor ready")
    inputs.usageRunning = true
    check(UsageSnapshot(inputs).usagePhase == .loading, "the first scan is the loading phase")
    inputs.usageFailed = true
    check(UsageSnapshot(inputs).usageError == nil, "a scan in flight outranks the last one's failure")
    inputs.usageRunning = false
    check(UsageSnapshot(inputs).usageError == "Usage could not be read.",
          "a command that died without writing its status is still a failed scan")
    check(UsageSnapshot(inputs).limits.map(\.provider) == ["claude", "codex"],
          "one limits section per shown provider, Claude first")
    inputs.providers = ["codex"]
    check(UsageSnapshot(inputs).limits.map(\.provider) == ["codex"], "a provider the app does not show has no section")

    // The line under the bars: only for a redemption of this window session.
    inputs.providers = ["claude"]
    let result = { (ts: Double, error: Any) in
        UsageResetResult(json: ["ts": ts, "outcome": NSNull(), "error": error, "confirmed": false], provider: "claude")
    }
    inputs.files.resetResults["claude"] = UsageResetResult(
        json: ["ts": now - 3600, "outcome": "reset", "confirmed": true], provider: "claude")
    inputs.resetNewsSince = now - 600
    check(UsageSnapshot(inputs).limits[0].resetStatus == nil, "a result from before the window opened is history")
    check(UsageSnapshot(inputs).limits[0].resetResult?.outcome == "reset", "though the last result stays readable")
    inputs.files.resetResults["claude"] = UsageResetResult(
        json: ["ts": now - 60, "outcome": "reset", "confirmed": true], provider: "claude")
    check(UsageSnapshot(inputs).limits[0].resetStatus == "Reset applied. Your windows have cleared.",
          "a result of this session is announced")
    inputs.resetDismissed["claude"] = now - 60
    check(UsageSnapshot(inputs).limits[0].resetStatus == nil, "until it is dismissed")
    inputs.resetBusy = ["claude"]
    let busy = UsageSnapshot(inputs).limits[0]
    check(busy.resetBusy && busy.resetStatus == UsageResetCredit.busyStatus, "a redemption in flight says so")

    inputs.resetBusy = []
    inputs.resetDismissed = [:]
    inputs.files.resetResults["claude"] = result(now - 60, "requestFailed")
    inputs.files.accounts["claude"] = UsageAccount(json: ["ts": now - 120], provider: "claude")
    check(UsageSnapshot(inputs).limits[0].resetNeedsRefresh,
          "an attempt that may have reached Claude asks for a limits refresh before the next")
    inputs.files.accounts["claude"] = UsageAccount(json: ["ts": now - 10], provider: "claude")
    check(!UsageSnapshot(inputs).limits[0].resetNeedsRefresh, "a sidecar written since then is that refresh")
    inputs.files.resetResults["claude"] = result(now - 60, "coolingDown")
    inputs.files.accounts["claude"] = UsageAccount(json: ["ts": now - 120], provider: "claude")
    check(!UsageSnapshot(inputs).limits[0].resetNeedsRefresh, "a settled refusal needs no refresh")

    // Which button may still spend a credit while the account is unknown: asked of the choices
    // the popover really draws, for a sidecar that still lists two grants.
    let ended = { (provider: String, creditId: Any, outcome: Any, error: Any) in
        UsageResetResult(json: ["ts": now - 60, "creditId": creditId, "outcome": outcome, "error": error,
                                "confirmed": false], provider: provider)
    }
    let sidecar = { (ts: Double) in
        UsageAccount(json: ["ts": ts, "resetCredits": ["availableCount": 3, "options": [
            ["creditId": "weekly_a", "kind": "weekly", "availableCount": 2] as [String: Any],
            ["creditId": "session_a", "kind": "session", "availableCount": 1] as [String: Any],
        ]] as [String: Any]], provider: "claude")
    }
    let allowed = { (inputs: UsageInputs) -> [Bool] in
        let state = UsageSnapshot(inputs).limits[0]
        return state.limits.resetChoices(now: now).map { state.mayRedeem(creditId: $0.creditId) }
    }
    inputs.files.accounts["claude"] = sidecar(now - 120)
    inputs.files.resetResults["claude"] = result(now - 60, "coolingDown")
    check(allowed(inputs) == [true, true], "after a settled refusal every credit may be used")
    inputs.files.resetResults["claude"] = ended("claude", "weekly_a", "reset", NSNull())
    check(UsageSnapshot(inputs).limits[0].resetNeedsRefresh && allowed(inputs) == [false, false],
          "a reset the re-poll could not confirm blocks every credit: the sidecar still lists the one just spent")
    for category in ["requestFailed", "unconfirmed"] {
        inputs.files.resetResults["claude"] = ended("claude", "weekly_a", NSNull(), category)
        check(allowed(inputs) == [true, false],
              "\(category): the same grant may be retried, its stored key is sent again, and no other grant may")
        inputs.files.resetResults["claude"] = ended("claude", NSNull(), NSNull(), category)
        check(allowed(inputs) == [false, false], "\(category) for a grant the result does not name blocks them all")
    }
    inputs.resetBusy = ["claude"]
    check(allowed(inputs) == [false, false], "nothing may be spent while a redemption is in flight")
    inputs.resetBusy = []
    inputs.files.accounts["claude"] = sidecar(now - 10)
    check(allowed(inputs) == [true, true], "a newer account file re-enables everything after an open attempt")
    inputs.files.resetResults["claude"] = ended("claude", "weekly_a", "reset", NSNull())
    check(!UsageSnapshot(inputs).limits[0].resetNeedsRefresh && allowed(inputs) == [true, true],
          "and after an unconfirmed reset")

    // Codex has one choice and names no grant: a retry after an open attempt is that same grant,
    // an unconfirmed reset blocks it like any other.
    inputs.providers = ["codex"]
    inputs.files.accounts["codex"] = UsageAccount(
        json: ["ts": now - 120, "resetCredits": ["availableCount": 1]], provider: "codex")
    inputs.files.resetResults["codex"] = ended("codex", NSNull(), NSNull(), "requestFailed")
    check(allowed(inputs) == [true], "codex: the single choice is the retry of the open attempt")
    inputs.files.resetResults["codex"] = ended("codex", NSNull(), "reset", NSNull())
    check(allowed(inputs) == [false], "codex: an unconfirmed reset blocks the single choice")
    inputs.files.accounts["codex"] = UsageAccount(
        json: ["ts": now - 10, "resetCredits": ["availableCount": 1]], provider: "codex")
    check(allowed(inputs) == [true], "codex: until a poll rewrites its account file")
}
usageChecks66()

// The rules are the model's; these hold the places that have to ask them. A spent credit cannot
// be given back, so the controller refuses by the same rule that disables the buttons.
func usageChecks67() {
    let source = appSources.joined(separator: "\n")
    let redeem = source.range(of: "func redeemUsageReset(").map { source[$0.upperBound...] } ?? ""
    let beforeSpawn = redeem.range(of: "runQuietCommand(.resetCredit").map { redeem[..<$0.lowerBound] } ?? ""
    check(beforeSpawn.contains(".mayRedeem(creditId: creditId)"),
          "the controller asks the model before it starts a redemption")
    check(source.contains(".disabled(!state.mayRedeem(creditId: choice.creditId))")
            && source.contains(".disabled(state?.mayRedeem(creditId: request.choice.creditId) != true)"),
          "the popover's reset buttons and the confirmation's are disabled by that rule")
    let rollover = source.range(of: "func pollLimitsIfRolledOver(").map { source[$0.upperBound...] } ?? ""
    let beforeStamp = rollover.range(of: "rolledOverHandled = newest").map { rollover[..<$0.lowerBound] } ?? ""
    check(beforeStamp.contains("ClaudeLimitsPoll.mayStart(") && !beforeStamp.contains("lastLimitsPoll >= 60"),
          "a rollover is recorded as handled only when the poll it asks for may really start")
    // The render mode's clock comes from the environment: CONTROL_BAR_RENDER_NOW=inf trapped there.
    check(!source.contains("Int(snapshot.now)") && source.contains("now \\(snapshot.now.clampedInt)"),
          "the render mode prints its clock through clampedInt")
}
usageChecks67()

// Added by the verifier: a redemption command that ended without a result still ends in a sentence.
func usageChecks68() {
    let now = 1_795_091_862.0
    var inputs = UsageInputs(now: now, providers: ["claude", "codex"])
    inputs.resetNewsSince = now - 600
    inputs.resetUnanswered = ["codex"]
    let quiet = UsageSnapshot(inputs)
    check(quiet.limits[1].resetStatus == "Could not use the reset credit.",
          "a redemption that left no result file is reported in T3's fallback sentence")
    check(quiet.limits[0].resetStatus == nil, "and only for the provider it was asked of")
    // An old result on disk must not be passed off as the answer to the run that left none.
    inputs.files.resetResults["codex"] = UsageResetResult(
        json: ["ts": now - 3600, "outcome": "reset", "confirmed": true], provider: "codex")
    check(UsageSnapshot(inputs).limits[1].resetStatus == "Could not use the reset credit.",
          "last week's result is not the answer to a run that wrote nothing")
    inputs.resetBusy = ["codex"]
    check(UsageSnapshot(inputs).limits[1].resetStatus == UsageResetCredit.busyStatus,
          "a new attempt in flight replaces the line")
    check(!UsageProviderState.resetRefreshHint.isEmpty, "the refresh-first hint has words for the Limits tab")
}
usageChecks68()

// While the outcome of a redemption is unknown no second grant may be offered: an answer the
// re-poll could not confirm, a key left by a command that died before writing how it ended. And
// the line under the cards asks for a refresh once.
func usageChecks71() {
    let now = 1_795_091_862.0
    var inputs = UsageInputs(now: now, providers: ["claude"])
    inputs.resetNewsSince = now - 600
    let sidecar = { (ts: Double) in
        UsageAccount(json: ["ts": ts, "resetCredits": ["availableCount": 3, "options": [
            ["creditId": "weekly_a", "kind": "weekly", "availableCount": 2] as [String: Any],
            ["creditId": "session_a", "kind": "session", "availableCount": 1] as [String: Any],
        ]] as [String: Any]], provider: "claude")
    }
    inputs.files.accounts["claude"] = sidecar(now - 120)
    let allowed = { (inputs: UsageInputs) -> [Bool] in
        let state = UsageSnapshot(inputs).limits[0]
        return state.limits.resetChoices(now: now).map { state.mayRedeem(creditId: $0.creditId) }
    }
    let line = { (inputs: UsageInputs) in UsageSnapshot(inputs).limits[0].resetStatus }
    let ended = { (ts: Double, outcome: Any, error: Any, confirmed: Bool) in
        UsageResetResult(json: ["ts": ts, "creditId": "weekly_a", "outcome": outcome, "error": error,
                                "confirmed": confirmed], provider: "claude")
    }
    let hint = " " + UsageProviderState.resetRefreshHint

    inputs.files.resetResults["claude"] = ended(now - 60, "alreadyRedeemed", NSNull(), false)
    check(allowed(inputs) == [false, false],
          "an already-redeemed answer the re-poll could not confirm blocks every credit: the count on screen predates it")
    check(line(inputs) == "That credit was already redeemed." + hint, "and its line asks for the refresh")
    inputs.files.resetResults["claude"] = ended(now - 60, "alreadyRedeemed", NSNull(), true)
    check(allowed(inputs) == [true, true] && line(inputs) == "That credit was already redeemed.",
          "a confirmed one is settled")

    inputs.files.resetResults["claude"] = ended(now - 60, "reset", NSNull(), false)
    check(line(inputs) == "The reset was applied, but Claude could not confirm the new limits. Refresh to check.",
          "an unconfirmed reset asks for a refresh once, in T3's words: \(line(inputs) ?? "nil")")
    inputs.files.resetResults["claude"] = ended(now - 60, NSNull(), "requestFailed", false)
    check(line(inputs) == "Claude could not redeem the reset." + hint, "an open attempt's line ends in the hint")

    // The command saved its key and died: the result on disk is last week's, the run wrote none.
    inputs.files.resetResults["claude"] = UsageResetResult(
        json: ["ts": now - 3600, "creditId": "session_a", "outcome": "reset", "confirmed": true], provider: "claude")
    inputs.resetUnanswered = ["claude"]
    let key = { (ts: Double) in
        (UsageResetResult(json: ["ts": ts, "creditId": "weekly_a", "error": "requestFailed"], provider: "claude"), ts)
    }
    inputs.files.resetPending["claude"] = key(now - 60)
    check(allowed(inputs) == [true, false],
          "a key left on disk is an open attempt: only its grant may be retried, with that key")
    check(line(inputs) == "Could not use the reset credit." + hint, "and the line says why the others wait")
    inputs.resetUnanswered = []
    inputs.files.resetResults["claude"] = UsageResetResult(
        json: ["ts": now - 30, "creditId": "weekly_a", "error": "cliUnavailable"], provider: "claude")
    check(allowed(inputs) == [true, false], "a later run that sent nothing does not close the attempt the key stands for")
    inputs.files.resetResults["claude"] = ended(now - 30, "reset", NSNull(), false)
    check(allowed(inputs) == [false, false], "a reset nobody confirmed still blocks them all beside a key")
    inputs.files.resetResults["claude"] = nil
    inputs.files.resetPending["claude"] = key(now - 86_400 - 60)
    inputs.files.accounts["claude"] = sidecar(now - 90_000)
    check(allowed(inputs) == [true, true], "a key older than a day is forgotten, as the script forgets it")
    inputs.files.resetPending["claude"] = (key(now - 60).0, now - 86_400 - 60)
    check(allowed(inputs) == [true, true], "the day counts from the key's making, not from its last send")
    inputs.files.resetPending["claude"] = key(now - 60)
    check(allowed(inputs) == [true, false], "a live one is not")
    inputs.files.accounts["claude"] = sidecar(now - 10)
    check(!UsageSnapshot(inputs).limits[0].resetNeedsRefresh && allowed(inputs) == [true, true],
          "an account file written after the key re-enables everything")

    // The seam: the key file as the script really leaves it, read the way the window reads it.
    var files = UsageFiles()
    files.reload(root: FileManager.default.currentDirectoryPath + "/build/seam")
    // A retry of the same grant after a fresh poll, killed mid-request: the key is older than the
    // account file, its last send is not.
    let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:
        FileManager.default.currentDirectoryPath + "/build/seam/reset-credit-pending.json")))) as? [String: Any]
    let created = usageNumber(raw?["createdAt"]) ?? 0, sent = usageNumber(raw?["sentAt"]) ?? 0
    var retried = UsageInputs(now: sent + 60, providers: ["claude"])
    retried.files.accounts["claude"] = sidecar(created + 1800)
    retried.files.resetResults["claude"] = UsageResetResult(
        json: ["ts": created, "creditId": "weekly_a", "error": "requestFailed"], provider: "claude")
    retried.files.resetPending = files.resetPending
    retried.resetUnanswered = ["claude"]
    check(sent - created >= 3600 && allowed(retried) == [true, false],
          "a retry killed mid-request after a fresh poll still leaves only its grant: the window reads when it was sent")
    let seam = files.resetPending["claude"]
    check(seam?.attempt.creditId == "weekly_a" && seam?.attempt.ts == sent && seam?.createdAt == created && created > 0
            && seam?.attempt.outcome == nil && seam?.attempt.error == "requestFailed",
          "pending key seam: build/seam/reset-credit-pending.json reads as an open attempt for its grant "
            + "(run the python suite first, it writes the file)")
}
usageChecks71()

// The popover's target is plain data the store can compare.
func usageChecks69() {
    check(UsagePopoverTarget(provider: "codex", row: "primary") == UsagePopoverTarget(provider: "codex", row: "primary")
            && UsagePopoverTarget(provider: "codex", row: "primary") != UsagePopoverTarget(provider: "claude", row: "primary"),
          "a popover is identified by its provider and its row")
}
usageChecks69()

// MARK: Usage window — one clock with the panel
// The line on the panel's bars (NamedWindow) and the tick on the Usage window's (UsageLimitRow)
// are read off the same limits file, so the same window must get the same place and the same
// verdict in both.
func usageChecks70() {
    let now = 1_795_112_308.0
    func window(_ key: String, _ minutes: Int, used: Int, resetsIn: Double) -> NamedWindow {
        NamedWindow(key: key, title: key, badge: nil, minutes: minutes,
                    window: LimitWindow(used: used, resets: now + resetsIn))
    }
    let set = LimitsSet(provider: "claude", windows: [
        window("five_hour", 300, used: 40, resetsIn: 2 * 3600),
        window("seven_day", 10080, used: 62, resetsIn: 3 * 86400),
        window("seven_day_fable", 10080, used: 20, resetsIn: 3 * 86400),
    ], source: "oauth", ts: now - 30, plan: nil)
    let rows = UsageProviderLimits(provider: "claude", set: set, account: nil, now: now).rows
    let words: [LimitPace: String] = [.ahead: "ahead", .on: "on", .under: "under"]
    for panel in set.drawable(at: now) {
        let row = rows.first { $0.id == panel.key }
        check(row?.evenPacePercent == panel.timeLeftPercent(at: now) && row?.evenPacePercent != nil
                && row?.pace == panel.pace(at: now).flatMap { words[$0] },
              "the Usage window's tick and the panel's line agree on \(panel.key): \(row?.evenPacePercent ?? -1)% left, \(row?.pace ?? "-")")
    }
}
usageChecks70()

// The same agreement where the two used to part (the pace harness of 0.30.0): a session blocked by a
// spent week, a Codex window without a length, a figure outside 0...100, a window without a reset.
// The panel draws `usable(_:account:now:)` of its windows, so that is what the Usage rows are held to.
func usageChecks72() {
    let now = 1_795_112_308.0
    func window(_ key: String, _ minutes: Int?, used: Int, resetsIn: Double?) -> NamedWindow {
        NamedWindow(key: key, title: key, badge: nil, minutes: minutes,
                    window: LimitWindow(used: used, resets: resetsIn.map { now + $0 }))
    }
    let words: [LimitPace: String] = [.ahead: "ahead", .on: "on", .under: "under"]
    func agree(_ set: LimitsSet, _ what: String, account: UsageAccount? = nil) {
        let rows = UsageProviderLimits(provider: set.provider, set: set, account: account, now: now).rows
        for panel in set.usable(set.drawable(at: now), account: account, now: now) {
            let row = rows.first { $0.id == panel.key }
            let (line, pace) = (panel.timeLeftPercent(at: now), panel.pace(at: now).flatMap { words[$0] })
            let (reset, rowReset) = (panel.window.resets.map { $0 - now }, row?.resetsAt.map { $0 - now })
            check(row?.remainingPercent == panel.window.remaining && row?.evenPacePercent == line
                    && row?.pace == pace && rowReset == reset,
                  "\(what), \(panel.key): panel \(panel.window.remaining)% left, line \(line ?? -1) \(pace ?? "-") "
                    + "reset \(reset ?? -1); Usage \(row?.remainingPercent ?? -1)% left, "
                    + "tick \(row?.evenPacePercent ?? -1) \(row?.pace ?? "-") reset \(rowReset ?? -1)")
        }
    }
    let spentWeek = LimitsSet(provider: "claude", windows: [
        window("five_hour", 300, used: -20, resetsIn: 18),
        window("seven_day", 10080, used: 100, resetsIn: 3 * 86400),
    ], source: "oauth", ts: now - 30, plan: nil)
    agree(spentWeek, "a session blocked by the spent week")
    let blocked = spentWeek.usable(spentWeek.drawable(at: now), account: nil, now: now).first
    check(blocked?.window.remaining == 0 && blocked?.timeLeftPercent(at: now) == nil && blocked?.pace(at: now) == nil
            && blocked?.window.resets == now + 3 * 86400 && blocked?.title == "five_hour",
          "the panel shows a blocked session with nothing left, no line and the week's reset, under its own name")
    agree(LimitsSet(provider: "claude", windows: [
        window("five_hour", 300, used: -20, resetsIn: 18),
        window("seven_day", 10080, used: 100, resetsIn: nil),
    ], source: "oauth", ts: now - 30, plan: nil), "a blocked session when the week's reset is unknown")
    agree(LimitsSet(provider: "claude", windows: [
        window("five_hour", 300, used: -20, resetsIn: nil),
        window("seven_day", 10080, used: 100, resetsIn: nil),
    ], source: "oauth", ts: now - 30, plan: nil), "a blocked session without reset times")
    let codexWeek = LimitsSet(provider: "codex", windows: [
        window("primary", 300, used: 30, resetsIn: 7200),
        window("secondary", 10080, used: 100, resetsIn: 86400),
        window("reserve:primary", 300, used: 10, resetsIn: 7200),
    ], source: "app-server", ts: now - 30, plan: "plus")
    agree(codexWeek, "a Codex session blocked by the spent week")
    check(codexWeek.usable(codexWeek.drawable(at: now), account: nil, now: now).map(\.window.remaining) == [0, 0, 90],
          "the Reserve pool is not blocked by the ordinary week")
    // limits.json without a plan, account.json with Free or Go: the slot without a length is the
    // Monthly row there, so it is not a session and the spent week does not block it on either side.
    let noPlan = LimitsSet(provider: "codex", windows: [
        window("primary", nil, used: 30, resetsIn: 3600),
        window("secondary", nil, used: 100, resetsIn: 86400),
    ], source: "app-server", ts: now - 30, plan: nil)
    for plan in ["free", "go", "plus"] {
        agree(noPlan, "a plan only account.json knows (\(plan))",
              account: UsageAccount(json: ["provider": "codex", "planType": plan], provider: "codex"))
    }
    agree(LimitsSet(provider: "codex", windows: [
        window("primary", nil, used: 30, resetsIn: 1200),
        window("secondary", nil, used: -20, resetsIn: 604.8),
    ], source: "app-server", ts: now - 30, plan: "plus"), "Codex windows without a length")
    agree(LimitsSet(provider: "claude", windows: [
        window("five_hour", 300, used: 101, resetsIn: 810),
        window("seven_day", 10080, used: -20, resetsIn: 586_656),
    ], source: "oauth", ts: now - 30, plan: nil), "figures outside 0...100")

    // The menu bar icon draws the same windows: a blocked session is a full bar with no line, and a
    // Codex bar keeps the label of the length its writer reported.
    let claudeIcon = LimitsBoard(claude: spentWeek, codex: nil).gauge(at: now)
    check(claudeIcon.fiveHour == 1 && claudeIcon.timeLeft.0 == nil && claudeIcon.sevenDay == 1,
          "the icon draws Claude's blocked session as spent, without a line: "
            + "\(claudeIcon.fiveHour ?? -1) line \(claudeIcon.timeLeft.0 ?? -1)")
    let codexIcon = LimitsBoard(claude: nil, codex: codexWeek).gauge(at: now)
    check(codexIcon.fiveHour == 1 && codexIcon.timeLeft.0 == nil && codexIcon.sevenDay == 1
            && codexIcon.labels == ("5h", "7d"),
          "the icon draws Codex's blocked session as spent, without a line, still labelled 5h: "
            + "\(codexIcon.fiveHour ?? -1) line \(codexIcon.timeLeft.0 ?? -1) \(codexIcon.labels)")
    let open = LimitsBoard(claude: nil, codex: LimitsSet(provider: "codex", windows: [
        window("primary", 300, used: 30, resetsIn: 7200),
        window("secondary", 10080, used: 99, resetsIn: 86400),
    ], source: "app-server", ts: now - 30, plan: "plus")).gauge(at: now)
    check(open.fiveHour == 0.3 && open.timeLeft.0 != nil,
          "a week with room leaves the session's own bar and line in the icon")
}
usageChecks72()

// MARK: Usage window — the files the real Python writers produced
// The same border as the limits seams above, for the Usage window's five files: written by the
// python suite (tests/test_usage_command.py, tests/test_account.py, tests/test_resets.py) with the
// real writers, read here with the real parsers.
let usageSummarySeamPath = FileManager.default.currentDirectoryPath + "/build/seam/usage-summary.json"
if let data = FileManager.default.contents(atPath: usageSummarySeamPath),
   let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    let seam = UsageSummary(json: root)
    check(seam.version == 1 && seam.readAt > 0 && seam.timeZone == "Europe/Berlin"
            && seam.zone.identifier == "Europe/Berlin",
          "usage seam: version, stamp and the zone the days were bucketed in cross over")
    check(seam.pricing.source == "litellm" && ["fresh", "cached", "unavailable"].contains(seam.pricing.status),
          "usage seam: the pricing block reads as a known status: \(seam.pricing.status)")
    check(UsageSummary.periodDays.map { seam.period($0).buckets.count } == [3, 3, 5, 5],
          "usage seam: all four periods arrive with their buckets: "
            + "\(UsageSummary.periodDays.map { seam.period($0).buckets.count })")
    let day = seam.period(1)
    let fast = day.buckets.first { $0.provider == "claude" && $0.hourStart == "2026-11-19T09:37:00.000Z" }
    check(day.isHourly && day.sinceTime != nil && fast?.day == "2026-11-19",
          "usage seam: the past 24h are hourly, aligned to the minute of the scan")
    check(!seam.period(30).isHourly && seam.period(30).sinceTime == nil
            && seam.period(30).buckets.allSatisfy { $0.hourStart == nil },
          "usage seam: the longer periods are daily and carry no hour")
    let sources = seam.period(30).sources
    check(sources.map(\.provider) == ["claude", "codex"] && sources.first?.status == "ok",
          "usage seam: one source per provider, Claude first")
    check(sources.last?.status == "partial" && sources.last?.message == "zstd_unavailable"
            && sources.last?.skippedFiles == 1,
          "usage seam: a compressed rollout nobody could read is a partial source with a fixed category")
    check(seam.period(30).warnings().contains { $0.contains("zstd") } && seam.period(1).warnings().isEmpty,
          "usage seam: that category becomes a sentence, only for the period it happened in: "
            + "\(seam.period(30).warnings())")
    let month = UsageTotals(period: seam.period(30), provider: nil)
    check(month.sessions == 5 && month.providers.map(\.provider) == ["claude", "codex"] && month.costUsd > 0,
          "usage seam: sessions come from the sources, cost from the buckets: \(month.sessions) sessions")
    let unpriced = month.models.first { $0.model == "claude-future-9" }
    check(unpriced?.isCostUnknown == true && month.costQuality.unpricedShare > 0,
          "usage seam: a model without a price is told apart from a free one")
    check(UsageTotals(period: seam.period(30), provider: "codex").providers.map(\.provider) == ["codex"],
          "usage seam: the provider filter keeps one provider's buckets")
} else {
    check(false, "usage summary seam fixture missing at \(usageSummarySeamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/usage-summary.json")
}

let usageStatusSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/usage-status.json"
if let data = FileManager.default.contents(atPath: usageStatusSeamPath),
   let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    let seam = UsageScanStatus(json: root)
    check(seam.state == "ok" && seam.detail.isEmpty && seam.ts > 0 && seam.failureText == nil,
          "usage status seam: a finished scan crosses over as ok with nothing to explain")
    check(seam.done == 0 && seam.total == 0 && seam.progressText(busy: false, hasSummary: true) == nil,
          "usage status seam: the file counter means something only while scanning")
} else {
    check(false, "usage status seam fixture missing at \(usageStatusSeamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/usage-status.json")
}

let accountSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/account.json"
if let data = FileManager.default.contents(atPath: accountSeamPath),
   let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    let seam = UsageAccount(json: root, provider: "claude")
    check(seam.ts > 0 && seam.subscriptionType == "max" && seam.email == "user@example.com",
          "account seam: the plan and the e-mail cross over")
    check(UsagePlan.claudeLabel(seam.subscriptionType) == "Claude Max Subscription",
          "account seam: the plan reads as T3's label")
    let orbit = seam.extraWindows.first
    check(seam.extraWindows.count == 1 && orbit?.id == "seven_day_orbit" && orbit?.kind == "weekly"
            && orbit?.name == "Orbit" && orbit?.usedPercent == 12.5 && orbit?.windowMinutes == 10080
            && orbit?.resetsAt == 1_790_492_400,
          "account seam: a model's own weekly window crosses over with its clock")
    check(seam.spend?.enabled == true && seam.spend?.usedPercent == 40, "account seam: the monthly spend crosses over")
    check(seam.resetCredits?.availableCount == 4 && seam.resetCredits?.nextExpiresAt == 1_796_940_000
            && seam.resetCredits?.options?.map(\.creditId) == ["session_a", "weekly_a", "fable_a"]
            && seam.resetCredits?.options?.map(\.kind) == ["session", "weekly", "fable"]
            && seam.resetCredits?.options?.map(\.availableCount) == [1, 1, 2],
          "account seam: the banked resets cross over, one option per kind with the grant to redeem")
    let built = UsageProviderLimits(provider: "claude", set: nil, account: seam, now: seam.ts)
    check(built.plan == "Claude Max Subscription" && built.email == "user@example.com" && built.ticketCount == 4,
          "account seam: the Limits tab's section is built from it")
    check(built.rows.map(\.label) == ["Weekly · Orbit", "Monthly spend"],
          "account seam: its rows are the ones limits.json cannot hold: \(built.rows.map(\.label))")
    let choices = built.resetChoices(now: seam.ts)
    check(choices.compactMap(\.creditId) == ["session_a", "weekly_a", "fable_a"] && choices.allSatisfy(\.redeemable),
          "account seam: each kind of reset is offered with its own grant: \(choices.map(\.summary))")
} else {
    check(false, "account seam fixture missing at \(accountSeamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/account.json")
}

let codexAccountSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/codex-account.json"
if let data = FileManager.default.contents(atPath: codexAccountSeamPath),
   let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    let seam = UsageAccount(json: root, provider: "codex")
    check(seam.ts > 0 && seam.planType == "promax" && seam.email == "user@example.com"
            && UsagePlan.codexLabel(seam.planType) == "ChatGPT Pro 500 Subscription",
          "codex account seam: the plan and the e-mail cross over")
    let credit = seam.extraWindows.first
    check(seam.extraWindows.count == 1 && credit?.id == "individual" && credit?.kind == "monthly"
            && credit?.name == "Monthly credit limit" && credit?.usedPercent == 30
            && credit?.resetsAt == 1_792_078_400 && credit?.windowMinutes == nil,
          "codex account seam: the credit limit crosses over without a length, so it gets no pace")
    check(seam.resetCredits?.availableCount == 2 && seam.resetCredits?.nextExpiresAt == 1_790_578_400
            && seam.resetCredits?.options == nil,
          "codex account seam: Codex banks resets as a count, not as grants")
    let built = UsageProviderLimits(provider: "codex", set: nil, account: seam, now: seam.ts)
    check(built.rows.map(\.label) == ["Monthly credit limit"] && built.rows.first?.evenPacePercent == nil,
          "codex account seam: an account with nothing but a credit limit still has a row: \(built.rows.map(\.label))")
    let choices = built.resetChoices(now: seam.ts)
    check(choices.count == 1 && choices.first?.creditId == nil && choices.first?.redeemable == true,
          "codex account seam: one choice and no id — the backend picks the credit itself")
} else {
    check(false, "codex account seam fixture missing at \(codexAccountSeamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/codex-account.json")
}

let resetResultSeamPath = FileManager.default.currentDirectoryPath + "/build/seam/reset-credit-result.json"
if let data = FileManager.default.contents(atPath: resetResultSeamPath),
   let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
    let seam = UsageResetResult(json: root, provider: "claude")
    check(seam.ts > 0 && seam.creditId == "weekly_a" && seam.outcome == "reset" && seam.error == nil && seam.confirmed,
          "reset result seam: a confirmed reset crosses over with the grant it spent")
    check(seam.message == "Reset applied. Your windows have cleared.",
          "reset result seam: and reads as T3's sentence: \(seam.message)")
} else {
    check(false, "reset result seam fixture missing at \(resetResultSeamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/reset-credit-result.json")
}

print(failures == 0 ? "\nall model checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
