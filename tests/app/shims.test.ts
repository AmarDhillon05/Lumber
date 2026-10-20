import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mixTake, resample } from '../../src/app-shims/mix';
import { encodeWav, decodeWav } from '../../src/app-shims/wav';

test('mixTake places drums at the offset and limits to -1 dBFS', () => {
  const sr = 1000;
  const song = [new Float32Array(1000).fill(0.5)];
  const drums = [new Float32Array(100).fill(0.9)];
  const out = mixTake({ song, drums, sampleRate: sr, drumOffsetSec: 0.5, songGain: 1, drumGain: 1 });
  const ceil = Math.pow(10, -1 / 20);
  assert.ok(Math.abs(out[0][100] - 0.5) < 1e-6);
  for (const v of out[0]) assert.ok(Math.abs(v) <= ceil + 1e-6);
  assert.ok(out[0][550] > 0.85); // summed and limited
});

test('mixTake trims drums that start before the song', () => {
  const out = mixTake({
    song: [new Float32Array(10)],
    drums: [Float32Array.from([1, 2, 3, 4].map((x) => x / 10))],
    sampleRate: 10,
    drumOffsetSec: -0.2,
    songGain: 1,
    drumGain: 1,
  });
  assert.ok(Math.abs(out[0][0] - 0.3) < 1e-6);
});

test('wav round trip 16/24/32', () => {
  const ch = [Float32Array.from([0, 0.5, -0.5, 0.25]), Float32Array.from([0.1, -0.1, 0.9, -0.9])];
  for (const bits of [16, 24, 32] as const) {
    const back = decodeWav(encodeWav(ch, 44100, bits));
    assert.equal(back.sampleRate, 44100);
    for (let c = 0; c < 2; c++) for (let i = 0; i < 4; i++) assert.ok(Math.abs(back.channels[c][i] - ch[c][i]) < 1e-3);
  }
});

test('resample length', () => {
  assert.equal(resample([new Float32Array(441)], 44100, 48000)[0].length, 480);
});
