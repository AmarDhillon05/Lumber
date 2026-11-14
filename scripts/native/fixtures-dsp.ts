// Golden fixtures for native/LumberCore's DSP + Timing ports.
//
//   npx tsx scripts/native/fixtures-dsp.ts
//
// Feeds deterministic inputs through the TypeScript implementations in src/
// and writes compact JSON to native/LumberCore/Tests/LumberCoreTests/Fixtures/
// {dsp,timing}/. Float arrays are stored as base64 little-endian float32
// ({"f32": "..."}), byte arrays as {"u8": "..."}.
//
// The TS render path (biquads, gain, convolution reverb) ran on
// react-native-audio-api's OfflineAudioContext, which doesn't exist under
// Node. For those fixtures this script installs ./webAudioRef.ts — a reference
// implementation written from the Web Audio spec — as that module, then runs
// the real src/dsp/render.ts. Math.random (reverb IR noise) is swapped for
// the same seeded LCG the Swift port uses.

import Module from 'module';
import * as fs from 'fs';
import * as path from 'path';
import * as webAudioRef from './webAudioRef';

// Must be installed before anything requires react-native-audio-api.
const origLoad = (Module as unknown as { _load: (...a: unknown[]) => unknown })._load;
(Module as unknown as { _load: (...a: unknown[]) => unknown })._load = function (this: unknown, ...args: unknown[]) {
  if (args[0] === 'react-native-audio-api') return webAudioRef;
  return origLoad.apply(this, args);
};

/* eslint-disable @typescript-eslint/no-require-imports */
const fx = require('../../src/dsp/effects') as typeof import('../../src/dsp/effects');
const { fft, nextPow2 } = require('../../src/dsp/fft') as typeof import('../../src/dsp/fft');
const biquad = require('../../src/dsp/biquad') as typeof import('../../src/dsp/biquad');
const { renderChain } = require('../../src/dsp/render') as typeof import('../../src/dsp/render');
const chainMod = require('../../src/dsp/blanketChain') as typeof import('../../src/dsp/blanketChain');
const terms = require('../../src/dsp/blanketTerms') as typeof import('../../src/dsp/blanketTerms');
const presets = require('../../src/dsp/presets') as typeof import('../../src/dsp/presets');
const mix = require('../../src/dsp/mix') as typeof import('../../src/dsp/mix');
const wav = require('../../src/dsp/wav') as typeof import('../../src/dsp/wav');
const { makeImpulseResponse } = require('../../src/dsp/reverbIR') as typeof import('../../src/dsp/reverbIR');
const offsets = require('../../src/audio/offsets') as typeof import('../../src/audio/offsets');
const calib = require('../../src/audio/calibration') as typeof import('../../src/audio/calibration');
const click = require('../../src/audio/click') as typeof import('../../src/audio/click');
const peaks = require('../../src/audio/peaks') as typeof import('../../src/audio/peaks');
const vsync = require('../../src/video/sync') as typeof import('../../src/video/sync');
const { EffectChain } = require('../../src/dsp/chain') as typeof import('../../src/dsp/chain');
/* eslint-enable @typescript-eslint/no-require-imports */

type Channels = Float32Array[];

const ROOT = path.resolve(__dirname, '../../native/LumberCore/Tests/LumberCoreTests/Fixtures');
const REVERB_SEED = 0x5eed0001; // DSP.defaultReverbSeed

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const f32 = (x: Float32Array) => ({ f32: Buffer.from(x.buffer, x.byteOffset, x.byteLength).toString('base64') });
const u8 = (x: Uint8Array) => ({ u8: Buffer.from(x.buffer, x.byteOffset, x.byteLength).toString('base64') });
const chans = (c: Channels) => c.map(f32);
const copy = (c: Channels): Channels => c.map((x) => Float32Array.from(x));

function rng(seed: number) {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function write(rel: string, data: unknown) {
  const file = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data));
  console.log(`${rel}  ${(fs.statSync(file).size / 1024).toFixed(1)} KB`);
}

/** A drum-ish stereo test signal: decaying noise/sine hits over a quiet noise floor. */
function drumSignal(n: number, sr: number, seed: number): Channels {
  const r = rng(seed);
  const L = new Float32Array(n);
  const R = new Float32Array(n);
  const hits = [0.01, 0.09, 0.17, 0.21, 0.29, 0.33];
  const amps = [0.95, 0.3, 0.7, 0.05, 0.85, 0.4];
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    let l = 0.002 * (r() * 2 - 1);
    let rr = 0.002 * (r() * 2 - 1);
    for (let h = 0; h < hits.length; h++) {
      const dt = t - hits[h];
      if (dt < 0) continue;
      const env = Math.exp(-dt * 40);
      const body = Math.sin(2 * Math.PI * (90 + 60 * h) * dt) * env;
      const noise = (r() * 2 - 1) * Math.exp(-dt * 120);
      l += amps[h] * (0.7 * body + 0.4 * noise);
      rr += amps[h] * (0.5 * body + 0.6 * noise) * (h % 2 ? 0.8 : 1.1);
    }
    L[i] = l;
    R[i] = rr;
  }
  return [L, R];
}

// ---------------------------------------------------------------------------
// dsp/effects.json
// ---------------------------------------------------------------------------

function effectsFixture() {
  const sr = 22050;
  const n = 4096;
  const input = drumSignal(n, sr, 42);
  const mono = [input[0]];

  // FFT
  const N = 256;
  const r = rng(7);
  const re = Float32Array.from({ length: N }, () => r() * 2 - 1);
  const im = Float32Array.from({ length: N }, () => r() * 2 - 1);
  const fRe = Float32Array.from(re);
  const fIm = Float32Array.from(im);
  fft(fRe, fIm);
  const iRe = Float32Array.from(fRe);
  const iIm = Float32Array.from(fIm);
  fft(iRe, iIm, true);

  const bp = biquad.bandpass(2000, 8000, sr);

  const cases: { name: string; fn: string; params: unknown; stereo: boolean; out: unknown }[] = [];
  const run = (name: string, fn: string, params: unknown, stereo: boolean, f: (c: Channels) => Channels) => {
    const out = f(copy(stereo ? input : mono));
    cases.push({ name, fn, params, stereo, out: chans(out) });
  };
  const dyn = (p: { thresholdDb: number; ratio: number; attackMs: number; releaseMs: number }) => p;
  let p: any;
  p = dyn({ thresholdDb: -18, ratio: 4, attackMs: 10, releaseMs: 100 });
  run('compress dynamic_range', 'compress', p, true, (c) => fx.compress(c, sr, p));
  const pNat = dyn({ thresholdDb: -3, ratio: 58, attackMs: 0.1, releaseMs: 50 });
  run('compress naturalness max', 'compress', pNat, false, (c) => fx.compress(c, sr, pNat));
  const pPunch0 = dyn({ thresholdDb: -20, ratio: 2, attackMs: 0, releaseMs: 80 });
  run('compress zero attack', 'compress', pPunch0, false, (c) => fx.compress(c, sr, pPunch0));
  const pGate = dyn({ thresholdDb: -40, ratio: 7, attackMs: 1, releaseMs: 100 });
  run('gate sustain', 'gate', pGate, true, (c) => fx.gate(c, sr, pGate));
  const pUp = { thresholdDb: -30, ratio: 4, maxGainDb: 12, attackMs: 5, releaseMs: 150 };
  run('upwardCompress detail', 'upwardCompress', pUp, true, (c) => fx.upwardCompress(c, sr, pUp));
  run('saturate drive 7', 'saturate', { drive: 7 }, false, (c) => fx.saturate(c, 7));
  const pPres = { lowHz: 2000, highHz: 8000, drive: 4, blend: 0.9 };
  run('presence', 'presence', pPres, true, (c) => fx.presence(c, sr, pPres));
  run('width 3', 'width', { amount: 3 }, true, (c) => fx.width(c, 3));
  const pSg = { propDecrease: 0.8, stationary: true };
  run('spectralGate stationary', 'spectralGate', pSg, false, (c) => fx.spectralGate(c, pSg));
  const pSg2 = { propDecrease: 1, stationary: false };
  run('spectralGate local', 'spectralGate', pSg2, true, (c) => fx.spectralGate(c, pSg2));

  // Resonance detection input: low tone + two rings + noise.
  const rn = 8192;
  const rr = rng(99);
  const resIn = Float32Array.from({ length: rn }, (_, i) => {
    const t = i / sr;
    return (
      0.05 * Math.sin(2 * Math.PI * 120 * t) +
      0.6 * Math.sin(2 * Math.PI * 2000 * t) +
      0.3 * Math.sin(2 * Math.PI * 650 * t) +
      0.01 * (rr() * 2 - 1)
    );
  });
  const resFreqs = fx.detectResonances([resIn], sr);
  const drumFreqs = fx.detectResonances(copy(input), sr);

  write('dsp/effects.json', {
    sampleRate: sr,
    input: chans(input),
    fft: { re: f32(re), im: f32(im), outRe: f32(fRe), outIm: f32(fIm), invRe: f32(iRe), invIm: f32(iIm) },
    nextPow2: [0, 1, 2, 3, 1000, 1024, 1025].map((v) => [v, nextPow2(v)]),
    bandpass: { lowHz: 2000, highHz: 8000, sampleRate: sr, coeffs: bp, filtfilt: f32(biquad.filtfilt(input[0], bp)) },
    cases,
    resonance: { input: f32(resIn), freqs: resFreqs, drumFreqs },
  });
}

// ---------------------------------------------------------------------------
// dsp/blanket.json — terms, order, presets, chain specs
// ---------------------------------------------------------------------------

function blanketFixture() {
  const builds: { values: Record<string, number>; chain: unknown }[] = [];
  for (const term of terms.BLANKET_TERM_KEYS) {
    for (const v of [-1, -0.5, 0.25, 1]) {
      builds.push({ values: { [term]: v }, chain: chainMod.buildBlanketChain({ [term]: v }) });
    }
  }
  for (const p of presets.PRESETS) builds.push({ values: p.values as Record<string, number>, chain: chainMod.buildBlanketChain(p.values) });
  const everything = Object.fromEntries(terms.BLANKET_TERM_KEYS.map((k, i) => [k, ((i % 5) - 2) / 2.5]));
  builds.push({ values: everything, chain: chainMod.buildBlanketChain(everything) });
  builds.push({ values: { volume: -1 }, chain: chainMod.buildBlanketChain({ volume: -1 }, 3) });
  builds.push({ values: { punch: 0.5, air: -0.2 }, chain: chainMod.buildBlanketChain({ punch: 0.5, air: -0.2 }, 1.5), intensity: 1.5 } as never);

  // Primitive builders
  const c = new EffectChain();
  c.high_pass(55, 2).high_pass(60, 6).low_pass(9000, 8).low_pass(5000, 3).band_pass(300, 3000).notch(1234).notch(500, 4);
  c.peak_eq(1000, -3, 2).low_shelf(120, 4).high_shelf(9000, -2).gain(-6);

  write('dsp/blanket.json', {
    intensity: chainMod.INTENSITY,
    renderOrder: chainMod.BLANKET_RENDER_ORDER,
    keys: terms.BLANKET_TERM_KEYS,
    categoryOrder: terms.CATEGORY_ORDER,
    terms: terms.BLANKET_TERM_KEYS.map((k) => ({ key: k, ...terms.BLANKET_TERMS[k] })),
    presets: presets.PRESETS,
    builds,
    primitives: c.chain,
  });
}

// ---------------------------------------------------------------------------
// dsp/render.json — Web Audio reference renders (biquads, gain, reverb, full chains)
// ---------------------------------------------------------------------------

async function renderFixture() {
  const sr = 22050;
  const n = 4096;
  const input = drumSignal(n, sr, 1234);
  const mono = [input[0]];

  const biquads: unknown[] = [];
  const specs: { kind: string; frequency: number; q?: number; gainDb?: number }[] = [
    { kind: 'lowpass', frequency: 1000, q: 0.7071 },
    { kind: 'lowpass', frequency: 12000, q: 1.3066 }, // above Nyquist → pass-through
    { kind: 'highpass', frequency: 80, q: 0.5412 },
    { kind: 'highpass', frequency: 300 }, // default Q = 1 (dB)
    { kind: 'bandpass', frequency: 1000, q: 0.5 },
    { kind: 'notch', frequency: 2000, q: 30 },
    { kind: 'notch', frequency: 650, q: 7.5 },
    { kind: 'peaking', frequency: 90, q: 1.2, gainDb: 4.5 },
    { kind: 'peaking', frequency: 350, q: 0.8, gainDb: -9 },
    { kind: 'lowshelf', frequency: 120, gainDb: 6 },
    { kind: 'highshelf', frequency: 8000, gainDb: -6 },
    { kind: 'highshelf', frequency: 10000, gainDb: 9 },
  ];
  for (const s of specs) {
    const { channels } = await renderChain(copy(mono), sr, [s as never]);
    const c = webAudioRef.webAudioBiquadCoeffs(s.kind, s.frequency, s.q ?? 1, s.gainDb ?? 0, sr);
    biquads.push({ spec: s, coeffs: c, out: f32(channels[0]) });
  }

  const renders: unknown[] = [];
  const render = async (name: string, src: Channels, chain: unknown[]) => {
    const restore = webAudioRef.seedMathRandom(REVERB_SEED);
    try {
      const { channels } = await renderChain(copy(src), sr, chain as never);
      renders.push({ name, stereo: src.length === 2, chain, out: chans(channels) });
    } finally {
      restore();
    }
  };
  await render('gain -6', mono, [{ kind: 'gain', db: -6 }]);
  await render('reverb mono', mono, [{ kind: 'reverb', roomSize: 0.3, damping: 0.7, wetLevel: 0.3, dryLevel: 1 }]);
  await render('reverb stereo', input, [{ kind: 'reverb', roomSize: 0.05, damping: 0.2, wetLevel: 0.45, dryLevel: 0.8 }]);
  for (const p of presets.PRESETS) {
    await render(`preset ${p.id}`, input, chainMod.buildBlanketChain(p.values));
  }
  await render('preset roomy mono', mono, chainMod.buildBlanketChain(presets.getPreset('roomy')!.values));
  await render('preset phone mono', mono, chainMod.buildBlanketChain(presets.getPreset('phone')!.values));

  // The IR itself (first 512 frames of each channel) to pin the generator.
  const restore = webAudioRef.seedMathRandom(REVERB_SEED);
  const ir = makeImpulseResponse(
    { createBuffer: (c: number, l: number, s: number) => new webAudioRef.AudioBufferRef(c, l, s) } as never,
    sr,
    0.3,
    0.7,
  );
  restore();
  const irRef = ir as unknown as webAudioRef.AudioBufferRef;

  write('dsp/render.json', {
    sampleRate: sr,
    reverbSeed: REVERB_SEED,
    input: chans(input),
    biquads,
    renders,
    impulse: {
      roomSize: 0.3,
      damping: 0.7,
      length: irRef.length,
      head: [f32(irRef.getChannelData(0).slice(0, 512)), f32(irRef.getChannelData(1).slice(0, 512))],
      normalizationScale: webAudioRef.normalizationScale(irRef),
    },
  });
}

// ---------------------------------------------------------------------------
// dsp/mix.json — mixTake, limiter, normalize, resample
// ---------------------------------------------------------------------------

function mixFixture() {
  const sr = 8000;
  const r = rng(5);
  const noise = (n: number, a: number) => Float32Array.from({ length: n }, () => a * (r() * 2 - 1));
  const song = [noise(900, 0.6), noise(900, 0.6)];
  const drums = [noise(700, 0.9)];
  const stereoDrums = [noise(500, 0.5), noise(500, 0.7)];
  const od = { drums: [noise(950, 0.4)], noDrums: [noise(950, 0.5), noise(950, 0.5)], amount: 0.35 };

  const mixes: unknown[] = [];
  const m = (name: string, opts: Parameters<typeof mix.mixTake>[0]) => {
    const out = mix.mixTake({ ...opts, song: copy(opts.song), drums: copy(opts.drums) });
    mixes.push({
      name,
      opts: {
        song: chans(opts.song),
        drums: chans(opts.drums),
        sampleRate: opts.sampleRate,
        drumOffsetSec: opts.drumOffsetSec,
        songGain: opts.songGain,
        drumGain: opts.drumGain,
        originalDrums: opts.originalDrums
          ? { drums: chans(opts.originalDrums.drums), noDrums: chans(opts.originalDrums.noDrums), amount: opts.originalDrums.amount }
          : null,
        limit: opts.limit ?? true,
        ceilingDb: opts.ceilingDb ?? -1,
        normalize: opts.normalize ?? false,
      },
      out: chans(out),
    });
  };
  m('limited, positive offset', { song, drums, sampleRate: sr, drumOffsetSec: 0.0251, songGain: 0.9, drumGain: 1.2 });
  m('negative offset, no limit', { song, drums, sampleRate: sr, drumOffsetSec: -0.0126, songGain: 0.5, drumGain: 0.7, limit: false });
  m('stereo drums, normalize -0.5', { song: [song[0]], drums: stereoDrums, sampleRate: sr, drumOffsetSec: 0.05, songGain: 0.3, drumGain: 0.3, normalize: true, ceilingDb: -0.5 });
  m('original drums', { song, drums, sampleRate: sr, drumOffsetSec: 0.01, songGain: 1, drumGain: 1, originalDrums: od });
  m('drums past the end', { song, drums, sampleRate: sr, drumOffsetSec: 0.2, songGain: 1, drumGain: 0.5 });

  // Limiter on a spiky signal with custom options
  const x = noise(3000, 0.4);
  x[500] = 1.8;
  x[501] = -1.4;
  x[2000] = 1.1;
  const y = noise(3000, 0.3);
  y[1500] = -2.5;
  const limIn = [x, y];
  const lim1 = mix.limitPeaks(copy(limIn), sr);
  const lim2 = mix.limitPeaks(copy(limIn), sr, { ceilingDb: -3, lookaheadMs: 2, releaseMs: 20 });
  const norm = mix.normalizePeak(copy(limIn), -2);

  const res: unknown[] = [];
  const toneIn = Float32Array.from({ length: 1000 }, (_, i) => 0.5 * Math.sin((2 * Math.PI * 1000 * i) / 44100) + 0.2 * Math.sin((2 * Math.PI * 9000 * i) / 44100));
  const noiseIn = noise(1000, 0.5);
  for (const [from, to] of [
    [44100, 48000],
    [48000, 44100],
    [48000, 47993],
    [22050, 48000],
    [48000, 16000],
  ]) {
    const out = mix.resample([toneIn, noiseIn], from, to);
    res.push({ from, to, out: chans(out) });
  }

  write('dsp/mix.json', {
    mixes,
    limiter: { input: chans(limIn), sampleRate: sr, defaultOut: chans(lim1), customOut: chans(lim2), normalizeOut: chans(norm) },
    resample: { input: chans([toneIn, noiseIn]), cases: res },
  });
}

// ---------------------------------------------------------------------------
// dsp/wav.json
// ---------------------------------------------------------------------------

function wavFixture() {
  const r = rng(11);
  const n = 257;
  const L = Float32Array.from({ length: n }, () => r() * 2.4 - 1.2); // includes out-of-range
  const R = Float32Array.from({ length: n }, () => r() * 2 - 1);
  L[3] = NaN;
  L[4] = Infinity;
  L[5] = 1;
  L[6] = -1;
  L[7] = 0.5 / 32768; // rounding tie
  L[8] = -0.5 / 32768;
  const encodes: unknown[] = [];
  for (const depth of [16, 24, 32] as const) {
    encodes.push({ bitDepth: depth, sampleRate: 44100, input: chans([L, R]), bytes: u8(wav.encodeWav([L, R], 44100, depth)) });
    encodes.push({ bitDepth: depth, sampleRate: 22050, input: chans([R]), bytes: u8(wav.encodeWav([R], 22050, depth)) });
  }

  // Decoder-only formats, hand-built.
  const header = (format: number, nch: number, sr: number, bits: number, data: Uint8Array, extensible = false) => {
    const fmtSize = extensible ? 40 : 16;
    const out = new Uint8Array(12 + 8 + fmtSize + 8 + data.length + (data.length & 1));
    const v = new DataView(out.buffer);
    const s = (o: number, t: string) => [...t].forEach((ch, i) => (out[o + i] = ch.charCodeAt(0)));
    s(0, 'RIFF');
    v.setUint32(4, out.length - 8, true);
    s(8, 'WAVE');
    s(12, 'fmt ');
    v.setUint32(16, fmtSize, true);
    v.setUint16(20, extensible ? 0xfffe : format, true);
    v.setUint16(22, nch, true);
    v.setUint32(24, sr, true);
    v.setUint32(28, (sr * nch * bits) / 8, true);
    v.setUint16(32, (nch * bits) / 8, true);
    v.setUint16(34, bits, true);
    if (extensible) {
      v.setUint16(36, 22, true);
      v.setUint16(38, bits, true);
      v.setUint32(40, 3, true);
      v.setUint16(44, format, true); // SubFormat GUID's first 2 bytes
    }
    const d = 20 + fmtSize;
    s(d, 'data');
    v.setUint32(d + 4, data.length, true);
    out.set(data, d + 8);
    return out;
  };
  const bytesOf = (n: number, f: (v: DataView, i: number) => void, size: number) => {
    const b = new Uint8Array(n * size);
    const v = new DataView(b.buffer);
    for (let i = 0; i < n; i++) f(v, i);
    return b;
  };
  const decodes: unknown[] = [];
  const dec = (name: string, bytes: Uint8Array) => {
    const d = wav.decodeWav(bytes);
    decodes.push({ name, bytes: u8(bytes), sampleRate: d.sampleRate, channels: chans(d.channels) });
  };
  dec('pcm8 mono', header(1, 1, 8000, 8, bytesOf(37, (v, i) => v.setUint8(i, (i * 53) & 255), 1)));
  dec('pcm32 stereo', header(1, 2, 48000, 32, bytesOf(40, (v, i) => v.setInt32(i * 4, Math.imul(i + 1, 0x3c6ef35f), true), 4)));
  dec('float64 mono', header(3, 1, 96000, 64, bytesOf(20, (v, i) => v.setFloat64(i * 8, Math.sin(i) * 1.5, true), 8)));
  dec('extensible pcm24 stereo', header(1, 2, 44100, 24, bytesOf(30, (v, i) => v.setUint8(i, (i * 97 + 13) & 255), 1), true));
  dec('extensible float32 mono', header(3, 1, 32000, 32, bytesOf(10, (v, i) => v.setFloat32(i * 4, i / 7 - 0.6, true), 4), true));
  // Streaming writer: data size 0xFFFFFFFF, clamped to the file.
  const stream = wav.encodeWav([R.subarray(0, 50)], 16000, 16);
  new DataView(stream.buffer).setUint32(40, 0xffffffff, true);
  dec('streaming data size', stream);

  write('dsp/wav.json', { encodes, decodes });
}

// ---------------------------------------------------------------------------
// timing/*.json
// ---------------------------------------------------------------------------

function timingFixture() {
  // offsets
  const r = rng(3);
  const clockSamples = Array.from({ length: 41 }, (_, i) => ({ ctxTime: 5 + i * 0.023, recSec: i === 0 ? 0 : i * 0.023 - 0.0123 + (r() - 0.5) * 0.004 }));
  const offsetCases = {
    recStart: { samples: clockSamples, out: offsets.estimateRecorderStartCtx(clockSamples) },
    medians: [[3, 1, 2], [4, 1, 3, 2], [5], [2.5, -1, 7.25, 0, 0]].map((v) => ({ in: v, out: offsets.median(v) })),
    drumOffsets: [
      { songStartSec: 30, songCtxStart: 12, recStartCtx: 10, latencySec: 0.12 },
      { songStartSec: 0, songCtxStart: 3.7, recStartCtx: 3.5123, latencySec: 0.0234 },
    ].map((i) => ({ in: i, out: offsets.computeDrumOffset(i) })),
    schedules: [
      [5, 0.25, 120, 4],
      [1.1, 0.1, 97.3, 3],
      [0, 0, 1e6, 1],
      [2, 0.5, NaN, 2],
      [2, 0.5, 10, 0],
    ].map(([now, lead, bpm, beats]) => ({ now, lead, bpm: Number.isNaN(bpm) ? 'NaN' : bpm, beats, out: offsets.scheduleCountIn(now, lead, bpm, beats) })),
    transport: [
      [4, 5, 30, null],
      [6.5, 5, 30, null],
      [10, 5, 30, { start: 30, end: 34 }],
      [8, 5, 30, { start: 30, end: 34 }],
      [123.456, 5, 30, { start: 31.5, end: 33.25 }],
      [20, 5, 30, { start: 34, end: 34 }],
    ].map(([now, sc, ss, loop]) => ({ now, songCtxStart: sc, songStartSec: ss, loop, out: offsets.transportPosition(now as number, sc as number, ss as number, loop as never) })),
    drumStart: [
      [30, 28],
      [30, 31],
      [12.25, 12.25],
    ].map(([s, o]) => ({ songSec: s, drumOffsetSec: o, out: offsets.drumStartFor(s, o) })),
  };

  // peaks
  const sig = Float32Array.from({ length: 10000 }, (_, i) => Math.sin(i * 0.37) * Math.exp(-i / 3000));
  const peakCases = [
    [8000, 0, 1.25, 16, 0],
    [8000, 0.5, 1, 7, 0.25],
    [100, 0, 200, 9, -3],
    [8000, 1, 1, 4, 0],
    [8000, 0, 2, 0, 0],
  ].map(([sr, a, b, cols, off]) => ({ sampleRate: sr, startSec: a, endSec: b, columns: cols, offsetSec: off, out: Array.from(peaks.windowPeaks(sig, sr, a, b, cols, off)) }));
  const monoIn = [Float32Array.from([0.1, 0.2, -0.3]), Float32Array.from([0.3, -0.25, 0.7])];

  // clicks
  const clicks = [
    { sampleRate: 48000, opts: click.BEAT_CLICK },
    { sampleRate: 44100, opts: click.ACCENT_CLICK },
    { sampleRate: 16000, opts: {} },
  ].map((c) => ({ ...c, out: f32(click.makeClick(c.sampleRate, c.opts)) }));

  // calibration: matched filter on a small signal + full estimates on synth signals
  const mf = Float32Array.from({ length: 700 }, () => r() * 2 - 1);
  const tpl = Float32Array.from({ length: 33 }, (_, i) => Math.sin(i / 3) * Math.exp(-i / 10));
  const synthCases = [
    { delayMs: 137.3, gain: 0.25, noise: 0.02, seed: 1 },
    { delayMs: 42.1, gain: 0.3, noise: 0.01, polarity: -1, lowpass: true, seed: 7 },
    { delayMs: 230, gain: 0.08, noise: 0.03, seed: 3 },
    { delayMs: 100, gain: 0, noise: 0.05, seed: 11 },
  ].map((o) => {
    const { x, clickTimes } = calSynth(o);
    return { synth: o, clickTimes, est: calib.estimateLatency(x, 48000, clickTimes), head: f32(x.slice(14000, 15000)) };
  });

  write('timing/timing.json', {
    offsets: offsetCases,
    peaks: { signal: f32(sig), cases: peakCases, toMono: { in: chans(monoIn), out: f32(peaks.toMono(monoIn)) } },
    clicks,
    matchedFilter: { x: f32(mf), t: f32(tpl), out: f32(calib.matchedFilter(mf, tpl)) },
    calibration: synthCases,
  });

  // video sync
  const q = 256 / 48000;
  const pairs = Array.from({ length: 60 }, (_, i) => {
    const wall = 200_000 + i * 25.3;
    return { wallMs: wall, ctxSec: Math.floor((wall / 1000 - 100) / q) * q };
  });
  pairs.push({ wallMs: 1, ctxSec: 0 });
  const progress = Array.from({ length: 40 }, (_, i) => ({ wallMs: 111_400 + (i + 1) * 100 + ((i * 7) % 20), durationSec: Math.floor((i + 1) * 3) / 30 }));
  progress.push({ wallMs: 111_350, durationSec: 0 });
  const pairs2 = Array.from({ length: 50 }, (_, i) => ({ wallMs: 110_000 + i * 25, ctxSec: (110_000 + i * 25) / 1000 - 100 }));
  const timingIn = [
    { pairs: pairs2, progress, recordCallWallMs: 111_000, songStartSec: 30, songCtxStart: 12, latencyMs: 108 },
    { pairs: pairs2, progress: [], recordCallWallMs: 111_000, songStartSec: 30, songCtxStart: 12, latencyMs: 108 },
    { pairs: pairs2, progress: [{ wallMs: 110_100, durationSec: 1 }], recordCallWallMs: 111_000, songStartSec: 30, songCtxStart: 12, latencyMs: 3 },
    { pairs: [], progress, recordCallWallMs: 0, songStartSec: 0, songCtxStart: 0, latencyMs: 0 },
  ];
  write('timing/videoSync.json', {
    wallToCtx: { pairs, out: vsync.wallToCtxOffset(pairs) },
    quantiles: [
      [[3, 1, 2], 0.5],
      [[0, 10], 0.25],
      [[5], 0.9],
      [[4, 8, 1, 9, 2], 0.1],
      [[4, 8, 1, 9, 2], 1.5],
      [[4, 8, 1, 9, 2], -1],
    ].map(([v, qq]) => ({ values: v, q: qq, out: vsync.quantile(v as number[], qq as number) })),
    startWall: { progress, out: vsync.estimateVideoStartWall(progress), out25: vsync.estimateVideoStartWall(progress, 0.25) },
    outputLatency: [108, 2, 8, 250.5].map((ms) => ({ ms, out: vsync.outputLatencySec(ms) })),
    timings: timingIn.map((i) => ({ in: i, out: vsync.videoTiming(i) })),
    plans: [
      [28.5, 40, 200],
      [-0.4, 10, 200],
      [195, 10, 200],
      [300, 10, 200],
      [199.97, 10, 200],
    ].map(([o, d, m]) => {
      const plan = vsync.planVideoExport(o, d, m);
      return { videoOffsetSec: o, videoDurationSec: d, mixDurationSec: m, out: plan, range: plan ? vsync.sampleRange(plan, 44100, Math.round(m * 44100)) : null };
    }),
    startFor: [
      [30, 28, 10],
      [27, 28, 10],
      [40, 28, 10],
      [40, 28, 0],
    ].map(([s, o, d]) => ({ songSec: s, videoOffsetSec: o, videoDurationSec: d, out: vsync.videoStartFor(s, o, d) })),
  });
}

// Same synth as tests/calibration.test.ts (ported to Swift in TimingCalibrationTests).
function calSynth(opts: { delayMs: number; gain: number; noise: number; polarity?: number; seed?: number; lowpass?: boolean }) {
  const SR = 48000;
  const clickTimes = Array.from({ length: 8 }, (_, i) => 0.3 + i * 0.5);
  const x = new Float32Array(Math.round(SR * 5));
  let s = (opts.seed ?? 1) >>> 0;
  const r = () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
  const gaussian = () => {
    const u = Math.max(1e-12, r());
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * r());
  };
  for (let i = 0; i < x.length; i++) x[i] = opts.noise * gaussian() + 0.05 * Math.sin((2 * Math.PI * 60 * i) / SR);
  const clk = click.makeClick(SR, click.BEAT_CLICK);
  const delay = (opts.delayMs / 1000) * SR;
  for (const t of clickTimes) {
    const start = t * SR + delay;
    const i0 = Math.floor(start);
    const frac = start - i0;
    for (let k = 0; k < clk.length; k++) {
      const v = (1 - frac) * clk[k] + frac * (clk[k - 1] ?? 0);
      x[i0 + k] += (opts.polarity ?? 1) * opts.gain * v;
    }
    for (let k = 0; k < clk.length; k++) x[i0 + k + 336] += 0.3 * opts.gain * clk[k];
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

async function main() {
  effectsFixture();
  blanketFixture();
  await renderFixture();
  mixFixture();
  wavFixture();
  timingFixture();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
