// Compact audio descriptors for the "Describe the sound" feature: what the
// drum take and the song actually sound like, so a prompt like "brighter" can
// be judged against where the audio already is. Pure TS (tested under Node).
//
// Cost is bounded: at most `maxSec` of audio is scanned for level/envelope
// (one pass, frame RMS), and the spectrum is an average of a few dozen
// 4096-point FFT windows spread over that span, not an STFT of the whole file.

import { fft } from '../dsp/fft';
import type { Channels } from '../dsp/types';

export const BAND_EDGES = {
  sub: [20, 60],
  low: [60, 250],
  lowMid: [250, 800],
  mid: [800, 2500],
  presence: [2500, 6000],
  air: [6000, 20000],
} as const;
export type Band = keyof typeof BAND_EDGES;
export const BANDS = Object.keys(BAND_EDGES) as Band[];

export interface AudioDescriptors {
  durationSec: number; // analysed span
  channels: number;
  rmsDb: number; // dBFS, whole analysed span
  peakDb: number; // dBFS sample peak
  crestDb: number; // peak − RMS: high = spiky/dynamic, low = squashed
  loudnessLufs: number; // integrated, K-weighted and gated (BS.1770-style)
  dynamicRangeDb: number; // 95th − 10th percentile of short-term frame level
  noiseFloorDb: number; // 10th percentile frame level (dBFS)
  bands: Record<Band, number>; // share of spectral energy per band, dB (0 = all of it)
  centroidHz: number; // spectral centroid (brightness)
  onsetsPerSec: number; // transient density
  decayMs: number; // median time for a hit to fall 20 dB (sustain / room)
  stereoWidth: number | null; // side / (mid + side) energy, 0..1; null for mono
}

export interface AnalyzeOptions {
  startSec?: number; // where to start (e.g. the part of the song under the take)
  maxSec?: number; // cap on the analysed span (default 30 s)
  fftWindows?: number; // number of spectrum windows (default 32)
}

const HOP = 512; // envelope frame (~10.7 ms at 48 kHz)
const FFT_N = 4096;
const SILENT_DB = -120;

const toDb = (power: number): number => (power > 1e-12 ? 10 * Math.log10(power) : SILENT_DB);
const ampDb = (amp: number): number => (amp > 1e-6 ? 20 * Math.log10(amp) : SILENT_DB);

function percentile(sorted: number[], p: number): number {
  if (!sorted.length) return SILENT_DB;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.round(p * (sorted.length - 1))));
  return sorted[i];
}

function median(xs: number[]): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// RBJ biquad (direct form I) for the BS.1770 K-weighting pre-filter at any rate.
interface Biquad { b0: number; b1: number; b2: number; a1: number; a2: number }
function highShelf(fs: number, f0: number, gainDb: number, q: number): Biquad {
  const A = Math.pow(10, gainDb / 40);
  const w = (2 * Math.PI * f0) / fs;
  const alpha = Math.sin(w) / (2 * q);
  const cos = Math.cos(w);
  const s = 2 * Math.sqrt(A) * alpha;
  const a0 = A + 1 - (A - 1) * cos + s;
  return {
    b0: (A * (A + 1 + (A - 1) * cos + s)) / a0,
    b1: (-2 * A * (A - 1 + (A + 1) * cos)) / a0,
    b2: (A * (A + 1 + (A - 1) * cos - s)) / a0,
    a1: (2 * (A - 1 - (A + 1) * cos)) / a0,
    a2: (A + 1 - (A - 1) * cos - s) / a0,
  };
}
function highPass(fs: number, f0: number, q: number): Biquad {
  const w = (2 * Math.PI * f0) / fs;
  const alpha = Math.sin(w) / (2 * q);
  const cos = Math.cos(w);
  const a0 = 1 + alpha;
  return {
    b0: (1 + cos) / 2 / a0,
    b1: -(1 + cos) / a0,
    b2: (1 + cos) / 2 / a0,
    a1: (-2 * cos) / a0,
    a2: (1 - alpha) / a0,
  };
}

/** Sum of K-weighted squares per 100 ms step, for gated loudness. */
function kWeightedSteps(ch: Float32Array, start: number, len: number, fs: number, step: number): Float64Array {
  const f1 = highShelf(fs, 1681.974450955533, 3.999843853973347, 0.7071752369554196);
  const f2 = highPass(fs, 38.13547087602444, 0.5003270373238773);
  const out = new Float64Array(Math.ceil(len / step));
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0, z1 = 0, z2 = 0;
  let u1 = 0, u2 = 0; // f2 input history (= f1 output history)
  for (let i = 0; i < len; i++) {
    const x = ch[start + i];
    const y = f1.b0 * x + f1.b1 * x1 + f1.b2 * x2 - f1.a1 * y1 - f1.a2 * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    const z = f2.b0 * y + f2.b1 * u1 + f2.b2 * u2 - f2.a1 * z1 - f2.a2 * z2;
    u2 = u1; u1 = y; z2 = z1; z1 = z;
    out[(i / step) | 0] += z * z;
  }
  return out;
}

/** BS.1770-style integrated loudness: 400 ms blocks, 75 % overlap, −70 / −10 gates. */
function integratedLufs(chs: Float32Array[], start: number, len: number, fs: number): number {
  const step = Math.max(1, Math.round(fs * 0.1));
  const steps = chs.map((c) => kWeightedSteps(c, start, len, fs, step));
  const nSteps = steps[0].length;
  const blocks: number[] = [];
  for (let b = 0; b + 4 <= nSteps; b++) {
    let sum = 0;
    for (const s of steps) sum += s[b] + s[b + 1] + s[b + 2] + s[b + 3];
    blocks.push(-0.691 + toDb(sum / (4 * step)));
  }
  if (!blocks.length) {
    let sum = 0;
    for (const s of steps) for (let i = 0; i < nSteps; i++) sum += s[i];
    return -0.691 + toDb(sum / Math.max(1, len));
  }
  const gate = (xs: number[], thr: number) => xs.filter((l) => l > thr);
  const meanLufs = (xs: number[]) => -0.691 + toDb(xs.reduce((a, l) => a + Math.pow(10, (l + 0.691) / 10), 0) / xs.length);
  const abs = gate(blocks, -70);
  if (!abs.length) return SILENT_DB;
  const rel = gate(abs, meanLufs(abs) - 10);
  return meanLufs(rel.length ? rel : abs);
}

/** Descriptors for a (mono or stereo) buffer. Silent input yields −120 dB levels and zeros. */
export function analyzeAudio(channels: Channels, sampleRate: number, opts: AnalyzeOptions = {}): AudioDescriptors {
  const chs = channels.slice(0, 2);
  const total = chs[0]?.length ?? 0;
  const start = Math.min(total, Math.max(0, Math.floor((opts.startSec ?? 0) * sampleRate)));
  const len = Math.min(total - start, Math.floor((opts.maxSec ?? 30) * sampleRate));
  const stereo = chs.length === 2;
  const nCh = Math.max(1, chs.length);

  // --- one pass: peak, energy, frame envelope, mid/side energy
  let peak = 0;
  let sumSq = 0;
  let midE = 0;
  let sideE = 0;
  const nFrames = Math.max(0, Math.floor(len / HOP));
  const frameDb = new Float64Array(nFrames);
  for (let f = 0; f < nFrames; f++) {
    let fe = 0;
    const base = start + f * HOP;
    for (let i = 0; i < HOP; i++) {
      let m = 0;
      for (let c = 0; c < nCh; c++) {
        const v = chs[c][base + i];
        const a = v < 0 ? -v : v;
        if (a > peak) peak = a;
        m += v;
        sumSq += v * v;
      }
      m /= nCh;
      fe += m * m;
      if (stereo) {
        const l = chs[0][base + i];
        const r = chs[1][base + i];
        const mid = (l + r) / 2;
        const side = (l - r) / 2;
        midE += mid * mid;
        sideE += side * side;
      }
    }
    frameDb[f] = toDb(fe / HOP);
  }
  const used = nFrames * HOP;
  const rmsDb = toDb(sumSq / Math.max(1, used * nCh));
  const peakDb = ampDb(peak);

  const sortedFrames = Array.from(frameDb).sort((a, b) => a - b);
  const noiseFloorDb = percentile(sortedFrames, 0.1);
  const loudFrame = percentile(sortedFrames, 0.95);
  const dynamicRangeDb = Math.max(0, loudFrame - noiseFloorDb);

  // --- onsets + decay on the frame envelope
  const hopSec = HOP / sampleRate;
  const minGap = Math.max(1, Math.round(0.05 / hopSec)); // 50 ms refractory
  const floorGate = Math.max(noiseFloorDb + 10, loudFrame - 40);
  const onsets: number[] = [];
  for (let f = 3; f < nFrames; f++) {
    const prevMin = Math.min(frameDb[f - 1], frameDb[f - 2], frameDb[f - 3]);
    const rise = frameDb[f] - prevMin;
    if (rise >= 8 && frameDb[f] >= floorGate && (!onsets.length || f - onsets[onsets.length - 1] >= minGap)) {
      onsets.push(f);
    }
  }
  const decays: number[] = [];
  for (let k = 0; k < onsets.length; k++) {
    const o = onsets[k];
    const end = k + 1 < onsets.length ? onsets[k + 1] : nFrames;
    let pk = o;
    for (let f = o; f < Math.min(end, o + 5); f++) if (frameDb[f] > frameDb[pk]) pk = f;
    const target = frameDb[pk] - 20;
    let f = pk;
    while (f < end && frameDb[f] > target) f++;
    decays.push((f - pk) * hopSec * 1000);
  }
  const durationSec = len / sampleRate;

  // --- averaged power spectrum over a few windows
  const nWin = len >= FFT_N ? Math.max(1, Math.min(opts.fftWindows ?? 32, Math.floor(len / FFT_N))) : 0;
  const nBins = FFT_N / 2;
  const power = new Float64Array(nBins);
  const hann = new Float32Array(FFT_N);
  for (let i = 0; i < FFT_N; i++) hann[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (FFT_N - 1));
  const re = new Float32Array(FFT_N);
  const im = new Float32Array(FFT_N);
  for (let w = 0; w < nWin; w++) {
    const off = start + (nWin === 1 ? 0 : Math.floor(((len - FFT_N) * w) / (nWin - 1)));
    for (let i = 0; i < FFT_N; i++) {
      let m = 0;
      for (let c = 0; c < nCh; c++) m += chs[c][off + i];
      re[i] = (m / nCh) * hann[i];
      im[i] = 0;
    }
    fft(re, im);
    for (let k = 0; k < nBins; k++) power[k] += re[k] * re[k] + im[k] * im[k];
  }
  const binHz = sampleRate / FFT_N;
  const bandE: Record<Band, number> = { sub: 0, low: 0, lowMid: 0, mid: 0, presence: 0, air: 0 };
  let totalE = 0;
  let centroidNum = 0;
  for (let k = 1; k < nBins; k++) {
    const hz = k * binHz;
    if (hz < 20 || hz > 20000) continue;
    const p = power[k];
    totalE += p;
    centroidNum += p * hz;
    for (const b of BANDS) {
      const [lo, hi] = BAND_EDGES[b];
      if (hz >= lo && hz < hi) {
        bandE[b] += p;
        break;
      }
    }
  }
  const bands = Object.fromEntries(
    BANDS.map((b) => [b, totalE > 0 ? toDb(bandE[b] / totalE) : SILENT_DB]),
  ) as Record<Band, number>;

  return {
    durationSec,
    channels: chs.length,
    rmsDb,
    peakDb,
    crestDb: rmsDb <= SILENT_DB ? 0 : peakDb - rmsDb,
    loudnessLufs: len > 0 ? integratedLufs(chs, start, len, sampleRate) : SILENT_DB,
    dynamicRangeDb,
    noiseFloorDb,
    bands,
    centroidHz: totalE > 0 ? centroidNum / totalE : 0,
    onsetsPerSec: durationSec > 0 ? onsets.length / durationSec : 0,
    decayMs: median(decays),
    stereoWidth: stereo ? (midE + sideE > 0 ? sideE / (midE + sideE) : 0) : null,
  };
}

/** Rounded copy for prompts / UI (keeps the request small and readable). */
export function roundDescriptors(d: AudioDescriptors): AudioDescriptors {
  const r = (x: number, p = 1) => Math.round(x * 10 ** p) / 10 ** p;
  return {
    durationSec: r(d.durationSec),
    channels: d.channels,
    rmsDb: r(d.rmsDb),
    peakDb: r(d.peakDb),
    crestDb: r(d.crestDb),
    loudnessLufs: r(d.loudnessLufs),
    dynamicRangeDb: r(d.dynamicRangeDb),
    noiseFloorDb: r(d.noiseFloorDb),
    bands: Object.fromEntries(BANDS.map((b) => [b, r(d.bands[b])])) as Record<Band, number>,
    centroidHz: Math.round(d.centroidHz),
    onsetsPerSec: r(d.onsetsPerSec, 2),
    decayMs: Math.round(d.decayMs),
    stereoWidth: d.stereoWidth == null ? null : r(d.stereoWidth, 3),
  };
}

export interface MixAnalysis {
  drums: AudioDescriptors;
  song: AudioDescriptors | null;
  songIsDrumless: boolean; // song descriptors come from the no-drums stem
}
