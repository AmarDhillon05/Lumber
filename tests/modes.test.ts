// Drum-removal modes and crash recovery. Registered in tests/run.ts.
import { crashMessage, initialState, recoverFromCrash, sessionOptions } from '../src/separation/modes';
import { ok, section } from './harness';

export function run(): void {
  section('separation modes');

  const clean = recoverFromCrash(initialState());
  ok('no breadcrumb: no change', clean.crashed === null && clean.state.mode === 'coreml');

  const crumb = { mode: 'coreml' as const, stage: 'run' as const, chunk: 3, total: 31, startedAt: 1 };
  const once = recoverFromCrash({ mode: 'coreml', inProgress: crumb, lastCrash: null });
  ok('crash in coreml steps down to cpu', once.state.mode === 'cpu' && once.state.inProgress === null);
  ok('crash is remembered', once.state.lastCrash?.chunk === 3);

  const twice = recoverFromCrash({ ...once.state, inProgress: { ...crumb, mode: 'cpu' } });
  ok('crash in cpu steps down to cpu-slow', twice.state.mode === 'cpu-slow');
  const floor = recoverFromCrash({ ...twice.state, inProgress: { ...crumb, mode: 'cpu-slow' } });
  ok('cpu-slow is the floor', floor.state.mode === 'cpu-slow');

  const stale = recoverFromCrash({ mode: 'cpu', inProgress: { ...crumb, mode: 'coreml' }, lastCrash: null });
  ok('never steps back up from a stale breadcrumb', stale.state.mode === 'cpu-slow');

  const msg = crashMessage(crumb, 'cpu');
  ok('crash message names chunk and next mode', /chunk 3 of 31/.test(msg) && /CPU/.test(msg), msg);

  for (const m of ['coreml', 'cpu', 'cpu-slow'] as const) {
    const o = sessionOptions(m) as any;
    ok(`${m}: arena and memory pattern off`, o.enableCpuMemArena === false && o.enableMemPattern === false);
    const cpu = o.executionProviders.find((p: any) => p.name === 'cpu');
    ok(`${m}: cpu provider without arena`, cpu && cpu.useArena === false);
  }
  const coreml = (sessionOptions('coreml') as any).executionProviders[0];
  ok('coreml uses numeric flags (the RN binding ignores booleans)', coreml.name === 'coreml' && typeof coreml.coreMlFlags === 'number');
  ok('cpu-slow is single-threaded', (sessionOptions('cpu-slow') as any).intraOpNumThreads === 1);
}
