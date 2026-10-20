import { ok, section } from './harness';
import {
  computeDrumOffset,
  drumStartFor,
  estimateRecorderStartCtx,
  scheduleCountIn,
  songToDrumTime,
  transportPosition,
} from '../src/audio/offsets';
import { windowPeaks } from '../src/audio/peaks';

const close = (a: number, b: number, eps = 1e-9) => ok(`${a} ≈ ${b}`, Math.abs(a - b) < eps);

export function run(): void {
  section('recorder start from jittery clock pairs is the median');
  {
  // True start = 10.0; pairs jitter by up to one 256-frame buffer (~5.3 ms).
  const buf = 256 / 48000;
  const samples = [];
  for (let i = 0; i < 101; i++) {
    const t = 10.2 + i * 0.02;
    const jitter = ((i * 37) % 11) / 10 - 0.5; // -0.5..0.5 buffers, centered
    samples.push({ ctxTime: t, recSec: t - 10 + jitter * buf });
  }
  samples.push({ ctxTime: 10.05, recSec: 0 }); // before audio flowed: ignored
  const est = estimateRecorderStartCtx(samples)!;
  ok('recStart within half a buffer', Math.abs(est - 10) < buf / 2, `est ${est}`);
  ok('no flowing samples → null', estimateRecorderStartCtx([{ ctxTime: 1, recSec: 0 }]) === null);
  }
  section('drum offset: perfect hit lands on the beat it was played to');
  {
  // Song started from 30 s at ctx 12.0; recorder started at ctx 10.0; 120 ms round trip.
  const songStartSec = 30;
  const songCtxStart = 12;
  const recStartCtx = 10;
  const latencySec = 0.12;
  const offset = computeDrumOffset({ songStartSec, songCtxStart, recStartCtx, latencySec });
  // A drummer hits exactly with song time 31.5 s as heard. It was scheduled at
  // ctx 13.5, heard + recorded with the round trip → ctx 13.62 → file 3.62 s.
  const fileTime = 13.5 + latencySec - recStartCtx;
  close(offset + fileTime, 31.5);
  close(songToDrumTime(31.5, offset), fileTime);
  }
  section('count-in schedule');
  {
  const s = scheduleCountIn(5, 0.25, 120, 4);
  ok('deepEqual', JSON.stringify(s.clickTimes) === JSON.stringify([5.25, 5.75, 6.25, 6.75]));
  close(s.songCtxStart, 7.25);
  const none = scheduleCountIn(5, 0.25, 120, 0);
  ok('no count-in clicks', none.clickTimes.length === 0);
  close(none.songCtxStart, 5.25);
  close(scheduleCountIn(0, 0, 1e6, 1).beatSec, 60 / 300); // bpm clamped
  }
  section('transport position with count-in and loop');
  {
  close(transportPosition(4, 5, 30), 30); // still counting in
  close(transportPosition(6.5, 5, 30), 31.5);
  const loop = { start: 30, end: 34 };
  close(transportPosition(5 + 5, 5, 30, loop), 31); // 35 wraps to 31
  close(transportPosition(5 + 3, 5, 30, loop), 33);
  }
  section('drum start for preview');
  {
  ok('deepEqual', JSON.stringify(drumStartFor(30, 28)) === JSON.stringify({ delaySec: 0, offsetSec: 2 }));
  ok('deepEqual', JSON.stringify(drumStartFor(30, 31)) === JSON.stringify({ delaySec: 1, offsetSec: 0 }));
  }
  section('window peaks honour the signal offset');
  {
  const sr = 100;
  const sig = new Float32Array(100); // 1 s
  sig[50] = 1; // at 0.5 s signal time
  const p = windowPeaks(sig, sr, 0, 4, 4, 2); // signal placed at 2 s
  ok('deepEqual', JSON.stringify(Array.from(p)) === JSON.stringify([0, 0, 1, 0]));
  }
}
