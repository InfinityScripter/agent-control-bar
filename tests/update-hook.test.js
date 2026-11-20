// hooks/update.js: the per-event hook. tests/merge.test.js covers the context figure, the Codex
// threads and the Quit marker; this file covers what the state file says between those — labels,
// the turn clock, what survives an event that omits a field, and the hook's own failure modes.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const {
  scripts, sandbox, run, execLog, spawnLog, barDir, stateDir, codexStateDir, readJSON,
} = require("./hook-harness");

const event = (home, name, payload, opts = {}) => {
  const res = run(scripts.update, home, { ...opts, argv: [name, ...(opts.argv || [])],
    stdin: typeof payload === "string" ? payload : JSON.stringify(payload) });
  // An exception in this hook aborts the Claude Code event it runs under, not only the update.
  assert.equal(res.status, 0, res.stderr);
  return res;
};
const state = (home, sid) => readJSON(path.join(stateDir(home), sid + ".json"));

test("each Claude tool reads as its activity, and an unknown tool as plain tool use", (t) => {
  const home = sandbox(t);
  for (const [tool, label] of [["Bash", "Running command"], ["Read", "Reading"],
    ["Grep", "Searching"], ["MultiEdit", "Editing"], ["Task", "Delegating"],
    ["mcp__github__get_me", "Using tool"]]) {
    event(home, "pre", { session_id: "s1", cwd: home, tool_name: tool });
    const s = state(home, "s1");
    assert.equal(s.state, "tool");
    assert.equal(s.label, label, tool);
    assert.equal(s.tool, tool);
  }
});

test("codex tools get codex's labels, never Claude's", (t) => {
  // "Read" is a Claude tool name; were the tables crossed, a Codex tool that happened to share
  // a name would read as the wrong activity. apply_patch is Codex's only editor.
  const home = sandbox(t);
  for (const [tool, label] of [["apply_patch", "Editing"], ["js", "Running code"],
    ["spawn_agent", "Delegating"], ["Read", "Using tool"]]) {
    event(home, "pre", { session_id: "c1", cwd: home, tool_name: tool },
      { argv: ["--provider", "codex"] });
    assert.equal(readJSON(path.join(codexStateDir(home), "c1.json")).label, label, tool);
  }
});

test("the Claude update labels only exact service hosts and recognizes cloud backends", (t) => {
  const home = sandbox(t);
  const cases = [
    [undefined, "anthropic"], ["https://api.anthropic.com", "anthropic"],
    ["https://api.z.ai/api/anthropic", "zai"], ["https://open.bigmodel.cn/api/anthropic", "zai"],
    ["https://api.deepseek.com/anthropic", "deepseek"], ["https://openrouter.ai/api", "openrouter"],
    ["https://api.z.ai.example.test", "custom"], ["https://api.z.ai@other.test", "custom"],
    ["not a url", "custom"],
  ];
  for (const [baseURL, expected] of cases) {
    event(home, "prompt", { session_id: "s1" }, { env: {
      ANTHROPIC_BASE_URL: baseURL, CLAUDE_CODE_USE_BEDROCK: undefined,
      CLAUDE_CODE_USE_VERTEX: undefined, CLAUDE_CODE_USE_FOUNDRY: undefined,
    } });
    assert.equal(state(home, "s1").modelService, expected, baseURL);
  }
  event(home, "prompt", { session_id: "s1" }, { env: {
    ANTHROPIC_BASE_URL: undefined, CLAUDE_CODE_USE_BEDROCK: "1",
  } });
  assert.equal(state(home, "s1").modelService, "custom");
});

test("Codex retains the model service across an unreadable rollout and retries the header", (t) => {
  const home = sandbox(t);
  const first = path.join(home, "first.jsonl");
  const second = path.join(home, "second.jsonl");
  const out = path.join(codexStateDir(home), "c1.json");
  fs.writeFileSync(first, JSON.stringify({ type: "session_meta", payload: { model_provider: "deepseek" } }));
  event(home, "prompt", { session_id: "c1", transcript_path: first }, { argv: ["--provider", "codex"] });
  assert.equal(readJSON(out).modelService, "deepseek");
  event(home, "prompt", { session_id: "c1", transcript_path: second }, { argv: ["--provider", "codex"] });
  assert.equal(readJSON(out).modelService, "deepseek");
  fs.writeFileSync(second, JSON.stringify({ type: "session_meta", payload: { model_provider: "openrouter" } }));
  event(home, "prompt", { session_id: "c1", transcript_path: second }, { argv: ["--provider", "codex"] });
  assert.equal(readJSON(out).modelService, "openrouter");
});

test("the turn clock starts at the prompt, runs through its tools and stops at Stop", (t) => {
  // startedAt drives the elapsed timer on the session row. A tool event resetting it would make
  // a long turn look a few seconds old after every tool call.
  const home = sandbox(t);
  fs.mkdirSync(stateDir(home), { recursive: true });
  fs.writeFileSync(path.join(stateDir(home), "s1.json"), JSON.stringify({ startedAt: 0 }));

  event(home, "prompt", { session_id: "s1", cwd: home });
  const begun = state(home, "s1").startedAt;
  assert.ok(begun > 0);
  // Pinned to a past moment so a reset to "now" cannot hide inside the same second.
  fs.writeFileSync(path.join(stateDir(home), "s1.json"),
    JSON.stringify({ ...state(home, "s1"), startedAt: 1000 }));

  event(home, "pre", { session_id: "s1", cwd: home, tool_name: "Bash" });
  assert.equal(state(home, "s1").startedAt, 1000);
  event(home, "post", { session_id: "s1", cwd: home, tool_name: "Bash" });
  assert.equal(state(home, "s1").startedAt, 1000);
  assert.equal(state(home, "s1").state, "thinking");

  event(home, "stop", { session_id: "s1", cwd: home });
  assert.equal(state(home, "s1").startedAt, 0);
});

test("waiting for a permission does not restart the turn clock", (t) => {
  // The next event after an approval is PostToolUse, at the END of the approved tool. A clock
  // zeroed by the request restarted there, so a ten-minute build read as a turn a second old
  // and the long-turn sound measured from the end of the wait instead of from the prompt.
  for (const [ask, payload] of [["permreq", {}],
    ["notify", { notification_type: "permission_prompt" }]]) {
    const home = sandbox(t);
    event(home, "prompt", { session_id: "s1", cwd: home });
    fs.writeFileSync(path.join(stateDir(home), "s1.json"),
      JSON.stringify({ ...state(home, "s1"), startedAt: 1000 }));

    event(home, ask, { session_id: "s1", cwd: home, ...payload });
    assert.equal(state(home, "s1").state, "permission", ask);
    assert.equal(state(home, "s1").startedAt, 1000, ask);
    event(home, "post", { session_id: "s1", cwd: home, tool_name: "Bash" });
    assert.equal(state(home, "s1").startedAt, 1000, ask);
  }
});

test("a tool event in a session that never saw its prompt still starts the clock", (t) => {
  // The hooks were installed mid-turn: there was no prompt event to start it, and a zero here
  // reads to the app as "no turn running" while a tool visibly is.
  const home = sandbox(t);
  event(home, "post", { session_id: "late", cwd: home, tool_name: "Bash" });
  assert.ok(state(home, "late").startedAt > 0);
});

test("fields an event leaves out are carried over from the session's file", (t) => {
  // Not every hook payload carries cwd, and the env vars that name the terminal are missing in
  // some hosts' hook processes. A blank on one event would drop the branch and the row click.
  const home = sandbox(t);
  const cwd = path.join(home, "work", "my-project");
  fs.mkdirSync(cwd, { recursive: true });
  event(home, "prompt", { session_id: "s1", cwd }, { env: {
    CLAUDE_CODE_ENTRYPOINT: "cli", TERM_PROGRAM: "iTerm.app",
    __CFBundleIdentifier: "com.googlecode.iterm2" } });

  event(home, "pre", { session_id: "s1", tool_name: "Read" }, { env: {
    CLAUDE_CODE_ENTRYPOINT: undefined, TERM_PROGRAM: undefined, __CFBundleIdentifier: undefined } });

  const s = state(home, "s1");
  assert.equal(s.cwd, cwd);
  assert.equal(s.project, "my-project");
  assert.equal(s.entrypoint, "cli");
  assert.equal(s.term_program, "iTerm.app");
  assert.equal(s.term_bundle, "com.googlecode.iterm2");
  assert.equal(s.started, true, "any update.js event is real activity");
});

test("a payload that does not parse still yields a state file, not a crash", (t) => {
  // The hook must exit 0 whatever arrives on stdin; a session id it cannot read becomes
  // "unknown" rather than a path built from undefined.
  const home = sandbox(t);
  event(home, "prompt", "{not json");
  assert.equal(state(home, "unknown").state, "thinking");
});

// What Cursor 3.30 sends, field for field. It runs the hooks in ~/.claude/settings.json for its
// own agent, and `cursor_version` is on every one of the 981 events in its hooks log that reached
// this script; Claude Code sends no such field.
const cursorEvent = (extra) => ({ conversation_id: "c0", generation_id: "g0", session_id: "cur1",
  hook_event_name: "preToolUse", cursor_version: "3.30.14", workspace_roots: ["/repo"],
  transcript_path: null, ...extra });

test("a run of Cursor's own agent is not a Claude Code session", (t) => {
  // Its Stop never arrived for seven of ten runs measured, so each sat in the panel as a nameless
  // "session" thinking for fifteen minutes, and seven at once set the crab on fire.
  const home = sandbox(t);
  const env = { CLAUDE_CODE_ENTRYPOINT: undefined };
  event(home, "prompt", cursorEvent({ hook_event_name: "beforeSubmitPrompt", prompt: "hi" }), { env });
  event(home, "pre", cursorEvent({ tool_name: "Shell" }), { env });
  event(home, "post", cursorEvent({ hook_event_name: "postToolUse", tool_name: "Shell" }), { env });
  event(home, "stop", cursorEvent({ hook_event_name: "stop",
    transcript_path: path.join(home, ".cursor", "projects", "repo", "t.jsonl") }), { env });
  assert.equal(fs.existsSync(path.join(stateDir(home), "cur1.json")), false);
  assert.deepEqual(spawnLog(home), [], "and somebody else's agent does not launch the app");
});

test("a Claude Code session that names no entrypoint is still a session", (t) => {
  // The line the Cursor check must not cross: an empty CLAUDE_CODE_ENTRYPOINT is allowed, so
  // its absence alone is no evidence of another host.
  const home = sandbox(t);
  event(home, "prompt", { session_id: "s1", cwd: home, hook_event_name: "UserPromptSubmit" },
    { env: { CLAUDE_CODE_ENTRYPOINT: undefined } });
  assert.equal(state(home, "s1").state, "thinking");
  assert.equal(state(home, "s1").entrypoint, "");
});

test("a corrupt state file from an earlier event is replaced, not fatal", (t) => {
  const home = sandbox(t);
  fs.mkdirSync(stateDir(home), { recursive: true });
  fs.writeFileSync(path.join(stateDir(home), "s1.json"), "{\"state\": \"tool\", trunc");
  event(home, "stop", { session_id: "s1", cwd: home });
  assert.equal(state(home, "s1").state, "done");
  assert.deepEqual(fs.readdirSync(stateDir(home)), ["s1.json"], "no temp file is left behind");
});

test("a notification that is not a permission prompt leaves the session's state alone", (t) => {
  // The idle notification ("Claude is waiting for your input") arrives after Stop; letting it
  // rewrite the file would turn a finished turn's "Done" back into something else.
  const home = sandbox(t);
  event(home, "stop", { session_id: "s1", cwd: home });
  const before = fs.readFileSync(path.join(stateDir(home), "s1.json"), "utf8");
  event(home, "notify", { session_id: "s1", notification_type: "idle_prompt",
    message: "Claude is waiting for your input" });
  assert.equal(fs.readFileSync(path.join(stateDir(home), "s1.json"), "utf8"), before);
});

test("the debug log stays off unless asked for, and is owner-only when on", (t) => {
  // It carries excerpts of what was typed; the home folder is readable by group staff on macOS.
  const quiet = sandbox(t);
  event(quiet, "prompt", { session_id: "s1", cwd: quiet, message: "secret" },
    { env: { CONTROL_BAR_DEBUG: undefined } });
  assert.equal(fs.existsSync(path.join(barDir(quiet), "hooks.log")), false);

  const home = sandbox(t);
  event(home, "notify", { session_id: "s1", message: "x".repeat(500) },
    { env: { CONTROL_BAR_DEBUG: "1" } });
  const logPath = path.join(barDir(home), "hooks.log");
  assert.equal(fs.statSync(logPath).mode & 0o777, 0o600);
  const line = fs.readFileSync(logPath, "utf8");
  assert.match(line, /\[notify\]/);
  // The excerpt is capped; the whole message never lands in the file.
  assert.ok(!line.includes("x".repeat(200)));
});

test("the debug log rotates past a megabyte and keeps one previous file", (t) => {
  const home = sandbox(t);
  fs.mkdirSync(barDir(home), { recursive: true });
  const logPath = path.join(barDir(home), "hooks.log");
  fs.writeFileSync(logPath, "o".repeat(1_000_001));

  event(home, "prompt", { session_id: "s1", cwd: home }, { env: { CONTROL_BAR_DEBUG: "1" } });

  assert.equal(fs.statSync(logPath + ".1").size, 1_000_001);
  assert.ok(fs.statSync(logPath).size < 1000, "the live log starts over");
});

test("a running app is probed, found and left alone", (t) => {
  // The self-heal relaunch is for a missing app. With the app up, an `open` would be a needless
  // LaunchServices round-trip on every probe window.
  const home = sandbox(t);
  event(home, "prompt", { session_id: "s1", cwd: home }, { env: { APP_RUNNING: "1" } });
  assert.ok(execLog(home).some((c) => c === "pgrep -x ClaudeControlBar"));
  assert.deepEqual(spawnLog(home), []);

  const down = sandbox(t);
  event(down, "prompt", { session_id: "s1", cwd: down });
  assert.deepEqual(spawnLog(down),
    ["open -g -b io.github.infinityscripter.claude-control-bar"]);
});
