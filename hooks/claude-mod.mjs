// The native app polls JSON files; the mods fs.write API cannot replace them atomically.
const WRITE_STATE = `import json,os,sys,tempfile
p=json.load(sys.stdin)
root=p['directory']
os.makedirs(root,mode=0o700,exist_ok=True)
os.chmod(root,0o700)
target=os.path.join(root,p['id']+'.json')
if p.get('remove'):
 try: os.unlink(target)
 except FileNotFoundError: pass
else:
 fd,tmp=tempfile.mkstemp(prefix='.'+p['id']+'.',suffix='.tmp',dir=root)
 try:
  os.fchmod(fd,0o600)
  with os.fdopen(fd,'w') as f: json.dump(p['record'],f)
  os.replace(tmp,target)
 finally:
  if os.path.exists(tmp): os.unlink(tmp)
`;

async function note($, text) {
  try { await $.ui.log(text); } catch {}
}

async function observe($, action) {
  try { await action(); } catch { await note($, 'Control Bar could not observe session activity.'); }
}

async function save($, state, remove = false, record = state.record) {
  const generation = state.generation, directory = state.directory;
  if (!record || (!remove && state.record !== record)) return;
  if (!remove) {
    const now = Math.floor(await $.clock.now() / 1000);
    if (state.record !== record || state.generation !== generation) return;
    record.collectorUpdatedAt = now;
  }
  const input = JSON.stringify({ directory, id: record.sessionId, record: { ...record }, remove });
  const write = state.queue.catch(() => {}).then(async () => {
    const result = await $.process.run(['/usr/bin/python3', '-c', WRITE_STATE], { stdin: input, timeoutMs: 1000 });
    if (result.exitCode !== 0) throw new Error('Control Bar state write failed');
  });
  state.queue = write;
  try { await write; } catch { await note($, 'Control Bar could not save session state; legacy hooks can resume on their next event after the mod lease expires.'); }
}

async function measure($, state) {
  const record = state.record, generation = state.generation;
  if (!record) return;
  try {
    const usage = await $.session.usage();
    const cwd = await $.session.cwd(), model = await $.session.model();
    if (state.record !== record || state.generation !== generation) return;
    const context = usage.context;
    if (Number.isFinite(context?.tokens) && context.tokens >= 0 && Number.isFinite(context.window) && context.window > 0) {
      record.tokens = Math.round(context.tokens);
      record.window = Math.round(context.window);
      record.pct = Math.min(100, Math.max(0, Math.round(Number.isFinite(context.percent) ? context.percent : context.tokens / context.window * 100)));
      record.assumed = false;
    }
    if (Number.isFinite(usage.cost?.usd)) record.cost = usage.cost.usd;
    record.cwd = cwd;
    record.project = cwd.replace(/\/+$/, '').split('/').pop() ?? '';
    record.model = model;
  } catch { await note($, 'Control Bar context is temporarily unavailable; keeping the last measurement.'); }
}

function working(state) {
  state.record.state = state.waiting.size ? 'permission' : state.active.size ? 'tool' : state.turnId ? 'thinking' : 'idle';
  state.record.label = state.waiting.size ? 'Awaiting permission' : state.active.size ? 'Using tool' : state.turnId ? 'Thinking…' : '';
  state.record.tool = state.active.values().next().value ?? '';
}

async function initialize($, state, startOfTurn = false) {
  const generation = state.generation;
  const home = await $.env.get('HOME');
  if (!home) throw new Error('Control Bar requires a home directory');
  const id = String(await $.session.id()).replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 64);
  if (!id) throw new Error('Control Bar requires a session id');
  const directory = await $.env.get('CONTROL_BAR_MOD_STATE_DIR') ?? `${home}/.claude/control-bar/state.d`;
  const path = `${directory}/${id}.json`;
  let previous = {};
  if (await $.fs.exists(path)) {
    try { const value = JSON.parse(await $.fs.read(path)); if (value && typeof value === 'object' && !Array.isArray(value)) previous = value; } catch {}
  }
  const process = await $.process.run(['/usr/bin/python3', '-c', 'import os; print(os.getppid())']);
  const pid = Number(process.stdout.trim());
  if (process.exitCode !== 0 || !Number.isInteger(pid) || pid <= 0) throw new Error('Control Bar could not identify the Claude process');
  if (state.generation !== generation) return;
  if (!startOfTurn && previous.pid === pid && previous.started && ['thinking', 'tool', 'permission'].includes(previous.state)) {
    if (previous.collector === 'claude-mod') {
      state.directory = directory;
      const handoff = state.record = { ...previous, sessionId: id, collector: 'legacy-mod-reload' };
      await save($, state, false, handoff);
      if (state.record === handoff) state.record = undefined;
    }
    await note($, 'Control Bar will use legacy hooks for the current turn and start mod collection on the next turn.');
    return;
  }
  const now = Math.floor(await $.clock.now() / 1000);
  const termProgram = await $.env.get('TERM_PROGRAM') ?? '', termBundle = await $.env.get('__CFBundleIdentifier') ?? '';
  if (state.generation !== generation) return;
  state.id = id; state.directory = directory;
  const record = state.record = {
    provider: 'claude', collector: 'claude-mod', sessionId: id,
    transcript: typeof previous.transcript === 'string' ? previous.transcript : '',
    entrypoint: 'cli', term_program: termProgram, term_bundle: termBundle,
    tty: typeof previous.tty === 'string' ? previous.tty : '',
    pid, state: 'idle', label: '', tool: '', started: false, startedAt: 0, ts: now,
  };
  for (const key of ['pct', 'tokens', 'window', 'assumed', 'cost', 'duration', 'linesAdded', 'linesRemoved', 'dirty']) if (previous[key] !== undefined) state.record[key] = previous[key];
  await measure($, state); await save($, state, false, record);
  if (state.record !== record || state.generation !== generation) return;
  state.timer?.cancel();
  state.timer = $.clock.every(5000, () => observe($, async () => {
    if (state.generation !== generation || state.record !== record || record.collector !== 'claude-mod') return;
    await measure($, state);
    const now = Math.floor(await $.clock.now() / 1000);
    if (state.generation !== generation || state.record !== record || record.collector !== 'claude-mod') return;
    if (record.state !== 'permission') record.ts = now;
    await save($, state, false, record);
  }));
}

export function register(on) {
  const state = { queue: Promise.resolve(), active: new Map(), waiting: new Set(), generation: 0, supported: true };
  on('session.start', async ($, e, next) => {
    const result = await next(e);
    // SDK 2.1.287 exposes process.run on CLI hosts only. Desktop retains its command hooks.
    state.supported = e.surface !== 'desktop';
    if (state.supported) await observe($, () => initialize($, state));
    return result;
  });
  on('turn.start', async ($, e, next) => {
    if (state.supported) await observe($, async () => {
      const generation = state.generation;
      if (!state.record || state.record.collector === 'legacy-mod-reload') await initialize($, state, true);
      const record = state.record;
      if (!record || state.generation !== generation) return;
      const now = Math.floor(await $.clock.now() / 1000);
      if (state.record !== record) return;
      state.turnId = e.turnId; state.active.clear(); state.waiting.clear();
      state.record.collector = 'claude-mod'; state.record.started = true;
      state.record.ts = state.record.startedAt = now;
      working(state); await measure($, state); await save($, state, false, record);
    });
    return next(e);
  });
  on('tool.call', async ($, e, next) => {
    if (!state.record || e.agentId) return next(e);
    const key = e.tool_use_id ?? e, generation = state.generation, currentTurn = state.turnId;
    state.active.set(key, e.tool); working(state);
    await observe($, async () => {
      const now = Math.floor(await $.clock.now() / 1000);
      if (state.generation === generation && state.record?.collector === 'claude-mod') { state.record.ts = now; await save($, state); }
    });
    try { return await next(e); } finally {
      if (state.generation === generation && state.turnId === currentTurn) {
        state.active.delete(key); state.waiting.delete(key);
        if (state.turnId && state.record?.collector === 'claude-mod') await observe($, async () => {
          const record = state.record;
          working(state);
          const now = Math.floor(await $.clock.now() / 1000);
          if (state.generation !== generation || state.turnId !== currentTurn || !state.record) return;
          record.ts = now; await measure($, state); await save($, state, false, record);
        });
      }
    }
  });
  on('ui.render', { component: 'AskUserQuestion' }, async ($, e, next) => {
    if (state.record && e.component === 'AskUserQuestion' && state.active.has(e.requestId)) await observe($, async () => {
      const record = state.record, now = Math.floor(await $.clock.now() / 1000);
      if (state.record !== record || !state.active.has(e.requestId)) return;
      state.waiting.add(e.requestId); working(state);
      record.ts = now; await save($, state, false, record);
    });
    return next(e);
  });
  on('classic.Notification', async ($, e, next) => {
    if (state.record && !e.agent_id && e.notification_type === 'permission_prompt') await observe($, async () => {
      const record = state.record, now = Math.floor(await $.clock.now() / 1000);
      if (state.record !== record) return;
      if (state.active.size === 1) {
        state.waiting.add(state.active.keys().next().value); working(state);
      } else {
        // The notification has no call id: allow legacy permission handling instead of guessing.
        state.record.collector = 'legacy-permission';
        state.record.state = 'permission'; state.record.label = 'Awaiting permission';
      }
      record.ts = now; await save($, state, false, record);
    });
    return next(e);
  });
  on('turn.complete', async ($, e, next) => {
    const result = await next(e);
    if (state.record && !e.agentId && (!e.turnId || e.turnId === state.turnId)) await observe($, async () => {
      const record = state.record, now = Math.floor(await $.clock.now() / 1000);
      if (state.record !== record || (e.turnId && e.turnId !== state.turnId)) return;
      state.turnId = undefined; state.active.clear(); state.waiting.clear();
      state.record.collector = 'claude-mod'; state.record.state = 'done'; state.record.label = 'Done'; state.record.tool = ''; state.record.startedAt = 0;
      record.ts = now; await measure($, state); await save($, state, false, record);
    });
    return result;
  });
  on('session.end', async ($, e, next) => {
    if (e.sessionId && state.record && e.sessionId !== state.record.sessionId) return next(e);
    state.generation += 1; state.timer?.cancel();
    const removal = save($, state, true);
    state.record = undefined; state.turnId = undefined; state.active.clear(); state.waiting.clear();
    await observe($, () => removal);
    return next(e);
  });
}
