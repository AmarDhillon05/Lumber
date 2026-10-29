// The few Spotify Web API calls Lumber uses. Pure (fetch and the token are
// injected). Field names follow the February 2026 API: playlist contents come
// from /playlists/{id}/items and each entry's track is under `item`.

import type { SpotifyTrack } from './links';
import type { FetchLike } from './youtubeCore';

const API = 'https://api.spotify.com/v1';

export interface SpotifyPlaylist {
  id: string;
  name: string;
  trackCount?: number;
  artworkUrl?: string;
}

export interface Page<T> {
  items: T[];
  next: number | null; // offset of the next page
}

export function toTrack(t: any): SpotifyTrack | null {
  if (!t || t.type === 'episode' || !t.id || t.is_local) return null;
  return {
    trackId: t.id,
    title: t.name,
    artists: (t.artists ?? []).map((a: any) => a.name).filter(Boolean),
    durationSec: t.duration_ms ? Math.round(t.duration_ms / 1000) : undefined,
    artworkUrl: t.album?.images?.[0]?.url,
  };
}

export class SpotifyApi {
  constructor(
    private fetch: FetchLike,
    private token: (forceRefresh?: boolean) => Promise<string>,
  ) {}

  private async get(path: string): Promise<any | null> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const res = await this.fetch(`${API}${path}`, {
        headers: { authorization: `Bearer ${await this.token(attempt > 0)}` },
      });
      if (res.status === 401 && attempt === 0) continue; // token went stale: refresh once
      if (res.status === 204) return null;
      if (res.status === 403) throw new Error('Spotify refused this request (only your own playlists can be opened)');
      if (res.status === 429) throw new Error('Spotify rate limit hit, try again in a minute');
      if (!res.ok) throw new Error(`Spotify API ${res.status} for ${path.split('?')[0]}`);
      const text = await res.text();
      return text ? JSON.parse(text) : null;
    }
    throw new Error('Spotify session expired, connect again');
  }

  // null when nothing is playing (or a podcast is).
  async currentlyPlaying(): Promise<SpotifyTrack | null> {
    const json = await this.get('/me/player/currently-playing');
    return json ? toTrack(json.item) : null;
  }

  async likedTracks(offset = 0): Promise<Page<SpotifyTrack>> {
    const json = await this.get(`/me/tracks?limit=50&offset=${offset}`);
    return page(json, offset, (i) => toTrack(i.track));
  }

  async playlists(offset = 0): Promise<Page<SpotifyPlaylist>> {
    const json = await this.get(`/me/playlists?limit=50&offset=${offset}`);
    return page(json, offset, (p) =>
      p?.id
        ? { id: p.id, name: p.name, trackCount: p.items?.total ?? p.tracks?.total, artworkUrl: p.images?.[0]?.url }
        : null,
    );
  }

  async playlistTracks(playlistId: string, offset = 0): Promise<Page<SpotifyTrack>> {
    const json = await this.get(`/playlists/${encodeURIComponent(playlistId)}/items?limit=50&offset=${offset}`);
    return page(json, offset, (i) => toTrack(i.item ?? i.track));
  }
}

function page<T>(json: any, offset: number, map: (raw: any) => T | null): Page<T> {
  const raw: any[] = json?.items ?? [];
  const items = raw.map(map).filter((x): x is T => x !== null);
  return { items, next: json?.next ? offset + raw.length : null };
}
