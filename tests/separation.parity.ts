// Parity check: TS STFT/chunking + ONNX graph vs PyTorch demucs apply_model.
// Needs LUMBER_MODEL (htdemucs_core.onnx) and LUMBER_REF (dir with mix.wav and
// ref_stems.f32 from scripts/separation/make_reference.py). Skips otherwise.
//   LUMBER_MODEL=... LUMBER_REF=... npx tsx tests/separation.parity.ts

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import * as ort from 'onnxruntime-node';
import { separate, SAMPLE_RATE } from '../src/separation/demucs';
import { ortRunner } from '../src/separation/ort';

function readFloatWav(path: string): Float32Array[] {
  const buf = readFileSync(path);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let p = 12;
  let channels = 0;
  let bits = 0;
  let format = 0;
  while (p < buf.length) {
    const id = buf.toString('ascii', p, p + 4);
    const size = dv.getUint32(p + 4, true);
    if (id === 'fmt ') {
      format = dv.getUint16(p + 8, true);
      channels = dv.getUint16(p + 10, true);
      bits = dv.getUint16(p + 22, true);
      if (format === 0xfffe) format = dv.getUint16(p + 32, true);
    } else if (id === 'data') {
      if (format !== 3 || bits !== 32) throw new Error('expected float32 wav');
      const frames = size / 4 / channels;
      const out = Array.from({ length: channels }, () => new Float32Array(frames));
      for (let i = 0; i < frames; i++)
        for (let c = 0; c < channels; c++) out[c][i] = dv.getFloat32(p + 8 + (i * channels + c) * 4, true);
      return out;
    }
    p += 8 + size + (size & 1);
  }
  throw new Error('no data chunk');
}

function snrDb(ref: Float32Array, est: Float32Array): number {
  let s = 0;
  let e = 0;
  for (let i = 0; i < ref.length; i++) {
    s += ref[i] * ref[i];
    e += (ref[i] - est[i]) ** 2;
  }
  return 10 * Math.log10(s / Math.max(e, 1e-30));
}

async function main() {
  const model = process.env.LUMBER_MODEL;
  const refDir = process.env.LUMBER_REF;
  if (!model || !refDir) {
    console.log('separation parity: skipped (set LUMBER_MODEL and LUMBER_REF)');
    return;
  }
  const mix = readFloatWav(join(refDir, 'mix.wav'));
  const n = mix[0].length;
  const raw = readFileSync(join(refDir, 'ref_stems.f32'));
  const ref = new Float32Array(raw.buffer, raw.byteOffset, raw.byteLength / 4); // (4, 2, n)
  const refStem = (s: number, c: number) => ref.subarray((s * 2 + c) * n, (s * 2 + c + 1) * n);

  const session = await ort.InferenceSession.create(model, { executionProviders: ['cpu'] });
  const drums = [new Float32Array(n), new Float32Array(n)];
  const noDrums = [new Float32Array(n), new Float32Array(n)];
  let pos = 0;
  const t0 = Date.now();
  await separate(mix, ortRunner(session, ort.Tensor), {
    write(d, nd) {
      for (let c = 0; c < 2; c++) {
        drums[c].set(d[c], pos);
        noDrums[c].set(nd[c], pos);
      }
      pos += d[0].length;
    },
  });
  const secs = (Date.now() - t0) / 1000;
  if (pos !== n) throw new Error(`wrote ${pos} samples, expected ${n}`);

  let worst = Infinity;
  for (let c = 0; c < 2; c++) {
    const refRest = new Float32Array(n);
    for (let s = 1; s < 4; s++) {
      const r = refStem(s, c);
      for (let i = 0; i < n; i++) refRest[i] += r[i];
    }
    const sd = snrDb(refStem(0, c), drums[c]);
    const sn = snrDb(refRest, noDrums[c]);
    console.log(`ch${c}: drums ${sd.toFixed(1)} dB, no-drums ${sn.toFixed(1)} dB vs PyTorch`);
    worst = Math.min(worst, sd, sn);
  }
  console.log(`${(n / SAMPLE_RATE).toFixed(1)} s of audio separated in ${secs.toFixed(1)} s (CPU)`);
  if (worst < 60) throw new Error(`separation parity too low: ${worst.toFixed(1)} dB (want ≥ 60 dB)`);
  console.log('separation parity: ok');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
