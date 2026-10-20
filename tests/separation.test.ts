// Model-free checks for the separation pipeline. A fake runner that returns
// the input spectrogram as "drums" and silence for every other source must
// give back the input exactly — that exercises STFT → iSTFT reconstruction,
// the CaC layout and the overlap-add chunking end to end.
//   npx tsx tests/separation.test.ts

import assert from 'node:assert/strict';
import { BINS, FRAMES, SEGMENT, separate, type DemucsRunner } from '../src/separation/demucs';
import { FFT } from '../src/separation/fft';
import { WavStream, type ByteSink } from '../src/separation/wavStream';

const identityDrums: DemucsRunner = {
  async run(_mix, mag) {
    const spec = new Float32Array(16 * BINS * FRAMES);
    spec.set(mag, 0); // source 0 = drums, all 4 CaC planes
    return { spec, wave: new Float32Array(8 * SEGMENT) };
  },
};

function maxAbsDiff(a: Float32Array, b: Float32Array, from = 0): number {
  let m = 0;
  for (let i = from; i < a.length; i++) m = Math.max(m, Math.abs(a[i] - b[i]));
  return m;
}

async function runSeparate(input: Float32Array[]) {
  const n = input[0].length;
  const drums = [new Float32Array(n), new Float32Array(n)];
  const rest = [new Float32Array(n), new Float32Array(n)];
  let pos = 0;
  let calls = 0;
  await separate(input, identityDrums, {
    write(d, r) {
      for (let c = 0; c < 2; c++) {
        drums[c].set(d[c], pos);
        rest[c].set(r[c], pos);
      }
      pos += d[0].length;
      calls++;
    },
  });
  return { drums, rest, pos, calls };
}

const tests: [string, () => Promise<void> | void][] = [
  [
    'fft round trip',
    () => {
      const f = new FFT(4096);
      const re = Float64Array.from({ length: 4096 }, () => Math.random() - 0.5);
      const im = new Float64Array(4096);
      const orig = re.slice();
      f.transform(re, im);
      f.transform(re, im, true);
      for (let i = 0; i < 4096; i++) assert.ok(Math.abs(re[i] / 4096 - orig[i]) < 1e-12);
    },
  ],
  [
    'identity runner reconstructs a multi-chunk stereo input',
    async () => {
      const n = Math.floor(SEGMENT * 2.3);
      const l = Float32Array.from({ length: n }, (_, i) => 0.5 * Math.sin(i * 0.01) + 0.1 * (Math.random() - 0.5));
      const r = Float32Array.from({ length: n }, (_, i) => 0.3 * Math.sin(i * 0.003));
      const { drums, rest, pos, calls } = await runSeparate([l, r]);
      assert.equal(pos, n);
      assert.equal(calls, Math.ceil(n / Math.floor(0.75 * SEGMENT)));
      // demucs drops the first two STFT frames and re-pads them with zeros, so
      // the spectral path alone can't rebuild the song's first ~1200 samples
      // (the model's time branch covers them). Check from NFFT/2 on. The same
      // edge error leaks in at a tiny cross-fade weight where later chunks
      // start, as it does in demucs, hence the 5e-3 bound.
      const from = 2048;
      assert.ok(maxAbsDiff(drums[0], l, from) < 5e-3, `L err ${maxAbsDiff(drums[0], l, from)}`);
      assert.ok(maxAbsDiff(drums[1], r, from) < 5e-3, `R err ${maxAbsDiff(drums[1], r, from)}`);
      // Non-drum sources are silent, so no-drums is 3*mean of the mix ≈ 0.
      assert.ok(maxAbsDiff(rest[0], new Float32Array(n)) < 1e-2);
    },
  ],
  [
    'short mono input (shorter than one segment)',
    async () => {
      const n = 44100 * 2;
      const m = Float32Array.from({ length: n }, (_, i) => Math.sin(i * 0.05));
      const { drums, pos, calls } = await runSeparate([m]);
      assert.equal(pos, n);
      assert.equal(calls, 1);
      assert.ok(maxAbsDiff(drums[0], m) < 1e-4);
      assert.ok(maxAbsDiff(drums[1], m) < 1e-4);
    },
  ],
  [
    'wav stream writes a valid float32 header and patches sizes',
    async () => {
      const bytes: number[] = [];
      const sink: ByteSink = {
        offset: 0,
        writeBytes(b) {
          for (let i = 0; i < b.length; i++) bytes[this.offset! + i] = b[i];
          this.offset! += b.length;
        },
      };
      const w = await WavStream.open(sink, 44100, 2);
      await w.write([Float32Array.of(0.5, -0.5), Float32Array.of(0.25, 1)]);
      await w.finish();
      const u = Uint8Array.from(bytes);
      const dv = new DataView(u.buffer);
      assert.equal(String.fromCharCode(...u.slice(0, 4)), 'RIFF');
      assert.equal(dv.getUint16(20, true), 3);
      assert.equal(dv.getUint32(40, true), 16);
      assert.equal(u.length, 44 + 16);
      assert.deepEqual([0, 1, 2, 3].map((i) => dv.getFloat32(44 + 4 * i, true)), [0.5, 0.25, -0.5, 1]);
    },
  ],
];

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`  ok  ${name}`);
    } catch (e) {
      failed++;
      console.log(`  FAIL ${name}\n${e}`);
    }
  }
  console.log(failed ? `${failed} separation test(s) failed` : 'separation tests: all passed');
  if (failed) process.exit(1);
})();
