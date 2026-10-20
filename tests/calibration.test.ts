import { ok, section } from './harness';
import { estimateLatency, isReliable } from '../src/audio/calibration';
import { makeClick, BEAT_CLICK } from '../src/audio/click';

const SR = 48000;

// Deterministic PRNG so failures reproduce.
function rng(seed: number) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}
function gaussian(r: () => number) {
  const u = Math.max(1e-12, r());
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * r());
}

function synth(opts: { delayMs: number; gain: number; noise: number; polarity?: number; seed?: number; lowpass?: boolean }) {
  const clickTimes = Array.from({ length: 8 }, (_, i) => 0.3 + i * 0.5);
  const x = new Float32Array(Math.round(SR * 5));
  const r = rng(opts.seed ?? 1);
  for (let i = 0; i < x.length; i++) {
    x[i] = opts.noise * gaussian(r) + 0.05 * Math.sin((2 * Math.PI * 60 * i) / SR); // noise + hum
  }
  const click = makeClick(SR, BEAT_CLICK);
  const delay = (opts.delayMs / 1000) * SR;
  for (const t of clickTimes) {
    const start = t * SR + delay;
    const i0 = Math.floor(start);
    const frac = start - i0; // fractional-sample delay via linear interpolation
    for (let k = 0; k < click.length; k++) {
      const v = (1 - frac) * click[k] + frac * (click[k - 1] ?? 0);
      x[i0 + k] += (opts.polarity ?? 1) * opts.gain * v;
    }
    // A little room echo 7 ms later.
    for (let k = 0; k < click.length; k++) x[i0 + k + 336] += 0.3 * opts.gain * click[k];
  }
  if (opts.lowpass) {
    let y = 0;
    for (let i = 0; i < x.length; i++) {
      y += 0.5 * (x[i] - y);
      x[i] = y;
    }
  }
  return { x, clickTimes };
}

export function run(): void {
  section('finds a 137.3 ms delay in noise');
  {
  const { x, clickTimes } = synth({ delayMs: 137.3, gain: 0.25, noise: 0.02 });
  const e = estimateLatency(x, SR, clickTimes);
  ok('latency', Math.abs(e.latencyMs - 137.3) < 1, `got ${e.latencyMs}`);
  ok('reliable', isReliable(e), JSON.stringify(e));
  }
  section('handles inverted polarity and a speaker-like lowpass');
  {
  const { x, clickTimes } = synth({ delayMs: 42.1, gain: 0.3, noise: 0.01, polarity: -1, lowpass: true, seed: 7 });
  const e = estimateLatency(x, SR, clickTimes);
  ok('latency', Math.abs(e.latencyMs - 42.1) < 1, `got ${e.latencyMs}`);
  }
  section('Bluetooth-scale delay (230 ms) at low SNR');
  {
  const { x, clickTimes } = synth({ delayMs: 230, gain: 0.08, noise: 0.03, seed: 3 });
  const e = estimateLatency(x, SR, clickTimes);
  ok('latency', Math.abs(e.latencyMs - 230) < 1.5, `got ${e.latencyMs}`);
  }
  section('pure noise is flagged unreliable');
  {
  const { x, clickTimes } = synth({ delayMs: 100, gain: 0, noise: 0.05, seed: 11 });
  const e = estimateLatency(x, SR, clickTimes);
  ok('noise unreliable', !isReliable(e), JSON.stringify(e));
  }
}
