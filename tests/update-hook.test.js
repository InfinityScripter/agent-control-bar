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
