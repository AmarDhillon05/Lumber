// A song the app can play and record over. Every source (Files import,
// YouTube, later Spotify→YouTube) ends with a local audio file — the app owns
// playback, so the song and the mic share one audio clock.

export type SongSourceKind = 'file' | 'youtube' | 'spotify';

export interface Song {
  id: string; // stable: `${source}:${externalId}` (file: content hash or uuid)
  title: string;
  artist?: string;
  durationSec?: number;
  artworkUrl?: string;
  source: SongSourceKind;
  uri: string; // file:// URI of the downloaded/imported audio in app storage
}

export interface SearchResult {
  externalId: string; // e.g. YouTube video id
  title: string;
  artist?: string; // channel name for YouTube
  durationSec?: number;
  artworkUrl?: string;
  source: SongSourceKind;
}

export interface SongSource {
  kind: SongSourceKind;
  search(query: string): Promise<SearchResult[]>;
  // Downloads the audio into app storage and returns the playable Song.
  fetch(result: SearchResult, onProgress?: (fraction: number) => void): Promise<Song>;
}
