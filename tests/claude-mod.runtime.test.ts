import { expect, test } from 'claude-code/testing';

test('native mod runtime publishes activity/context and clears an aborted turn', async ($, on) => {
  const records: { state: string; pct: number; pid: number }[] = [];
  on('clock.now', () => ({ value: 1_800_000_000_000 }));
  on('clock.every', () => ({ deny: 'No recurring timers in the test fixture' }));
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/tmp/acb-runtime-fixture' : undefined }));
  on('session.id', () => ({ value: 'native-sdk-session' }));
  on('session.cwd', () => ({ value: '/work/project' }));
  on('session.model', () => ({ value: 'claude-test' }));
  on('session.usage', () => ({ value: { startedAt: 1_800_000_000_000, context: { tokens: 50_000, window: 200_000, percent: 25 }, rateLimits: [] } }));
  on('fs.exists', () => ({ value: false }));
  on('process.run', (_$, e) => {
    if (e.init?.stdin) records.push(JSON.parse(e.init.stdin).record);
    return { value: { exitCode: 0, stdout: '321\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } };
  });
  on('session.start', (_$, e) => ({ cwd: e.cwd }));
  on('turn.start', (_$, e) => ({ turnId: e.turnId }));
  let questionStarted!: () => void, answer!: (value: { result: string }) => void;
  const started = new Promise<void>(resolve => { questionStarted = resolve; });
  on('tool.call', (_$, e) => {
    if (e.tool !== 'AskUserQuestion') return { result: 'tool-result' };
    questionStarted();
    return new Promise<{ result: string }>(resolve => { answer = resolve; });
  });
  on('ui.render', () => ({ type: 'Box' }));
  on('turn.complete', () => ({ text: '' }));

  await $.session.start({ surface: 'terminal', cwd: '/work/project', isInteractive: true });
  await $.turn.start({ text: 'fixture', turnId: 'native-turn' });
  const result = await $.tool.call({ tool: 'Read', file_path: '/work/project/a', tool_use_id: 'read' });
  expect(result.result).toBe('tool-result');
  expect(records.at(-1)?.state).toBe('thinking');
  expect(records.at(-1)?.pct).toBe(25);
  expect(records.at(-1)?.pid).toBe(321);
  const question = $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'question', questions: [] });
  await started;
  await $.ui.render({ surface: 'terminal', component: 'AskUserQuestion', requestId: 'question', props: { tool: 'AskUserQuestion', questions: [] } });
  expect(records.at(-1)?.state).toBe('permission');
  answer({ result: 'answered' }); await question;
  expect(records.at(-1)?.state).toBe('thinking');
  await $.turn.complete({ turnId: 'native-turn', reason: 'aborted', isAborted: true, answer: '', durationMs: 1000 });
  expect(records.at(-1)?.state).toBe('done');
});
