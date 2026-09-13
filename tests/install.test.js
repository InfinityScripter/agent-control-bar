const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

const installerPath = path.resolve(__dirname, "../hooks/install.js");
const uninstallerPath = path.resolve(__dirname, "../hooks/uninstall.js");
const staleNode = "/opt/homebrew/Cellar/node/26.5.0/bin/node";
const nodePathPrefix =
  'PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}" node ';

const runScript = (scriptPath, home) => {
  const script = [
    `require("node:child_process").execSync = () => {};`,
    `Object.defineProperty(process, "execPath", { value: process.env.MOCK_EXEC_PATH });`,
    `require(process.env.SCRIPT_PATH);`,
  ].join("\n");

  execFileSync(process.execPath, ["-e", script], {
    env: {
      ...process.env,
      HOME: home,
      SCRIPT_PATH: scriptPath,
      MOCK_EXEC_PATH: staleNode,
    },
    stdio: "pipe",
  });
};

const runInstaller = (home) => runScript(installerPath, home);
const runUninstaller = (home) => runScript(uninstallerPath, home);

const readSettings = (home) => {
  const settingsPath = path.join(home, ".claude", "settings.json");
  return JSON.parse(fs.readFileSync(settingsPath, "utf8"));
};

const hookCommands = (settings) => {
  return Object.values(settings.hooks)
    .flat()
    .flatMap((entry) => entry.hooks || [])
    .map((hook) => hook.command || "");
};

const statusBarCommands = (settings) =>
  hookCommands(settings).filter((command) => command.startsWith(nodePathPrefix));

const shellQuote = (value) => `'${value.replace(/'/g, `'\\''`)}'`;
const shellDoubleQuote = (value) =>
  value.replace(/["\\`$]/g, (character) => `\\${character}`);

test("installs portable, quoted hook commands and replaces stale hooks", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude $`\"' status bar test-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  const claudeDir = path.join(home, ".claude");
  const settingsPath = path.join(claudeDir, "settings.json");
  const oldScript = path.join(claudeDir, "control-bar", "update.js");
  const unrelatedCommand = "echo keep-me";
  const original = {
    customSetting: true,
    hooks: {
      PreToolUse: [
        {
          matcher: "*",
          hooks: [
            { type: "command", command: `${staleNode} ${oldScript} pre` },
            { type: "command", command: unrelatedCommand },
            { type: "prompt" },
          ],
        },
      ],
      Notification: [{ matcher: "empty-entry" }],
    },
  };
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(settingsPath, JSON.stringify(original, null, 2));
  const oldAgentPlist = path.join(
    home,
    "Library",
    "LaunchAgents",
    "com.local.claudestatusbar.watcher.plist",
  );
  fs.mkdirSync(path.dirname(oldAgentPlist), { recursive: true });
  fs.writeFileSync(oldAgentPlist, "obsolete");

  runInstaller(home);

  const settings = readSettings(home);
  const allCommands = hookCommands(settings);
  const commands = statusBarCommands(settings);
  const updatePath = path.join(claudeDir, "control-bar", "update.js");
  const lifecyclePath = path.join(claudeDir, "control-bar", "lifecycle.js");

  assert.equal(settings.customSetting, true);
  assert.equal(fs.existsSync(oldAgentPlist), false);
  assert.equal(commands.length, 8);
  assert.ok(commands.every((command) => command.startsWith(nodePathPrefix)));
  assert.ok(allCommands.every((command) => !command.includes(staleNode)));
  assert.ok(allCommands.every((command) => !command.includes(process.execPath)));
  assert.ok(commands.includes(`${nodePathPrefix}${shellQuote(updatePath)} pre`));
  assert.ok(commands.includes(`${nodePathPrefix}${shellQuote(lifecyclePath)} start`));

  const lifecycleEnd = commands.find((command) => command.endsWith(" end"));
  const fixtureBin = path.join(home, "minimal-bin");
  fs.mkdirSync(fixtureBin);
  fs.symlinkSync(process.execPath, path.join(fixtureBin, "node"));
  const statePath = path.join(
    claudeDir,
    "control-bar",
    "state.d",
    "quoted-path-test.json",
  );
  fs.mkdirSync(path.dirname(statePath), { recursive: true });
  fs.writeFileSync(statePath, "{}");
  const fixtureCommand = lifecycleEnd.replace(
    "/opt/homebrew/bin:/usr/local/bin",
    shellDoubleQuote(fixtureBin),
  );
  const noNodeEnvironment = {
    ...process.env,
    HOME: home,
    PATH: "",
  };
  assert.throws(() => {
    execFileSync("/bin/sh", ["-c", "command -v node"], {
      env: noNodeEnvironment,
      stdio: "pipe",
    });
  });
  execFileSync("/bin/sh", ["-c", fixtureCommand], {
    env: noNodeEnvironment,
    input: JSON.stringify({ session_id: "quoted-path-test" }),
    stdio: "pipe",
  });
  assert.equal(fs.existsSync(statePath), false);

  assert.equal(allCommands.filter((command) => command === unrelatedCommand).length, 1);
  assert.equal(
    settings.hooks.PreToolUse.flatMap((entry) => entry.hooks).filter(
      (hook) => hook.type === "prompt",
    ).length,
    1,
  );
  assert.deepEqual(
    JSON.parse(fs.readFileSync(`${settingsPath}.bak-control-bar`, "utf8")),
    original,
  );

  const firstInstall = settings;
  runInstaller(home);
  assert.deepEqual(readSettings(home), firstInstall);

  runUninstaller(home);
  const uninstalled = readSettings(home);
  assert.equal(statusBarCommands(uninstalled).length, 0);
  assert.equal(uninstalled.customSetting, true);
  assert.equal(
    uninstalled.hooks.PreToolUse.flatMap((entry) => entry.hooks).filter(
      (hook) => hook.command === unrelatedCommand,
    ).length,
    1,
  );
});

test("an unparseable settings.json is left alone — no rewrite, no backup of the garbage", (t) => {
  // The single most destructive error path there is: a rewrite from {} would take the user's
  // own settings with it, and a .bak of the garbage would overwrite the last good backup.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-corrupt-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  const claudeDir = path.join(home, ".claude");
  const settingsPath = path.join(claudeDir, "settings.json");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(settingsPath, "{ definitely not json");
  const before = fs.readFileSync(settingsPath);

  assert.throws(() => runInstaller(home), (error) => error.status === 1);
  assert.deepEqual(fs.readFileSync(settingsPath), before, "install rewrote a corrupt file");
  assert.equal(fs.existsSync(settingsPath + ".bak-control-bar"), false,
    "install backed up garbage");

  assert.throws(() => runUninstaller(home), (error) => error.status === 1);
  assert.deepEqual(fs.readFileSync(settingsPath), before, "uninstall rewrote a corrupt file");
});

test("--hooks-only strips the hooks and leaves the running app and LaunchAgent alone", (t) => {
  // This is the plugin's lease claim: bootstrap.py runs it DURING SessionStart while the app is
  // drawing. A regression that puts pkill back on this path kills the user's app on every
  // session start; one that skips the strip leaves both channels firing forever.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-hooks-only-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  runInstaller(home);
  assert.equal(statusBarCommands(readSettings(home)).length, 8);

  const execLog = path.join(home, "exec-log.txt");
  fs.writeFileSync(execLog, "");
  const script = [
    `require("node:child_process").execSync = (cmd) => {`,
    `  require("node:fs").appendFileSync(process.env.EXEC_LOG, cmd + "\\n");`,
    `};`,
    `process.argv.push("--hooks-only");`,
    `require(process.env.SCRIPT_PATH);`,
  ].join("\n");
  execFileSync(process.execPath, ["-e", script], {
    env: {
      ...process.env,
      HOME: home,
      SCRIPT_PATH: uninstallerPath,
      EXEC_LOG: execLog,
    },
    stdio: "pipe",
  });

  assert.equal(statusBarCommands(readSettings(home)).length, 0, "the duplicate hooks remain");
  const log = fs.readFileSync(execLog, "utf8");
  assert.ok(!log.includes("pkill"), "--hooks-only killed the running app");
  assert.ok(!log.includes("launchctl"), "--hooks-only tore down the LaunchAgent");
});

test("foreign hooks that merely resemble ours survive install and uninstall", (t) => {
  // Ownership used to be a substring check on the directory "~/.claude/control-bar" — which is
  // also a PREFIX of a user's own "~/.claude/control-bar-extra", and a substring of any command
  // that merely reads a file out of our directory. Both kinds of stranger were deleted.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-foreign-hooks-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  const claudeDir = path.join(home, ".claude");
  const foreignCommands = [
    `node ${shellQuote(path.join(claudeDir, "control-bar-extra", "custom.js"))} pre`,
    `node ${shellQuote(path.join(claudeDir, "my-control-bar", "hook.js"))}`,
    `cat ${shellQuote(path.join(claudeDir, "control-bar", "mcp.json"))}`,
    // The exact-script name is itself a prefix of a neighbour's file: without the right-hand
    // boundary this one read as ours and vanished.
    `cat ${shellQuote(path.join(claudeDir, "control-bar", "update.js.bak"))}`,
  ];
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(
    path.join(claudeDir, "settings.json"),
    JSON.stringify(
      {
        hooks: {
          Stop: [
            {
              hooks: foreignCommands.map((command) => ({ type: "command", command })),
            },
          ],
        },
      },
      null,
      2,
    ),
  );

  runInstaller(home);
  for (const command of foreignCommands) {
    assert.equal(
      hookCommands(readSettings(home)).filter((c) => c === command).length,
      1,
      `install removed a foreign hook: ${command}`,
    );
  }

  runUninstaller(home);
  for (const command of foreignCommands) {
    assert.equal(
      hookCommands(readSettings(home)).filter((c) => c === command).length,
      1,
      `uninstall removed a foreign hook: ${command}`,
    );
  }
});

test("reinstalling is idempotent", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude status bar test-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  runInstaller(home);
  const first = readSettings(home);
  runInstaller(home);
  const second = readSettings(home);

  assert.deepEqual(second, first);
  assert.equal(statusBarCommands(second).length, 8);
});

test("an empty inherited PATH never searches the working directory", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude status bar security test-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  runInstaller(home);
  const lifecycleEnd = hookCommands(readSettings(home)).find(
    (command) => command.includes("lifecycle.js") && command.endsWith(" end"),
  );
  const hostileCwd = path.join(home, "hostile-project");
  const canaryPath = path.join(home, "cwd-node-ran");
  fs.mkdirSync(hostileCwd);
  fs.writeFileSync(
    path.join(hostileCwd, "node"),
    `#!/bin/sh\n: > ${shellQuote(canaryPath)}\nexit 0\n`,
  );
  fs.chmodSync(path.join(hostileCwd, "node"), 0o755);

  const missingFallbacks = [
    path.join(home, "missing-homebrew-bin"),
    path.join(home, "missing-local-bin"),
  ].join(":");
  const isolatedCommand = lifecycleEnd.replace(
    "/opt/homebrew/bin:/usr/local/bin",
    shellDoubleQuote(missingFallbacks),
  );

  assert.throws(
    () => {
      execFileSync("/bin/sh", ["-c", isolatedCommand], {
        cwd: hostileCwd,
        env: {
          ...process.env,
          HOME: home,
          PATH: "",
        },
        input: JSON.stringify({ session_id: "security-test" }),
        stdio: "pipe",
      });
    },
    (error) => error.status === 127,
  );
  assert.equal(fs.existsSync(canaryPath), false);
});

test("a settings.json symlinked into dotfiles stays a symlink", (t) => {
  // Settings are commonly a symlink into ~/dotfiles. rename() over the link replaces the link
  // itself with a regular file: the dotfiles original silently stops receiving changes, and the
  // user loses the sync they set up on purpose without a single error message.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-symlink-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  const claudeDir = path.join(home, ".claude");
  const settingsPath = path.join(claudeDir, "settings.json");
  const dotfiles = path.join(home, "dotfiles");
  const target = path.join(dotfiles, "settings.json");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.mkdirSync(dotfiles, { recursive: true });
  fs.writeFileSync(target, JSON.stringify({ customSetting: true }, null, 2));
  fs.symlinkSync(target, settingsPath);

  runInstaller(home);

  assert.ok(fs.lstatSync(settingsPath).isSymbolicLink(), "the symlink was replaced by a file");
  const written = JSON.parse(fs.readFileSync(target, "utf8"));
  assert.equal(written.customSetting, true);
  assert.ok(written.hooks, "hooks did not reach the dotfiles original");

  runUninstaller(home);
  assert.ok(fs.lstatSync(settingsPath).isSymbolicLink(), "uninstall replaced the symlink");
});

// --- Codex CLI hooks -------------------------------------------------------------------
// ~/.codex/hooks.json has the same shape as Claude's settings.json hooks block, and on a real
// machine it already holds other tools' hooks — this one had five foreign entries. Merging is
// therefore the whole job; clobbering would silently disable somebody else's product.

const codexHooksPath = (home) => path.join(home, ".codex", "hooks.json");
const codexCommands = (home) =>
  Object.values(JSON.parse(fs.readFileSync(codexHooksPath(home), "utf8")).hooks)
    .flat().flatMap((entry) => entry.hooks || []).map((hook) => hook.command || "");

test("codex hooks are merged in beside foreign ones, and a second run changes nothing", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-codex-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  fs.mkdirSync(path.join(home, ".codex"), { recursive: true });
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  const foreign = "/bin/sh '/Users/somebody/.orca/agent-hooks/codex-hook.sh'";
  fs.writeFileSync(codexHooksPath(home), JSON.stringify({
    hooks: {
      PreToolUse: [{ hooks: [{ type: "command", command: foreign, timeout: 10 }] }],
      SessionStart: [{ hooks: [{ type: "command", command: foreign }] }],
    },
    // A sibling key the installer has no business touching.
    experimental: { something: true },
  }, null, 2));

  runInstaller(home);

  const commands = codexCommands(home);
  assert.equal(commands.filter((c) => c === foreign).length, 2, "both foreign hooks survive");
  const ours = commands.filter((c) => c.includes("--provider codex"));
  assert.equal(ours.length, 8, "eight codex events are covered");
  const file = JSON.parse(fs.readFileSync(codexHooksPath(home), "utf8"));
  assert.equal(file.experimental.something, true, "sibling keys are left alone");
  // Codex has no Notification event; the permission signal is PermissionRequest, and Interrupt
  // is a bonus Claude has no equivalent of — Esc arrives as an event instead of being guessed
  // from the transcript.
  assert.deepEqual(Object.keys(file.hooks).sort(), [
    "Interrupt", "PermissionRequest", "PostToolUse", "PreToolUse", "SessionEnd",
    "SessionStart", "Stop", "UserPromptSubmit",
  ]);

  // Codex re-asks for trust whenever a hook command changes, so a rewrite that does not change
  // the commands must not happen at all — every app launch runs this installer.
  const first = fs.readFileSync(codexHooksPath(home));
  runInstaller(home);
  assert.deepEqual(fs.readFileSync(codexHooksPath(home)), first);
});

test("codex's one-second events get a budget that fits inside it", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-codex-budget-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  fs.mkdirSync(path.join(home, ".codex"), { recursive: true });
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });

  runInstaller(home);

  const hooks = JSON.parse(fs.readFileSync(codexHooksPath(home), "utf8")).hooks;
  const timeoutOf = (evt) => hooks[evt][0].hooks[0].timeout;
  // Codex caps SessionEnd and Interrupt at one second (three at most) and kills the hook after
  // it. Asking for more would be a lie; these two only delete a file or write one.
  assert.equal(timeoutOf("SessionEnd"), 3);
  assert.equal(timeoutOf("Interrupt"), 3);
  assert.equal(timeoutOf("PreToolUse"), 10);
});

test("a machine without codex gets no codex hooks at all", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-nocodex-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });

  runInstaller(home);

  assert.ok(!fs.existsSync(path.join(home, ".codex")), "no directory is created for it either");
});

test("the plugin channel owns Claude's hooks but codex's are still installed", (t) => {
  // The lease exists because Claude Code merges plugin hooks with settings.json hooks and runs
  // both. Codex reads neither — ~/.codex/hooks.json is its only channel, so standing down there
  // means Codex sessions are invisible for everyone who installed the plugin.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-codex-plugin-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const pluginRoot = path.join(home, "plugin");
  fs.mkdirSync(pluginRoot, { recursive: true });
  fs.mkdirSync(path.join(home, ".codex"), { recursive: true });
  fs.mkdirSync(path.join(home, ".claude", "control-bar"), { recursive: true });
  fs.writeFileSync(path.join(home, ".claude", "settings.json"), JSON.stringify({ hooks: {} }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "owner.json"),
    JSON.stringify({ channel: "plugin", pluginRoot }));

  runInstaller(home);

  assert.deepEqual(readSettings(home).hooks, {}, "Claude's hooks stay with the plugin");
  assert.equal(codexCommands(home).filter((c) => c.includes("--provider codex")).length, 8);
  // The commands point at the copies in ~/.claude/control-bar, so those have to exist whichever
  // channel won the lease.
  for (const name of ["update.js", "lifecycle.js"]) {
    assert.ok(fs.existsSync(path.join(home, ".claude", "control-bar", name)), name + " was deployed");
  }
});

test("a codex hooks file that does not parse is left alone", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-codex-broken-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  fs.mkdirSync(path.join(home, ".codex"), { recursive: true });
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  fs.writeFileSync(codexHooksPath(home), "{ not json");

  runInstaller(home);

  // Rewriting it from {} would take the user's own Codex hooks with it, and Claude's hooks must
  // still get installed either way.
  assert.equal(fs.readFileSync(codexHooksPath(home), "utf8"), "{ not json");
  assert.equal(statusBarCommands(readSettings(home)).length, 8, "Claude's install still happened");
});

test("uninstalling takes the codex hooks with it and leaves foreign ones", (t) => {
  // Left behind, they point at scripts that no longer exist: Codex would run a failing hook on
  // every single event, for the rest of the install's life.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-codex-off-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  fs.mkdirSync(path.join(home, ".codex"), { recursive: true });
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  const foreign = "/bin/sh '/Users/somebody/hook.sh'";
  fs.writeFileSync(codexHooksPath(home), JSON.stringify({
    hooks: { Stop: [{ hooks: [{ type: "command", command: foreign }] }] } }, null, 2));

  runInstaller(home);
  runUninstaller(home);

  const file = JSON.parse(fs.readFileSync(codexHooksPath(home), "utf8"));
  assert.deepEqual(Object.keys(file.hooks), ["Stop"], "only the foreign event is left");
  assert.deepEqual(codexCommands(home), [foreign]);
});

test("handing Claude's hooks to the plugin does not disturb the codex ones", (t) => {
  // bootstrap.py runs `uninstall.js --hooks-only` when the plugin claims the lease. That is a
  // Claude-channel conflict and nothing to do with Codex — and every removal-plus-reinstall of
  // a Codex hook makes Codex ask the user to trust it again.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "control-bar-codex-lease-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  fs.mkdirSync(path.join(home, ".codex"), { recursive: true });
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });

  runInstaller(home);
  const before = fs.readFileSync(codexHooksPath(home));
  execFileSync(process.execPath, ["-e",
    `require("node:child_process").execSync = () => {};\nrequire(process.env.SCRIPT_PATH);`,
    "uninstall.js", "--hooks-only"],
    { env: { ...process.env, HOME: home, SCRIPT_PATH: uninstallerPath }, stdio: "pipe" });

  assert.deepEqual(fs.readFileSync(codexHooksPath(home)), before);
  assert.deepEqual(readSettings(home).hooks, {}, "Claude's own hooks did go");
});
