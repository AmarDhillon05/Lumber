// Golden fixtures for the Swift port of the Demucs pipeline
// (native/LumberCore/Sources/LumberCore/Separation). Runs the TypeScript
// pipeline — itself checked against PyTorch demucs at ~95 dB — on
// deterministic signals with a deterministic fake model, and stores sampled
// outputs plus per-channel sums so the Swift tests can compare.
//   npx tsx scripts/native/fixtures-separation.ts

import { writeFileSync } from 'node:fs';
import { BINS, FRAMES, SEGMENT, separate, spectrogram, type DemucsRunner } from '../../src/separation/demucs';

const OUT = 'native/LumberCore/Tests/LumberCoreTests/Fixtures/separation/separation.json';

// Same formulas in tests/…/SeparationTests.swift.
export function signal(n: number): [Float32Array, Float32Array] {
  const l = new Float32Array(n);
  const r = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    l[i] = 0.5 * Math.sin(i * 0.01) + 0.3 * Math.sin(i * 0.0371 + 1) + 0.1 * Math.sin(i * 0.5);
    r[i] = 0.4 * Math.sin(i * 0.013 + 0.5) + 0.2 * Math.sin(i * 0.11) + 0.05;
  }
  return [l, r];
}

// Fake model: each source gets a fixed share of the input spectrogram and of
// the mix waveform.
const SPEC = [0.6, 0.2, 0.15, 0.05];
const WAVE = [0.05, 0.02, 0.01, 0.0];
const fakeRunner: DemucsRunner = {
  async run(mix, mag) {
    const plane = BINS * FRAMES;
    const spec = new Float32Array(16 * plane);
    for (let s = 0; s < 4; s++)
      for (let c = 0; c < 4; c++) {
        const base = (s * 4 + c) * plane;
        for (let x = 0; x < plane; x++) spec[base + x] = mag[c * plane + x] * SPEC[s];
      }
    const wave = new Float32Array(8 * SEGMENT);
    for (let s = 0; s < 4; s++)
      for (let ch = 0; ch < 2; ch++) {
        const base = (s * 2 + ch) * SEGMENT;
        for (let x = 0; x < SEGMENT; x++) wave[base + x] = mix[ch * SEGMENT + x] * WAVE[s];
      }
    return { spec, wave };
  },
};

const sample = (a: Float32Array, step: number) => {
  const idx: number[] = [];
  const val: number[] = [];
  for (let i = 0; i < a.length; i += step) {
    idx.push(i);
    val.push(a[i]);
  }
  return { idx, val };
};
const stats = (a: Float32Array) => {
  let s = 0;
  let s2 = 0;
  for (const v of a) {
    s += v;
    s2 += v * v;
  }
  return { sum: s, sumSq: s2 };
};

async function run(n: number) {
  const input = signal(n);
  const outs = [new Float32Array(n), new Float32Array(n), new Float32Array(n), new Float32Array(n)];
  let pos = 0;
  let blocks = 0;
  await separate(input, fakeRunner, {
    write(d, nd) {
      [d[0], d[1], nd[0], nd[1]].forEach((b, k) => outs[k].set(b, pos));
      pos += d[0].length;
      blocks++;
    },
  });
  return { n, blocks, channels: outs.map((o) => ({ ...sample(o, 997), ...stats(o) })) };
}

(async () => {
  const [l, r] = signal(SEGMENT);
  const mag = spectrogram(l, r);
  const fixture = {
    spectrogram: { ...sample(mag, 4999), ...stats(mag) },
    single: await run(2 * 44100),
    multi: await run(SEGMENT * 2 + 12345),
  };
  writeFileSync(OUT, JSON.stringify(fixture));
  console.log(`wrote ${OUT}`);
})();
