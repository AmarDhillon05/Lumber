// Pasted links → playable search results. Pure (fetch is injected) so it runs
// under Node tests and in the app.
//
// - YouTube / YouTube Music links resolve to that exact video.
// - Spotify track links can't give audio (DRM), so we read the track's title,
//   artists and duration from its public page — no login or API credentials —
//   and find the best YouTube match, preferring official audio uploads whose
//   duration matches.

import { searchVideos, type FetchLike, type VideoHit } from './youtubeCore';
import type { SearchResult } from './types';

export type ParsedLink =
  | { kind: 'youtube'; videoId: string }
  | { kind: 'spotify'; trackId: string }
  | { kind: 'spotify-short'; url: string };

const YT_ID = /^[A-Za-z0-9_-]{11}$/;
const SPOTIFY_ID = /^[A-Za-z0-9]{22}$/;

export function parseLink(text: string): ParsedLink | null {
  const s = text.trim();
  const uri = /^spotify:track:([A-Za-z0-9]{22})$/.exec(s);
  if (uri) return { kind: 'spotify', trackId: uri[1] };

  const m = /^(?:https?:\/\/)?([^/?#\s]+)([^\s]*)$/i.exec(s);
  if (!m) return null;
  const host = m[1].toLowerCase().replace(/^(www|m|music)\./, '');
  const rest = m[2];
  const path = rest.split(/[?#]/)[0];
  const query = rest.includes('?') ? rest.slice(rest.indexOf('?') + 1).split('#')[0] : '';
  const param = (k: string) =>
    query
      .split('&')
      .map((kv) => kv.split('='))
      .find(([key]) => key === k)?.[1];

  if (host === 'youtube.com' || host === 'youtube-nocookie.com') {
    const v = param('v');
    if (v && YT_ID.test(v)) return { kind: 'youtube', videoId: v };
    const seg = /^\/(?:shorts|embed|live|v)\/([A-Za-z0-9_-]{11})/.exec(path);
    if (seg) return { kind: 'youtube', videoId: seg[1] };
    return null;
  }
  if (host === 'youtu.be') {
    const id = path.slice(1, 12);
    return YT_ID.test(id) ? { kind: 'youtube', videoId: id } : null;
  }
  if (host === 'open.spotify.com' || host === 'play.spotify.com') {
    // Also covers localized paths like /intl-de/track/<id>.
    const t = /\/track\/([A-Za-z0-9]{22})/.exec(path);
    return t ? { kind: 'spotify', trackId: t[1] } : null;
  }
  if (host === 'spotify.link' || host === 'spotify.app.link') {
    return { kind: 'spotify-short', url: `https://${host}${rest}` };
  }
  return null;
}

// ---------------------------------------------------------------------------
// Spotify track page

export interface SpotifyTrack {
  trackId: string;
  title: string;
  artists: string[];
  durationSec?: number;
  artworkUrl?: string;
}

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (all, e: string) => {
    if (e[0] === '#') {
      const code = e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : all;
    }
    return ENTITIES[e.toLowerCase()] ?? all;
  });
}

function meta(html: string, key: string): string | undefined {
  const re = new RegExp(`<meta\\s+(?:property|name)="${key}"\\s+content="([^"]*)"`, 'i');
  const m = re.exec(html);
  return m ? decodeEntities(m[1]) : undefined;
}

export function parseSpotifyTrackPage(trackId: string, html: string): SpotifyTrack {
  const title = meta(html, 'og:title');
  if (!title) throw new Error('Could not read the Spotify track (page format changed?)');
  // "AC/DC" or "Artist A, Artist B"; og:description ("A · Album · Song · 1980") as fallback.
  const musicians = meta(html, 'music:musician_description') ?? meta(html, 'og:description')?.split(' · ')[0];
  const artists = (musicians ?? '')
    .split(',')
    .map((a) => a.trim())
    .filter(Boolean);
  const duration = Number(meta(html, 'music:duration'));
  return {
    trackId,
    title,
    artists,
    durationSec: Number.isFinite(duration) && duration > 0 ? duration : undefined,
    artworkUrl: meta(html, 'og:image'),
  };
}

const PAGE_HEADERS = {
  'user-agent':
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  'accept-language': 'en',
};

export async function fetchSpotifyTrack(trackId: string, fetch: FetchLike): Promise<SpotifyTrack> {
  const res = await fetch(`https://open.spotify.com/track/${trackId}`, { headers: PAGE_HEADERS });
  if (!res.ok) throw new Error(`Spotify page HTTP ${res.status}`);
  return parseSpotifyTrackPage(trackId, await res.text());
}

// spotify.link short links redirect (via an HTML page) to open.spotify.com.
export async function expandSpotifyShortLink(url: string, fetch: FetchLike): Promise<string> {
  const res = await fetch(url, { headers: PAGE_HEADERS });
  const html = await res.text();
  const m = /open\.spotify\.com\/(?:intl-[a-z-]+\/)?track\/([A-Za-z0-9]{22})/i.exec(html);
  if (!m) throw new Error('That Spotify link is not a track');
  return m[1];
}

// ---------------------------------------------------------------------------
// Matching a Spotify track to a YouTube upload

const normalize = (s: string) =>
  s
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();

// Variants that are almost never what you want to drum along to, unless the
// Spotify title itself says so.
const UNWANTED = ['live', 'cover', 'drumcover', 'karaoke', 'instrumental', 'remix', 'slowed', 'sped up', 'nightcore', '8d', 'reverb', 'lyrics', 'reaction', 'tutorial', 'lesson', 'alternate', 'acoustic', 'demo', 'extended', 'version'];

export function scoreMatch(track: SpotifyTrack, hit: VideoHit): number {
  const title = normalize(hit.title);
  const channel = normalize(hit.channel ?? '');
  const wanted = normalize(track.title);
  const artist = normalize(track.artists[0] ?? '');
  let score = 0;

  // Duration is the strongest signal that it's the studio recording.
  if (track.durationSec && hit.durationSec) {
    const diff = Math.abs(track.durationSec - hit.durationSec);
    score += diff <= 2 ? 40 : diff <= 5 ? 30 : diff <= 15 ? 10 : diff <= 40 ? -10 : -40;
  }
  const words = wanted.split(' ').filter(Boolean);
  const present = words.filter((w) => title.includes(w)).length;
  score += words.length ? (25 * present) / words.length : 0;
  if (artist && (title.includes(artist) || channel.includes(artist))) score += 15;

  // Auto-generated "Artist - Topic" channels carry the album audio.
  if (channel.endsWith(' topic')) score += 20;
  if (/official (audio|video|music video)|\baudio\b/.test(title)) score += 8;
  // The artist's own channel, e.g. "TheKillersMusic", "acdcVEVO", "The Weeknd".
  const compact = (x: string) => x.replace(/ /g, '');
  if (artist && compact(channel).includes(compact(artist).replace(/^the/, ''))) score += 12;
  if (channel.endsWith('vevo')) score += 4;

  for (const bad of UNWANTED) {
    const re = new RegExp(`\\b${bad}\\b`);
    if (re.test(title) && !re.test(wanted)) score -= 25;
  }
  return score;
}

export function rankMatches(track: SpotifyTrack, hits: VideoHit[]): VideoHit[] {
  return hits
    .map((h, i) => ({ h, s: scoreMatch(track, h) - i * 0.5 })) // slight tie-break by YouTube's order
    .sort((a, b) => b.s - a.s)
    .map((x) => x.h);
}

// ---------------------------------------------------------------------------
// Entry point for the Library search box

export interface LinkResults {
  label: string; // shown above the results, e.g. "Spotify: AC/DC – Back In Black"
  results: SearchResult[];
}

const hitToResult = (h: VideoHit): SearchResult => ({
  externalId: h.videoId,
  title: h.title,
  artist: h.channel,
  durationSec: h.durationSec,
  artworkUrl: h.thumbnailUrl,
  source: 'youtube',
});

async function youtubeVideo(videoId: string, fetch: FetchLike): Promise<SearchResult> {
  // oEmbed gives title/channel/thumbnail without the player API; duration
  // and the stream are resolved when the user downloads it.
  const res = await fetch(
    `https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(`https://www.youtube.com/watch?v=${videoId}`)}`,
  );
  const info = res.ok ? await res.json() : {};
  return {
    externalId: videoId,
    title: info.title ?? videoId,
    artist: info.author_name,
    artworkUrl: info.thumbnail_url,
    source: 'youtube',
  };
}

// Returns null when the text isn't a supported link (treat it as a search).
export async function resolveLink(text: string, fetch: FetchLike, maxResults = 5): Promise<LinkResults | null> {
  const link = parseLink(text);
  if (!link) return null;
  if (link.kind === 'youtube') {
    const r = await youtubeVideo(link.videoId, fetch);
    return { label: 'YouTube link', results: [r] };
  }
  const trackId = link.kind === 'spotify' ? link.trackId : await expandSpotifyShortLink(link.url, fetch);
  const track = await fetchSpotifyTrack(trackId, fetch);
  const artist = track.artists[0];
  const hits = await searchVideos(artist ? `${artist} - ${track.title}` : track.title, fetch);
  const ranked = rankMatches(track, hits).slice(0, maxResults);
  return {
    label: `Spotify: ${track.artists.join(', ') || 'Unknown'} – ${track.title}`,
    results: ranked.map(hitToResult),
  };
}
