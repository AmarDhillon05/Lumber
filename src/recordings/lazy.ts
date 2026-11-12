// The player needs expo-video's native code; load it only when it's there.

import { hasVideoPlayer } from '../video/lazy';

/* eslint-disable @typescript-eslint/no-require-imports */
export const RecordingPlayer = hasVideoPlayer
  ? (require('./Player') as typeof import('./Player')).RecordingPlayer
  : null;
