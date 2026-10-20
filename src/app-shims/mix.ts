// SHIM — stand-in for src/dsp/mix.ts (being written on another branch).
// Delete once the real module lands and point src/app-shims/index.ts at it.

import type { Channels } from '../dsp/types';

export interface MixTakeInput {
  song: Channels;
  drums: Channels;
  sampleRate: number;
  drumOffsetSec: number; // song time where drum sample 0 sits (may be negative)
  songGain: number;
  drumGain: number;
  originalDrums?: { drums: Channels; noDrums: Channels; amount: number };
}

const CEILING = Math.pow(10, -1 / 20); // −1 dBFS

export function mixTake(i: MixTakeInput): Channels {
  const sr = i.sampleRate;
  const bed: Channels = i.originalDrums
    ? sumInto(i.originalDrums.noDrums, i.originalDrums.drums, i.originalDrums.amount)
    : i.song;
  const offset = Math.round(i.drumOffsetSec * sr);
  const drumLen = i.drums[0]?.length ?? 0;
  const length = Math.max(bed[0]?.length ?? 0, offset + drumLen);
  const nch = Math.max(bed.length, i.drums.length, 1);
  const out: Channels = Array.from({ length: nch }, () => new Float32Array(Math.max(0, length)));
  for (let c = 0; c < nch; c++) {
    const o = out[c];
    const b = bed[c % bed.length];
    if (b) for (let n = 0; n < b.length; n++) o[n] += i.songGain * b[n];
    const d = i.drums[c % i.drums.length];
    if (d) {
      const from = Math.max(0, -offset);
      for (let n = from; n < d.length; n++) o[n + offset] += i.drumGain * d[n];
    }
  }
  return limit(out, sr);
}

function sumInto(a: Channels, b: Channels, gainB: number): Channels {
  const nch = Math.max(a.length, b.length);
  const len = Math.max(a[0].length, b[0].length);
  return Array.from({ length: nch }, (_, c) => {
    const o = new Float32Array(len);
    const ac = a[c % a.length];
    const bc = b[c % b.length];
    for (let n = 0; n < ac.length; n++) o[n] += ac[n];
    for (let n = 0; n < bc.length; n++) o[n] += gainB * bc[n];
    return o;
  });
}

// Look-ahead peak limiter: gain follows the minimum required gain over the
// next 5 ms (so it is down before the peak arrives), releases over ~80 ms.
function limit(ch: Channels, sr: number): Channels {
  const n = ch[0]?.length ?? 0;
  const need = new Float32Array(n);
  for (let k = 0; k < n; k++) {
    let p = 0;
    for (const c of ch) p = Math.max(p, Math.abs(c[k]));
    need[k] = p > CEILING ? CEILING / p : 1;
  }
  const look = Math.max(1, Math.round(sr * 0.005));
  const rel = 1 - Math.exp(-1 / (sr * 0.08));
  // Sliding minimum over [k, k+look] with a monotonic deque.
  const dq = new Int32Array(n + 1);
  let h = 0;
  let t = 0;
  let g = 1;
  let j = 0;
  for (let k = 0; k < n; k++) {
    while (j < n && j <= k + look) {
      while (t > h && need[dq[t - 1]] >= need[j]) t--;
      dq[t++] = j++;
    }
    while (dq[h] < k) h++;
    const target = need[dq[h]];
    g = target < g ? target : g + (target - g) * rel;
    for (const c of ch) {
      const v = c[k] * Math.min(g, need[k]);
      c[k] = v > CEILING ? CEILING : v < -CEILING ? -CEILING : v;
    }
  }
  return ch;
}

export function resample(channels: Channels, from: number, to: number): Channels {
  if (from === to) return channels;
  const ratio = from / to;
  return channels.map((src) => {
    const len = Math.floor((src.length * to) / from);
    const out = new Float32Array(len);
    for (let n = 0; n < len; n++) {
      const x = n * ratio;
      const i = Math.floor(x);
      const f = x - i;
      out[n] = (src[i] ?? 0) * (1 - f) + (src[i + 1] ?? src[i] ?? 0) * f;
    }
    return out;
  });
}
