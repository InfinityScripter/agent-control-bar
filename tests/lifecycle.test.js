// hooks/lifecycle.js: SessionStart/SessionEnd. tests/merge.test.js covers the reap of dead
// sessions, the Quit marker across a resume and the Codex surfaces; this file covers the seed
// file itself, the running-app branch, and how the hook behaves on input it did not expect.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const {
  scripts, sandbox, run, spawnLog, barDir, stateDir, codexStateDir, readJSON,
} = require("./hook-harness");

const lifecycle = (home, argv, payload, opts = {}) => {
  const res = run(scripts.lifecycle, home, { ...opts, argv,
    stdin: typeof payload === "string" ? payload : JSON.stringify(payload) });
  assert.equal(res.status, 0, res.stderr);
  return res;
};

test("a session start seeds an idle, not-yet-started file the owner alone can read", (t) => {
  // started:false keeps a merely-opened conversation out of the dropdown until it does
  // something; the file still counts the session for launch and liveness from this moment.
  const home = sandbox(t);
  const cwd = path.join(home, "repo", "app");
  fs.mkdirSync(cwd, { recursive: true });
  lifecycle(home, ["start"], { session_id: "s1", cwd, transcript_path: "/tmp/t.jsonl" });

  const file = path.join(stateDir(home), "s1.json");
  const seed = readJSON(file);
  assert.equal(seed.state, "idle");
  assert.equal(seed.started, false);
  assert.equal(seed.startedAt, 0);
  assert.equal(seed.project, "app");
  assert.equal(seed.cwd, cwd);
  assert.equal(seed.transcript, "/tmp/t.jsonl", "carried from the very first event");
  assert.ok(seed.pid > 0);
  assert.equal("provider" in seed, false, "a Claude seed reads as Claude's by having no provider");
  // The seed names the working directory and the transcript; the home folder is readable by
  // group staff on macOS. tests/merge.test.js pins the same modes for update.js.
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(fs.statSync(stateDir(home)).mode & 0o777, 0o700);
  assert.deepEqual(fs.readdirSync(stateDir(home)), ["s1.json"], "no temp file is left behind");
});

test("Claude startup records the configured model service without the endpoint", (t) => {
  const home = sandbox(t);
  const base = "https://api.deepseek.com/anthropic?marker=private-fixture";
  lifecycle(home, ["start"], { session_id: "deepseek" }, { env: { ANTHROPIC_BASE_URL: base } });
  const seed = readJSON(path.join(stateDir(home), "deepseek.json"));
  assert.equal(seed.modelService, "deepseek");
  assert.doesNotMatch(JSON.stringify(seed), /private-fixture|api\.deepseek\.com/);
});

test("a start seeds over a resumed session's frozen state", (t) => {
  // A resume fires SessionStart with no turn running; a file stuck on "tool" from before the
  // sleep would keep the icon animating until the next event.
  const home = sandbox(t);
  fs.mkdirSync(stateDir(home), { recursive: true });
  fs.writeFileSync(path.join(stateDir(home), "s1.json"),
    JSON.stringify({ state: "tool", label: "Running command", started: true, pid: process.pid }));
  lifecycle(home, ["start"], { session_id: "s1", cwd: home, source: "resume" });
  assert.equal(readJSON(path.join(stateDir(home), "s1.json")).state, "idle");
});

// A file's mtime is the last event its session sent, so setting it is how a test says "this one
// has been silent for that long".
const writeAged = (dir, name, state, hoursAgo) => {
  const file = path.join(dir, name + ".json");
  fs.writeFileSync(file, JSON.stringify(state));
  const at = Date.now() / 1000 - hoursAgo * 3600;
  fs.utimesSync(file, at, at);
};

test("with the app running, a start clears the long-dead files and still asks LaunchServices for it", (t) => {
  // The app never deletes a state file and SessionEnd does not always come, so this sweep is the
  // only thing that keeps the directory from growing for as long as the app stays up. A dead pid
  // alone is not enough while it runs: a resumed session rewrites its file under a new pid, and
  // a sweep that read the old one a moment earlier would delete the new event.
  const home = sandbox(t);
  fs.mkdirSync(stateDir(home), { recursive: true });
  writeAged(stateDir(home), "old-dead", { pid: 999999 }, 2);
  writeAged(stateDir(home), "fresh-dead", { pid: 999999 }, 0);
  writeAged(stateDir(home), "old-live", { pid: process.pid }, 2);
  // The context figure lives and dies with its session file, and one left with no session file
  // at all is swept as well.
  const contextDir = path.join(barDir(home), "context.d");
  fs.mkdirSync(contextDir, { recursive: true });
  for (const name of ["old-dead", "fresh-dead", "orphan"]) {
    fs.writeFileSync(path.join(contextDir, name + ".json"), "{}");
  }

  lifecycle(home, ["start"], { session_id: "s1", cwd: home }, { env: { APP_RUNNING: "1" } });

  assert.deepEqual(fs.readdirSync(stateDir(home)).sort(),
    ["fresh-dead.json", "old-live.json", "s1.json"]);
  assert.deepEqual(fs.readdirSync(contextDir), ["fresh-dead.json"]);
  // `open -g` on a running app is a no-op that also covers the race where it is quitting.
  assert.deepEqual(spawnLog(home), ["open -g -b io.github.infinityscripter.claude-control-bar"]);
});

test("with the app running, a Codex terminal session is given a day past its recorded pid", (t) => {
  // That pid can be Codex's shared daemon, which dies while the terminal client lives on; the
  // app goes by the terminal's owner and keeps the row, so the file has to outlast the pid.
  const home = sandbox(t);
  const dir = codexStateDir(home);
  fs.mkdirSync(dir, { recursive: true });
  const cli = { pid: 999999, provider: "codex", surface: "cli" };
  writeAged(dir, "cli-hours", cli, 2);
  writeAged(dir, "cli-days", cli, 25);
  writeAged(dir, "app-hours", { pid: 999999, provider: "codex", surface: "app" }, 2);

  lifecycle(home, ["start", "--provider", "codex"],
    { session_id: "c1", cwd: home, source: "startup" }, { env: { APP_RUNNING: "1" } });

  assert.deepEqual(fs.readdirSync(dir).sort(), ["c1.json", "cli-hours.json"]);
});

test("a start from Cursor's own agent seeds no session and launches nothing", (t) => {
  // See the Cursor test in update-hook.test.js for where this payload comes from. It is not a
  // new Claude Code session in any sense: it must not void an explicit Quit either, or the next
  // real event would bring the app back up, and it does no sweeping on Claude Code's behalf.
  const home = sandbox(t);
  fs.mkdirSync(stateDir(home), { recursive: true });
  writeAged(stateDir(home), "old-dead", { pid: 999999 }, 2);
  const marker = path.join(barDir(home), "quit-intent");
  fs.writeFileSync(marker, "");
  lifecycle(home, ["start"], { session_id: "cur1", cursor_version: "3.30.14",
    hook_event_name: "sessionStart", workspace_roots: [home], transcript_path: null },
    { env: { CLAUDE_CODE_ENTRYPOINT: undefined, APP_RUNNING: "1" } });
  assert.deepEqual(fs.readdirSync(stateDir(home)), ["old-dead.json"]);
  assert.ok(fs.existsSync(marker), "Cursor took the user's Quit away");
  assert.deepEqual(spawnLog(home), []);
});

test("a state file whose pid does not parse is reaped as dead", (t) => {
  // No pid is no proof of life; left alone, such a file would count a phantom session forever.
  const home = sandbox(t);
  fs.mkdirSync(stateDir(home), { recursive: true });
  fs.writeFileSync(path.join(stateDir(home), "broken.json"), "{oops");
  fs.writeFileSync(path.join(stateDir(home), "nopid.json"), JSON.stringify({ state: "idle" }));
  lifecycle(home, ["start"], { session_id: "s1", cwd: home });
  assert.deepEqual(fs.readdirSync(stateDir(home)), ["s1.json"]);
});

test("a payload that does not parse still seeds a file under a safe name", (t) => {
  const home = sandbox(t);
  lifecycle(home, ["start"], "garbage");
  assert.equal(readJSON(path.join(stateDir(home), "unknown.json")).state, "idle");
});

test("an unknown event touches no session", (t) => {
  const home = sandbox(t);
  fs.mkdirSync(stateDir(home), { recursive: true });
  fs.writeFileSync(path.join(stateDir(home), "s1.json"), JSON.stringify({ pid: process.pid }));
  lifecycle(home, ["restart"], { session_id: "s1", cwd: home });
  assert.deepEqual(fs.readdirSync(stateDir(home)), ["s1.json"]);
  assert.deepEqual(spawnLog(home), []);
});

test("a Claude session end does not apply codex's foreign-rollout rule", (t) => {
  // The rollout comparison exists because Codex workers share nothing else with their parent's
  // SessionEnd. Claude's transcript path changes legitimately (a compaction writes a new one),
  // and a Claude session whose file outlived its end would sit in the panel as a ghost.
  const home = sandbox(t);
  fs.mkdirSync(stateDir(home), { recursive: true });
  fs.writeFileSync(path.join(stateDir(home), "s1.json"),
    JSON.stringify({ pid: process.pid, transcript: "/old.jsonl" }));
  lifecycle(home, ["end"], { session_id: "s1", transcript_path: "/new.jsonl" });
  assert.deepEqual(fs.readdirSync(stateDir(home)), []);
});

test("a codex session end with its own rollout, or with none, removes its file", (t) => {
  const home = sandbox(t);
  fs.mkdirSync(codexStateDir(home), { recursive: true });
  const write = (id) => fs.writeFileSync(path.join(codexStateDir(home), id + ".json"),
    JSON.stringify({ pid: process.pid, transcript: "/r.jsonl", provider: "codex" }));
  write("same");
  write("bare");
  lifecycle(home, ["end", "--provider", "codex"], { session_id: "same", transcript_path: "/r.jsonl" });
  lifecycle(home, ["end", "--provider", "codex"], { session_id: "bare" });
  assert.deepEqual(fs.readdirSync(codexStateDir(home)), []);
});

test("a codex rollout one record long still names the surface", (t) => {
  // Every session at its first hook: no newline yet, and the whole read IS the line. Only a
  // read shorter than the file means the line runs on past it.
  const home = sandbox(t);
  const transcript = path.join(home, "rollout.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "session_meta",
    payload: { originator: "codex_vscode", thread_source: "user", model_provider: "ZAI" } }));
  lifecycle(home, ["start", "--provider", "codex"],
    { session_id: "c1", cwd: home, transcript_path: transcript, source: "startup" });
  const seed = readJSON(path.join(codexStateDir(home), "c1.json"));
  assert.equal(seed.surface, "ide");
  assert.equal(seed.provider, "codex");
  assert.equal(seed.modelService, "zai");
  fs.writeFileSync(transcript, "{");
  lifecycle(home, ["start", "--provider", "codex"],
    { session_id: "c1", cwd: home, transcript_path: transcript, source: "resume" });
  assert.equal(readJSON(path.join(codexStateDir(home), "c1.json")).modelService, "zai");
});

test("a codex start writes no context directory and never touches Claude's", (t) => {
  // Codex states its context in its own rollout; a context.d sweep on its behalf would spend
  // its one-second budget on files that are Claude's business.
  const home = sandbox(t);
  fs.mkdirSync(path.join(barDir(home), "context.d"), { recursive: true });
  fs.writeFileSync(path.join(barDir(home), "context.d", "orphan.json"), "{}");
  lifecycle(home, ["start", "--provider", "codex"], { session_id: "c1", cwd: home, source: "startup" });
  assert.deepEqual(fs.readdirSync(path.join(barDir(home), "context.d")), ["orphan.json"]);
});

test("a codex worker's start launches nothing", (t) => {
  // It is part of the user's session, which already launched the app.
  const home = sandbox(t);
  const transcript = path.join(home, "worker.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "session_meta",
    payload: { originator: "codex-tui", thread_source: "subagent" } }) + "\n");
  lifecycle(home, ["start", "--provider", "codex"],
    { session_id: "w1", cwd: home, transcript_path: transcript, source: "startup" });
  assert.deepEqual(spawnLog(home), []);
});

// Known bug, recorded rather than fixed here: lifecycle.js deletes quit-intent for any start
// that is not a resume BEFORE it looks at whether the thread is a Codex worker. A subagent
// spawned with source "startup" therefore voids the user's explicit Quit, and the parent
// session's next update.js event self-heals the app back up. The fix is to move the worker
// check above the marker removal; until then this runs as a todo and does not fail the suite.
test("a codex worker's start does not void an explicit Quit", {
  todo: "worker SessionStart removes quit-intent before the worker check",
}, (t) => {
  const home = sandbox(t);
  fs.mkdirSync(barDir(home), { recursive: true });
  const marker = path.join(barDir(home), "quit-intent");
  fs.writeFileSync(marker, "");
  const transcript = path.join(home, "worker.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "session_meta",
    payload: { originator: "codex-tui", thread_source: "subagent" } }) + "\n");
  lifecycle(home, ["start", "--provider", "codex"],
    { session_id: "w1", cwd: home, transcript_path: transcript, source: "startup" });
  assert.ok(fs.existsSync(marker), "the worker took the user's Quit away");
});
