// Round-trip latency calibration.
//
// Play N clicks out of the speaker at known ctx times while the mic records
// (same engine path as a real take), then find where those clicks landed in
// the recording. The lag between where they were scheduled and where they
// were heard is the round-trip latency for the current output route.
//
// The math here is pure and Node-testable; runCalibration() takes the engine
// as a parameter (type-only import) so this file never pulls in native code.

import type { Engine } from './engine';
import { makeClick, BEAT_CLICK } from './click';
import { median } from './offsets';
import { fft, nextPow2 } from '../dsp/fft';

export interface LatencyEstimate {
  latencyMs: number;
  // Peak-to-median ratio of the coarse onset correlation. ~1 means no clicks
  // were found; real clicks give well over 8 (pure noise sits around 2-3).
  confidence: number;
  // Spread (ms) of per-click lags around the estimate; large = unreliable.
  spreadMs: number;
}

export interface EstimateOptions {
  maxLagSec?: number; // search window, default 0.6 s (covers Bluetooth)
  template?: Float32Array; // the click waveform, for sub-ms refinement
}

/**
 * Find the delay of a click train inside `recorded`.
 *
 * 1. Matched filter: cross-correlate the recording with the click waveform
 *    (FFT), which lifts the clicks far above broadband noise and hum.
 * 2. Coarse: sum the filter's energy (1 ms bins) at every click position for
 *    each candidate lag — a cross-correlation with the scheduled click train.
 * 3. Fine: the same sum at full sample rate inside ±2 ms of the coarse peak.
 *
 * @param recorded mono mic samples
 * @param clickFileTimes where each click would sit in the recording with zero
 *   latency (seconds from the recording's first sample)
 */
export function estimateLatency(
  recorded: Float32Array,
  sampleRate: number,
  clickFileTimes: number[],
  opts: EstimateOptions = {},
): LatencyEstimate {
  const maxLagSec = opts.maxLagSec ?? 0.6;
  const template = opts.template ?? makeClick(sampleRate, BEAT_CLICK);
  const m = matchedFilter(recorded, template);
  const m2 = new Float32Array(m.length);
  for (let i = 0; i < m.length; i++) m2[i] = m[i] * m[i];

  const bin = Math.max(1, Math.round(sampleRate / 1000)); // 1 ms bins
  const nb = Math.floor(m2.length / bin);
  const binE = new Float64Array(nb);
  for (let b = 0; b < nb; b++) {
    let e = 0;
    for (let k = 0; k < bin; k++) e += m2[b * bin + k];
    binE[b] = e;
  }
  const maxLag = Math.round((maxLagSec * sampleRate) / bin);
  const clickBins = clickFileTimes.map((t) => Math.floor((t * sampleRate) / bin));
  const scores = new Float64Array(maxLag + 1);
  for (let lag = 0; lag <= maxLag; lag++) {
    let s = 0;
    for (const c of clickBins) {
      const b = c + lag;
      if (b >= 0 && b < nb) s += binE[b];
    }
    scores[lag] = s;
  }
  let best = 0;
  for (let lag = 1; lag <= maxLag; lag++) if (scores[lag] > scores[best]) best = lag;
  const med = median(Array.from(scores));
  const confidence = scores[best] / (med + 1e-12);

  const starts = clickFileTimes.map((t) => Math.round(t * sampleRate));
  const center = best * bin;
  const fineLag = argmaxLag(m2, starts, center - 2 * bin, center + 3 * bin);

  // Per-click lags (each searched within ±5 ms) to judge consistency.
  const perClick = starts.map((s) => argmaxLag(m2, [s], fineLag - 5 * bin, fineLag + 5 * bin));
  const spread = Math.sqrt(
    perClick.reduce((a, l) => a + (l - fineLag) ** 2, 0) / Math.max(1, perClick.length),
  );

  return {
    latencyMs: (fineLag / sampleRate) * 1000,
    confidence,
    spreadMs: (spread / sampleRate) * 1000,
  };
}

/** out[n] = sum_k x[n+k] * t[k], computed with an FFT. Same length as x. */
export function matchedFilter(x: Float32Array, t: Float32Array): Float32Array {
  const n = nextPow2(x.length + t.length);
  const xr = new Float32Array(n);
  const xi = new Float32Array(n);
  const tr = new Float32Array(n);
  const ti = new Float32Array(n);
  xr.set(x);
  tr.set(t);
  fft(xr, xi);
  fft(tr, ti);
  // X * conj(T) → correlation.
  for (let i = 0; i < n; i++) {
    const re = xr[i] * tr[i] + xi[i] * ti[i];
    const im = xi[i] * tr[i] - xr[i] * ti[i];
    xr[i] = re;
    xi[i] = im;
  }
  fft(xr, xi, true);
  return xr.slice(0, x.length);
}

/** Lag in [lo, hi] maximizing the summed (squared) filter output at starts+lag. */
function argmaxLag(m2: Float32Array, starts: number[], lo: number, hi: number): number {
  lo = Math.max(0, Math.round(lo));
  hi = Math.max(lo, Math.round(hi));
  let bestLag = lo;
  let bestScore = -Infinity;
  for (let lag = lo; lag <= hi; lag++) {
    let score = 0;
    for (const s of starts) {
      const o = s + lag;
      if (o >= 0 && o < m2.length) score += m2[o];
    }
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }
  return bestLag;
}

// --- Device run -------------------------------------------------------------

export const CALIBRATION_CLICKS = 8;
export const CALIBRATION_INTERVAL_SEC = 0.5;

export function isReliable(e: LatencyEstimate): boolean {
  return e.confidence >= 8 && e.spreadMs <= 2;
}

/**
 * Plays clicks through the current output, records them, and returns the
 * measured round-trip latency. Run it on the speaker (or with headphones held
 * to the mic) in a quiet room.
 */
export async function runCalibration(engine: Engine): Promise<LatencyEstimate & { routeKey: string }> {
  const { samples, sampleRate, clickFileTimes, routeKey } = await engine.recordClickTrain(
    CALIBRATION_CLICKS,
    CALIBRATION_INTERVAL_SEC,
  );
  const est = estimateLatency(samples, sampleRate, clickFileTimes, {
    template: makeClick(sampleRate, BEAT_CLICK),
  });
  return { ...est, routeKey };
}
