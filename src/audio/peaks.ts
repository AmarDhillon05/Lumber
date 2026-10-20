// Waveform peaks for the editor lanes. Pure.

import type { Channels } from '../dsp/types';

/** Mono mixdown (average). Returns the input channel itself when mono. */
export function toMono(channels: Channels): Float32Array {
  if (channels.length === 1) return channels[0];
  const n = channels[0].length;
  const out = new Float32Array(n);
  for (const ch of channels) for (let i = 0; i < n; i++) out[i] += ch[i];
  for (let i = 0; i < n; i++) out[i] /= channels.length;
  return out;
}

/**
 * Peak |amplitude| per column for the time window [startSec, endSec) of a
 * signal that sits at `offsetSec` on that timeline (signal time 0 = timeline
 * offsetSec). Columns outside the signal are 0.
 */
export function windowPeaks(
  signal: Float32Array,
  sampleRate: number,
  startSec: number,
  endSec: number,
  columns: number,
  offsetSec = 0,
): Float32Array {
  const out = new Float32Array(columns);
  if (columns <= 0 || endSec <= startSec) return out;
  const colSec = (endSec - startSec) / columns;
  // Cap the per-column scan so very zoomed-out views stay cheap.
  const MAX_SCAN = 2048;
  for (let c = 0; c < columns; c++) {
    const a = Math.max(0, Math.floor((startSec + c * colSec - offsetSec) * sampleRate));
    const b = Math.min(signal.length, Math.floor((startSec + (c + 1) * colSec - offsetSec) * sampleRate));
    if (b <= a) continue;
    const step = Math.max(1, Math.floor((b - a) / MAX_SCAN));
    let p = 0;
    for (let i = a; i < b; i += step) {
      const v = Math.abs(signal[i]);
      if (v > p) p = v;
    }
    out[c] = p;
  }
  return out;
}
