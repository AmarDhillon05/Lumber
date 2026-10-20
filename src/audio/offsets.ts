// Pure timing math for lining a recorded drum take up with the song.
//
// Clocks involved (all seconds):
//   ctx time   — AudioContext.currentTime. Song playback is scheduled on it.
//   file time  — position inside the recorded drum WAV (0 = first mic sample).
//   song time  — position inside the song file.
//
// The mic recorder runs on the same audio engine as the context, so file time
// and ctx time differ by a constant: recStartCtx (the ctx time at which file
// sample 0 was captured). We estimate it by sampling (ctx.currentTime,
// recorder.getCurrentDuration()) pairs while recording.
//
// What the drummer plays along to is the song as *heard*: output latency
// later than scheduled. What lands in the file is that hit plus input latency.
// Both are lumped into one round-trip latency measured by calibration (which
// runs through the exact same code path, so any constant bias in the
// recStartCtx estimate is absorbed there too).

export interface ClockSample {
  ctxTime: number; // AudioContext.currentTime when sampled
  recSec: number; // recorder.getCurrentDuration() at the same moment
}

/**
 * Estimate the ctx time of the recorder's first sample from (ctx, recorder)
 * clock pairs. Both clocks advance in hardware-buffer steps, so a single pair
 * can be off by a buffer; the median of many is stable. Pairs taken before
 * any audio was written (recSec <= 0) carry no information and are skipped.
 */
export function estimateRecorderStartCtx(samples: ClockSample[]): number | null {
  const diffs = samples.filter((s) => s.recSec > 0).map((s) => s.ctxTime - s.recSec);
  if (diffs.length === 0) return null;
  return median(diffs);
}

export function median(values: number[]): number {
  const v = [...values].sort((a, b) => a - b);
  const mid = v.length >> 1;
  return v.length % 2 ? v[mid] : (v[mid - 1] + v[mid]) / 2;
}

export interface DrumOffsetInput {
  songStartSec: number; // song position playback started from
  songCtxStart: number; // ctx time the song source was scheduled to start
  recStartCtx: number; // ctx time of the drum file's first sample
  latencySec: number; // round-trip output+input latency to compensate
}

/**
 * Song-timeline position where drum-file time 0 belongs. Place the drum file
 * so that its sample t sits at song time (drumOffsetSec + t).
 *
 * A hit recorded at file time t happened at ctx time recStartCtx + t, in
 * response to song audio scheduled latencySec earlier, i.e. at song time
 *   songStartSec + (recStartCtx + t - latencySec - songCtxStart).
 * Usually negative-ish relative to songStartSec, because the recorder starts
 * before the count-in and the song.
 */
export function computeDrumOffset(i: DrumOffsetInput): number {
  return i.songStartSec + (i.recStartCtx - i.songCtxStart) - i.latencySec;
}

/** Song time → drum-file time for a take placed at drumOffsetSec. */
export function songToDrumTime(songSec: number, drumOffsetSec: number): number {
  return songSec - drumOffsetSec;
}

export interface Schedule {
  clickTimes: number[]; // ctx times of count-in clicks (first is the accent)
  songCtxStart: number; // ctx time the song starts
  beatSec: number;
}

/**
 * Lay out a count-in followed by the song, starting `leadSec` after `now`.
 * With countInBeats = 0 the song starts right at now + leadSec.
 */
export function scheduleCountIn(now: number, leadSec: number, bpm: number, countInBeats: number): Schedule {
  const beatSec = 60 / clampBpm(bpm);
  const t0 = now + leadSec;
  const clickTimes = Array.from({ length: Math.max(0, countInBeats) }, (_, i) => t0 + i * beatSec);
  return { clickTimes, songCtxStart: t0 + Math.max(0, countInBeats) * beatSec, beatSec };
}

export function clampBpm(bpm: number): number {
  if (!Number.isFinite(bpm)) return 120;
  return Math.min(300, Math.max(30, bpm));
}

/**
 * Song position for a transport that started the song at ctx time
 * songCtxStart from songStartSec. Before the start (count-in) it returns
 * songStartSec. With a loop the position wraps inside [loopStart, loopEnd).
 */
export function transportPosition(
  now: number,
  songCtxStart: number,
  songStartSec: number,
  loop?: { start: number; end: number } | null,
): number {
  const elapsed = Math.max(0, now - songCtxStart);
  const pos = songStartSec + elapsed;
  if (!loop || loop.end <= loop.start || pos < loop.end) return pos;
  const len = loop.end - loop.start;
  return loop.start + ((pos - loop.start) % len);
}

/**
 * For preview playback: given a song position, where to start the drum
 * buffer and how long to wait before starting it (when the drums begin later
 * in the song than the playhead).
 */
export function drumStartFor(songSec: number, drumOffsetSec: number): { delaySec: number; offsetSec: number } {
  const t = songToDrumTime(songSec, drumOffsetSec);
  return t >= 0 ? { delaySec: 0, offsetSec: t } : { delaySec: -t, offsetSec: 0 };
}
