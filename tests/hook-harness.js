// Shared runner for the hook suites (update-hook, lifecycle, uninstall). The hooks are scripts,
// not modules: they read argv, stdin and HOME at load time and call process.exit, so each run is
// a child process with child_process stubbed out before the script is required.
//
// The stubs record instead of acting: a test must not pgrep, launch or pkill the developer's own
// menu bar app, and it has to be able to assert that the hook did NOT do one of those things.
//   - execSync: logged to exec-log.txt. `pgrep` throws (no such process) unless the test asks for
//     a running app; every other command throws too, which is what `ps` without a terminal looks
//     like to ttyDev() and what launchctl/pkill look like when there is nothing to stop.
//   - execFileSync: logged to execfile-log.txt; throws when the test asks it to fail.
//   - spawn: logged to spawn-calls.txt (the scripts only ever spawn `open`).

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const hooksDir = path.resolve(__dirname, "../hooks");
const scripts = {
  update: path.join(hooksDir, "update.js"),
  lifecycle: path.join(hooksDir, "lifecycle.js"),
  uninstall: path.join(hooksDir, "uninstall.js"),
};

const sandbox = (t, prefix = "ccb-hook-") => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  if (t) t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  return home;
};

const STUBS = [
  `const cp = require("node:child_process");`,
  `const log = (file, line) => require("node:fs").appendFileSync(file, line + "\\n");`,
  `cp.execSync = (cmd) => {`,
  `  log(process.env.EXEC_LOG, cmd);`,
  `  if (process.env.APP_RUNNING === "1" && cmd.startsWith("pgrep")) return "";`,
  `  throw new Error("stubbed: " + cmd);`,
  `};`,
  `cp.execFileSync = (file, args) => {`,
  `  log(process.env.EXECFILE_LOG, [file, ...(args || [])].join(" "));`,
  `  if (process.env.EXECFILE_FAIL === "1") throw new Error("stubbed failure");`,
  `  return "";`,
  `};`,
  `cp.spawn = (cmd, args) => { log(process.env.SPAWN_LOG, cmd + " " + args.join(" ")); return { unref() {} }; };`,
  `require(process.env.SCRIPT_PATH);`,
].join("\n");

// argv goes after the script path: under `node -e` the script is not in process.argv, and the
// hooks read their event from argv[2]. `env` overrides (or, with undefined, removes) variables
// from the test runner's own environment, which may legitimately carry TERM_PROGRAM and friends.
const run = (script, home, { argv = [], stdin = "{}", env = {} } = {}) => {
  const childEnv = { ...process.env, HOME: home, SCRIPT_PATH: script,
    EXEC_LOG: path.join(home, "exec-log.txt"),
    EXECFILE_LOG: path.join(home, "execfile-log.txt"),
    SPAWN_LOG: path.join(home, "spawn-calls.txt") };
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) delete childEnv[key];
    else childEnv[key] = value;
  }
  return spawnSync(process.execPath, ["-e", STUBS, script, ...argv],
    { env: childEnv, input: stdin, encoding: "utf8" });
};

const lines = (file) => {
  try { return fs.readFileSync(file, "utf8").split("\n").filter(Boolean); } catch { return []; }
};
const execLog = (home) => lines(path.join(home, "exec-log.txt"));
const execFileLog = (home) => lines(path.join(home, "execfile-log.txt"));
const spawnLog = (home) => lines(path.join(home, "spawn-calls.txt"));

const barDir = (home) => path.join(home, ".claude", "control-bar");
const stateDir = (home) => path.join(barDir(home), "state.d");
const codexStateDir = (home) => path.join(barDir(home), "codex", "state.d");
const readJSON = (file) => JSON.parse(fs.readFileSync(file, "utf8"));

module.exports = {
  scripts, sandbox, run, execLog, execFileLog, spawnLog,
  barDir, stateDir, codexStateDir, readJSON,
};
