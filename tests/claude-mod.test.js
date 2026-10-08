const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { sandbox, run, scripts, stateDir, readJSON } = require('./hook-harness');

const load = () => import('../hooks/claude-mod.mjs');

function runtime() {
  const hooks = new Map();
  const writes = [];
  const timers = [];
  let now = 1_800_000_000_000;
  let sessionId = 'mod-session';
  let usage = { startedAt: now, context: { tokens: 40_000, window: 200_000, percent: 20 }, cost: { usd: 0.25 } };
  const $ = {
    session: { id: async () => sessionId, cwd: async () => '/work/project', model: async () => 'claude-test', usage: async () => { if (usage instanceof Error) throw usage; return usage; } },
    env: { get: async name => name === 'HOME' ? '/tmp/mod-fixture' : undefined },
    fs: { exists: async () => false, read: async () => '' },
    clock: { now: async () => now, every: (_ms, callback) => { const timer = { callback, cancelled: false, cancel() { this.cancelled = true; } }; timers.push(timer); return timer; } },
    process: { run: async (_argv, init = {}) => { if (init.stdin) writes.push(JSON.parse(init.stdin)); return { exitCode: 0, stdout: '321\n', stderr: '' }; } },
    ui: { log: async () => {} },
  };
  const on = (name, matcher, handler) => {
    const fn = typeof matcher === 'function' ? matcher : handler;
    hooks.set(name, fn);
    return { catch() {} };
  };
  const fire = (name, event = {}, handler = async e => e, signal = new AbortController().signal) => {
    const next = Object.assign(handler, { signal, origin: { plugin: 'engine', tier: 'core' } });
    return hooks.has(name) ? hooks.get(name)($, event, next) : next(event);
  };
  return { $, on, fire, writes, timers, last: () => writes.at(-1)?.record, advance: () => { now += 5_000; }, setUsage: value => { usage = value; }, setId: value => { sessionId = value; } };
}

test('mod publishes real context and Unix seconds in the native reader format', async () => {
  const { register } = await load();
  const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' });
  await r.fire('turn.start', { turnId: 't1' });
  assert.equal(r.last().state, 'thinking');
  assert.equal(r.last().pid, 321);
  assert.equal(r.last().startedAt, 1_800_000_000);
  assert.equal(r.last().ts, 1_800_000_000);
  assert.equal(r.last().tokens, 40_000);
  assert.equal(r.last().window, 200_000);
  assert.equal(r.last().pct, 20);
  assert.equal(r.last().assumed, false);
  assert.equal(r.last().collector, 'claude-mod');
});

test('parallel tool completion retains working status and the original result', async () => {
  const { register } = await load();
  const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' });
  await r.fire('turn.start', { turnId: 't1' });
  let finishA, finishB;
  const a = r.fire('tool.call', { tool: 'Bash', tool_use_id: 'a' }, () => new Promise(resolve => { finishA = resolve; }));
  const b = r.fire('tool.call', { tool: 'Read', tool_use_id: 'b' }, () => new Promise(resolve => { finishB = resolve; }));
  await new Promise(resolve => setImmediate(resolve));
  finishA({ result: 'A' }); assert.deepEqual(await a, { result: 'A' });
  assert.equal(r.last().state, 'tool');
  finishB({ result: 'B' }); assert.deepEqual(await b, { result: 'B' });
  assert.equal(r.last().state, 'thinking');
});

test('permission checks alone do not prove a visible user request; real question clears on completion', async () => {
  const { register } = await load();
  const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' });
  await r.fire('turn.start', { turnId: 't1' });
  await r.fire('tool.check', { tool: 'Bash', tool_use_id: 'q' }, async () => ({ decision: 'ask' }));
  assert.notEqual(r.last().state, 'permission');
  let answer;
  const pending = r.fire('tool.call', { tool: 'AskUserQuestion', tool_use_id: 'q' }, () => new Promise(resolve => { answer = resolve; }));
  await new Promise(resolve => setImmediate(resolve));
  await r.fire('ui.render', { component: 'AskUserQuestion', requestId: 'q', props: {} });
  assert.equal(r.last().state, 'permission');
  answer({ result: { answers: {} } }); await pending;
  assert.equal(r.last().state, 'thinking');
  await r.fire('turn.complete', { turnId: 't1', reason: 'aborted' });
  assert.equal(r.last().state, 'done');
});

test('clear releases the previous session and lazily starts the next one', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' });
  await r.fire('turn.start', { turnId: 'old' });
  await r.fire('session.end', { reason: 'clear', sessionId: 'mod-session' });
  assert.equal(r.writes.at(-1).remove, true);
  r.setId('new-session');
  await r.fire('turn.start', { turnId: 'new' });
  assert.equal(r.writes.at(-1).id, 'new-session');
  assert.equal(r.last().state, 'thinking');
});

test('an in-flight heartbeat cannot resurrect a session after clear', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' });
  await r.fire('turn.start', { turnId: 'old' });
  let finishUsage, finishRemove;
  r.$.session.usage = () => new Promise(resolve => { finishUsage = resolve; });
  const run = r.$.process.run;
  r.$.process.run = async (argv, init) => {
    const result = await run(argv, init);
    if (init?.stdin && JSON.parse(init.stdin).remove) await new Promise(resolve => { finishRemove = resolve; });
    return result;
  };
  const heartbeat = r.timers[0].callback();
  const end = r.fire('session.end', { reason: 'clear', sessionId: 'mod-session' });
  await new Promise(resolve => setImmediate(resolve));
  finishUsage({ context: { tokens: 60_000, window: 200_000, percent: 30 } });
  await new Promise(resolve => setImmediate(resolve));
  finishRemove(); await Promise.all([heartbeat, end]);
  assert.equal(r.writes.at(-1).remove, true);
});

test('a stale session end cannot remove the replacement session', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' });
  await r.fire('session.end', { reason: 'clear', sessionId: 'mod-session' });
  r.setId('replacement'); await r.fire('turn.start', { turnId: 'new' });
  const count = r.writes.length;
  await r.fire('session.end', { reason: 'clear', sessionId: 'mod-session' });
  assert.equal(r.writes.length, count);
  assert.equal(r.writes.at(-1).id, 'replacement');
});

test('a stale lazy initialization cannot assign its turn to a replacement session', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  const run = r.$.process.run;
  let finishPid;
  r.$.process.run = async (argv, init) => {
    r.$.process.run = run;
    await new Promise(resolve => { finishPid = resolve; });
    return run(argv, init);
  };
  const oldTurn = r.fire('turn.start', { turnId: 'old' });
  await new Promise(resolve => setImmediate(resolve));
  await r.fire('session.end', { reason: 'clear', sessionId: 'mod-session' });
  r.setId('replacement'); await r.fire('turn.start', { turnId: 'new' });
  finishPid(); await oldTurn;
  await r.fire('turn.complete', { turnId: 'new', reason: 'answer' });
  assert.equal(r.writes.at(-1).id, 'replacement');
  assert.equal(r.last().state, 'done');
});

test('observation errors are logged without replacing the underlying turn or tool result', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  const logs = []; r.$.ui.log = async message => { logs.push(message); };
  const run = r.$.process.run;
  r.$.process.run = async () => { throw new Error('process API unavailable'); };
  assert.deepEqual(await r.fire('turn.start', { turnId: 't' }, async () => ({ turnId: 't' })), { turnId: 't' });
  assert.ok(logs.length > 0);
  r.$.process.run = run;
  await r.fire('turn.start', { turnId: 't' });
  const result = await r.fire('tool.call', { tool: 'Read', tool_use_id: 'r' }, async () => {
    r.$.clock.now = async () => { throw new Error('clock unavailable'); };
    return { result: 'real result' };
  });
  assert.deepEqual(result, { result: 'real result' });
  assert.ok(logs.length > 1);
});

test('a failed usage reading cannot retain a completed tool or erase context', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' });
  await r.fire('turn.start', { turnId: 't1' });
  r.setUsage(new Error('temporarily unavailable'));
  assert.deepEqual(await r.fire('tool.call', { tool: 'Read', tool_use_id: 't' }, async () => ({ result: 'ok' })), { result: 'ok' });
  assert.equal(r.last().state, 'thinking');
  assert.equal(r.last().tokens, 40_000);
});

test('unsupported Desktop process APIs leave legacy collection untouched', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'desktop' });
  await r.fire('turn.start', { turnId: 'desktop-turn' });
  assert.equal(r.writes.length, 0);
});

test('reloading an active mod releases its lease so legacy permission and stop events run immediately', async t => {
  const { register } = await load(); const r = runtime(); register(r.on);
  const home = sandbox(t), file = path.join(stateDir(home), 'mod-session.json');
  fs.mkdirSync(stateDir(home), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ pid: process.pid, started: true, state: 'tool', collector: 'claude-mod', collectorUpdatedAt: Math.floor(Date.now() / 1000) }));
  r.$.env.get = async name => name === 'HOME' ? home : undefined;
  r.$.clock.now = async () => Date.now();
  r.$.fs.exists = async filename => fs.existsSync(filename);
  r.$.fs.read = async filename => fs.readFileSync(filename, 'utf8');
  r.$.process.run = async (argv, init = {}) => {
    const result = spawnSync(argv[0], argv.slice(1), { input: init.stdin, encoding: 'utf8' });
    return { exitCode: result.status, stdout: result.stdout, stderr: result.stderr };
  };
  await r.fire('session.start', { surface: 'terminal' });
  assert.equal(readJSON(file).collector, 'legacy-mod-reload');
  assert.equal(readJSON(file).state, 'tool');
  assert.equal(r.timers.length, 0);
  for (const [event, expected] of [['notify', 'permission'], ['stop', 'done']]) {
    const result = run(scripts.update, home, { argv: [event], stdin: JSON.stringify({ session_id: 'mod-session', cwd: home, notification_type: 'permission_prompt' }) });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readJSON(file).state, expected);
  }
  await r.fire('turn.start', { turnId: 'next' });
  assert.equal(readJSON(file).state, 'thinking');
  assert.equal(readJSON(file).collector, 'claude-mod');
});

test('a new turn overlapping reload handoff keeps its own collector and heartbeat', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  r.$.fs.exists = async () => true;
  r.$.fs.read = async () => JSON.stringify({ pid: 321, started: true, state: 'tool', collector: 'claude-mod', collectorUpdatedAt: 1_800_000_000 });
  const run = r.$.process.run;
  let releaseHandoff;
  r.$.process.run = async (argv, init) => {
    if (init?.stdin && JSON.parse(init.stdin).record.collector === 'legacy-mod-reload') await new Promise(resolve => { releaseHandoff = resolve; });
    return run(argv, init);
  };
  const reload = r.fire('session.start', { surface: 'terminal' });
  await new Promise(resolve => setImmediate(resolve));
  const turn = r.fire('turn.start', { turnId: 'next' });
  await new Promise(resolve => setImmediate(resolve));
  releaseHandoff(); await Promise.all([reload, turn]);
  assert.equal(r.timers.length, 1);
  await r.fire('turn.complete', { turnId: 'next', reason: 'answer' });
  assert.equal(r.last().state, 'done');
});

test('a corrupt old JSON value cannot stop startup and current metadata is refreshed', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  r.$.fs.exists = async () => true; r.$.fs.read = async () => 'null';
  await r.fire('session.start', { surface: 'terminal' });
  r.$.session.model = async () => 'new-model'; r.$.session.cwd = async () => '/work/renamed';
  await r.fire('turn.start', { turnId: 't' });
  assert.equal(r.last().model, 'new-model'); assert.equal(r.last().project, 'renamed');
});

test('uncorrelated parallel permission prompts hand state back to legacy collection', async () => {
  const { register } = await load(); const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' }); await r.fire('turn.start', { turnId: 't' });
  let a, b;
  const pa = r.fire('tool.call', { tool: 'Bash', tool_use_id: 'a' }, () => new Promise(resolve => { a = resolve; }));
  const pb = r.fire('tool.call', { tool: 'Read', tool_use_id: 'b' }, () => new Promise(resolve => { b = resolve; }));
  await new Promise(resolve => setImmediate(resolve));
  await r.fire('classic.Notification', { notification_type: 'permission_prompt', agent_id: 'worker' });
  assert.notEqual(r.last().state, 'permission');
  await r.fire('classic.Notification', { notification_type: 'permission_prompt' });
  assert.equal(r.last().state, 'permission'); assert.equal(r.last().collector, 'legacy-permission');
  const count = r.writes.length; await r.timers[0].callback(); assert.equal(r.writes.length, count);
  a({ result: 'a' }); b({ result: 'b' }); await Promise.all([pa, pb]);
  await r.fire('turn.complete', { turnId: 't', reason: 'answer' });
  assert.equal(r.last().collector, 'claude-mod'); assert.equal(r.last().state, 'done');
});

test('the SDK process publisher atomically writes private JSON and cleans up on session end', async t => {
  const { register } = await load(); const r = runtime(); register(r.on);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'acb-mod-publish-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  r.$.env.get = async name => name === 'HOME' ? home : undefined;
  r.$.process.run = async (argv, init = {}) => {
    const result = spawnSync(argv[0], argv.slice(1), { input: init.stdin, encoding: 'utf8' });
    return { exitCode: result.status, stdout: result.stdout, stderr: result.stderr };
  };
  await r.fire('session.start', { surface: 'terminal' }); await r.fire('turn.start', { turnId: 't' });
  const directory = path.join(home, '.claude/control-bar/state.d');
  const file = path.join(directory, 'mod-session.json');
  const reading = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(reading.state, 'thinking'); assert.equal(reading.pct, 20);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
  assert.deepEqual(fs.readdirSync(directory), ['mod-session.json']);
  const seam = path.join(__dirname, '../build/seam/claude-mod-session.json');
  fs.mkdirSync(path.dirname(seam), { recursive: true });
  fs.copyFileSync(file, seam);
  await r.fire('session.end', { reason: 'other', sessionId: 'mod-session' });
  assert.equal(fs.existsSync(file), false);
});

test('temporary missing context preserves the previous measurement and heartbeat keeps turn timing', async () => {
  const { register } = await load();
  const r = runtime(); register(r.on);
  await r.fire('session.start', { surface: 'terminal' });
  await r.fire('turn.start', { turnId: 't1' });
  r.setUsage({ startedAt: 1_800_000_000_000, context: {} }); r.advance();
  await r.timers[0].callback();
  assert.equal(r.last().tokens, 40_000);
  assert.equal(r.last().startedAt, 1_800_000_000);
  assert.equal(r.last().collectorUpdatedAt, 1_800_000_005);
});
