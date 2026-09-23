// Behaviour introduced by merging claude-mcp-bar in. Every case here is a defect that was
// either shipped once or caught with a measurement — not a shape check on the code.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

const installerPath = path.resolve(__dirname, "../hooks/install.js");
const lifecyclePath = path.resolve(__dirname, "../hooks/lifecycle.js");
const updatePath = path.resolve(__dirname, "../hooks/update.js");

const sandbox = () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "ccb-"));
  fs.mkdirSync(path.join(home, ".claude", "control-bar", "state.d"), { recursive: true });
  return home;
};

// child_process is stubbed out: the real scripts pgrep and spawn `open`, and a test must not
// launch a menu bar app or kill the one the developer is using. execSync THROWS, because the
// only thing these scripts run through it is `pgrep -x`, and that is how pgrep reports "no such
// process" — the branch under test. spawn records every call into spawnLog(home) instead of
// merely silencing it, so a test can also assert the app was NOT launched.
const run = (scriptPath, home, argv = [], stdin = "{}") =>
  execFileSync(
    process.execPath,
    ["-e", [
      `require("node:child_process").execSync = () => { throw new Error("pgrep: no match"); };`,
      `require("node:child_process").spawn = (cmd, args) => {`,
      `  require("node:fs").appendFileSync(process.env.SPAWN_LOG, cmd + " " + args.join(" ") + "\\n");`,
      `  return { unref() {} };`,
      `};`,
      `require(process.env.SCRIPT_PATH);`,
      // The scripts read their event from process.argv[2]. Under `node -e` the script path is
      // not in argv, so it is put back here — otherwise the event lands in argv[1] and every
      // hook silently takes its "unknown event" branch and writes nothing.
    ].join("\n"), scriptPath, ...argv],
    { env: { ...process.env, HOME: home, SCRIPT_PATH: scriptPath,
             SPAWN_LOG: path.join(home, "spawn-calls.txt") },
      input: stdin, stdio: "pipe" }
  ).toString();

const settingsPath = (home) => path.join(home, ".claude", "settings.json");
const stateDir = (home) => path.join(home, ".claude", "control-bar", "state.d");
const spawnLog = (home) => path.join(home, "spawn-calls.txt");

test("the app channel stands down while the plugin owns the hooks", () => {
  const home = sandbox();
  const pluginRoot = path.join(home, "plugin");
  fs.mkdirSync(pluginRoot);
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "owner.json"),
    JSON.stringify({ channel: "plugin", pluginRoot }));

  const out = run(installerPath, home);
  assert.match(out, /Plugin channel owns the hooks/);
  // Claude Code merges plugin hooks with settings.json hooks and runs every match; installing
  // both sets means two node processes per tool call, forever.
  assert.deepEqual(JSON.parse(fs.readFileSync(settingsPath(home), "utf8")).hooks, {});
});

test("the lease is reclaimed once the plugin directory is gone", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "owner.json"),
    JSON.stringify({ channel: "plugin", pluginRoot: path.join(home, "uninstalled-plugin") }));

  run(installerPath, home);
  const commands = Object.values(JSON.parse(fs.readFileSync(settingsPath(home), "utf8")).hooks)
    .flat().flatMap((e) => e.hooks || []).map((h) => h.command);
  assert.equal(commands.length, 8, "all eight hooks reinstated");
});

test("a second install run leaves settings.json byte-identical", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }));
  run(installerPath, home);
  const first = fs.readFileSync(settingsPath(home));
  const out = run(installerPath, home);
  // The app runs the installer on every launch so it can reclaim the hooks when the plugin
  // goes away. Rewriting an unchanged file each time churns something the user edits by hand.
  assert.match(out, /already current/);
  assert.deepEqual(fs.readFileSync(settingsPath(home)), first);
});

test("a session start reaps only sessions whose process is gone", () => {
  const home = sandbox();
  const live = { sessionId: "live", pid: process.pid, ts: 1 };
  const dead = { sessionId: "dead", pid: 999999, ts: 1 };
  fs.writeFileSync(path.join(stateDir(home), "live.json"), JSON.stringify(live));
  fs.writeFileSync(path.join(stateDir(home), "dead.json"), JSON.stringify(dead));

  run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "new", cwd: home }));

  const left = fs.readdirSync(stateDir(home)).sort();
  // This used to clear the whole directory whenever the app was not running. Two sessions
  // opening at once both see it down, and the second wiped the first one's file.
  assert.deepEqual(left, ["live.json", "new.json"]);
});

test("a session file is readable by its owner and nobody else", () => {
  const home = sandbox();
  // The sandbox pre-creates state.d with the umask default; removed so the hook creates it and
  // the mode under test is the one the hook asks for.
  fs.rmSync(stateDir(home), { recursive: true, force: true });

  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s0", cwd: home }));

  // The file names the working directory, the transcript and the pid, and a macOS home folder is
  // group-readable by staff — which is every local account on the machine.
  assert.equal(fs.statSync(path.join(stateDir(home), "s0.json")).mode & 0o777, 0o600);
  assert.equal(fs.statSync(stateDir(home)).mode & 0o777, 0o700);
});

test("context is measured from the transcript with the CLI's own formula", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  fs.writeFileSync(transcript, [
    JSON.stringify({ type: "assistant", message: { model: "claude-opus-4-8", content: [{ text: "hi" }],
      usage: { input_tokens: 1000, cache_creation_input_tokens: 4000, cache_read_input_tokens: 95000,
               output_tokens: 50000 } } }),
    // Appended after the real turn and must not be measured — an interrupted turn once showed 0%.
    JSON.stringify({ type: "assistant", message: { model: "claude-opus-4-8",
      content: [{ text: "[Request interrupted by user]" }], usage: { input_tokens: 5 } } }),
  ].join("\n"));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-8": 1000000 } }));

  run(updatePath, home, ["prompt"],
      JSON.stringify({ session_id: "s1", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s1.json"), "utf8"));
  // 1000 + 4000 + 95000 = 100000 of 1000000. output_tokens is NOT in the numerator.
  assert.equal(state.tokens, 100000);
  assert.equal(state.pct, 10);
  assert.equal(state.assumed, false);
});

test("a model absent from the registry borrows its family's widest window", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
    model: "claude-opus-5", content: [{ text: "hi" }],
    usage: { input_tokens: 154452 } } }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-5": 200000, "claude-opus-4-8": 1000000 } }));

  run(updatePath, home, ["prompt"],
      JSON.stringify({ session_id: "s2", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s2.json"), "utf8"));
  // Measured on Claude Code 2.1.205: transcripts say claude-opus-5, a name the binary's model
  // registry does not contain at all. Falling through to the 200k default put this very session
  // at 77% when the honest figure is 15%.
  assert.equal(state.window, 1000000);
  assert.equal(state.pct, 15);
  assert.equal(state.assumed, true, "an inferred window is marked, not passed off as measured");
});

// The same cases scripts/mcpbar.py's window_for is checked against (tests/test_mcpbar.py): two
// copies of one rule in two languages, pinned by one table instead of a "keep in step" comment.
test("windowFor agrees with window_for on every shared case", () => {
  const { cases } = JSON.parse(
    fs.readFileSync(path.resolve(__dirname, "fixtures/window-for.json"), "utf8"));
  for (const [i, c] of cases.entries()) {
    const home = sandbox();
    const transcript = path.join(home, "t.jsonl");
    // One token: small enough that no window is overflowed into the million one.
    fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
      model: c.model, content: [{ text: "hi" }], usage: { input_tokens: 1 } } }));
    fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
      JSON.stringify({ models: c.table }));
    run(updatePath, home, ["prompt"],
        JSON.stringify({ session_id: "w" + i, cwd: home, transcript_path: transcript }));
    const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "w" + i + ".json"), "utf8"));
    assert.equal(state.window, c.window, c.model);
    assert.equal(state.assumed, !c.exact, c.model);
  }
});

// The window a session runs in is a property of the SESSION, not of the model: the same
// claude-opus-5 answers with 200k in one place and 1M in another. Recomputing from the
// transcript has to guess which, and a wrong guess moves the percentage by a factor of five.
// Claude Code states both the size and the finished percentage in the statusLine payload.
const writeContextSidecar = (home, sid, record) => {
  const dir = path.join(home, ".claude", "control-bar", "context.d");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify(record));
};

test("Claude Code's own context figure beats the transcript recomputation", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
    model: "claude-opus-5", content: [{ text: "hi" }],
    usage: { input_tokens: 192782 } } }));
  // The scraped table is behind and says 200k — recomputing here yields 96%.
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-5": 200000 } }));
  writeContextSidecar(home, "s4", {
    pct: 19, tokens: 192782, window: 1000000, model: "claude-opus-5",
    ts: Math.floor(Date.now() / 1000),
  });

  run(updatePath, home, ["prompt"],
      JSON.stringify({ session_id: "s4", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s4.json"), "utf8"));
  assert.equal(state.pct, 19);
  assert.equal(state.window, 1000000);
  assert.equal(state.assumed, false, "a figure Claude Code stated is measured, not inferred");
});

test("a statusLine reading old enough to be stale loses to the transcript", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
    model: "claude-opus-4-8", content: [{ text: "hi" }],
    usage: { input_tokens: 100000 } } }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-8": 1000000 } }));
  // The desktop app never runs a status line, so a session that moved from the terminal to the
  // app would otherwise keep showing whatever the terminal last saw, forever.
  writeContextSidecar(home, "s5", {
    pct: 3, tokens: 6000, window: 200000, model: "claude-opus-4-8",
    ts: Math.floor(Date.now() / 1000) - 3600,
  });

  run(updatePath, home, ["prompt"],
      JSON.stringify({ session_id: "s5", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s5.json"), "utf8"));
  assert.equal(state.pct, 10);
  assert.equal(state.tokens, 100000);
});

test("session cost, duration and lines changed ride along from the statusLine record", () => {
  const home = sandbox();
  writeContextSidecar(home, "s7", {
    pct: 19, tokens: 192782, window: 1000000, model: "claude-opus-5",
    cost: 0.42, duration: 4500, linesAdded: 48, linesRemoved: 6,
    ts: Math.floor(Date.now() / 1000),
  });

  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s7", cwd: home }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s7.json"), "utf8"));
  assert.equal(state.cost, 0.42);
  assert.equal(state.duration, 4500);
  assert.equal(state.linesAdded, 48);
  assert.equal(state.linesRemoved, 6);
});

test("a stale statusLine record still lends its cost: the total only ever grows", () => {
  // The context figure goes stale (the session may have moved to the app, which measures
  // differently), but the cost so far is a fact about the past, not an estimate.
  const home = sandbox();
  writeContextSidecar(home, "s8", {
    pct: 3, tokens: 6000, window: 200000, model: "m", cost: 1.5, duration: 60,
    linesAdded: 0, linesRemoved: 0, ts: Math.floor(Date.now() / 1000) - 3600,
  });

  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s8", cwd: home }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s8.json"), "utf8"));
  assert.equal(state.cost, 1.5);
  assert.equal(state.duration, 60);
});

test("the uncommitted count is measured at turn boundaries and carried through tool events", () => {
  // PreToolUse blocks the tool call until the hook exits, and a git status walk on a large
  // tree is the slowest thing this hook could do — so it runs on prompt and stop only.
  const home = sandbox();
  const repo = path.join(home, "repo");
  fs.mkdirSync(repo);
  execFileSync("git", ["-C", repo, "init", "-q"]);
  fs.writeFileSync(path.join(repo, "a.txt"), "1");

  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "g3", cwd: repo }));
  fs.writeFileSync(path.join(repo, "b.txt"), "2");
  run(updatePath, home, ["pre"], JSON.stringify({ session_id: "g3", cwd: repo, tool_name: "Bash" }));
  const midTurn = JSON.parse(fs.readFileSync(path.join(stateDir(home), "g3.json"), "utf8"));
  assert.equal(midTurn.dirty, 1, "a tool event reuses the figure from the turn's start");

  run(updatePath, home, ["stop"], JSON.stringify({ session_id: "g3", cwd: repo }));
  const turnEnd = JSON.parse(fs.readFileSync(path.join(stateDir(home), "g3.json"), "utf8"));
  assert.equal(turnEnd.dirty, 2, "the turn's end re-measures");
});

test("the count of uncommitted files comes from git status; outside a repo it is null", () => {
  const home = sandbox();
  const repo = path.join(home, "repo");
  fs.mkdirSync(repo);
  execFileSync("git", ["-C", repo, "init", "-q"]);
  fs.writeFileSync(path.join(repo, "a.txt"), "1");
  fs.writeFileSync(path.join(repo, "b.txt"), "2");

  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "g1", cwd: repo }));
  const inRepo = JSON.parse(fs.readFileSync(path.join(stateDir(home), "g1.json"), "utf8"));
  assert.equal(inRepo.dirty, 2);

  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "g2", cwd: home }));
  const outside = JSON.parse(fs.readFileSync(path.join(stateDir(home), "g2.json"), "utf8"));
  assert.equal(outside.dirty, null);
});

test("ending a session takes its context record with it", () => {
  const home = sandbox();
  fs.writeFileSync(path.join(stateDir(home), "s6.json"), JSON.stringify({ sessionId: "s6" }));
  writeContextSidecar(home, "s6", { pct: 1, tokens: 1, window: 200000, model: "m", ts: 1 });

  run(lifecyclePath, home, ["end"], JSON.stringify({ session_id: "s6" }));

  const sidecar = path.join(home, ".claude", "control-bar", "context.d", "s6.json");
  assert.equal(fs.existsSync(sidecar), false, "otherwise context.d grows for the life of the install");
});

test("an unreadable transcript keeps the last known context instead of blanking it", () => {
  const home = sandbox();
  fs.writeFileSync(path.join(stateDir(home), "s3.json"), JSON.stringify({
    sessionId: "s3", pid: process.pid, pct: 42, tokens: 84000, window: 200000,
    model: "claude-opus-4-5", transcript: path.join(home, "gone.jsonl"), ts: 1,
  }));

  run(updatePath, home, ["post"], JSON.stringify({ session_id: "s3", cwd: home }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s3.json"), "utf8"));
  // A compaction rewrites the transcript; a read landing mid-rewrite finds no usage record.
  // Blanking the number there reads as "context freed", which is the opposite of the truth.
  assert.equal(state.pct, 42);
  assert.equal(state.tokens, 84000);
});

test("a notification is a permission prompt by its type, not by substrings of its text", () => {
  const home = sandbox();
  // "Shallow" contains "allow"; with the substring check this ordinary notification parked
  // the icon on "Awaiting permission" — a state with a two-hour timeout.
  run(updatePath, home, ["notify"], JSON.stringify({
    session_id: "typed-shallow", notification_type: "idle_prompt", message: "Shallow clone finished",
  }));
  assert.equal(fs.existsSync(path.join(stateDir(home), "typed-shallow.json")), false);

  run(updatePath, home, ["notify"], JSON.stringify({
    session_id: "typed-perm", notification_type: "permission_prompt", message: "whatever the text says",
  }));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "typed-perm.json"), "utf8"));
  assert.equal(state.state, "permission");
});

test("the legacy notification-text fallback matches whole words only", () => {
  const home = sandbox();
  // Payloads old enough to lack notification_type still classify by text — on word
  // boundaries: shallow/fallow/permissionless must not read as permission prompts.
  for (const [sid, message] of [
    ["legacy-shallow", "Shallow clone finished"],
    ["legacy-fallow", "Field left fallow"],
    ["legacy-permless", "Running in permissionless mode"],
  ]) {
    run(updatePath, home, ["notify"], JSON.stringify({ session_id: sid, message }));
    assert.equal(fs.existsSync(path.join(stateDir(home), `${sid}.json`)), false,
      `${sid} misread as a permission prompt`);
  }

  run(updatePath, home, ["notify"], JSON.stringify({
    session_id: "legacy-perm", message: "Claude needs your permission to use Bash",
  }));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "legacy-perm.json"), "utf8"));
  assert.equal(state.state, "permission");
});

// settings.json is shared with Claude Code and edited by hand. Both cases below are about not
// destroying someone else's work in it.

test("the first-run backup carries owner-only bits, whatever the original had", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }, null, 2) + "\n");
  // The umask default. A backup born with it held the full settings.json snapshot readable
  // by group staff — every local account — and nothing ever revisited it.
  fs.chmodSync(settingsPath(home), 0o644);
  run(installerPath, home);
  assert.equal(fs.statSync(settingsPath(home) + ".bak-control-bar").mode & 0o777, 0o600);
});

test("a settings write leaves no temp file and keeps the file's mode", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }, null, 2) + "\n");
  fs.chmodSync(settingsPath(home), 0o600);
  run(installerPath, home);
  const dir = path.join(home, ".claude");
  assert.equal(fs.readdirSync(dir).filter((f) => f.endsWith(".tmp")).length, 0);
  assert.equal(fs.statSync(settingsPath(home)).mode & 0o777, 0o600);
  assert.ok(fs.readFileSync(settingsPath(home), "utf8").includes("control-bar"));
});

test("a settings file changed underneath us is left alone rather than clobbered", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }, null, 2) + "\n");
  // The installer reads settings.json, then checks the fingerprint again before renaming. A
  // writer that lands in between must not be overwritten — its change would vanish silently and
  // the .bak, taken once at first install, could not bring it back.
  //
  // Nor is it a success. Nothing got installed, and the app takes the exit status as its verdict:
  // this path used to exit 0, which told the app the hooks were in place, so nothing tried again
  // until the next launch.
  let failure;
  try {
    execFileSync(
      process.execPath,
      ["-e", [
        `require("node:child_process").execSync = () => { throw new Error("pgrep: no match"); };`,
        `require("node:child_process").spawn = () => ({ unref() {} });`,
        // Sneak a write in between the installer's read and its rename. The first-run backup
        // write is the hook: it happens after the parse and before the fingerprint re-check.
        `const fs = require("node:fs");`,
        `const real = fs.writeFileSync;`,
        `fs.writeFileSync = (p, ...rest) => {`,
        `  real(p, ...rest);`,
        `  if (String(p).endsWith(".bak-control-bar")) {`,
        `    real(process.env.SETTINGS, JSON.stringify({ theirs: true }, null, 2) + "\\n");`,
        `  }`,
        `};`,
        `require(process.env.SCRIPT_PATH);`,
      ].join("\n"), installerPath],
      { env: { ...process.env, HOME: home, SCRIPT_PATH: installerPath, SETTINGS: settingsPath(home) },
        input: "{}", stdio: "pipe" }
    );
  } catch (error) {
    failure = error;
  }
  assert.equal(failure?.status, 75, "an install that wrote nothing exited as if it had worked");
  assert.match(failure.stderr.toString(), /changed while we were working on it/);
  assert.deepEqual(JSON.parse(fs.readFileSync(settingsPath(home), "utf8")), { theirs: true });
  assert.equal(fs.readdirSync(path.join(home, ".claude")).filter((f) => f.endsWith(".tmp")).length, 0);
  assert.equal(fs.existsSync(path.join(home, ".claude", "control-bar", "owner.json")), false,
    "an install that did not happen still claimed the lease");
});

// A row click resolves the app to focus from TERM_PROGRAM — but Cursor, Windsurf and VS Code
// all report TERM_PROGRAM="vscode" (forks inherit it), so a session living in Cursor's terminal
// opened Visual Studio Code, and the extension panel (no TERM_PROGRAM at all) opened nothing.
// LaunchServices stamps every process launched from an app bundle with __CFBundleIdentifier;
// that names the host exactly, and `open -b` takes it verbatim — no name mapping to maintain.
//
// process.env is spread into the child at call time, so tests flip the variable in OUR env and
// restore it — the runner itself may legitimately carry one (tests launched from an IDE do).
const withBundleEnv = (value, fn) => {
  const saved = process.env.__CFBundleIdentifier;
  if (value === undefined) delete process.env.__CFBundleIdentifier;
  else process.env.__CFBundleIdentifier = value;
  try { return fn(); } finally {
    if (saved === undefined) delete process.env.__CFBundleIdentifier;
    else process.env.__CFBundleIdentifier = saved;
  }
};

test("the session file records the bundle id of the app hosting the session", () => {
  const home = sandbox();
  withBundleEnv("com.todesktop.230313mzl4w4u92", () =>
    run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s8", cwd: home })));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s8.json"), "utf8"));
  assert.equal(state.term_bundle, "com.todesktop.230313mzl4w4u92");
});

test("the seeded session carries the host bundle id from the first moment", () => {
  const home = sandbox();
  withBundleEnv("com.googlecode.iterm2", () =>
    run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "n1", cwd: home })));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "n1.json"), "utf8"));
  assert.equal(state.term_bundle, "com.googlecode.iterm2");
});

test("an event arriving without the env var keeps the bundle id already on file", () => {
  const home = sandbox();
  fs.writeFileSync(path.join(stateDir(home), "s7.json"), JSON.stringify(
    { sessionId: "s7", pid: process.pid, term_bundle: "com.todesktop.230313mzl4w4u92", ts: 1 }));
  withBundleEnv(undefined, () =>
    run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s7", cwd: home })));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s7.json"), "utf8"));
  assert.equal(state.term_bundle, "com.todesktop.230313mzl4w4u92");
});

// An explicit menu Quit writes ~/.claude/control-bar/quit-intent. SessionStart fires for
// brand-new sessions AND for resumes (--resume/--continue, wake after sleep, compaction) —
// and both lifecycle.js and bootstrap.py launch the app from it. Only a genuinely new session
// is fresh consent: voiding the Quit because a laptop lid opened is exactly the reported
// "I quit it and it came back on its own".

const quitMarker = (home) => path.join(home, ".claude", "control-bar", "quit-intent");

test("an explicit Quit survives a session resume", () => {
  // All three resume-shaped sources: the list must stay in step with bootstrap.py's, and a
  // value dropped from lifecycle.js alone would otherwise stay green here.
  for (const source of ["resume", "compact", "fork"]) {
    const home = sandbox();
    fs.writeFileSync(quitMarker(home), "");
    run(lifecyclePath, home, ["start"],
      JSON.stringify({ session_id: "r1", cwd: home, source }));
    assert.ok(fs.existsSync(quitMarker(home)), `the marker must outlive a ${source}`);
    assert.ok(!fs.existsSync(spawnLog(home)), `a ${source} must not bring a quit app back`);
    // The seed still lands: it is what clears a state frozen mid-turn, resume included.
    const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "r1.json"), "utf8"));
    assert.equal(state.state, "idle");
  }
});

test("a genuinely new session voids the Quit and brings the app back", () => {
  const home = sandbox();
  fs.writeFileSync(quitMarker(home), "");
  run(lifecyclePath, home, ["start"],
    JSON.stringify({ session_id: "n2", cwd: home, source: "startup" }));
  assert.ok(!fs.existsSync(quitMarker(home)), "a new session is fresh consent");
  assert.ok(fs.existsSync(spawnLog(home)), "and the app comes up for it");
});

test("a resume with no Quit on file still self-heals the app", () => {
  const home = sandbox();
  run(lifecyclePath, home, ["start"],
    JSON.stringify({ session_id: "r3", cwd: home, source: "resume" }));
  assert.ok(fs.existsSync(spawnLog(home)),
    "no marker means nothing to honor — a crashed app relaunches");
});

test("a payload without source keeps the pre-source behavior", () => {
  const home = sandbox();
  fs.writeFileSync(quitMarker(home), "");
  run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "n4", cwd: home }));
  // An old Claude Code sends no source; treating that as a resume would leave the app
  // permanently down after one Quit.
  assert.ok(!fs.existsSync(quitMarker(home)));
  assert.ok(fs.existsSync(spawnLog(home)));
});

test("update.js's self-heal relaunch honors an explicit Quit too", () => {
  // The same marker, the other opener: every prompt/tool event self-heals a killed app, and
  // without the check a menu Quit lasted exactly until the next tool call.
  const healed = sandbox();
  run(updatePath, healed, ["post"], JSON.stringify({ session_id: "s1", cwd: healed }));
  assert.ok(fs.existsSync(spawnLog(healed)),
    "with no marker, a live session relaunches the missing app");

  const quit = sandbox();
  fs.writeFileSync(quitMarker(quit), "");
  run(updatePath, quit, ["post"], JSON.stringify({ session_id: "s1", cwd: quit }));
  assert.ok(!fs.existsSync(spawnLog(quit)), "the marker suppresses the self-heal");
});

test("a start sweeps context files orphaned by a late statusline capture", () => {
  // statusline.py runs detached, and a capture from the session's final redraw can land AFTER
  // SessionEnd removed the state file — a context.d entry no loop ever visited again.
  const home = sandbox();
  const contextDir = path.join(home, ".claude", "control-bar", "context.d");
  fs.mkdirSync(contextDir, { recursive: true });
  fs.writeFileSync(path.join(contextDir, "orphan.json"), "{}");
  fs.writeFileSync(path.join(stateDir(home), "live.json"),
    JSON.stringify({ sessionId: "live", pid: process.pid, ts: 1 }));
  fs.writeFileSync(path.join(contextDir, "live.json"), "{}");

  run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "new", cwd: home }));

  assert.deepEqual(fs.readdirSync(contextDir).sort(), ["live.json"],
    "the orphan goes, a live session's context file stays");
});

// The js→swift seam. These files are parsed by Session.init in Sources/Sessions.swift — a
// second, independent implementation of the same schema. This pin holds the writer's half of
// the contract; the reader's half is the seam fixture below, which the swift model checks
// parse with the real Session initializer.

test("the state file a hook event writes carries exactly the keys the swift reader parses", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  // With a measurable transcript the context block is present too — the fullest shape.
  fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
    model: "claude-opus-4-8", content: [{ text: "hi" }], usage: { input_tokens: 1000 } } }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-8": 200000 } }));

  run(updatePath, home, ["pre"], JSON.stringify({
    session_id: "pin1", cwd: home, transcript_path: transcript, tool_name: "Bash",
  }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "pin1.json"), "utf8"));
  assert.deepEqual(Object.keys(state).sort(), [
    "assumed", "cost", "cwd", "dirty", "duration", "entrypoint", "label", "linesAdded",
    "linesRemoved", "model", "pct", "pid", "project", "sessionId", "started", "startedAt",
    "state", "term_bundle", "term_program", "tokens", "tool", "transcript", "ts", "tty",
    "window",
  ]);
  assert.equal(typeof state.state, "string");
  assert.equal(typeof state.pid, "number");
  assert.equal(typeof state.ts, "number");
  assert.equal(typeof state.started, "boolean");
  assert.equal(typeof state.pct, "number");

  // The reader's half of this seam: the swift model checks parse THIS file with the real
  // Session initializer. Written by the real update.js — not a hand fixture — so a key
  // rename on either side now fails a suite. Run the node suite before the swift one.
  const seamDir = path.resolve(__dirname, "..", "build", "seam");
  fs.mkdirSync(seamDir, { recursive: true });
  fs.copyFileSync(path.join(stateDir(home), "pin1.json"), path.join(seamDir, "session.json"));
});

test("the seeded session file carries exactly the keys the swift reader parses", () => {
  const home = sandbox();
  run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "pin2", cwd: home }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "pin2.json"), "utf8"));
  assert.deepEqual(Object.keys(state).sort(), [
    "cwd", "entrypoint", "label", "pid", "project", "sessionId", "started", "startedAt",
    "state", "term_bundle", "term_program", "tool", "transcript", "ts", "tty",
  ]);
  assert.equal(state.started, false, "a merely-opened session stays out of the dropdown");
  assert.equal(state.state, "idle");
});

test("a usage record buried deeper than the first tail read is still found", () => {
  // The tail is read in two steps — a small one that covers almost every turn, and the full
  // 2 MB only when the small one finds no usage record. This is the fallback's proof.
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  const filler = JSON.stringify({ type: "progress", data: "x".repeat(1000) });
  fs.writeFileSync(transcript, [
    JSON.stringify({ type: "assistant", message: { model: "claude-opus-4-8", content: [{ text: "hi" }],
      usage: { input_tokens: 50000 } } }),
    ...Array(400).fill(filler),   // ~400 KB past the record, well beyond the first read
  ].join("\n"));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-8": 200000 } }));

  run(updatePath, home, ["post"],
      JSON.stringify({ session_id: "deep", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "deep.json"), "utf8"));
  assert.equal(state.pct, 25);
});

test("the self-heal probe runs at most once every 30 seconds", () => {
  // pgrep is a fork — two of them per tool call, before this. A probe that just ran answers
  // for the next half minute; a crash still heals within that window.
  const home = sandbox();
  run(updatePath, home, ["pre"], JSON.stringify({ session_id: "s1", cwd: home, tool_name: "Bash" }));
  run(updatePath, home, ["post"], JSON.stringify({ session_id: "s1", cwd: home }));
  const launches = fs.readFileSync(spawnLog(home), "utf8").trim().split("\n");
  assert.equal(launches.length, 1, "the second event within the window did not probe again");
});

test("a state write that fails is logged rather than swallowed", () => {
  // The write IS the hook's output. A persistently failing one made the menu bar look frozen
  // forever with no diagnostic anywhere.
  const home = sandbox();
  fs.rmSync(stateDir(home), { recursive: true });
  fs.writeFileSync(stateDir(home), "not a directory");
  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s1", cwd: home }));
  const log = fs.readFileSync(path.join(home, ".claude", "control-bar", "problems.log"), "utf8");
  assert.match(log, /update\.js: could not write .*s1\.json/);
});

test("a session id cannot escape state.d", () => {
  const home = sandbox();
  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "../../evil", cwd: home }));
  assert.ok(!fs.existsSync(path.join(home, ".claude", "evil.json")));
  assert.ok(!fs.existsSync(path.join(home, "evil.json")));
  assert.ok(fs.existsSync(path.join(stateDir(home), "....evil.json")));
});

test("stop and permreq events map to their states, an unknown event writes nothing", () => {
  const home = sandbox();
  run(updatePath, home, ["pre"], JSON.stringify({ session_id: "s1", cwd: home, tool_name: "Bash" }));
  run(updatePath, home, ["permreq"], JSON.stringify({ session_id: "s1", cwd: home }));
  let state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s1.json"), "utf8"));
  assert.equal(state.state, "permission");
  assert.equal(state.startedAt, 0);

  run(updatePath, home, ["stop"], JSON.stringify({ session_id: "s1", cwd: home }));
  state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s1.json"), "utf8"));
  assert.equal(state.state, "done");
  assert.equal(state.label, "Done");

  run(updatePath, home, ["bogus"], JSON.stringify({ session_id: "s2", cwd: home }));
  assert.ok(!fs.existsSync(path.join(stateDir(home), "s2.json")));
});

// --- Codex CLI sessions ----------------------------------------------------------------
// The same two hooks serve both agents, told apart by `--provider codex`. Codex's own facts
// are verified against codex-cli 0.154.0 on a live machine (docs/codex-support-plan.md §0):
// the hook payload carries session_id/cwd/transcript_path/model, process.ppid IS the codex
// process, and the transcript is a rollout JSONL whose session_meta names the surface.

const codexStateDir = (home) => path.join(home, ".claude", "control-bar", "codex", "state.d");

// One rollout file: the session_meta line every rollout opens with, plus whatever follows.
const rollout = (home, lines = [], meta = {}) => {
  const file = path.join(home, "rollout.jsonl");
  fs.writeFileSync(file, [
    JSON.stringify({ timestamp: "2026-09-13T12:24:52.382Z", type: "session_meta", payload: {
      session_id: "c1", cwd: home, originator: "codex_cli_rs", thread_source: "user",
      cli_version: "0.154.0", ...meta } }),
    ...lines,
  ].join("\n"));
  return file;
};

// A token_count record carries two blocks, and only one of them is the context. Measured on a
// real 110-turn session: total_token_usage reached 25,374,147 against a window of 828,400 — it
// accumulates every turn ever billed, so reading it would park every session at 100% after a
// few turns. last_token_usage is what currently occupies the window, and it grew 60k → 323k
// over that session without once passing the window. The cumulative block here is deliberately
// 30x the window so a future reader that grabs the wrong one fails this test instead of shipping.
const tokenCount = (used, window) => JSON.stringify({
  timestamp: "2026-09-13T12:24:55.912Z", type: "event_msg", payload: { type: "token_count",
    info: {
      total_token_usage: { input_tokens: window * 29, cached_input_tokens: 0,
        cache_write_input_tokens: 0, output_tokens: window, reasoning_output_tokens: 0,
        total_tokens: window * 30 },
      last_token_usage: { input_tokens: used - 400, cached_input_tokens: used - 1000,
        cache_write_input_tokens: 0, output_tokens: 300, reasoning_output_tokens: 100,
        total_tokens: used },
      model_context_window: window } } });

test("a codex event writes into codex's own state directory, never into Claude's", () => {
  // Two agents, one file layout, separate directories: the Claude contract has two writers
  // already and a Codex session landing in state.d would be reaped by Claude's own rules.
  const home = sandbox();
  run(updatePath, home, ["pre", "--provider", "codex"], JSON.stringify({
    session_id: "c1", cwd: home, tool_name: "exec", model: "gpt-5.6-sol",
  }));

  const state = JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "c1.json"), "utf8"));
  assert.equal(state.provider, "codex");
  assert.equal(state.state, "tool");
  // `exec` is Codex's shell tool — the label has to read like Claude's "Running command",
  // or the same activity gets two different words depending on the agent.
  assert.equal(state.label, "Running command");
  assert.deepEqual(fs.readdirSync(stateDir(home)), [], "Claude's directory stays empty");
});

test("codex context is measured from the rollout with the window codex itself reports", () => {
  // Claude's window has to be guessed from the model name; Codex states it in every
  // token_count record, so the figure is exact and `assumed` is honestly false.
  const home = sandbox();
  const transcript = rollout(home, [tokenCount(41_420, 200_000)]);

  run(updatePath, home, ["prompt", "--provider", "codex"],
      JSON.stringify({ session_id: "c1", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "c1.json"), "utf8"));
  assert.equal(state.tokens, 41_420);
  assert.equal(state.window, 200_000);
  assert.equal(state.pct, 21);
  assert.equal(state.assumed, false);
});

test("the newest token count wins, and a rollout without one keeps the last known figure", () => {
  const home = sandbox();
  const transcript = rollout(home, [tokenCount(10_000, 200_000), tokenCount(60_000, 200_000)]);
  const payload = JSON.stringify({ session_id: "c1", cwd: home, transcript_path: transcript });
  run(updatePath, home, ["prompt", "--provider", "codex"], payload);
  let state = JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "c1.json"), "utf8"));
  assert.equal(state.pct, 30, "the last record in the file is the current one");

  // A compaction rewrites the rollout; a read landing mid-rewrite finds no token_count. A
  // momentarily missing number would blank the context bar and read as "context freed".
  fs.writeFileSync(transcript, "");
  run(updatePath, home, ["post", "--provider", "codex"], payload);
  state = JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "c1.json"), "utf8"));
  assert.equal(state.pct, 30);
});

test("a codex subagent never becomes a row of its own", () => {
  // Codex spawns subagents as full threads with their own session id, rollout and hooks. One
  // prompt of the user's showed five running sessions before this: the parent and four workers.
  const home = sandbox();
  const worker = rollout(home, [], { thread_source: "subagent", agent_nickname: "Parfit" });

  run(lifecyclePath, home, ["start", "--provider", "codex"],
      JSON.stringify({ session_id: "w1", cwd: home, transcript_path: worker, source: "startup" }));
  run(updatePath, home, ["pre", "--provider", "codex"], JSON.stringify({
    session_id: "w1", cwd: home, transcript_path: worker, tool_name: "exec", agent_id: "a1",
  }));

  assert.ok(!fs.existsSync(codexStateDir(home)) || fs.readdirSync(codexStateDir(home)).length === 0,
    "a worker thread writes no state file at all");
});

test("a codex worker is turned away by its rollout, not only by a field on the payload", () => {
  // The payload's agent_id is what Codex's hook docs describe, but it has never been SEEN on a
  // live worker event — only asserted. The rollout's thread_source has been. So a worker whose
  // events carry no agent_id at all (the case that would otherwise slip through, and the case
  // nothing else in this suite covers) must still be turned away.
  const home = sandbox();
  const worker = rollout(home, [], { thread_source: "guardian_review" });

  run(updatePath, home, ["pre", "--provider", "codex"], JSON.stringify({
    session_id: "w2", cwd: home, transcript_path: worker, tool_name: "exec",
  }));

  assert.ok(!fs.existsSync(path.join(codexStateDir(home), "w2.json")),
    "no agent_id on the payload, and it is still not a session of its own");
});

test("the session's tty is found once and carried, not re-measured per event", () => {
  // Finding it costs a `ps` — the only field here that costs a process — and PreToolUse holds the
  // tool call until this hook exits. A session's controlling terminal cannot change, so measuring
  // it again on every event would be a spawn per tool call for an answer already on disk.
  const home = sandbox();
  fs.writeFileSync(path.join(stateDir(home), "t9.json"), JSON.stringify({
    sessionId: "t9", tty: "/dev/ttys042", pid: process.pid, ts: 1 }));

  run(updatePath, home, ["post"], JSON.stringify({ session_id: "t9", cwd: home }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "t9.json"), "utf8"));
  assert.equal(state.tty, "/dev/ttys042");
});

test("the codex turn id is recorded per event and never inherited from the last turn", () => {
  // The app matches this id against the turn_id on the rollout record that ENDS a turn, which is
  // how it tells "this session's turn is over" from "some turn finished in this file" without
  // comparing a whole-second hook clock against a millisecond rollout one. Inheriting a finished
  // turn's id is the one way that match could end a turn still running, so an event that carries
  // no id must clear the field rather than keep the old one.
  const home = sandbox();
  const payload = (extra) => JSON.stringify({ session_id: "t1", cwd: home, ...extra });
  const read = () => JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "t1.json"), "utf8"));

  run(updatePath, home, ["prompt", "--provider", "codex"], payload({ turn_id: "turn-a" }));
  assert.equal(read().turn_id, "turn-a");

  run(updatePath, home, ["post", "--provider", "codex"], payload({ turn_id: "turn-b" }));
  assert.equal(read().turn_id, "turn-b", "a new turn replaces the old id");

  run(updatePath, home, ["post", "--provider", "codex"], payload({}));
  assert.equal(read().turn_id, "", "and an event without one leaves no stale id behind");
});

test("a codex worker is turned away on every event, not only on the first one", () => {
  // Codex defines agent_id on four of the events this app registers and on NEITHER of the two
  // that end a turn — Stop and Interrupt carry none at all. So on those two the documented field
  // can never turn a worker away, and the rollout is the only thing that can. Reading it once, on
  // the event that first wrote the file, left every later event with nothing.
  const home = sandbox();
  // rollout() always writes the one path, so each thread's file is copied aside before the next
  // call overwrites it: two threads, two rollouts, which is the whole shape being tested.
  const minePath = path.join(home, "mine.jsonl");
  fs.copyFileSync(rollout(home, [], { thread_source: "user" }), minePath);
  const workerPath = path.join(home, "worker.jsonl");
  fs.copyFileSync(rollout(home, [], { thread_source: "subagent" }), workerPath);

  run(updatePath, home, ["prompt", "--provider", "codex"], JSON.stringify({
    session_id: "s1", cwd: home, transcript_path: minePath, turn_id: "turn-a" }));
  const state = () => JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "s1.json"), "utf8"));
  assert.equal(state().state, "thinking", "the user's own thread is a session");

  // The worker's Stop, arriving on the same session id with the worker's rollout and no agent_id.
  run(updatePath, home, ["stop", "--provider", "codex"], JSON.stringify({
    session_id: "s1", cwd: home, transcript_path: workerPath }));
  assert.equal(state().state, "thinking", "a worker's Stop does not end the session's turn");
  assert.equal(state().transcript, minePath, "and does not repoint the row at the worker's rollout");
});

test("a codex worker's SessionEnd does not delete the session's file", () => {
  // SessionEnd carries no agent id either, and it does not rewrite state — it deletes the file
  // outright. A worker's end landing on a live session took the row off the panel mid-turn.
  const home = sandbox();
  const minePath = path.join(home, "mine.jsonl");
  fs.copyFileSync(rollout(home, [], { thread_source: "user" }), minePath);
  const workerPath = path.join(home, "worker.jsonl");
  fs.copyFileSync(rollout(home, [], { thread_source: "subagent" }), workerPath);

  run(updatePath, home, ["prompt", "--provider", "codex"], JSON.stringify({
    session_id: "s2", cwd: home, transcript_path: minePath }));
  run(lifecyclePath, home, ["end", "--provider", "codex"], JSON.stringify({
    session_id: "s2", cwd: home, transcript_path: workerPath }));

  assert.ok(fs.existsSync(path.join(codexStateDir(home), "s2.json")),
    "the session survives a worker's end");

  // Its own end still removes it, or nothing ever would.
  run(lifecyclePath, home, ["end", "--provider", "codex"], JSON.stringify({
    session_id: "s2", cwd: home, transcript_path: minePath }));
  assert.ok(!fs.existsSync(path.join(codexStateDir(home), "s2.json")),
    "and its own end still ends it");
});

test("a codex session already running when the hooks arrived still gets its surface", () => {
  // It never fired SessionStart, so nothing seeded the surface — the badge would stay blank for
  // the rest of its life. The first event reads the rollout once and settles it.
  const home = sandbox();
  const transcript = rollout(home, [], { originator: "codex_exec" });

  run(updatePath, home, ["prompt", "--provider", "codex"],
      JSON.stringify({ session_id: "late", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "late.json"), "utf8"));
  assert.equal(state.surface, "exec");
});

test("the codex surface comes from the rollout's own originator", () => {
  const home = sandbox();
  const cases = [["codex_cli_rs", "cli"], ["codex_vscode", "ide"], ["Codex Desktop", "app"],
                 ["codex_exec", "exec"], ["something-new", ""]];
  for (const [originator, surface] of cases) {
    const transcript = rollout(home, [], { originator });
    run(lifecyclePath, home, ["start", "--provider", "codex"], JSON.stringify({
      session_id: "s-" + surface, cwd: home, transcript_path: transcript, source: "startup",
    }));
    const state = JSON.parse(
      fs.readFileSync(path.join(codexStateDir(home), "s-" + surface + ".json"), "utf8"));
    assert.equal(state.surface, surface, originator + " is a " + (surface || "nameless") + " surface");
  }
});

test("a fat session_meta line still names the surface", () => {
  // Codex 0.154 writes 18.6 KB into that first line on this machine — workspace roots, git
  // information, the lot. The reader used to take 8 KB of it, which is half a JSON object: the
  // parse threw, the catch swallowed it, and every session from that build lost its badge
  // silently. Nothing in the panel said why, because a missing badge looks like a design choice.
  const home = sandbox();
  // A second record after it, so the line really is cut at its newline rather than at the end of
  // the file — the shape a live rollout has, and the branch the one-line fixture never exercises.
  const transcript = rollout(home, [tokenCount(1000, 200000)], {
    originator: "Codex Desktop", workspace_roots: ["x".repeat(30000)],
  });
  run(lifecyclePath, home, ["start", "--provider", "codex"], JSON.stringify({
    session_id: "fat", cwd: home, transcript_path: transcript, source: "startup",
  }));
  const state = JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "fat.json"), "utf8"));
  assert.equal(state.surface, "app");

  // The per-event hook carries its own copy of the reader, and only the SessionStart one was
  // covered — a fix applied to one file and forgotten in the other would have passed.
  run(updatePath, home, ["post", "--provider", "codex"], JSON.stringify({
    session_id: "fat-post", cwd: home, transcript_path: transcript, tool_name: "exec",
  }));
  const posted = JSON.parse(
    fs.readFileSync(path.join(codexStateDir(home), "fat-post.json"), "utf8"));
  assert.equal(posted.surface, "app", "update.js reads the same fat line");
});

test("a session_meta line longer than the reader will ever take yields no badge, not a wrong one", () => {
  // The ceiling has to exist — a rollout whose first line is a megabyte is not worth reading on
  // every hook — and past it the answer is "unknown", exactly as for an originator nobody knows.
  const home = sandbox();
  const transcript = rollout(home, [], {
    originator: "Codex Desktop", workspace_roots: ["x".repeat(600000)],
  });
  run(lifecyclePath, home, ["start", "--provider", "codex"], JSON.stringify({
    session_id: "huge", cwd: home, transcript_path: transcript, source: "startup",
  }));
  const state = JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "huge.json"), "utf8"));
  assert.equal(state.surface, "");
});

test("a codex session start reaps its own dead sessions and leaves Claude's alone", () => {
  const home = sandbox();
  fs.mkdirSync(codexStateDir(home), { recursive: true });
  fs.writeFileSync(path.join(codexStateDir(home), "dead.json"),
    JSON.stringify({ sessionId: "dead", pid: 999999, ts: 1 }));
  fs.writeFileSync(path.join(stateDir(home), "claude.json"),
    JSON.stringify({ sessionId: "claude", pid: 999999, ts: 1 }));

  run(lifecyclePath, home, ["start", "--provider", "codex"],
      JSON.stringify({ session_id: "c1", cwd: home, source: "startup" }));

  assert.deepEqual(fs.readdirSync(codexStateDir(home)).sort(), ["c1.json"]);
  // Claude's dead file is Claude's own business: SessionEnd for Codex has a one-second budget,
  // and walking a second directory on somebody else's behalf is how that budget gets blown.
  assert.deepEqual(fs.readdirSync(stateDir(home)), ["claude.json"]);
});

test("ending a codex session removes only its own file", () => {
  const home = sandbox();
  run(updatePath, home, ["prompt", "--provider", "codex"],
      JSON.stringify({ session_id: "c1", cwd: home }));
  run(updatePath, home, ["prompt", "--provider", "codex"],
      JSON.stringify({ session_id: "c2", cwd: home }));

  run(lifecyclePath, home, ["end", "--provider", "codex"], JSON.stringify({ session_id: "c1" }));

  assert.deepEqual(fs.readdirSync(codexStateDir(home)).sort(), ["c2.json"]);
});

test("the codex state file carries exactly the keys the swift reader parses", () => {
  const home = sandbox();
  const transcript = rollout(home, [tokenCount(41_420, 200_000)], { originator: "codex_vscode" });
  run(lifecyclePath, home, ["start", "--provider", "codex"], JSON.stringify({
    session_id: "pin3", cwd: home, transcript_path: transcript, source: "startup" }));
  run(updatePath, home, ["pre", "--provider", "codex"], JSON.stringify({
    session_id: "pin3", cwd: home, transcript_path: transcript, tool_name: "apply_patch",
    model: "gpt-5.6-sol", turn_id: "turn-7",
  }));

  const state = JSON.parse(fs.readFileSync(path.join(codexStateDir(home), "pin3.json"), "utf8"));
  assert.deepEqual(Object.keys(state).sort(), [
    "assumed", "cost", "cwd", "dirty", "duration", "entrypoint", "label", "linesAdded",
    "linesRemoved", "model", "pct", "pid", "project", "provider", "sessionId", "started",
    "startedAt", "state", "surface", "term_bundle", "term_program", "tokens", "tool",
    "transcript", "ts", "tty", "turn_id", "window",
  ]);
  assert.equal(state.surface, "ide", "the surface survives the events that follow the start");
  assert.equal(state.model, "gpt-5.6-sol", "the model comes from the payload, not from a guess");

  // The reader's half: the swift model checks parse THIS file with the real Session
  // initializer. Its own fixture, so the Claude seam keeps its independent pin.
  const seamDir = path.resolve(__dirname, "..", "build", "seam");
  fs.mkdirSync(seamDir, { recursive: true });
  fs.copyFileSync(path.join(codexStateDir(home), "pin3.json"),
                  path.join(seamDir, "codex-session.json"));
});

test("the app channel records its lease in owner.json", () => {
  // The lease is what keeps the two install channels from stacking hooks; every other test
  // seeds it by hand, so nothing had pinned that install.js actually writes it.
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }));
  run(installerPath, home);
  const ownerPath = path.join(home, ".claude", "control-bar", "owner.json");
  const owner = JSON.parse(fs.readFileSync(ownerPath, "utf8"));
  assert.equal(owner.channel, "app");
  assert.equal(typeof owner.ts, "number");
  assert.equal(fs.statSync(ownerPath).mode & 0o777, 0o600, "the lease is owner-only like every state file");
  assert.ok(!fs.readdirSync(path.dirname(ownerPath)).some((f) => f.endsWith(".tmp")), "no temp file left behind");
});
