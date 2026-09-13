#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const home = os.homedir();
// The exact scripts our hook commands point at — both of them, so neither set is orphaned.
// NOT the directory as a substring: that also matched a user's own "control-bar-extra" and any
// command that merely reads a file out of our directory (see install.js, same contract and the
// same anchoring: the bare spelling is bounded on the right or "update.js" swallows a
// neighbour's "update.js.bak"; the shellQuote spelling carries homes with an apostrophe;
// bootstrap.py mirrors all of this).
const sbDir = path.join(home, ".claude", "control-bar");
const shellQuote = (value) => `'${value.replace(/'/g, `'\\''`)}'`;
const ownScripts = [path.join(sbDir, "update.js"), path.join(sbDir, "lifecycle.js")];
const boundary = (ch) => ch === undefined || ch === " " || ch === "'" || ch === '"';
const pointsAt = (command, script) => {
  for (let at = command.indexOf(script); at !== -1; at = command.indexOf(script, at + 1)) {
    if (boundary(command[at + script.length])) return true;
  }
  return command.includes(shellQuote(script));
};
const isOurs = (command) => ownScripts.some((script) => pointsAt(command, script));
const settingsPath = path.join(home, ".claude", "settings.json");

// --hooks-only strips the settings.json hooks and stops there. That is what the plugin channel
// needs when it claims the lease: the app itself must keep running and keep drawing, only its
// duplicate set of hooks has to go.
const hooksOnly = process.argv.includes("--hooks-only");

// Codex's hooks go only on a real uninstall, never on --hooks-only: the lease is a Claude Code
// problem (it merges plugin hooks with settings.json hooks and runs both), while
// ~/.codex/hooks.json is the single channel Codex reads. Removing and re-adding an entry there
// makes Codex ask the user to trust it again, so the lease handover must not touch it.
// On a real uninstall they have to go, though — left behind they point at scripts that were
// just deleted, and Codex would run a failing hook on every event from then on.
if (!hooksOnly) {
  const codexHooksPath = path.join(home, ".codex", "hooks.json");
  try {
    const file = JSON.parse(fs.readFileSync(codexHooksPath, "utf8"));
    const before = JSON.stringify(file, null, 2) + "\n";
    for (const evt of Object.keys((file || {}).hooks || {})) {
      // Per-hook, so a foreign hook sharing the entry survives; the event key goes only when
      // nothing of anyone's is left under it.
      file.hooks[evt] = (file.hooks[evt] || [])
        .map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !isOurs(h.command || "")) }))
        .filter((e) => (e.hooks || []).length > 0);
      if (file.hooks[evt].length === 0) delete file.hooks[evt];
    }
    const next = JSON.stringify(file, null, 2) + "\n";
    if (next !== before) {
      const tmp = `${codexHooksPath}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, next, { mode: fs.statSync(codexHooksPath).mode });
      fs.renameSync(tmp, codexHooksPath);
      console.log("Removed control-bar hooks from", codexHooksPath);
    }
  } catch {
    // No Codex, no hooks file, or one that does not parse: nothing to remove, and a file we
    // cannot read is one we must not rewrite from a guess.
  }
}

if (!hooksOnly) {
  // Undo the statusLine interception first, while the script that knows how still exists: the
  // limits capture rewires settings.json's statusLine.command to this install's statusline.sh,
  // and the README's next step is "drag the app to the Trash" — after which every status-line
  // redraw would exec a dead path and the user's original command would stay stranded in the
  // sidecars forever. Gated on the install's own sidecars, so python3 is only ever spawned on a
  // machine where the capture was actually installed (which proves /usr/bin/python3 works — a
  // bare CLT-less Mac must not get the system's developer-tools dialog from an uninstall).
  // mcpbar.py refuses politely when the command is no longer ours, so this stays idempotent.
  // Both layouts: Resources/scripts/ (bundle) and ../scripts/ (repo/plugin).
  const sidecars = ["statusline-saved.json", "statusline-inner-command", "statusline-installed.json"];
  if (sidecars.some((f) => fs.existsSync(path.join(sbDir, f)))) {
    for (const rel of [["scripts", "mcpbar.py"], ["..", "scripts", "mcpbar.py"]]) {
      const mcpbar = path.join(__dirname, ...rel);
      if (!fs.existsSync(mcpbar)) continue;
      try {
        cp.execFileSync("/usr/bin/python3", [mcpbar, "statusline", "--uninstall"], { stdio: "ignore" });
      } catch (e) {
        // Said out loud, not swallowed: this is exactly the case the block exists for. The
        // app is about to be trashed, and a status line still pointing at its wrapper would
        // exec a dead path on every redraw with the user's own command stranded in the sidecars.
        console.error(`Could not restore the statusLine command (${e.message}). Run before trashing the app:`);
        console.error(`  /usr/bin/python3 "${mcpbar}" statusline --uninstall`);
      }
      break;
    }
  }
  // Tear down the desktop watcher LaunchAgent (best-effort; safe if absent).
  const AGENT_LABEL = "com.local.claudestatusbar.watcher";
  const agentPlist = path.join(home, "Library", "LaunchAgents", AGENT_LABEL + ".plist");
  try { cp.execSync(`launchctl bootout gui/${process.getuid()}/${AGENT_LABEL}`, { stdio: "ignore" }); } catch {}
  if (fs.existsSync(agentPlist)) { fs.rmSync(agentPlist); console.log("Removed desktop watcher LaunchAgent."); }
  try { cp.execSync("pkill -x ClaudeControlBar", { stdio: "ignore" }); } catch {}
}

if (!fs.existsSync(settingsPath)) { console.log("No settings.json; nothing to do."); process.exit(0); }

// Same contract as install.js: fingerprint before, verify before the rename, write through a
// temp file. Removing hooks is no less destructive than adding them — this path rewrites the
// whole of a file Claude Code and the user both own.
const stamp = () => {
  try { const st = fs.statSync(settingsPath); return `${st.mtimeMs}:${st.size}`; } catch { return ""; }
};
// See install.js: a settings.json symlinked into ~/dotfiles must keep being a symlink, including
// when the link dangles and realpath refuses to answer.
const resolveSettingsPath = () => {
  try { return fs.realpathSync(settingsPath); } catch {}
  try {
    if (fs.lstatSync(settingsPath).isSymbolicLink()) {
      return path.resolve(path.dirname(settingsPath), fs.readlinkSync(settingsPath));
    }
  } catch {}
  return settingsPath;
};
const writeSettingsAtomic = (text, readAt) => {
  if (stamp() !== readAt) {
    console.log("settings.json changed while we were working on it — nothing removed.");
    return false;
  }
  let mode;
  try { mode = fs.statSync(settingsPath).mode; } catch {}
  const target = resolveSettingsPath();
  const tmp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text, mode === undefined ? undefined : { mode });
  fs.renameSync(tmp, target);
  return true;
};

const readAt = stamp();
let settings;
try {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
} catch (err) {
  // Removing hooks from a file we cannot read means rewriting it from a guess. Say so and stop.
  console.error("settings.json does not parse — nothing removed:", err.message);
  process.exit(1);
}
// Compared against the re-serialised parse so the user's own formatting is not mistaken for a
// change: the plugin runs this on every session start.
const before = JSON.stringify(settings, null, 2) + "\n";
for (const evt of Object.keys(settings.hooks || {})) {
  settings.hooks[evt] = (settings.hooks[evt] || [])
    .map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !isOurs(h.command || "")) }))
    .filter((e) => (e.hooks || []).length > 0);
  if (settings.hooks[evt].length === 0) delete settings.hooks[evt];
}
const next = JSON.stringify(settings, null, 2) + "\n";
if (next === before) {
  if (!hooksOnly) console.log("No control-bar hooks in", settingsPath);
} else if (writeSettingsAtomic(next, readAt)) {
  console.log("Removed control-bar hooks from", settingsPath);
}
