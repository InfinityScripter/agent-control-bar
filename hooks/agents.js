// Agents besides Claude Code and Codex, and the one place that says how each is hooked.
//
// Every agent here takes Claude-shaped hooks: a JSON file whose `hooks` object maps an event name
// to entries of `{ matcher?, hooks: [{ type: "command", command, timeout }] }`, and a stdin payload
// carrying `session_id`, `cwd` and `tool_name`. What differs is where the file lives, what the
// events are called, which of them exist, and the unit of the timeout. Each agent's sessions go
// to a directory of their own (`<id>/state.d`), for the same reason Codex has one: a stray file
// in another agent's directory would be reaped by rules written for somebody else.
//
// The event lists come from Orca (stablyai/orca, src/main/<agent>/hook-service.ts at fde1ae7),
// which installs the same hooks for the same purpose. They were read from its source, not
// checked against a live install of each agent — see docs/multi-vendor-plan.md.
//
// Required by install.js and uninstall.js only. update.js and lifecycle.js run on every event
// and take what they need from argv (`--provider <id>`), so a hook never loads this file.

const fs = require("fs");
const path = require("path");

// The verbs are update.js's and lifecycle.js's own words: prompt, pre, post, notify, permreq,
// stop (update.js) and start, end (lifecycle.js).
const AGENTS = [
  {
    // Gemini has no permission-prompt hook (Orca: "approvals cannot produce a waiting state"),
    // so a Gemini session never shows "Awaiting permission". Its timeouts are milliseconds, and
    // it parses the hook's stdout as JSON — update.js answers `{}` for it.
    id: "gemini",
    title: "Gemini CLI",
    home: ".gemini",
    file: "settings.json",
    timeoutUnit: "ms",
    events: [
      ["BeforeAgent", "prompt"],
      ["BeforeTool", "pre"],
      ["AfterTool", "post"],
      ["AfterAgent", "stop"],
    ],
  },
  {
    // A Gemini CLI fork with Claude's event names; PermissionRequest and Notification both exist.
    id: "qwen",
    title: "Qwen Code",
    home: ".qwen",
    file: "settings.json",
    timeoutUnit: "s",
    events: [
      ["SessionStart", "start"],
      ["UserPromptSubmit", "prompt"],
      ["PreToolUse", "pre"],
      ["PostToolUse", "post"],
      ["PermissionRequest", "permreq"],
      ["Notification", "notify"],
      ["Stop", "stop"],
      ["SessionEnd", "end"],
    ],
  },
  {
    // Factory Droid has no PermissionRequest; the wait arrives as a Notification. The tool events
    // carry an explicit "*" matcher, as Orca writes them.
    id: "droid",
    title: "Factory Droid",
    home: ".factory",
    file: "settings.json",
    timeoutUnit: "s",
    events: [
      ["SessionStart", "start"],
      ["UserPromptSubmit", "prompt"],
      ["PreToolUse", "pre", "*"],
      ["PostToolUse", "post", "*"],
      ["Notification", "notify"],
      ["Stop", "stop"],
    ],
  },
];

const LIFECYCLE = new Set(["start", "end"]);
const TIMEOUT_SECONDS = 10;

const readJSON = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };

// Where the bytes belong when the file is a symlink into dotfiles — see install.js for why a
// rename over the link itself is the one thing that must not happen.
const resolveTarget = (file) => {
  try { return fs.realpathSync(file); } catch {}
  try {
    if (fs.lstatSync(file).isSymbolicLink()) return path.resolve(path.dirname(file), fs.readlinkSync(file));
  } catch {}
  return file;
};

const writeAtomic = (file, text) => {
  let mode;
  try { mode = fs.statSync(file).mode; } catch {}
  const target = resolveTarget(file);
  const tmp = `${target}.${process.pid}.tmp`;
  // A new file gets owner-only bits: it is an agent's settings file, not ours to open up.
  fs.writeFileSync(tmp, text, { mode: mode === undefined ? 0o600 : mode });
  fs.renameSync(tmp, target);
};

// Per-hook, never per-entry: a foreign hook sharing an entry object with ours survives, and an
// event key goes only when nothing of anyone's is left under it.
const stripOurs = (hooks, isOurs) => {
  for (const evt of Object.keys(hooks)) {
    if (!Array.isArray(hooks[evt])) continue;
    hooks[evt] = hooks[evt]
      .map((entry) => (entry && typeof entry === "object" && Array.isArray(entry.hooks))
        ? { ...entry, hooks: entry.hooks.filter((h) => !isOurs((h && h.command) || "")) }
        : entry)
      .filter((entry) => !(entry && typeof entry === "object" && Array.isArray(entry.hooks)
        && entry.hooks.length === 0));
    if (hooks[evt].length === 0) delete hooks[evt];
  }
};

// The file with our hooks for `agent` merged in. `commandFor(verb)` is the full command for one
// of our verbs, already carrying `--provider <id>`. Returns null for a file that is not an object.
const merged = (file, agent, commandFor, isOurs) => {
  if (!file || typeof file !== "object" || Array.isArray(file)) return null;
  const next = JSON.parse(JSON.stringify(file));
  if (!next.hooks || typeof next.hooks !== "object" || Array.isArray(next.hooks)) next.hooks = {};
  // Ours are stripped from every event first, not only the ones listed: an event dropped from the
  // list in a later version must not keep a stale entry behind.
  stripOurs(next.hooks, isOurs);
  const timeout = agent.timeoutUnit === "ms" ? TIMEOUT_SECONDS * 1000 : TIMEOUT_SECONDS;
  for (const [evt, verb, matcher] of agent.events) {
    const entry = { hooks: [{ type: "command", command: commandFor(verb), timeout }] };
    if (matcher) entry.matcher = matcher;
    next.hooks[evt] = [...(Array.isArray(next.hooks[evt]) ? next.hooks[evt] : []), entry];
  }
  return next;
};

const configPath = (home, agent) => path.join(home, agent.home, agent.file);

// Installs our hooks for every agent whose home directory exists. An agent that is not installed
// gets nothing — creating ~/.gemini on a machine without Gemini would be a lie on disk. A file
// that does not parse is said out loud and left alone: rewriting it would take the user's own
// settings with it. An unchanged file is not rewritten (this runs on every app launch).
const installAll = (home, { cmd, life, isOurs, log = console.log, warn = console.error }) => {
  for (const agent of AGENTS) {
    const dir = path.join(home, agent.home);
    if (!fs.existsSync(dir)) continue;
    const file = configPath(home, agent);
    const current = fs.existsSync(file) ? readJSON(file) : {};
    const commandFor = (verb) => (LIFECYCLE.has(verb) ? life(verb) : cmd(verb)) + " --provider " + agent.id;
    const next = merged(current, agent, commandFor, isOurs);
    if (!next) {
      warn(`${file} does not parse — ${agent.title} hooks not installed.`);
      continue;
    }
    const before = current && fs.existsSync(file) ? JSON.stringify(current, null, 2) + "\n" : "";
    const text = JSON.stringify(next, null, 2) + "\n";
    if (text === before) continue;
    try {
      writeAtomic(file, text);
      log(`Installed ${agent.title} hooks into ${file}`);
    } catch (err) {
      warn(`could not write ${file}: ${err.message}`);
    }
  }
};

// Removes our hooks from every agent's file. A file we cannot read is one we must not rewrite
// from a guess, so it is skipped.
const uninstallAll = (home, { isOurs, log = console.log }) => {
  for (const agent of AGENTS) {
    const file = configPath(home, agent);
    const current = readJSON(file);
    if (!current || typeof current !== "object" || Array.isArray(current)) continue;
    if (!current.hooks || typeof current.hooks !== "object" || Array.isArray(current.hooks)) continue;
    const next = JSON.parse(JSON.stringify(current));
    const had = Object.keys(next.hooks).length;
    stripOurs(next.hooks, isOurs);
    // Only a hooks object we emptied goes; one the user left empty is theirs.
    if (had && Object.keys(next.hooks).length === 0) delete next.hooks;
    const before = JSON.stringify(current, null, 2) + "\n";
    const text = JSON.stringify(next, null, 2) + "\n";
    if (text === before) continue;
    try {
      writeAtomic(file, text);
      log(`Removed control-bar hooks from ${file}`);
    } catch {}
  }
};

module.exports = { AGENTS, installAll, uninstallAll, merged, configPath };
