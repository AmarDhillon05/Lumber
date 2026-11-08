// How drum removal runs, and stepping down to a safer mode after a crash.
//
// A hard crash (iOS killing the app for memory) can't be caught in JS, so the
// app leaves a breadcrumb while it works. If the next launch finds a breadcrumb
// that never got cleared, that run died, and the next run uses a safer mode:
//   coreml   — Core ML (Neural Engine/GPU) with CPU fallback. Fastest.
//   cpu      — ONNX Runtime CPU only, 2 threads.
//   cpu-slow — CPU, 1 thread, short pause between chunks. Slowest, lightest.
// Every mode turns off ONNX Runtime's memory arena: with it on, a CPU run kept
// ~5 GB after two 7.8 s chunks; off, memory goes back down after each chunk.

export type Mode = 'coreml' | 'cpu' | 'cpu-slow';
export const MODES: Mode[] = ['coreml', 'cpu', 'cpu-slow'];

export interface Breadcrumb {
  mode: Mode;
  stage: 'load' | 'decode' | 'run';
  chunk?: number;
  total?: number;
  startedAt: number;
}

export interface ModeState {
  mode: Mode;
  inProgress: Breadcrumb | null;
  lastCrash: Breadcrumb | null;
}

export const initialState = (): ModeState => ({ mode: 'coreml', inProgress: null, lastCrash: null });

// Core ML flag bits (onnxruntime coreml_provider_factory.h).
const COREML_FLAG_ONLY_ALLOW_STATIC_INPUT_SHAPES = 0x008;
const COREML_FLAG_CREATE_MLPROGRAM = 0x010;

// Called once before a run: if the previous run never finished, it crashed,
// so record it and step down one mode.
export function recoverFromCrash(state: ModeState): { state: ModeState; crashed: Breadcrumb | null } {
  const crashed = state.inProgress;
  if (!crashed) return { state, crashed: null };
  const i = MODES.indexOf(crashed.mode);
  const mode = MODES[Math.min(MODES.length - 1, Math.max(i, MODES.indexOf(state.mode)) + 1)];
  return { state: { mode, inProgress: null, lastCrash: crashed }, crashed };
}

export function sessionOptions(mode: Mode): Record<string, unknown> {
  const common = { enableCpuMemArena: false, enableMemPattern: false, executionMode: 'sequential' };
  if (mode === 'coreml') {
    return {
      ...common,
      executionProviders: [
        { name: 'coreml', coreMlFlags: COREML_FLAG_CREATE_MLPROGRAM | COREML_FLAG_ONLY_ALLOW_STATIC_INPUT_SHAPES },
        { name: 'cpu', useArena: false },
      ],
    };
  }
  return {
    ...common,
    graphOptimizationLevel: 'basic',
    intraOpNumThreads: mode === 'cpu' ? 2 : 1,
    interOpNumThreads: 1,
    executionProviders: [{ name: 'cpu', useArena: false }],
  };
}

export const pauseBetweenChunksMs = (mode: Mode) => (mode === 'cpu-slow' ? 250 : 0);

export function describeMode(mode: Mode): string {
  return mode === 'coreml' ? 'Core ML' : mode === 'cpu' ? 'CPU' : 'safe mode (slow)';
}

export function crashMessage(crash: Breadcrumb, next: Mode): string {
  const where =
    crash.stage === 'run' && crash.total
      ? `at chunk ${crash.chunk ?? 0} of ${crash.total}`
      : crash.stage === 'load'
        ? 'while loading the model'
        : 'while decoding the song';
  return `Last drum removal crashed ${where} using ${describeMode(crash.mode)}. Retrying with ${describeMode(next)}.`;
}
