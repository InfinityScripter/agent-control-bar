#!/usr/bin/env node
// Maps an agent's hook event to this session's file: ~/.claude/control-bar/state.d/<session_id>.json
// for Claude Code, ~/.claude/control-bar/codex/state.d/<session_id>.json for Codex CLI.
// Usage: node update.js <prompt|pre|post|notify|permreq|stop> [--provider codex]

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const dir = path.join(os.homedir(), ".claude", "control-bar");
// Written by the app's Quit menu item; suppresses the relaunch below so Quit sticks.
// lifecycle.js removes it on the next SessionStart (a new session = fresh consent).
const quitMarker = path.join(dir, "quit-intent");
const event = process.argv[2] || "";
// One hook file serves both agents. The alternative — a second copy for Codex — means every
// fix to the shared 300 lines has to be made twice, and the copy that gets forgotten is the
// one nobody notices. The provider only ever changes which directory and which transcript
// parser is used; the state file's shape is deliberately identical.
const providerFlag = process.argv.indexOf("--provider");
const codex = providerFlag > 0 && process.argv[providerFlag + 1] === "codex";
const stateDir = codex ? path.join(dir, "codex", "state.d") : path.join(dir, "state.d");

const TOOL_LABELS = {
  Bash: "Running command", Edit: "Editing", Write: "Writing", MultiEdit: "Editing",
  NotebookEdit: "Editing", Read: "Reading", Grep: "Searching", Glob: "Searching",
  WebFetch: "Browsing web", WebSearch: "Searching web", Task: "Delegating",
  TodoWrite: "Planning",
};

// Codex names its tools differently, and the same activity has to read the same way whichever
// agent is doing it — "exec" and "Bash" are both a shell. The shell family is long because
// Codex has shipped several generations of it and old versions are still in use; `exec` and
// `js` are the two that actually appear in this machine's rollouts, the rest come from the
// tool registry in openai/codex. An unknown name falls through to "Using tool", as for Claude.
const CODEX_TOOL_LABELS = {
  exec: "Running command", shell: "Running command", shell_command: "Running command",
  exec_command: "Running command", unified_exec: "Running command",
  write_stdin: "Running command", js: "Running code",
  apply_patch: "Editing", read_file: "Reading", web_search: "Searching web",
  view_image: "Reading", update_plan: "Planning",
  spawn_agent: "Delegating", wait_agent: "Delegating", list_agents: "Delegating",
  followup_task: "Delegating", send_message: "Delegating", wait: "Delegating",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

// The first line of a Codex rollout is a session_meta record naming which surface the session
// runs on and whether the thread is the user's or a worker's. Neither fact changes mid-session.
// (lifecycle.js carries the same reader for SessionStart — keep the two in step. A shared third
// file would have to be copied into ~/.claude/control-bar and added to the bundle, the installer
// and the CI identity guard for twenty lines; the repo already keeps the hook-ownership
// predicate in three copies for the same reason.)
const CODEX_SURFACES = {
  codex_cli_rs: "cli", codex_vscode: "ide", codex_work_desktop: "app",
  "Codex Desktop": "app", codex_exec: "exec",
};

const codexRollout = (transcript) => {
  if (!transcript) return null;
  let fd;
  try {
    fd = fs.openSync(transcript, "r");
    const buf = Buffer.alloc(8192);
    const read = fs.readSync(fd, buf, 0, 8192, 0);
    const meta = (JSON.parse(buf.toString("utf8", 0, read).split("\n")[0]) || {}).payload || {};
    return {
      // An unknown originator yields no surface rather than a guessed one: a wrong "CLI" badge
      // on a desktop session is worse than no badge.
      surface: CODEX_SURFACES[meta.originator] || "",
      // A missing field is an older Codex that had no workers at all, so it counts as the user's.
      worker: typeof meta.thread_source === "string" && meta.thread_source !== "user",
    };
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
  }
};

// --- context window ---------------------------------------------------------
// Claude Code hands the used-context percentage to statusLine and to nothing else, and the
// desktop app never runs statusLine (it drives the CLI headless, where there is no TUI to draw
// a status line into). So the number is recomputed here from the session transcript, with the
// same formula the CLI uses, and rides along in the session file the app already reads.

const windowCache = path.join(dir, "model-windows.json");
const contextDir = path.join(dir, "context.d");
const DEFAULT_WINDOW = 200000;
// How long a statusLine reading stays worth trusting. The status line redraws on every
// assistant message, so inside a live terminal session the record is never older than a turn;
// past this the session has almost certainly moved to the desktop app, which runs no status
// line at all — and a frozen figure from an hour ago is worse than a recomputed one.
const STATUSLINE_MAX_AGE = 900;
// Records that must not be measured: interrupted turns and Claude Code's own synthetic replies.
const SKIP_TEXTS = new Set([
  "[Request interrupted by user]",
  "[Request interrupted by user for tool use]",
  "No response requested.",
]);

const readJSON = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };

// The model->window table is scraped out of the Claude Code binary by scripts/mcpbar.py and
// cached; this hook only reads it. Scraping 226 MB on every tool call is not an option.
const FAMILIES = ["opus", "sonnet", "haiku", "fable", "mythos"];
const familyOf = (id) => id.split("-").find((part) => FAMILIES.includes(part)) || "";

// Returns [window, exact]. The table is not a complete list of what a session can report:
// transcripts record the served model name, and that name may not exist in the local registry
// at all. Measured on Claude Code 2.1.205: the registry knows claude-opus-4-8 and maps the
// alias "opus" onto it, while transcripts say claude-opus-5 — a name absent from the binary.
// Falling straight through to the 200k default put a 154k-token session at 77% when the honest
// figure was 15%, so an unknown name borrows the widest window in its own family instead.
// Anthropic has never narrowed a family's window across generations, which is what makes the
// borrow safe; it is still a guess, so the caller marks it assumed.
function windowFor(model, models) {
  const id = String(model || "").toLowerCase();
  if (id.includes("[1m]")) return [1000000, true];
  const base = id.replace(/-\d{8}$/, "");
  if (models[base]) return [models[base], true];
  const family = familyOf(base);
  const kin = Object.keys(models).filter((k) => familyOf(k) === family).map((k) => models[k]);
  return family && kin.length ? [Math.max(...kin), false] : [DEFAULT_WINDOW, false];
}

// What Claude Code itself reported for this session, captured by hooks/statusline.py.
// Preferred over the recomputation below, because the recomputation has to GUESS the window
// size: it belongs to the session, not to the model, and the same claude-opus-5 answers with
// 200k in one place and 1M in another. Guessing wrong moves the percentage by a factor of five.
function contextFromStatusLine(sessionId, now) {
  const record = readJSON(path.join(contextDir, sessionId + ".json"));
  if (!record || typeof record.pct !== "number" || !(record.window > 0)) return null;
  if (!(now - (record.ts || 0) <= STATUSLINE_MAX_AGE)) return null;
  return {
    pct: record.pct, tokens: record.tokens, window: record.window,
    model: record.model || "", assumed: false,
  };
}

// Session cost, wall time and lines changed, from the same statusLine record. No age check,
// unlike the context figure above: a percentage can be re-measured from the transcript, a
// running total cannot — and the last known figure is a fact about the session, not a guess.
// null when no status line ever ran for this session (the desktop app runs none).
function costFromStatusLine(sessionId, prev) {
  const record = readJSON(path.join(contextDir, sessionId + ".json"));
  const source = typeof (record || {}).cost === "number" ? record : prev;
  const num = (v) => (typeof v === "number" ? v : null);
  return {
    cost: num(source.cost), duration: num(source.duration),
    linesAdded: num(source.linesAdded), linesRemoved: num(source.linesRemoved),
  };
}

// Files with uncommitted changes, untracked included: the "1 uncommitted" on the session card.
// null outside a git repository or when git is missing/slow. Measured only at the turn's
// boundaries — prompt and stop — and carried through the tool events in between: PreToolUse
// blocks the tool call until this hook exits, and a status walk over a large tree is the
// slowest thing the hook could do, so it must not run twice per tool call. The hard timeout
// is the second net. The app reads .git/HEAD for the branch without spawning git; a status
// walk has no such shortcut.
function dirtyCount(cwd, event, prev) {
  if (!cwd) return null;
  if (event !== "prompt" && event !== "stop") return typeof prev.dirty === "number" ? prev.dirty : null;
  try {
    const res = cp.spawnSync("git", ["-C", cwd, "status", "--porcelain"],
      { encoding: "utf8", timeout: 1500, stdio: ["ignore", "pipe", "ignore"] });
    if (res.status !== 0 || res.error) return null;
    return res.stdout.split("\n").filter(Boolean).length;
  } catch {
    return null;
  }
}

// used% = clamp(round((input + cache_creation + cache_read) / window * 100), 0, 100).
// output_tokens is NOT in the numerator — checked against a live statusLine payload.
function contextOf(transcript) {
  let fd;
  try {
    fd = fs.openSync(transcript, "r");
    const size = fs.fstatSync(fd).size;
    if (!size) return null;
    const models = (readJSON(windowCache) || {}).models || {};
    // Tail only: a long session's transcript runs to tens of megabytes, and the newest usage
    // record is always at the end. Two steps, because this runs twice per tool call: the
    // record is nearly always within the last few lines, so 128 KB finds it; only a turn that
    // ends in a very large tool result needs the 2 MB read (one turn plus such a result).
    for (const span of [Math.min(size, 131_072), Math.min(size, 2_000_000)]) {
      const found = codex ? codexUsageInTail(fd, size, span) : usageInTail(fd, size, span, models);
      if (found) return found;
      if (span === size) break;
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
  }
}

function tailLines(fd, size, span) {
  const buf = Buffer.alloc(span);
  fs.readSync(fd, buf, 0, span, size - span);
  let text = buf.toString("utf8");
  // The read starts mid-line, and possibly mid-UTF-8-character; dropping the first partial
  // line discards both problems at once.
  if (size > span) text = text.slice(text.indexOf("\n") + 1);
  return text.split("\n");
}

// Codex states the window in every record, so there is nothing to guess and nothing to borrow
// from a model family: `assumed` is honestly false.
//
// Which of the record's two totals is the context is the whole point of this function.
// total_token_usage accumulates every turn ever billed — measured at 25,374,147 on a 110-turn
// session whose window is 828,400 — so reading it parks a session at 100% after a few turns.
// last_token_usage is what occupies the window right now; on that same session it grew from
// 60k to 323k and never passed the window.
function codexUsageInTail(fd, size, span) {
  const lines = tailLines(fd, size, span);
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].includes('"token_count"')) continue;
    let rec;
    try { rec = JSON.parse(lines[i]); } catch { continue; }
    const info = ((rec || {}).payload || {}).info || {};
    const last = info.last_token_usage || {};
    const window = info.model_context_window;
    const tokens = last.total_tokens;
    if (typeof tokens !== "number" || !(window > 0)) continue;
    return {
      pct: Math.max(0, Math.min(100, Math.round((tokens / window) * 100))),
      tokens, window, model: "", assumed: false,
    };
  }
  return null;
}

function usageInTail(fd, size, span, models) {
  const lines = tailLines(fd, size, span);
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].includes('"usage"')) continue;
    let rec;
    try { rec = JSON.parse(lines[i]); } catch { continue; }
    if (!rec || rec.type !== "assistant" || rec.isSidechain) continue;
    const msg = rec.message || {};
    if (msg.model === "<synthetic>") continue;
    const blocks = msg.content;
    if (Array.isArray(blocks) && blocks[0] && SKIP_TEXTS.has(blocks[0].text)) continue;
    const usage = msg.usage || {};
    if (typeof usage.input_tokens !== "number") continue;

    const tokens = usage.input_tokens
      + (usage.cache_creation_input_tokens || 0)
      + (usage.cache_read_input_tokens || 0);
    let [window, exact] = windowFor(msg.model, models);
    let assumed = !exact;
    if (tokens > window) {
      // Observation beats the table: this many tokens could not physically fit a 200k window,
      // so the session runs in the million one and the scraped table is behind. Showing the
      // recomputed figure is more honest than pinning a fake 100%.
      window = 1000000;
      assumed = true;
    }
    return {
      pct: Math.max(0, Math.min(100, Math.round((tokens / window) * 100))),
      tokens, window, model: msg.model || "", assumed,
    };
  }
  return null;
}

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  // Off by default; CONTROL_BAR_DEBUG=1 logs every hook invocation to hooks.log.
  if (process.env.CONTROL_BAR_DEBUG === "1") {
    try {
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      // Rotated at 1 MB, keeping one previous file. The line below carries an excerpt of the
      // event's message, so this is a file that can hold fragments of what was typed — letting
      // it grow without limit for the life of the install is not a debugging aid, it is a
      // transcript nobody asked for.
      const logPath = path.join(dir, "hooks.log");
      try {
        if (fs.statSync(logPath).size > 1_000_000) fs.renameSync(logPath, logPath + ".1");
      } catch {}
      // 0600: this file holds fragments of what was typed, and the home folder is readable by
      // group staff on macOS — every local account. The mode applies when the log is created.
      fs.appendFileSync(logPath,
        `${new Date().toISOString()} [${event}] tool=${p.tool_name || "-"} mode=${p.permission_mode || "-"} msg=${JSON.stringify(p.message || "").slice(0, 160)} keys=${Object.keys(p).join(",")}\n`,
        { mode: 0o600 });
    } catch {}
  }

  // This session's own file is the unit of state AND the liveness marker. Writing it on any
  // event also tracks sessions that predate the hook install (never fired SessionStart).
  const sid = safeId(p.session_id);
  const statePath = path.join(stateDir, sid + ".json");

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  // A Codex subagent is a thread of its own: own session id, own rollout, own hook events.
  // Left alone, one prompt of the user's showed five running sessions — the parent plus four
  // workers — and whichever worker fired last decided what the menu bar icon said.
  //
  // Two nets, because only one of them is a fact. `agent_id`/`agent_type` on the payload is
  // what Codex's hook documentation describes, and it is free to check — but it has NOT been
  // seen on a live worker's own event here, only asserted. The rollout's `thread_source` has:
  // `subagent` and `guardian_review` both appear in this machine's files. So the documented
  // field is the cheap first look, and the rollout is what actually decides.
  //
  // Read only when this session has no file yet: one open per session, not per event. A
  // worker has no file by definition (it never gets one), which is the one case that pays the
  // read every time — and a worker's life is a handful of events.
  const codexMeta = codex && !prev.provider ? codexRollout(p.transcript_path || prev.transcript) : null;
  if (codex && (p.agent_id || p.agent_type || (codexMeta && codexMeta.worker))) return;

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  // The app reads <cwd>/.git/HEAD for the branch and disambiguates same-named projects by
  // parent folder; carried over from prev for events whose payload omits cwd.
  const cwd = p.cwd || prev.cwd || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "", startedAt = prev.startedAt || 0;

  switch (event) {
    case "prompt":
      state = "thinking"; label = "Thinking…"; startedAt = ts; break;
    case "pre": {
      const t = p.tool_name || "";
      const labels = codex ? CODEX_TOOL_LABELS : TOOL_LABELS;
      state = "tool"; label = labels[t] || "Using tool";
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      break;
    case "notify": {
      // Only a permission prompt drives the icon here (CLI path; desktop uses permreq). Ignore
      // every other Notification (esp. the idle_prompt "Claude is waiting for your input") so the
      // icon rests instead of parking on a confusing "Waiting for you".
      //
      // notification_type is the answer whenever it is present; the message text is a fallback
      // for payloads old enough to lack the field, and it matches whole words only — "allow" as
      // a SUBSTRING also lives inside "shallow", and one such notification parked the icon on
      // "Awaiting permission", a state with a two-hour timeout.
      const isPerm = p.notification_type
        ? p.notification_type === "permission_prompt"
        : /\b(permission|approve|allow)\b/i.test(p.message || "");
      if (!isPerm) return;
      state = "permission"; label = "Awaiting permission"; startedAt = 0;
      break;
    }
    case "permreq":
      // Desktop-app permission signal; not redundant with notify (that's CLI-only).
      state = "permission"; label = "Awaiting permission"; startedAt = 0; break;
    case "stop":
      state = "done"; label = "Done"; startedAt = 0; break;
    default:
      return;
  }

  // CLAUDE_CODE_ENTRYPOINT tags the surface running this session ("cli", "claude-desktop", …);
  // carried over from prev for the odd event where the env var isn't set.
  const entrypoint = process.env.CLAUDE_CODE_ENTRYPOINT || prev.entrypoint || "";
  // TERM_PROGRAM identifies the terminal app for a CLI session (Apple_Terminal, iTerm.app,
  // vscode, WezTerm, …); the app uses it to bring that terminal to the front on a row click.
  const termProgram = process.env.TERM_PROGRAM || prev.term_program || "";
  // __CFBundleIdentifier (stamped by LaunchServices on every process launched from an app
  // bundle) names the exact host app — TERM_PROGRAM cannot: Cursor, Windsurf and VS Code all
  // report "vscode", and the IDE extension panel sets no TERM_PROGRAM at all. The app prefers
  // this for the row click (`open -b`), keeping the TERM_PROGRAM map as the fallback.
  const termBundle = process.env.__CFBundleIdentifier || prev.term_bundle || "";
  // process.ppid IS this session's `claude` process (verified: hooks are spawned directly by it,
  // stable for the session's life, on both CLI and desktop). The app uses kill(pid,0) for liveness.
  // started:true — any update.js event (prompt/tool/permission/stop) is real activity, so the session
  // graduates from "merely opened" to visible in the dropdown. Clicking a conversation never fires here.
  const transcript = p.transcript_path || prev.transcript || "";
  // Carried over from prev when this event's transcript is unreadable (a compaction rewrites the
  // file, and a read landing mid-rewrite finds no usage record) — a momentarily missing number
  // would otherwise blank the context bar and read as "context freed".
  const ctx = contextFromStatusLine(sid, ts)
    || (transcript && contextOf(transcript))
    || {
      pct: prev.pct, tokens: prev.tokens, window: prev.window, model: prev.model, assumed: prev.assumed,
    };
  const out = { state, label, tool: p.tool_name || "", project, cwd, sessionId: p.session_id || "", transcript, entrypoint, term_program: termProgram, term_bundle: termBundle, pid: process.ppid, started: true, startedAt, ts, ...ctx,
    ...costFromStatusLine(sid, prev), dirty: dirtyCount(cwd, event, prev) };
  if (codex) {
    // The app keys its session map by "<provider>:<id>" and draws the pill from this field, so
    // an old file without it has to keep reading as Claude's — hence a field rather than a
    // second shape. Codex names the model in every payload, so unlike Claude's it needs no
    // transcript lookup; the surface is settled once at SessionStart and carried from there,
    // because it takes reading the rollout's first line and never changes mid-session.
    out.provider = "codex";
    // Settled once and carried: from the seed file SessionStart wrote, or — for a session that
    // was already running when the hooks were installed, which never fired SessionStart — from
    // the rollout read above.
    out.surface = typeof prev.surface === "string" ? prev.surface
                  : (codexMeta ? codexMeta.surface : "");
    out.model = p.model || prev.model || "";
  }
  try {
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    const tmp = statePath + "." + process.pid + ".tmp";
    // Written with the mode set at creation: the file carries the working directory, the
    // transcript path and the pid, and the umask default of 0644 hands all three to any other
    // local account (the home folder is group-readable by staff on macOS).
    fs.writeFileSync(tmp, JSON.stringify(out), { mode: 0o600 });
    fs.renameSync(tmp, statePath);
  } catch (e) {
    // This write IS the hook's output; a persistently failing one (full disk, a chmod gone
    // wrong) made the menu bar look frozen forever. problems.log is the app's own breadcrumb
    // file, so the failure lands where the README already sends people to look.
    try { fs.appendFileSync(path.join(dir, "problems.log"), `update.js: could not write ${statePath}: ${e.message}\n`); } catch {}
  }

  // Self-heal: a session with live state but no app to show it relaunches the app. Covers
  // install-while-a-session-is-already-open (that session never fires SessionStart, the only
  // other opener) and an app killed/crashed mid-session. Skipped after an explicit menu Quit.
  // pgrep is a fork, and this ran on every PreToolUse and PostToolUse — two forks per tool
  // call for an answer that does not change between them. A probe that just ran answers for
  // the next half minute; a crash still heals within that window. The marker's mtime is the
  // clock, so the throttle costs one stat instead of a process.
  const probeMarker = path.join(dir, "self-heal-probed");
  try {
    if (fs.existsSync(quitMarker)) return;
    try { if (Date.now() - fs.statSync(probeMarker).mtimeMs < 30_000) return; } catch {}
    try { fs.writeFileSync(probeMarker, "", { mode: 0o600 }); } catch {}
    cp.execSync("pgrep -x ClaudeControlBar", { stdio: "ignore" });
  } catch {
    try { cp.spawn("open", ["-g", "-b", "io.github.infinityscripter.claude-control-bar"], { stdio: "ignore", detached: true }).unref(); } catch {}
  }
});
