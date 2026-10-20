// Run the app's drum-removal pipeline on a desktop (Windows/macOS/Linux) to
// hear the quality on real songs before it's on the phone. Same TS code, with
// onnxruntime-node instead of onnxruntime-react-native.
//
//   npm run separate -- <song.(mp3|m4a|wav|...)> [out_dir]
//
// Non-WAV input needs ffmpeg on PATH. The model downloads to models/ once.

import { spawnSync } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, openSync, closeSync, writeSync } from 'node:fs';
import { basename, extname, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import * as ort from 'onnxruntime-node';
import { SAMPLE_RATE, separate } from '../src/separation/demucs';
import { MODEL_URL } from '../src/separation/model';
import { ortRunner } from '../src/separation/ort';
import { WavStream, type ByteSink } from '../src/separation/wavStream';

async function ensureModel(path: string) {
  if (existsSync(path)) return;
  mkdirSync(join(path, '..'), { recursive: true });
  console.log(`downloading model → ${path}`);
  const res = await fetch(MODEL_URL);
  if (!res.ok || !res.body) throw new Error(`model download failed: ${res.status}`);
  await pipeline(Readable.fromWeb(res.body as never), createWriteStream(path));
}

function decode(file: string): Float32Array[] {
  const r = spawnSync(
    'ffmpeg',
    ['-v', 'error', '-i', file, '-f', 'f32le', '-ac', '2', '-ar', String(SAMPLE_RATE), '-'],
    { maxBuffer: 2 ** 31 - 1 },
  );
  if (r.error || r.status !== 0)
    throw new Error(`ffmpeg failed (is it on PATH?): ${r.error ?? r.stderr.toString()}`);
  const all = new Float32Array(r.stdout.buffer, r.stdout.byteOffset, r.stdout.byteLength / 4);
  const n = all.length / 2;
  const l = new Float32Array(n);
  const rr = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    l[i] = all[2 * i];
    rr[i] = all[2 * i + 1];
  }
  return [l, rr];
}

function fileSink(path: string): ByteSink & { close(): void } {
  const fd = openSync(path, 'w');
  return {
    offset: 0,
    writeBytes(b) {
      writeSync(fd, b, 0, b.length, this.offset!);
      this.offset! += b.length;
    },
    close: () => closeSync(fd),
  };
}

async function main() {
  const [song, outArg] = process.argv.slice(2);
  if (!song) throw new Error('usage: npm run separate -- <song> [out_dir]');
  const out = outArg ?? join('separated', basename(song, extname(song)));
  mkdirSync(out, { recursive: true });

  const modelPath = join('models', 'htdemucs_core.onnx');
  await ensureModel(modelPath);
  const session = await ort.InferenceSession.create(modelPath, { executionProviders: ['cpu'] });

  const input = decode(song);
  console.log(`${(input[0].length / SAMPLE_RATE).toFixed(1)} s of audio`);
  const drumsSink = fileSink(join(out, 'drums.wav'));
  const restSink = fileSink(join(out, 'no_drums.wav'));
  const drums = await WavStream.open(drumsSink, SAMPLE_RATE, 2);
  const rest = await WavStream.open(restSink, SAMPLE_RATE, 2);
  const t0 = Date.now();
  await separate(
    input,
    ortRunner(session, ort.Tensor),
    {
      async write(d, n) {
        await drums.write(d);
        await rest.write(n);
      },
    },
    (f) => process.stdout.write(`\r${Math.round(f * 100)}%`),
  );
  await drums.finish();
  await rest.finish();
  drumsSink.close();
  restSink.close();
  console.log(`\ndone in ${((Date.now() - t0) / 1000).toFixed(1)} s → ${out}/drums.wav, no_drums.wav`);
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
