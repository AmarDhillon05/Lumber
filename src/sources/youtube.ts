// YouTube song source: search, then download the audio-only AAC/m4a stream
// into app storage. Pure logic lives in youtubeCore.ts; this file is the thin
// expo-file-system layer. Best-effort: YouTube changes break it periodically —
// see docs/youtube.md for how to fix it. Files import is always the fallback.

import { Directory, File, Paths } from 'expo-file-system';
import type { SearchResult, Song, SongSource } from './types';
import { downloadAudio, resolveAudio, searchVideos, type ChunkIO } from './youtubeCore';
import { youtubeFetch } from './youtubePlatform';

export function songsDirectory(): Directory {
  const dir = new Directory(Paths.document, 'songs');
  if (!dir.exists) dir.create({ intermediates: true, idempotent: true });
  return dir;
}

function toSearchResult(h: Awaited<ReturnType<typeof searchVideos>>[number]): SearchResult {
  return {
    externalId: h.videoId,
    title: h.title,
    artist: h.channel,
    durationSec: h.durationSec,
    artworkUrl: h.thumbnailUrl,
    source: 'youtube',
  };
}

function expoChunkIO(part: File, scratch: File): ChunkIO {
  return {
    async fetchRange(url, headers, onBytes) {
      // Native download (URLSession) to a scratch file, then read it back.
      // Keeps big transfers off the JS fetch polyfill.
      await File.downloadFileAsync(url, scratch, {
        headers,
        idempotent: true, // overwrite the previous chunk's scratch file
        onProgress: (p) => onBytes(p.bytesWritten),
      });
      const bytes = await scratch.bytes();
      scratch.delete();
      return bytes;
    },
    async append(bytes) {
      await part.write(bytes, { append: true });
    },
  };
}

export const youtubeSource: SongSource = {
  kind: 'youtube',

  async search(query: string): Promise<SearchResult[]> {
    const q = query.trim();
    if (!q) return [];
    const hits = await searchVideos(q, youtubeFetch());
    return hits.map(toSearchResult);
  },

  async fetch(result: SearchResult, onProgress?: (fraction: number) => void): Promise<Song> {
    const videoId = result.externalId;
    const audio = await resolveAudio(videoId, youtubeFetch());
    const song = (uri: string): Song => ({
      id: `youtube:${videoId}`,
      title: result.title || audio.title || videoId,
      artist: result.artist ?? audio.channel,
      durationSec: audio.durationSec ?? result.durationSec,
      artworkUrl: result.artworkUrl ?? audio.thumbnailUrl,
      source: 'youtube',
      uri,
    });

    const dest = new File(songsDirectory(), `youtube-${videoId}.m4a`);
    if (dest.exists && dest.size === audio.contentLength) {
      onProgress?.(1);
      return song(dest.uri);
    }

    const part = new File(Paths.cache, `youtube-${videoId}.m4a.part`);
    const scratch = new File(Paths.cache, `youtube-${videoId}.chunk`);
    if (part.exists) part.delete();
    part.create();
    try {
      await downloadAudio(audio, expoChunkIO(part, scratch), { onProgress });
      if (dest.exists) dest.delete();
      part.moveSync(dest);
    } catch (e) {
      if (part.exists) part.delete();
      if (scratch.exists) scratch.delete();
      throw e;
    }
    return song(dest.uri);
  },
};
