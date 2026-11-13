// Agents beyond Claude Code and Codex (hooks/agents.js): what the installer writes into each
// agent's own settings file, what it must never touch, and what the hooks write for each agent.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");
const { AGENTS } = require("../hooks/agents");
const { scripts, sandbox, run, barDir, readJSON } = require("./hook-harness");

const installerPath = path.resolve(__dirname, "../hooks/install.js");

const runScript = (scriptPath, home, argv = []) => {
  const script = [
    `require("node:child_process").execSync = () => {};`,
    `process.argv.push(...JSON.parse(process.env.EXTRA_ARGV));`,
    `require(process.env.SCRIPT_PATH);`,
  ].join("\n");
  return execFileSync(process.execPath, ["-e", script], {
    env: { ...process.env, HOME: home, SCRIPT_PATH: scriptPath, EXTRA_ARGV: JSON.stringify(argv) },
    stdio: "pipe", encoding: "utf8",
  });
};
const install = (home) => runScript(installerPath, home);
const uninstall = (home, argv = []) => runScript(scripts.uninstall, home, argv);

const settingsOf = (home, agent) => path.join(home, agent.home, agent.file);
const ours = (file, id) => Object.values(file.hooks || {}).flat()
  .flatMap((entry) => entry.hooks || []).map((h) => h.command || "")
  .filter((c) => c.endsWith(" --provider " + id));
const agent = (id) => AGENTS.find((a) => a.id === id);

test("each installed agent gets one hook per event, with its own provider and timeout unit", (t) => {
  const home = sandbox(t, "acb-agents-");
  for (const a of AGENTS) fs.mkdirSync(path.join(home, a.home), { recursive: true });
  install(home);
  for (const a of AGENTS) {
    const file = readJSON(settingsOf(home, a));
    assert.equal(ours(file, a.id).length, a.events.length, a.id);
    for (const [evt, verb, matcher] of a.events) {
      const entries = file.hooks[evt];
      assert.equal(entries.length, 1, `${a.id} ${evt}`);
      const [hook] = entries[0].hooks;
      const script = verb === "start" || verb === "end" ? "lifecycle.js" : "update.js";
      assert.ok(hook.command.includes(script + "' " + verb + " --provider " + a.id), hook.command);
      assert.equal(hook.timeout, a.timeoutUnit === "ms" ? 10000 : 10, `${a.id} ${evt} timeout`);
      assert.equal(entries[0].matcher, matcher, `${a.id} ${evt} matcher`);
    }
    assert.equal(fs.statSync(settingsOf(home, a)).mode & 0o777, 0o600, "a new settings file is owner-only");
  }
});

test("an agent that is not installed gets no directory and no file", (t) => {
  const home = sandbox(t, "acb-agents-none-");
  install(home);
  for (const a of AGENTS) assert.ok(!fs.existsSync(path.join(home, a.home)), a.id);
});

test("the user's settings and foreign hooks survive, and a second run changes nothing", (t) => {
  const home = sandbox(t, "acb-agents-merge-");
  const gemini = agent("gemini");
  const file = settingsOf(home, gemini);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const foreign = "/bin/sh '/Users/somebody/.orca/agent-hooks/gemini-hook.sh'";
  fs.writeFileSync(file, JSON.stringify({
    theme: "GitHub",
    hooks: { BeforeTool: [{ hooks: [{ type: "command", command: foreign, timeout: 5000 }] }] },
  }), { mode: 0o644 });
  install(home);
  const after = readJSON(file);
  assert.equal(after.theme, "GitHub");
  assert.equal(after.hooks.BeforeTool[0].hooks[0].command, foreign, "the foreign hook stays first");
  assert.equal(after.hooks.BeforeTool.length, 2);
  assert.equal(fs.statSync(file).mode & 0o777, 0o644, "an existing file keeps its mode");
  const first = fs.readFileSync(file);
  const mtime = fs.statSync(file).mtimeMs;
  install(home);
  assert.deepEqual(fs.readFileSync(file), first);
  assert.equal(fs.statSync(file).mtimeMs, mtime, "an unchanged file is not rewritten");
});

test("a settings file that does not parse is left exactly as it is", (t) => {
  const home = sandbox(t, "acb-agents-broken-");
  const file = settingsOf(home, agent("qwen"));
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, "{ // comments are not JSON\n}");
  install(home);
  assert.equal(fs.readFileSync(file, "utf8"), "{ // comments are not JSON\n}");
});

test("a settings file symlinked into dotfiles stays a symlink", (t) => {
  const home = sandbox(t, "acb-agents-link-");
  const droid = agent("droid");
  const real = path.join(home, "dotfiles", "factory.json");
  fs.mkdirSync(path.dirname(real), { recursive: true });
  fs.writeFileSync(real, "{}");
  fs.mkdirSync(path.join(home, droid.home), { recursive: true });
  fs.symlinkSync(real, settingsOf(home, droid));
  install(home);
  assert.ok(fs.lstatSync(settingsOf(home, droid)).isSymbolicLink());
  assert.equal(ours(readJSON(real), "droid").length, droid.events.length);
});

test("uninstall takes ours out and leaves the rest; --hooks-only leaves other agents alone", (t) => {
  const home = sandbox(t, "acb-agents-uninstall-");
  const gemini = agent("gemini");
  const file = settingsOf(home, gemini);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const foreign = "/usr/local/bin/my-hook";
  fs.writeFileSync(file, JSON.stringify({
    theme: "GitHub",
    hooks: { AfterAgent: [{ hooks: [{ type: "command", command: foreign }] }] },
  }));
  install(home);
  uninstall(home, ["--hooks-only"]);
  assert.equal(ours(readJSON(file), "gemini").length, gemini.events.length);
  uninstall(home);
  const after = readJSON(file);
  assert.equal(ours(after, "gemini").length, 0);
  assert.equal(after.theme, "GitHub");
  assert.deepEqual(Object.keys(after.hooks), ["AfterAgent"]);
  assert.equal(after.hooks.AfterAgent[0].hooks[0].command, foreign);
});

// --- the hooks themselves ----------------------------------------------------------------

const event = (home, name, provider, payload) => {
  const res = run(scripts.update, home, { argv: [name, "--provider", provider],
    stdin: JSON.stringify(payload) });
  assert.equal(res.status, 0, res.stderr);
  return res;
};
const stateOf = (home, provider, sid) => readJSON(path.join(barDir(home), provider, "state.d", sid + ".json"));

test("each agent's sessions land in its own directory and carry its provider", (t) => {
  const home = sandbox(t);
  for (const id of ["gemini", "qwen", "droid"]) {
    event(home, "prompt", id, { session_id: "s-" + id, cwd: home, transcript_path: "/tmp/t.json", model: "m" });
    const s = stateOf(home, id, "s-" + id);
    assert.equal(s.provider, id);
    assert.equal(s.state, "thinking");
    assert.equal(s.transcript, "", "another agent's transcript is never handed to Claude's parser");
    assert.equal(s.model, "m");
  }
  assert.ok(!fs.existsSync(path.join(barDir(home), "state.d", "s-gemini.json")), "nothing in Claude's directory");
});

test("Gemini always gets a JSON answer on stdout; the others get nothing", (t) => {
  const home = sandbox(t);
  assert.equal(event(home, "pre", "gemini", { session_id: "g", tool_name: "run_shell_command" }).stdout, "{}\n");
  assert.equal(event(home, "bogus", "gemini", { session_id: "g" }).stdout, "{}\n", "even for an event it ignores");
  assert.equal(event(home, "pre", "qwen", { session_id: "q", tool_name: "read_file" }).stdout, "");
});

test("the other agents' tools read as their activity", (t) => {
  const home = sandbox(t);
  for (const [id, tool, label] of [["gemini", "run_shell_command", "Running command"],
    ["gemini", "replace", "Editing"], ["qwen", "read_file", "Reading"],
    ["droid", "Execute", "Running command"], ["droid", "Create", "Writing"],
    ["droid", "mystery", "Using tool"]]) {
    event(home, "pre", id, { session_id: "x", tool_name: tool });
    assert.equal(stateOf(home, id, "x").label, label, `${id} ${tool}`);
  }
});

test("a permission request counts for Qwen, as it does for Claude", (t) => {
  const home = sandbox(t);
  event(home, "permreq", "qwen", { session_id: "q" });
  assert.equal(stateOf(home, "qwen", "q").state, "permission");
});

test("a provider that is not a plain word is Claude's, never a path", (t) => {
  const home = sandbox(t);
  event(home, "prompt", "../../evil", { session_id: "e" });
  assert.ok(fs.existsSync(path.join(barDir(home), "state.d", "e.json")));
  assert.ok(!fs.existsSync(path.join(home, "evil")));
});

test("SessionStart seeds the agent's file and SessionEnd removes it", (t) => {
  const home = sandbox(t);
  const life = (name) => {
    const res = run(scripts.lifecycle, home, { argv: [name, "--provider", "qwen"],
      stdin: JSON.stringify({ session_id: "q1", cwd: home, transcript_path: "/tmp/t" }) });
    assert.equal(res.status, 0, res.stderr);
  };
  life("start");
  const seed = stateOf(home, "qwen", "q1");
  assert.equal(seed.provider, "qwen");
  assert.equal(seed.transcript, "");
  life("end");
  assert.ok(!fs.existsSync(path.join(barDir(home), "qwen", "state.d", "q1.json")));
});
