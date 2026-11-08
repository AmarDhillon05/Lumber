// Camera-free glue between the Record screen's camera panel and the take.

import type { TakeVideo } from '../state/types';
import { videoTiming, type ProgressSample, type WallCtxPair } from './sync';

export interface CameraClip {
  uri: string;
  facing: 'front' | 'back';
  recordCallWallMs: number;
  progress: ProgressSample[];
  pairs: WallCtxPair[];
}

export interface CameraPanelHandle {
  /** Starts filming if the camera is on and ready. Returns whether it started. */
  start(): boolean;
  /** Stops filming now; resolves with the clip once the file is written (null if not filming). */
  stop(): Promise<CameraClip | null>;
}

/** Turns a finished clip into the take's video metadata (null if it can't be placed). */
export function takeVideoFrom(
  clip: CameraClip,
  timing: { songStartSec: number; songCtxStart: number; latencyMs: number },
): TakeVideo | null {
  const t = videoTiming({ pairs: clip.pairs, progress: clip.progress, recordCallWallMs: clip.recordCallWallMs, ...timing });
  if (!t) return null;
  return { uri: clip.uri, offsetSec: t.offsetSec, durationSec: t.durationSec, facing: clip.facing, syncSource: t.source };
}
