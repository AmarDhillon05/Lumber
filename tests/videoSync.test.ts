import { ok, section } from './harness';
import {
  computeVideoOffset,
  estimateVideoStartWall,
  finalVideoOffsetSec,
  outputLatencySec,
  planVideoExport,
  quantile,
  sampleRange,
  videoStartFor,
  videoTiming,
  wallToCtxOffset,
} from '../src/video/sync';

const close = (name: string, a: number, b: number, eps = 1e-6) => ok(`${name}: ${a} ≈ ${b}`, Math.abs(a - b) < eps);

export function run(): void {
  section('video: wall ↔ ctx clock mapping');
  {
    // ctx = wall/1000 − 100, ctx steps in 256-frame quanta (~5.3 ms).
    const q = 256 / 48000;
    const pairs = [];
    for (let i = 0; i < 200; i++) {
      const wall = 200_000 + i * 25.3;
      const ctxTrue = wall / 1000 - 100;
      pairs.push({ wallMs: wall, ctxSec: Math.floor(ctxTrue / q) * q });
    }
    pairs.push({ wallMs: 1, ctxSec: 0 }); // context not running yet: ignored
    const off = wallToCtxOffset(pairs)!;
    ok('offset within one render quantum', Math.abs(off - -100) < q, `off ${off}`);
    ok('no pairs → null', wallToCtxOffset([]) === null);
  }

  section('video: start estimate from progress events');
  {
    // First frame at wall 10 000 ms; 30 fps → duration lags real time by up
    // to a frame; delivery adds 1–20 ms. Both only ever make wall − d larger.
    const samples = [];
    for (let i = 1; i <= 100; i++) {
      const wall = 10_000 + i * 100 + ((i * 7) % 20) + 1; // delivery delay
      const real = (wall - ((i * 7) % 20) - 1 - 10_000) / 1000;
      const dur = Math.floor(real * 30) / 30; // last written frame
      samples.push({ wallMs: wall, durationSec: dur });
    }
    samples.push({ wallMs: 10_050, durationSec: 0 }); // nothing written yet: ignored
    const est = estimateVideoStartWall(samples)!;
    ok('start within 25 ms, never early', est >= 10_000 && est - 10_000 < 25, `est ${est}`);
    ok('no progress → null', estimateVideoStartWall([]) === null);
    close('quantile mid', quantile([3, 1, 2], 0.5), 2);
    close('quantile interp', quantile([0, 10], 0.25), 2.5);
  }

  section('video: offset on the song timeline');
  {
    // Song from 30 s at ctx 12; video frame 0 at ctx 11.4; 108 ms round trip → 100 ms output.
    close('output latency', outputLatencySec(108), 0.1);
    ok('output latency never negative', outputLatencySec(2) === 0);
    const off = computeVideoOffset({ songStartSec: 30, songCtxStart: 12, videoStartCtx: 11.4, outputLatencySec: 0.1 });
    // A hit on song time 31 (heard at ctx 13.1) is filmed at video time 13.1 − 11.4 = 1.7.
    close('hit lands on its beat', off + 1.7, 31);
  }

  section('video: full timing from samples');
  {
    const wallOff = -100; // ctx = wall/1000 − 100
    const pairs = Array.from({ length: 50 }, (_, i) => {
      const wall = 110_000 + i * 25;
      return { wallMs: wall, ctxSec: wall / 1000 + wallOff };
    });
    // Frame 0 at wall 111 400 → ctx 11.4.
    const progress = Array.from({ length: 30 }, (_, i) => ({ wallMs: 111_400 + (i + 1) * 100, durationSec: (i + 1) * 0.1 }));
    const t = videoTiming({ pairs, progress, recordCallWallMs: 111_000, songStartSec: 30, songCtxStart: 12, latencyMs: 108 })!;
    ok('uses progress', t.source === 'progress');
    close('offset', t.offsetSec, 30 + (11.4 - 12) - 0.1);
    close('duration from last event', t.durationSec, 3);
    const noProg = videoTiming({ pairs, progress: [], recordCallWallMs: 111_000, songStartSec: 30, songCtxStart: 12, latencyMs: 108 })!;
    ok('falls back to the call time', noProg.source === 'call');
    close('fallback offset', noProg.offsetSec, 30 + (11.0 - 12) - 0.1);
    // A start estimate before the call is impossible → fallback.
    const bogus = videoTiming({
      pairs,
      progress: [{ wallMs: 110_100, durationSec: 1 }],
      recordCallWallMs: 111_000,
      songStartSec: 30,
      songCtxStart: 12,
      latencyMs: 108,
    })!;
    ok('rejects start before the call', bogus.source === 'call');
    ok('no clock pairs → null', videoTiming({ pairs: [], progress, recordCallWallMs: 0, songStartSec: 0, songCtxStart: 0, latencyMs: 0 }) === null);
    close('nudge', finalVideoOffsetSec(10, 250), 10.25);
    close('no nudge', finalVideoOffsetSec(10, undefined), 10);
  }

  section('video: export plan trims to the overlap');
  {
    // Clip of 40 s placed at song 28.5; mix 200 s long.
    const p = planVideoExport(28.5, 40, 200)!;
    close('audio start', p.audioStartSec, 28.5);
    close('video start', p.videoStartSec, 0);
    close('duration', p.durationSec, 40);
    // Clip starts before the song (offset −0.4): cut 0.4 s off the clip.
    const early = planVideoExport(-0.4, 10, 200)!;
    close('early audio start', early.audioStartSec, 0);
    close('early video start', early.videoStartSec, 0.4);
    close('early duration', early.durationSec, 9.6);
    // Clip runs past the end of the mix.
    const late = planVideoExport(195, 10, 200)!;
    close('late duration', late.durationSec, 5);
    ok('no overlap → null', planVideoExport(300, 10, 200) === null);
    const [a, b] = sampleRange(p, 48000, 200 * 48000);
    ok('sample range', a === 28.5 * 48000 && b === a + 40 * 48000, `${a}..${b}`);
    const [c, d] = sampleRange(late, 48000, 200 * 48000);
    ok('sample range clamped', d === 200 * 48000 && c === 195 * 48000);
  }

  section('video: preview start');
  {
    ok('inside', JSON.stringify(videoStartFor(30, 28, 10)) === JSON.stringify({ delaySec: 0, videoSec: 2 }));
    ok('before', JSON.stringify(videoStartFor(27, 28, 10)) === JSON.stringify({ delaySec: 1, videoSec: 0 }));
    ok('after the clip → null', videoStartFor(40, 28, 10) === null);
  }
}
