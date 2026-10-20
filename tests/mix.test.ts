import { mixTake, limitPeaks, normalizePeak, resample } from '../src/dsp/mix';
import type { Channels } from '../src/dsp/types';
import { ok, peak, section, tone, finite } from './harness';

const sr = 48000;
const ceil1 = Math.pow(10, -1 / 20);
const filled = (n: number, v: number) => new Float32Array(n).fill(v);
const ramp = (n: number) => Float32Array.from({ length: n }, (_, i) => i / n);
const base = { sampleRate: sr, songGain: 1, drumGain: 1, limit: false } as const;

// Max abs error of x[from..to) against an ideal sine.
function sineErr(x: Float32Array, freq: number, rate: number, amp: number, from: number, to: number): number {
  let e = 0;
  for (let i = from; i < to; i++) e = Math.max(e, Math.abs(x[i] - amp * Math.sin((2 * Math.PI * freq * i) / rate)));
  return e;
}

const rms = (x: Float32Array, from = 0, to = x.length) => {
  let s = 0;
  for (let i = from; i < to; i++) s += x[i] * x[i];
  return Math.sqrt(s / Math.max(1, to - from));
};

export function run(): void {
  section('mix');

  // positive offset: mono drums land at offset on both channels; length covers both
  {
    const song: Channels = [new Float32Array(sr), new Float32Array(sr)];
    const drums: Channels = [ramp(sr)];
    const out = mixTake({ ...base, song, drums, drumOffsetSec: 0.5 });
    const off = sr / 2;
    ok('positive offset: stereo out, length song∪drums', out.length === 2 && out[0].length === sr + off, `len=${out[0].length}`);
    ok(
      'positive offset: drums placed at offset on both channels',
      out[0][off - 1] === 0 && out[0][off + 100] === drums[0][100] && out[1][off + 100] === drums[0][100],
    );
  }

  // negative offset trims the drum start
  {
    const song: Channels = [new Float32Array(sr)];
    const drums: Channels = [ramp(sr)];
    const out = mixTake({ ...base, song, drums, drumOffsetSec: -0.25 });
    const trim = sr / 4;
    ok('negative offset: drum start trimmed', out[0][0] === drums[0][trim] && out[0][10] === drums[0][trim + 10]);
    ok('negative offset: length = max(song, drums − trim)', out[0].length === sr, `len=${out[0].length}`);
  }

  // drums entirely before the song start contribute nothing
  {
    const out = mixTake({ ...base, song: [filled(100, 0.1)], drums: [filled(50, 1)], drumOffsetSec: -1 });
    ok('drums fully trimmed: backing only', out[0].length === 100 && Math.abs(out[0][0] - 0.1) < 1e-7);
  }

  // gains
  {
    const out = mixTake({
      ...base,
      song: [filled(1000, 0.2), filled(1000, 0.2)],
      drums: [filled(1000, 0.4)],
      drumOffsetSec: 0,
      songGain: 0.5,
      drumGain: 0.25,
    });
    ok('gains: 0.2·0.5 + 0.4·0.25 = 0.2', Math.abs(out[0][500] - 0.2) < 1e-6 && Math.abs(out[1][500] - 0.2) < 1e-6);
  }

  // originalDrums: backing = noDrums + amount·drums, song ignored
  {
    const out = mixTake({
      ...base,
      song: [filled(1000, 9)],
      drums: [new Float32Array(1000)],
      drumOffsetSec: 0,
      songGain: 0.5,
      originalDrums: { noDrums: [filled(1000, 0.1)], drums: [filled(1000, 0.3)], amount: 0.5 },
    });
    ok('originalDrums: (0.1 + 0.5·0.3)·0.5', Math.abs(out[0][10] - 0.125) < 1e-6, `${out[0][10]}`);
  }

  // limiter: hot mix stays under −1 dBFS
  {
    const song: Channels = [tone(220, 1.5, sr, sr), tone(330, 1.5, sr, sr)];
    const drums: Channels = [tone(80, 1.2, sr, sr)];
    const out = mixTake({ ...base, limit: true, song, drums, drumOffsetSec: 0.1 });
    const p = Math.max(peak(out[0]), peak(out[1]));
    ok('limiter ceiling −1 dBFS', p <= ceil1 + 1e-6 && finite(out[0]), `peak=${(20 * Math.log10(p)).toFixed(3)} dB`);
  }

  // limiter leaves a signal under the ceiling untouched
  {
    const x = tone(440, 0.5, sr, sr);
    const ch: Channels = [Float32Array.from(x)];
    limitPeaks(ch, sr);
    ok('limiter transparent below ceiling', ch[0].every((v, i) => v === x[i]));
  }

  // limiter is local: a single spike only ducks around itself
  {
    const x = tone(440, 0.5, sr, sr);
    const at = sr / 2;
    x[at] = 2;
    const ch: Channels = [Float32Array.from(x)];
    limitPeaks(ch, sr, { lookaheadMs: 5, releaseMs: 50 });
    const L = Math.round(0.005 * sr);
    const far = at - 2 * L;
    ok(
      'limiter ducks spike, leaves earlier audio',
      Math.abs(ch[0][at]) <= ceil1 + 1e-7 && ch[0][far] === x[far] && Math.abs(ch[0][at + sr / 4] - x[at + sr / 4]) < 1e-3,
    );
  }

  // normalize: quiet mix brought up to the ceiling
  {
    const out = mixTake({
      ...base,
      limit: true,
      normalize: true,
      song: [tone(220, 0.1, sr, sr)],
      drums: [tone(110, 0.05, sr, sr)],
      drumOffsetSec: 0,
    });
    ok('normalize peak = ceiling', Math.abs(peak(out[0]) - ceil1) < 1e-6);
    const silent: Channels = [new Float32Array(10)];
    normalizePeak(silent);
    ok('normalize leaves silence alone', silent[0].every((v) => v === 0));
  }

  section('resample');

  // 44.1k → 48k: length and frequency preserved
  {
    const inLen = 44100;
    const x = tone(1000, 0.5, inLen, 44100);
    const [y] = resample([x], 44100, 48000);
    ok('44.1k→48k length', y.length === 48000, `len=${y.length}`);
    const e = sineErr(y, 1000, 48000, 0.5, 2000, 46000);
    ok('44.1k→48k 1 kHz sine preserved', e < 2e-3, `maxerr=${e.toExponential(2)}`);
  }

  // 48k → 44.1k, stereo, high tone near the passband edge
  {
    const L = tone(15000, 0.5, sr, sr);
    const R = tone(440, 0.5, sr, sr);
    const [yl, yr] = resample([L, R], 48000, 44100);
    ok('48k→44.1k length', yl.length === 44100 && yr.length === 44100);
    const el = sineErr(yl, 15000, 44100, 0.5, 2000, 42000);
    const er = sineErr(yr, 440, 44100, 0.5, 2000, 42000);
    ok('48k→44.1k sines preserved (15 kHz, 440 Hz)', el < 5e-3 && er < 2e-3, `err=${el.toExponential(2)},${er.toExponential(2)}`);
  }

  // anti-aliasing: a 23 kHz tone at 48k is above the 44.1k Nyquist → removed
  {
    const [y] = resample([tone(23000, 0.5, sr, sr)], 48000, 44100);
    const r = rms(y, 2000, 42000);
    ok('48k→44.1k rejects 23 kHz (alias)', r < 0.005, `rms=${r.toExponential(2)}`);
  }

  // non-rational-friendly ratio (interpolated phase table)
  {
    const x = tone(1000, 0.5, sr, sr);
    const [y] = resample([x], 48000, 47993);
    ok('48k→47993 length', y.length === Math.round((sr * 47993) / 48000));
    const e = sineErr(y, 1000, 47993, 0.5, 2000, 45000);
    ok('48k→47993 sine preserved', e < 3e-3, `maxerr=${e.toExponential(2)}`);
  }

  // same rate → copy
  {
    const x = ramp(100);
    const [y] = resample([x], 48000, 48000);
    ok('same-rate copy', y !== x && y.every((v, i) => v === x[i]));
  }
}
