// hooks/uninstall.js. tests/install.test.js runs it as install's inverse (foreign hooks, the
// symlinked settings.json, --hooks-only, the codex lease); this file covers the rest of the
// teardown — what it leaves untouched, the statusLine restore and the LaunchAgent.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const {
  scripts, sandbox, run, execLog, execFileLog, barDir,
} = require("./hook-harness");

const settingsPath = (home) => path.join(home, ".claude", "settings.json");
const codexHooksPath = (home) => path.join(home, ".codex", "hooks.json");
const ourCommand = (home, script, evt) =>
  `node '${path.join(barDir(home), script)}' ${evt}`;
const mcpbar = path.resolve(__dirname, "../scripts/mcpbar.py");

const uninstall = (home, argv = [], env = {}) => {
  const res = run(scripts.uninstall, home, { argv, env, stdin: "" });
  return res;
};

const writeSettings = (home, settings, text) => {
  fs.mkdirSync(path.dirname(settingsPath(home)), { recursive: true });
  fs.writeFileSync(settingsPath(home), text ?? JSON.stringify(settings, null, 2) + "\n");
};

test("no settings.json is nothing to do, not an error", (t) => {
  const home = sandbox(t);
  const res = uninstall(home);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /No settings\.json; nothing to do/);
  assert.equal(fs.existsSync(settingsPath(home)), false, "and it is not created either");
});

test("a settings.json with none of our hooks keeps its own formatting", (t) => {
  // The plugin runs the --hooks-only half of this on every session start. Comparing against the
  // re-serialised parse is what keeps a hand-formatted file from being rewritten each time.
  const home = sandbox(t);
  const text = '{\n    "theme": "dark",\n    "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo hi" } ] } ] }\n}\n';
  writeSettings(home, null, text);

  for (const argv of [[], ["--hooks-only"]]) {
    const res = uninstall(home, argv);
    assert.equal(res.status, 0, res.stderr);
    assert.equal(fs.readFileSync(settingsPath(home), "utf8"), text);
  }
});

test("removing hooks keeps the file's mode and every other setting", (t) => {
  const home = sandbox(t);
  writeSettings(home, {
    model: "opus",
    permissions: { allow: ["Bash(ls)"] },
    hooks: {
      PreToolUse: [{ matcher: "*", hooks: [{ type: "command", command: ourCommand(home, "update.js", "pre") }] }],
      SessionStart: [{ hooks: [
        { type: "command", command: ourCommand(home, "lifecycle.js", "start") },
        { type: "command", command: "echo mine" },
      ] }],
    },
  });
  fs.chmodSync(settingsPath(home), 0o600);

  const res = uninstall(home);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /Removed control-bar hooks/);
  const after = JSON.parse(fs.readFileSync(settingsPath(home), "utf8"));
  assert.deepEqual(after, {
    model: "opus",
    permissions: { allow: ["Bash(ls)"] },
    // The event whose only hook was ours goes; the shared entry keeps the user's hook.
    hooks: { SessionStart: [{ hooks: [{ type: "command", command: "echo mine" }] }] },
  });
  assert.equal(fs.statSync(settingsPath(home)).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(path.dirname(settingsPath(home))), ["settings.json"],
    "no temp file is left behind");

  // A second run is a no-op and says so.
  const again = uninstall(home);
  assert.match(again.stdout, /No control-bar hooks in/);
});

test("the statusLine is handed back only where its capture was installed", (t) => {
  // Without a sidecar there is nothing to restore, and spawning /usr/bin/python3 on a Mac
  // without the Command Line Tools pops the system's developer-tools dialog — from an uninstall.
  const bare = sandbox(t);
  writeSettings(bare, { hooks: {} });
  assert.equal(uninstall(bare).status, 0);
  assert.deepEqual(execFileLog(bare), []);

  const captured = sandbox(t);
  writeSettings(captured, { hooks: {} });
  fs.mkdirSync(barDir(captured), { recursive: true });
  fs.writeFileSync(path.join(barDir(captured), "statusline-saved.json"), "{}");
  assert.equal(uninstall(captured).status, 0);
  // Run from the repo/plugin layout, the script is found one level up from hooks/.
  assert.deepEqual(execFileLog(captured), [`/usr/bin/python3 ${mcpbar} statusline --uninstall`]);
});

test("the plugin's lease claim never touches the statusLine", (t) => {
  // --hooks-only runs while the app keeps drawing: the capture is still wanted.
  const home = sandbox(t);
  writeSettings(home, { hooks: {} });
  fs.mkdirSync(barDir(home), { recursive: true });
  fs.writeFileSync(path.join(barDir(home), "statusline-installed.json"), "{}");
  assert.equal(uninstall(home, ["--hooks-only"]).status, 0);
  assert.deepEqual(execFileLog(home), []);
});

test("a statusLine restore that fails says how to finish it, and the hooks still go", (t) => {
  const home = sandbox(t);
  writeSettings(home, { hooks: { Stop: [{ hooks: [
    { type: "command", command: ourCommand(home, "update.js", "stop") }] }] } });
  fs.mkdirSync(barDir(home), { recursive: true });
  fs.writeFileSync(path.join(barDir(home), "statusline-inner-command"), "echo");

  const res = uninstall(home, [], { EXECFILE_FAIL: "1" });
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stderr, /Could not restore the statusLine command/);
  assert.ok(res.stderr.includes(`/usr/bin/python3 "${mcpbar}" statusline --uninstall`),
    "the exact command to run by hand");
  assert.deepEqual(JSON.parse(fs.readFileSync(settingsPath(home), "utf8")).hooks, {});
});

test("a full uninstall stops the app and removes the desktop watcher", (t) => {
  const home = sandbox(t);
  writeSettings(home, { hooks: {} });
  const plist = path.join(home, "Library", "LaunchAgents", "com.local.claudestatusbar.watcher.plist");
  fs.mkdirSync(path.dirname(plist), { recursive: true });
  fs.writeFileSync(plist, "<plist/>");

  const res = uninstall(home);
  assert.equal(res.status, 0, res.stderr);
  assert.equal(fs.existsSync(plist), false);
  const log = execLog(home);
  assert.ok(log.some((c) => /^launchctl bootout gui\/\d+\/com\.local\.claudestatusbar\.watcher$/.test(c)), log.join("\n"));
  assert.ok(log.includes("pkill -x ClaudeControlBar"));
});

test("a codex hooks file that does not parse is not rewritten by an uninstall", (t) => {
  // Same rule as settings.json: removing hooks from a file we cannot read means rewriting it
  // from a guess. tests/install.test.js pins this for the install side.
  const home = sandbox(t);
  writeSettings(home, { hooks: {} });
  fs.mkdirSync(path.dirname(codexHooksPath(home)), { recursive: true });
  const garbage = `{"hooks": {"Stop": [ ${ourCommand(home, "update.js", "stop")}`;
  fs.writeFileSync(codexHooksPath(home), garbage);

  assert.equal(uninstall(home).status, 0);
  assert.equal(fs.readFileSync(codexHooksPath(home), "utf8"), garbage);
});

test("the codex hooks file keeps its mode when our hooks leave it", (t) => {
  const home = sandbox(t);
  writeSettings(home, { hooks: {} });
  fs.mkdirSync(path.dirname(codexHooksPath(home)), { recursive: true });
  fs.writeFileSync(codexHooksPath(home), JSON.stringify({ hooks: {
    SessionStart: [{ hooks: [{ type: "command",
      command: ourCommand(home, "lifecycle.js", "start --provider codex") }] }],
  } }));
  fs.chmodSync(codexHooksPath(home), 0o640);

  const res = uninstall(home);
  assert.equal(res.status, 0, res.stderr);
  assert.deepEqual(JSON.parse(fs.readFileSync(codexHooksPath(home), "utf8")), { hooks: {} });
  assert.equal(fs.statSync(codexHooksPath(home)).mode & 0o777, 0o640);
});
