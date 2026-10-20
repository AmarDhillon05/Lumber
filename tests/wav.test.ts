import { encodeWav, decodeWav } from '../src/dsp/wav';
import type { Channels } from '../src/dsp/types';
import { ok, section, tone } from './harness';

const maxErr = (a: Float32Array, b: Float32Array) => {
  let e = 0;
  for (let i = 0; i < a.length; i++) e = Math.max(e, Math.abs(a[i] - b[i]));
  return e;
};

export function run(): void {
  section('wav');

  const sr = 44100;
  const n = 4411; // odd length → exercises the 24-bit mono pad byte
  const L = tone(440, 0.8, n, sr);
  const R = tone(660, -0.6, n, sr);
  const stereo: Channels = [L, R];

  for (const [depth, tol] of [
    [16, 1 / 32768],
    [24, 1 / 8388608],
    [32, 0],
  ] as const) {
    const bytes = encodeWav(stereo, sr, depth);
    const back = decodeWav(bytes);
    const e = Math.max(maxErr(L, back.channels[0]), maxErr(R, back.channels[1]));
    ok(
      `wav ${depth === 32 ? '32f' : depth}-bit round trip`,
      back.sampleRate === sr && back.channels.length === 2 && back.channels[0].length === n && e <= tol,
      `maxerr=${e.toExponential(2)}`,
    );
  }

  // header sanity for the default (16-bit)
  {
    const bytes = encodeWav(stereo, sr);
    const v = new DataView(bytes.buffer);
    ok(
      'wav 16-bit header',
      bytes.length === 44 + n * 4 && v.getUint32(4, true) === bytes.length - 8 && v.getUint16(22, true) === 2,
    );
  }

  // odd data size gets a pad byte and still decodes
  {
    const mono: Channels = [tone(440, 0.5, n, sr)];
    const bytes = encodeWav(mono, sr, 24);
    const v = new DataView(bytes.buffer);
    const back = decodeWav(bytes);
    ok(
      'wav 24-bit odd-size padded',
      bytes.length % 2 === 0 && v.getUint32(4, true) === bytes.length - 8 && back.channels[0].length === n,
    );
  }

  // out-of-range samples clip instead of wrapping
  {
    const back = decodeWav(encodeWav([Float32Array.from([1.5, -1.5, 1, -1])], sr, 16));
    const c = back.channels[0];
    ok('wav 16-bit clips', c[0] > 0.999 && c[1] === -1 && c[2] > 0.999 && c[3] === -1);
  }

  // unknown chunks before data are skipped
  {
    const plain = encodeWav([Float32Array.from([0.25, -0.25])], 8000, 16);
    const list = new Uint8Array(8 + 5 + 1); // 'LIST', size 5, body, pad
    list.set([0x4c, 0x49, 0x53, 0x54, 5, 0, 0, 0, 1, 2, 3, 4, 5, 0]);
    const out = new Uint8Array(plain.length + list.length);
    out.set(plain.subarray(0, 36), 0); // RIFF + fmt
    out.set(list, 36);
    out.set(plain.subarray(36), 36 + list.length);
    new DataView(out.buffer).setUint32(4, out.length - 8, true);
    const back = decodeWav(out);
    ok('wav skips unknown chunks', back.sampleRate === 8000 && back.channels[0][0] === 0.25 && back.channels[0][1] === -0.25);
  }

  {
    let threw = false;
    try {
      decodeWav(new Uint8Array(16));
    } catch {
      threw = true;
    }
    ok('wav rejects non-RIFF', threw);
  }
}
