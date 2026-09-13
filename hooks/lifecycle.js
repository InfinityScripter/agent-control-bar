#!/usr/bin/env node
// SessionStart/SessionEnd hooks. Usage: node lifecycle.js <start|end> [--provider codex]
// (hook JSON, incl. session_id, on stdin)

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "io.github.infinityscripter.claude-control-bar";
const EXEC = "ClaudeControlBar";
const dir = path.join(os.homedir(), ".claude", "control-bar");
const event = process.argv[2];
// See update.js for why one file serves both agents. Codex gets its own directory, never a
// second shape.
const providerFlag = process.argv.indexOf("--provider");
const codex = providerFlag > 0 && process.argv[providerFlag + 1] === "codex";
const stateDir = codex ? path.join(dir, "codex", "state.d") : path.join(dir, "state.d");
// One file per session, written by hooks/statusline.py: the context percentage Claude Code
// itself reported. It lives and dies with the session file, or context.d grows without bound.
// Codex has none: it states the context in its own rollout, so nothing has to be captured.
const contextDir = path.join(dir, "context.d");
const sessionDirs = codex ? [stateDir] : [stateDir, contextDir];

// 0700/0600 everywhere below, not the umask default. A session file carries the working
// directory, the transcript path and the pid, and the home folder is group-readable by staff
// on macOS — which is every local account on the machine.
fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });

const running = () => { try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch { return false; } };
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

// kill(pid, 0) probes existence without signalling: it throws ESRCH when the process is gone
// and EPERM when it exists but belongs to someone else (same user here, so it should not
// happen — treated as alive anyway, because deleting a live session's file is the worse error).
const alive = (pid) => {
  if (!(pid > 0)) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
};

const forget = (id) => {
  for (const d of sessionDirs) {
    try { fs.rmSync(path.join(d, id + ".json"), { force: true }); } catch {}
  }
};

// The rollout's first line is a session_meta record naming the surface and whether this thread
// is the user's or a worker's. Read once, at SessionStart: neither fact changes mid-session,
// and the per-event hook must not pay for a file open it does not need.
//
// `originator` is the honest source for the surface — a Codex session in the IDE and one in
// the desktop app both report `source: "vscode"`, so the hook payload cannot tell them apart.
// An unknown originator yields no surface rather than a guessed one: a wrong "CLI" badge on a
// desktop session is worse than no badge.
const CODEX_SURFACES = {
  // Two spellings for the terminal: codex_cli_rs is what older builds wrote, "codex-tui" is what
  // 0.154 writes — measured across 303 rollouts on this machine, where codex_cli_rs appears zero
  // times. Dropping the old one would blank the badge for anyone still on a build that sends it.
  codex_cli_rs: "cli", "codex-tui": "cli", codex_vscode: "ide", codex_work_desktop: "app",
  "Codex Desktop": "app", codex_exec: "exec",
};

// How much of that first line is worth reading. It used to be 8 KB, and on this machine every one
// of 303 rollouts opens with more than that — median 19 KB, largest 70 KB — so the parse threw on
// half an object, the catch said "unknown", and no session from this build ever got a badge.
// Half a megabyte leaves the line room to grow; past it the answer is no answer, never a
// truncated line handed to JSON.parse.
const CODEX_META_BYTES = 524288;

const codexMeta = (transcript) => {
  if (!transcript) return { surface: "", worker: false };
  let fd;
  try {
    fd = fs.openSync(transcript, "r");
    const buf = Buffer.alloc(CODEX_META_BYTES);
    const read = fs.readSync(fd, buf, 0, CODEX_META_BYTES, 0);
    const text = buf.toString("utf8", 0, read);
    const end = text.indexOf("\n");
    // No newline: the file's own size tells the two cases apart — a file one record long (the
    // whole read is the line) against a line that does not end inside what we took.
    if (end === -1 && read < fs.fstatSync(fd).size) return { surface: "", worker: false };
    const meta = (JSON.parse(end === -1 ? text : text.slice(0, end)) || {}).payload || {};
    return {
      surface: CODEX_SURFACES[meta.originator] || "",
      // Anything that is not the user's own thread is somebody's worker: `subagent` and
      // `guardian_review` both appear in this machine's rollouts. A missing field is an older
      // Codex that had no workers at all, so it counts as the user's.
      worker: typeof meta.thread_source === "string" && meta.thread_source !== "user",
    };
  } catch {
    return { surface: "", worker: false };
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
  }
};

const reapDeadSessions = () => {
  let files = [];
  try { files = fs.readdirSync(stateDir); } catch { return; }
  for (const f of files.filter((n) => n.endsWith(".json"))) {
    const full = path.join(stateDir, f);
    let pid = 0;
    try { pid = JSON.parse(fs.readFileSync(full, "utf8")).pid || 0; } catch {}
    if (!alive(pid)) forget(f.slice(0, -5));
  }
  // Strays: statusline.py runs detached, and a capture from the session's last redraw can land
  // AFTER SessionEnd's forget() — re-creating context.d/<sid>.json with no state file to pair
  // with. The loop above walks stateDir only, so such a file was never visited again and the
  // directory grew without bound, the exact leak the header comment promises away.
  let ctx = [];
  if (codex) return;   // Codex writes no context files, so there are no strays to collect.
  try { ctx = fs.readdirSync(contextDir); } catch { return; }
  for (const f of ctx.filter((n) => n.endsWith(".json"))) {
    if (!fs.existsSync(path.join(stateDir, f))) {
      try { fs.rmSync(path.join(contextDir, f), { force: true }); } catch {}
    }
  }
};

const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  // The mode is set at creation rather than chmod'ed after: the temp file is written in full
  // before the rename, so a later chmod would leave it world-readable for that whole window.
  fs.writeFileSync(tmp, JSON.stringify(obj), { mode: 0o600 });
  fs.renameSync(tmp, file);
};

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => run());
process.stdin.on("error", () => run());
setTimeout(run, 1000); // hooks always pipe stdin, but never hang the session

function run() {
  if (done) return; done = true;
  let id = "", cwd = "", transcript = "", source = "";
  // The transcript path is carried from the very first event so the next hook can measure the
  // context window without waiting for one that happens to include it.
  try { const j = JSON.parse(input); id = j.session_id; cwd = j.cwd || ""; transcript = j.transcript_path || ""; source = j.source || ""; } catch {}
  id = safeId(id);
  const statePath = path.join(stateDir, id + ".json");

  if (event === "start") {
    // SessionStart fires for brand-new sessions AND for resumes (--resume/--continue, wake
    // after sleep, compaction). Only a genuinely new session voids a prior explicit Quit (see
    // update.js's self-relaunch suppress) — a resume honors it, or the app "comes back on its
    // own" the moment a laptop lid opens. No source at all is an old Claude Code: it keeps the
    // pre-source behavior, else one Quit would leave the app permanently down there.
    // bootstrap.py's may_launch() applies this same list in parallel — keep the two in step.
    const resumed = ["resume", "compact", "fork"].includes(source);
    if (!resumed) {
      try { fs.rmSync(path.join(dir, "quit-intent"), { force: true }); } catch {}
    }
    // Leftovers from a crash would inflate the count, so they go — but only the ones whose
    // process is actually gone. The app not running is no evidence a SESSION is dead: two
    // sessions opening at once both see it down, and the second one's blanket wipe took out
    // the first one's file before the app had ever read it. Liveness is the pid, nothing else.
    if (!running()) reapDeadSessions();
    // A Codex worker thread gets no file of its own: it is part of the user's session, not a
    // session of its own, and four of them at once turned one prompt into five rows. Its own
    // SessionEnd still runs harmlessly — forget() on a file that was never written is a no-op.
    const meta = codex ? codexMeta(transcript) : { surface: "", worker: false };
    if (meta.worker) process.exit(0);
    // Seed an idle file: counts the session immediately, and clears any frozen state from a
    // resume (SessionStart fires on resume with no active turn).
    try {
      // started:false — a merely-opened conversation seeds this for launch + liveness but stays out of
      // the dropdown until it has real activity (update.js flips started:true on a prompt/tool).
      const seed = { state: "idle", label: "", tool: "", project: cwd ? path.basename(cwd) : "", cwd, sessionId: id, transcript, entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT || "", term_program: process.env.TERM_PROGRAM || "", term_bundle: process.env.__CFBundleIdentifier || "", pid: process.ppid, started: false, startedAt: 0, ts: Math.floor(Date.now() / 1000) };
      if (codex) { seed.provider = "codex"; seed.surface = meta.surface; }
      writeAtomic(statePath, seed);
    } catch {}
    if (!resumed || !fs.existsSync(path.join(dir, "quit-intent"))) {
      cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
    }
  } else if (event === "end") {
    // Removing the file drops this session from the aggregate — this is also what recovers a
    // frozen animation on force-quit (SessionEnd fires, but no Stop). No state rewrite needed.
    forget(id);
  }
  process.exit(0);
}
