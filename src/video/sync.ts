// Pure timing math for lining the camera clip up with the song timeline.
//
// Clocks involved:
//   wall time  — performance.now() in JS (ms). The only clock both the camera
//                events and the AudioContext can be read against.
//   ctx time   — AudioContext.currentTime (s). The song is scheduled on it.
//   video time — position inside the recorded clip (s, 0 = first frame).
//   song time  — position inside the song file (s); also the export timeline.
//
// Steps:
//   1. While recording, sample (wall, ctx.currentTime) pairs → wallToCtx.
//   2. expo-camera's onRecordingProgress reports the clip's recordedDuration
//      every ~100 ms. wall − duration at delivery is the wall time of the
//      first frame plus non-negative noise (frame quantization, capture
//      pipeline, event delivery), so a low percentile is the best estimate.
//      Fallback when no progress arrived: the wall time recordAsync was called.
//   3. A drummer hitting at video time v did so at ctx videoStartCtx + v,
//      while hearing song audio scheduled outputLatency earlier. So video
//      time 0 belongs at song time
//        songStartSec + (videoStartCtx − songCtxStart) − outputLatency.
//   Whatever bias remains (camera pipeline, latency split) is the per-project
//   "Video offset" nudge in Edit.

import { median } from '../audio/offsets';

export interface WallCtxPair {
  wallMs: number; // performance.now()
  ctxSec: number; // AudioContext.currentTime read right after
}

export interface ProgressSample {
  wallMs: number; // performance.now() when the event reached JS
  durationSec: number; // recordedDuration reported by the camera
}

/** ctx = wall/1000 + offset. Median of many pairs (ctx advances in render quanta). */
export function wallToCtxOffset(pairs: WallCtxPair[]): number | null {
  const d = pairs.filter((p) => Number.isFinite(p.ctxSec) && p.ctxSec > 0).map((p) => p.ctxSec - p.wallMs / 1000);
  return d.length ? median(d) : null;
}

/** q-quantile (0..1) with linear interpolation. */
export function quantile(values: number[], q: number): number {
  const v = [...values].sort((a, b) => a - b);
  if (v.length === 1) return v[0];
  const pos = Math.min(1, Math.max(0, q)) * (v.length - 1);
  const i = Math.floor(pos);
  const f = pos - i;
  return i + 1 < v.length ? v[i] + (v[i + 1] - v[i]) * f : v[i];
}

/** Wall time (ms) of the clip's first frame from progress events, or null. */
export function estimateVideoStartWall(samples: ProgressSample[], q = 0.1): number | null {
  const d = samples.filter((s) => s.durationSec > 0 && Number.isFinite(s.durationSec)).map((s) => s.wallMs - s.durationSec * 1000);
  return d.length ? quantile(d, q) : null;
}

// Built-in mic input latency on iPhone is a few ms; with Bluetooth output the
// mic stays built in, so most of the measured round trip is output.
export const INPUT_LATENCY_MS = 8;

/** Output (heard-later) share of the calibrated round-trip latency, seconds. */
export function outputLatencySec(roundTripMs: number, inputMs = INPUT_LATENCY_MS): number {
  return Math.max(0, roundTripMs - inputMs) / 1000;
}

export interface VideoOffsetInput {
  songStartSec: number;
  songCtxStart: number;
  videoStartCtx: number;
  outputLatencySec: number;
}

/** Song time where video time 0 belongs (see header). */
export function computeVideoOffset(i: VideoOffsetInput): number {
  return i.songStartSec + (i.videoStartCtx - i.songCtxStart) - i.outputLatencySec;
}

export interface VideoTimingInput {
  pairs: WallCtxPair[];
  progress: ProgressSample[];
  recordCallWallMs: number; // when recordAsync was called
  songStartSec: number;
  songCtxStart: number;
  latencyMs: number; // round-trip latency compensated for the drums
}

export interface VideoTiming {
  offsetSec: number; // song time of video time 0
  source: 'progress' | 'call'; // which start estimate was used
  durationSec: number; // from the last progress event (0 if none)
}

export function videoTiming(i: VideoTimingInput): VideoTiming | null {
  const off = wallToCtxOffset(i.pairs);
  if (off === null) return null;
  const fromProgress = estimateVideoStartWall(i.progress);
  // The first frame can't precede the call that started the recording.
  const usable = fromProgress !== null && fromProgress >= i.recordCallWallMs - 50;
  const startWall = usable ? fromProgress! : i.recordCallWallMs;
  const durationSec = i.progress.reduce((m, s) => Math.max(m, s.durationSec), 0);
  return {
    offsetSec: computeVideoOffset({
      songStartSec: i.songStartSec,
      songCtxStart: i.songCtxStart,
      videoStartCtx: startWall / 1000 + off,
      outputLatencySec: outputLatencySec(i.latencyMs),
    }),
    source: usable ? 'progress' : 'call',
    durationSec,
  };
}

/** Recorded offset plus the per-project nudge (positive = video later). */
export function finalVideoOffsetSec(offsetSec: number, nudgeMs: number | undefined): number {
  return offsetSec + (nudgeMs ?? 0) / 1000;
}

export interface VideoExportPlan {
  audioStartSec: number; // where to cut the mix (song time)
  videoStartSec: number; // where to cut the clip (video time)
  durationSec: number; // length of the output
}

/**
 * The output is the overlap of the clip (placed at videoOffsetSec on the song
 * timeline) and the rendered mix [0, mixDurationSec). Both get trimmed to it,
 * so there are no black or frozen frames and the audio is the exact mix.
 */
export function planVideoExport(videoOffsetSec: number, videoDurationSec: number, mixDurationSec: number): VideoExportPlan | null {
  const lo = Math.max(0, videoOffsetSec);
  const hi = Math.min(mixDurationSec, videoOffsetSec + videoDurationSec);
  if (!(hi - lo > 0.05)) return null;
  return { audioStartSec: lo, videoStartSec: lo - videoOffsetSec, durationSec: hi - lo };
}

/**
 * Preview: for a song position, where the clip should be and how long to
 * wait before it starts. null once the song position is past the clip.
 */
export function videoStartFor(
  songSec: number,
  videoOffsetSec: number,
  videoDurationSec: number,
): { delaySec: number; videoSec: number } | null {
  const t = songSec - videoOffsetSec;
  if (videoDurationSec > 0 && t >= videoDurationSec) return null;
  return t >= 0 ? { delaySec: 0, videoSec: t } : { delaySec: -t, videoSec: 0 };
}

/** Sample range [start, end) of a mix to keep for the export. */
export function sampleRange(plan: VideoExportPlan, sampleRate: number, totalSamples: number): [number, number] {
  const a = Math.max(0, Math.min(totalSamples, Math.round(plan.audioStartSec * sampleRate)));
  const b = Math.max(a, Math.min(totalSamples, a + Math.round(plan.durationSec * sampleRate)));
  return [a, b];
}
