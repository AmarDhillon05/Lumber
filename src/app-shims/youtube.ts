// SHIM — stand-in for src/sources/youtube.ts (not on any branch yet).
// Delete once the real module lands and point src/app-shims/index.ts at it.

import type { SongSource } from '../sources/types';

export const youtubeSource: SongSource = {
  kind: 'youtube',
  async search() {
    throw new Error('YouTube search is not available in this build yet — use Import file.');
  },
  async fetch() {
    throw new Error('YouTube download is not available in this build yet.');
  },
};
