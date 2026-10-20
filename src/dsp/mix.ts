// Export-time mixing: place the processed drum take against the song (or the
// separated no-drums stem), sum, and brick-wall limit. Plus a windowed-sinc
// resampler for 44.1k ↔ 48k. Pure Float32Array code — no audio engine.

import type { Channels } from './types';

const dbToLin = (db: number) => Math.pow(10, db / 20);

// ---------------------------------------------------------------------------
// Mixer
// ---------------------------------------------------------------------------

export interface OriginalDrums {
  /** Separated drum stem of the song. */
  drums: Channels;
  /** Song with drums removed (bass + other + vocals). */
  noDrums: Channels;
  /** How much of the original drums to keep, 0..1 (linear). */
  amount: number;
}

export interface MixTakeOptions {
  /** Backing track (ignored when originalDrums is given). */
  song: Channels;
  /** Processed drum take. Mono drums are sent to every output channel. */
  drums: Channels;
  /** All inputs must already be at this rate (see resample). */
  sampleRate: number;
  /**
   * Song time (seconds) at which drum sample 0 lands. Negative trims that much
   * off the start of the drums.
   */
  drumOffsetSec: number;
  /** Linear gain on the backing (song, or noDrums + amount·drums). */
  songGain: number;
  /** Linear gain on the drum take. */
  drumGain: number;
  /** Replace the song with noDrums + amount·drums from drum separation. */
  originalDrums?: OriginalDrums;
  /** Brick-wall limit the sum (default true). */
  limit?: boolean;
  /** Limiter / normalize ceiling in dBFS (default −1). */
  ceilingDb?: number;
  /** After limiting, scale so the peak sits exactly at the ceiling (default false). */
  normalize?: boolean;
}

/**
 * Mix a drum take over the backing. Output channel count is the max of the
 * inputs (mono sources are spread to all channels); output length covers both
 * the backing and the placed drums.
 */
export function mixTake(opts: MixTakeOptions): Channels {
  const { sampleRate, drumGain, songGain, originalDrums } = opts;
  const drums = opts.drums;

  // Backing: the song, or the separated stems with a little original drum back in.
  const backingParts: { ch: Channels; gain: number }[] = originalDrums
    ? [
        { ch: originalDrums.noDrums, gain: songGain },
        { ch: originalDrums.drums, gain: songGain * originalDrums.amount },
      ]
    : [{ ch: opts.song, gain: songGain }];

  const offset = Math.round(opts.drumOffsetSec * sampleRate);
  const drumLen = len(drums);
  const drumStart = Math.max(0, -offset); // first drum sample that lands in the output
  const drumEnd = Math.max(0, drumLen + offset); // output index just past the last drum sample

  const backingLen = Math.max(0, ...backingParts.map((b) => len(b.ch)));
  const n = Math.max(backingLen, drumLen > drumStart ? drumEnd : 0);
  const nch = Math.max(1, drums.length, ...backingParts.map((b) => b.ch.length));

  const out: Channels = Array.from({ length: nch }, () => new Float32Array(n));

  for (const { ch, gain } of backingParts) {
    if (!ch.length || gain === 0) continue;
    for (let c = 0; c < nch; c++) {
      const src = ch[Math.min(c, ch.length - 1)];
      const dst = out[c];
      const m = Math.min(src.length, n);
      for (let i = 0; i < m; i++) dst[i] += src[i] * gain;
    }
  }

  if (drums.length && drumGain !== 0) {
    for (let c = 0; c < nch; c++) {
      const src = drums[Math.min(c, drums.length - 1)];
      const dst = out[c];
      for (let j = drumStart; j < src.length; j++) dst[j + offset] += src[j] * drumGain;
    }
  }

  const ceilingDb = opts.ceilingDb ?? -1;
  if (opts.limit !== false) limitPeaks(out, sampleRate, { ceilingDb });
  if (opts.normalize) normalizePeak(out, ceilingDb);
  return out;
}

const len = (ch: Channels) => (ch.length ? ch[0].length : 0);

// ---------------------------------------------------------------------------
// Limiter / normalize
// ---------------------------------------------------------------------------

export interface LimiterOptions {
  /** Output ceiling, dBFS (default −1). */
  ceilingDb?: number;
  /** Lookahead / attack ramp length (default 5 ms). */
  lookaheadMs?: number;
  /** Gain recovery time constant (default 80 ms). */
  releaseMs?: number;
}

/**
 * Stereo-linked lookahead brick-wall peak limiter, in place. Offline, so the
 * "lookahead" is non-causal with no added latency: the gain starts ramping
 * down `lookaheadMs` before a peak and is guaranteed ≤ ceiling/|peak| at it.
 */
export function limitPeaks(channels: Channels, sampleRate: number, opts: LimiterOptions = {}): Channels {
  const n = len(channels);
  if (!n) return channels;
  const ceiling = dbToLin(opts.ceilingDb ?? -1);
  const L = Math.max(1, Math.round(((opts.lookaheadMs ?? 5) / 1000) * sampleRate));
  const relCoeff = Math.exp(-1 / (((opts.releaseMs ?? 80) / 1000) * sampleRate));

  // Required gain per sample.
  const g = new Float32Array(n);
  let needed = false;
  for (let i = 0; i < n; i++) {
    let p = 0;
    for (let c = 0; c < channels.length; c++) {
      const a = Math.abs(channels[c][i]);
      if (a > p) p = a;
    }
    g[i] = p > ceiling ? ceiling / p : 1;
    if (g[i] < 1) needed = true;
  }
  if (!needed) return channels;

  // m[i] = min(g[i .. i+L]) via a monotonic deque.
  const m = new Float32Array(n);
  const dq = new Int32Array(n);
  let head = 0;
  let tail = 0;
  let next = 0; // next index to push
  for (let i = 0; i < n; i++) {
    const hi = Math.min(n - 1, i + L);
    for (; next <= hi; next++) {
      while (tail > head && g[dq[tail - 1]] >= g[next]) tail--;
      dq[tail++] = next;
    }
    while (dq[head] < i) head++;
    m[i] = g[dq[head]];
  }

  // s[i] = mean(m[i-L .. i]): every term's window contains i, so s[i] ≤ g[i],
  // and the moving average turns the step into a smooth ramp.
  // Then release: gain may fall instantly to s but recovers exponentially.
  // Before index L the window reaches past the start; pad it with m[0]
  // (= min g[0..L], so the bound still holds).
  let acc = 0;
  let env = 1;
  for (let i = 0; i < n; i++) {
    acc += m[i];
    if (i > L) acc -= m[i - L - 1];
    const s = i >= L ? acc / (L + 1) : (acc + (L - i) * m[0]) / (L + 1);
    env = Math.min(s, 1 - (1 - env) * relCoeff);
    for (let c = 0; c < channels.length; c++) {
      let y = channels[c][i] * env;
      // float rounding guard: never exceed the ceiling
      if (y > ceiling) y = ceiling;
      else if (y < -ceiling) y = -ceiling;
      channels[c][i] = y;
    }
  }
  return channels;
}

/** Scale in place so the absolute peak equals `ceilingDb` dBFS (silence untouched). */
export function normalizePeak(channels: Channels, ceilingDb = -1): Channels {
  let p = 0;
  for (const ch of channels) for (let i = 0; i < ch.length; i++) p = Math.max(p, Math.abs(ch[i]));
  if (p < 1e-9) return channels;
  const g = dbToLin(ceilingDb) / p;
  for (const ch of channels) for (let i = 0; i < ch.length; i++) ch[i] *= g;
  return channels;
}

// ---------------------------------------------------------------------------
// Resampler
// ---------------------------------------------------------------------------

const ZERO_CROSSINGS = 32; // per side, at the filter cutoff
const ROLLOFF = 0.95; // cutoff as a fraction of the lower Nyquist
const KAISER_BETA = 9; // ≈ 90 dB stopband
const MAX_EXACT_PHASES = 2048; // rational ratios up to this use exact phases
const INTERP_PHASES = 1024; // otherwise: fine table + linear interpolation

const gcd = (a: number, b: number): number => (b ? gcd(b, a % b) : a);

function besselI0(x: number): number {
  let sum = 1;
  let term = 1;
  const q = (x * x) / 4;
  for (let k = 1; k < 50; k++) {
    term *= q / (k * k);
    sum += term;
    if (term < 1e-12 * sum) break;
  }
  return sum;
}

/**
 * Band-limited resample (Kaiser-windowed sinc, polyphase). Output length is
 * round(inLength · toRate / fromRate). Same-rate input is copied.
 */
export function resample(channels: Channels, fromRate: number, toRate: number): Channels {
  if (fromRate === toRate) return channels.map((c) => Float32Array.from(c));
  if (!(fromRate > 0 && toRate > 0)) throw new Error('resample: rates must be positive');

  const fr = Math.round(fromRate);
  const tr = Math.round(toRate);
  const div = gcd(fr, tr);
  const up = tr / div; // L
  const down = fr / div; // M
  const ratio = toRate / fromRate;

  const fc = Math.min(1, ratio) * ROLLOFF; // cutoff, as a fraction of input Nyquist
  const half = Math.ceil(ZERO_CROSSINGS / fc); // taps per side, in input samples
  const taps = 2 * half;

  const exact = up <= MAX_EXACT_PHASES;
  const phases = exact ? up : INTERP_PHASES;
  // table[p][k]: weight of input sample (base - half + 1 + k) at fractional
  // position frac = p / phases past `base`.
  const rows = exact ? phases : phases + 1;
  const table = new Float32Array(rows * taps);
  const i0b = besselI0(KAISER_BETA);
  for (let p = 0; p < rows; p++) {
    const frac = p / phases;
    let sum = 0;
    for (let k = 0; k < taps; k++) {
      const t = k - half + 1 - frac; // input offset relative to the exact position
      const x = fc * t;
      const sinc = x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
      const r = t / half;
      const w = Math.abs(r) >= 1 ? 0 : besselI0(KAISER_BETA * Math.sqrt(1 - r * r)) / i0b;
      const v = fc * sinc * w;
      table[p * taps + k] = v;
      sum += v;
    }
    // unity DC gain per phase
    for (let k = 0; k < taps; k++) table[p * taps + k] /= sum;
  }

  return channels.map((x) => {
    const inLen = x.length;
    const outLen = Math.round((inLen * toRate) / fromRate);
    const y = new Float32Array(outLen);
    for (let n = 0; n < outLen; n++) {
      let base: number;
      let row0: number;
      let row1 = -1;
      let mix = 0;
      if (exact) {
        const num = n * down; // exact input position = num / up
        base = Math.floor(num / up);
        row0 = (num - base * up) * taps;
      } else {
        const pos = n / ratio;
        base = Math.floor(pos);
        const fp = (pos - base) * phases;
        const p = Math.floor(fp);
        mix = fp - p;
        row0 = p * taps;
        row1 = (p + 1) * taps;
      }
      const start = base - half + 1;
      let acc = 0;
      const k0 = Math.max(0, -start);
      const k1 = Math.min(taps, inLen - start);
      if (row1 < 0) {
        for (let k = k0; k < k1; k++) acc += x[start + k] * table[row0 + k];
      } else {
        for (let k = k0; k < k1; k++) {
          const w = table[row0 + k] + (table[row1 + k] - table[row0 + k]) * mix;
          acc += x[start + k] * w;
        }
      }
      y[n] = acc;
    }
    return y;
  });
}
