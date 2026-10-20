// Pure YouTube (InnerTube) logic: no React Native or Expo imports, so it runs
// unchanged under Node (`tsx`) for tests/spikes and under Hermes in the app.
// Network access goes through an injected `fetch`.
//
// Why hand-rolled rather than youtubei.js: we only need two InnerTube calls
// (search + player) and plain JSON. The player call uses clients whose stream
// URLs come back already signed (no `signatureCipher`, no `n` param), so no
// player-JS deciphering, no `eval`/`new Function`, no PO token, and no
// polyfills beyond `fetch` + `JSON`. See docs/youtube.md.

export type FetchLike = (
  url: string,
  init?: { method?: string; headers?: Record<string, string>; body?: string },
) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<any>;
  text(): Promise<string>;
}>;

// ---------------------------------------------------------------------------
// Clients

export interface InnertubeClient {
  key: string;
  nameId: number; // X-Youtube-Client-Name
  userAgent: string;
  context: Record<string, unknown>; // context.client (minus hl/gl/visitorData)
}

// Versions mirror youtubei.js 18.2 (Constants.CLIENTS). When YouTube starts
// rejecting a client, bump its version from the latest youtubei.js / yt-dlp.
export const CLIENTS: Record<string, InnertubeClient> = {
  // Best option as of Oct 2026: direct URLs, no n-param, no PO token.
  // Can't play "made for kids" videos.
  ANDROID_VR: {
    key: 'ANDROID_VR',
    nameId: 28,
    userAgent:
      'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    context: {
      clientName: 'ANDROID_VR',
      clientVersion: '1.65.10',
      deviceMake: 'Oculus',
      deviceModel: 'Quest 3',
      androidSdkVersion: 32,
      osName: 'Android',
      osVersion: '12L',
      platform: 'MOBILE',
      clientFormFactor: 'SMALL_FORM_FACTOR',
    },
  },
  VISIONOS: {
    key: 'VISIONOS',
    nameId: 101,
    userAgent:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
    context: {
      clientName: 'VISIONOS',
      clientVersion: '1.02',
      deviceMake: 'Apple',
      deviceModel: 'RealityDevice17,1',
      osName: 'visionOS',
      osVersion: '26.5.23O471',
      platform: 'MOBILE',
    },
  },
  // Returns direct URLs, but googlevideo may demand a GVS PO token for them
  // (403 on download). Last resort.
  IOS: {
    key: 'IOS',
    nameId: 5,
    userAgent: 'com.google.ios.youtube/20.11.6 (iPhone10,4; U; CPU iOS 16_7_7 like Mac OS X)',
    context: {
      clientName: 'IOS',
      clientVersion: '20.11.6',
      deviceMake: 'Apple',
      deviceModel: 'iPhone10,4',
      osName: 'iOS',
      osVersion: '16.7.7.20H330',
      platform: 'MOBILE',
    },
  },
};

export const DEFAULT_CLIENT_ORDER = ['ANDROID_VR', 'VISIONOS', 'IOS'];

const WEB = {
  nameId: 1,
  version: '2.20260623.01.00',
  userAgent:
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
};

const YT = 'https://www.youtube.com';

// ---------------------------------------------------------------------------
// Session (visitor data)

// A visitor id ties requests together; without one the player endpoint
// answers LOGIN_REQUIRED ("Sign in to confirm you're not a bot").
export async function getVisitorData(fetch: FetchLike): Promise<string> {
  const res = await fetch(`${YT}/sw.js_data`, { headers: { 'user-agent': WEB.userAgent } });
  if (!res.ok) throw new Error(`YouTube: sw.js_data HTTP ${res.status}`);
  return parseVisitorData(await res.text());
}

export function parseVisitorData(swJsData: string): string {
  const json = JSON.parse(swJsData.replace(/^\)\]\}'/, ''));
  const v = json?.[0]?.[2]?.[0]?.[0]?.[13];
  if (typeof v !== 'string' || !v) throw new Error('YouTube: no visitorData in sw.js_data');
  return v;
}

// ---------------------------------------------------------------------------
// Search

export interface VideoHit {
  videoId: string;
  title: string;
  channel?: string;
  durationSec?: number;
  thumbnailUrl?: string;
}

export function buildSearchRequest(query: string, visitorData: string) {
  return {
    url: `${YT}/youtubei/v1/search?prettyPrint=false`,
    init: {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'user-agent': WEB.userAgent,
        'x-youtube-client-name': String(WEB.nameId),
        'x-youtube-client-version': WEB.version,
        'x-goog-visitor-id': visitorData,
      },
      body: JSON.stringify({
        context: { client: { clientName: 'WEB', clientVersion: WEB.version, hl: 'en', gl: 'US', visitorData } },
        query,
        params: 'EgIQAQ==', // filter: type = video
      }),
    },
  };
}

// Walks the search response and collects every `videoRenderer`. Robust to
// YouTube reshuffling the section/shelf nesting around them.
export function parseSearchResponse(json: unknown): VideoHit[] {
  const hits: VideoHit[] = [];
  const seen = new Set<string>();
  const walk = (node: any): void => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      for (const n of node) walk(n);
      return;
    }
    const vr = node.videoRenderer;
    if (vr && typeof vr.videoId === 'string' && !seen.has(vr.videoId)) {
      seen.add(vr.videoId);
      // Live streams have no lengthText; they can't be downloaded as a file.
      const lengthText = vr.lengthText?.simpleText ?? textOf(vr.lengthText);
      if (lengthText) {
        hits.push({
          videoId: vr.videoId,
          title: textOf(vr.title) ?? vr.videoId,
          channel: textOf(vr.ownerText) ?? textOf(vr.longBylineText),
          durationSec: parseClock(lengthText),
          thumbnailUrl: bestThumbnail(vr.thumbnail?.thumbnails),
        });
      }
    }
    for (const k in node) if (k !== 'videoRenderer') walk(node[k]);
  };
  walk(json);
  return hits;
}

export async function searchVideos(query: string, fetch: FetchLike, visitorData?: string): Promise<VideoHit[]> {
  const vd = visitorData ?? (await getVisitorData(fetch));
  const req = buildSearchRequest(query, vd);
  const res = await fetch(req.url, req.init);
  if (!res.ok) throw new Error(`YouTube search HTTP ${res.status}`);
  return parseSearchResponse(await res.json());
}

// ---------------------------------------------------------------------------
// Player + format selection

export interface AdaptiveFormat {
  itag: number;
  url?: string;
  signatureCipher?: string;
  mimeType: string;
  bitrate?: number;
  averageBitrate?: number;
  contentLength?: string;
  approxDurationMs?: string;
  audioQuality?: string;
  xtags?: string;
  isDrc?: boolean;
  audioTrack?: { audioIsDefault?: boolean; displayName?: string };
}

export interface ResolvedAudio {
  videoId: string;
  client: string;
  itag: number;
  mimeType: string;
  url: string;
  contentLength: number;
  durationSec?: number;
  title?: string;
  channel?: string;
  thumbnailUrl?: string;
  userAgent: string; // send with media requests
}

export function buildPlayerRequest(client: InnertubeClient, videoId: string, visitorData: string) {
  return {
    url: `${YT}/youtubei/v1/player?prettyPrint=false`,
    init: {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'user-agent': client.userAgent,
        'x-youtube-client-name': String(client.nameId),
        'x-youtube-client-version': String(client.context.clientVersion),
        'x-goog-visitor-id': visitorData,
      },
      body: JSON.stringify({
        videoId,
        context: { client: { ...client.context, hl: 'en', gl: 'US', visitorData } },
        contentCheckOk: true,
        racyCheckOk: true,
      }),
    },
  };
}

// Picks the audio-only format iOS decodes natively: AAC in MP4 (m4a).
// Preference: itag 140 (AAC-LC 128k) > other audio/mp4 by bitrate. Skips
// ciphered URLs, DRC (loudness-normalised) variants and dubbed tracks.
export function pickAudioFormat(formats: AdaptiveFormat[]): AdaptiveFormat | undefined {
  const ok = formats.filter(
    (f) =>
      f.mimeType?.startsWith('audio/mp4') &&
      typeof f.url === 'string' &&
      !f.isDrc &&
      !(f.xtags ?? '').includes('drc') &&
      (f.audioTrack ? f.audioTrack.audioIsDefault !== false : true),
  );
  ok.sort((a, b) => score(b) - score(a));
  return ok[0];
}

function score(f: AdaptiveFormat): number {
  const isAac = /mp4a\.40\.2/.test(f.mimeType) ? 1 : 0;
  return (f.itag === 140 ? 1e9 : 0) + isAac * 1e8 + (f.averageBitrate ?? f.bitrate ?? 0);
}

export class PlayabilityError extends Error {
  constructor(
    message: string,
    public readonly attempts: { client: string; status?: string; reason?: string }[],
  ) {
    super(message);
  }
}

export function parsePlayerResponse(videoId: string, client: InnertubeClient, json: any): ResolvedAudio | { status?: string; reason?: string } {
  const ps = json?.playabilityStatus;
  if (ps?.status !== 'OK') return { status: ps?.status, reason: ps?.reason ?? ps?.messages?.[0] };
  const formats: AdaptiveFormat[] = json.streamingData?.adaptiveFormats ?? [];
  const f = pickAudioFormat(formats);
  if (!f || !f.url) return { status: 'NO_FORMAT', reason: 'no direct audio/mp4 format' };
  const vd = json.videoDetails ?? {};
  // (No `new URL().searchParams`: React Native's URL implementation lacks it.)
  const contentLength = Number(f.contentLength ?? /[?&]clen=(\d+)/.exec(f.url)?.[1] ?? NaN);
  if (!Number.isFinite(contentLength) || contentLength <= 0) {
    return { status: 'NO_FORMAT', reason: 'audio format has no contentLength' };
  }
  const lengthSeconds = Number(vd.lengthSeconds);
  return {
    videoId,
    client: client.key,
    itag: f.itag,
    mimeType: f.mimeType,
    url: f.url,
    contentLength,
    durationSec: Number.isFinite(lengthSeconds) && lengthSeconds > 0 ? lengthSeconds : undefined,
    title: vd.title,
    channel: vd.author,
    thumbnailUrl: bestThumbnail(vd.thumbnail?.thumbnails),
    userAgent: client.userAgent,
  };
}

// Tries each client in order until one returns a playable direct m4a URL.
export async function resolveAudio(
  videoId: string,
  fetch: FetchLike,
  opts: { clients?: string[]; visitorData?: string } = {},
): Promise<ResolvedAudio> {
  const vd = opts.visitorData ?? (await getVisitorData(fetch));
  const attempts: { client: string; status?: string; reason?: string }[] = [];
  for (const key of opts.clients ?? DEFAULT_CLIENT_ORDER) {
    const client = CLIENTS[key];
    if (!client) continue;
    try {
      const req = buildPlayerRequest(client, videoId, vd);
      const res = await fetch(req.url, req.init);
      if (!res.ok) {
        attempts.push({ client: key, status: `HTTP ${res.status}` });
        continue;
      }
      const r = parsePlayerResponse(videoId, client, await res.json());
      if ('url' in r) return r;
      attempts.push({ client: key, ...r });
    } catch (e) {
      attempts.push({ client: key, status: 'ERROR', reason: String((e as Error)?.message ?? e) });
    }
  }
  const summary = attempts.map((a) => `${a.client}: ${a.status ?? '?'}${a.reason ? ` (${a.reason})` : ''}`).join('; ');
  throw new PlayabilityError(`YouTube: no playable audio for ${videoId}. ${summary}`, attempts);
}

// ---------------------------------------------------------------------------
// Download planning

// googlevideo throttles long single requests to ~real-time; ~10 MB ranged
// requests come back at full speed. A song's m4a is 3-10 MB, so usually 1 chunk.
export const CHUNK_BYTES = 10 * 1024 * 1024;

export interface Chunk {
  start: number; // inclusive
  end: number; // inclusive
}

export function planChunks(contentLength: number, chunkBytes = CHUNK_BYTES): Chunk[] {
  if (!(contentLength > 0)) return [];
  if (!(chunkBytes > 0)) throw new Error('chunkBytes must be > 0');
  const chunks: Chunk[] = [];
  for (let start = 0; start < contentLength; start += chunkBytes) {
    chunks.push({ start, end: Math.min(start + chunkBytes, contentLength) - 1 });
  }
  return chunks;
}

// The `range` query param (rather than a Range header) is what YouTube's own
// clients use; it avoids CORS preflights and works on every googlevideo host.
export function chunkUrl(url: string, c: Chunk): string {
  return `${url}${url.includes('?') ? '&' : '?'}range=${c.start}-${c.end}`;
}

export function mediaHeaders(audio: Pick<ResolvedAudio, 'userAgent'>): Record<string, string> {
  return { 'user-agent': audio.userAgent, accept: '*/*' };
}

// ISO-BMFF files (mp4/m4a) start with a box whose type is 'ftyp'.
export function isMp4(bytes: Uint8Array): boolean {
  return bytes.length >= 8 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70;
}

export function mp4Brand(bytes: Uint8Array): string | undefined {
  if (!isMp4(bytes) || bytes.length < 12) return undefined;
  return String.fromCharCode(bytes[8], bytes[9], bytes[10], bytes[11]);
}

// ---------------------------------------------------------------------------
// Small helpers

export function parseClock(text: string | undefined): number | undefined {
  if (!text) return undefined;
  const parts = text.trim().split(':').map((p) => Number(p.replace(/[^\d]/g, '')));
  if (parts.length === 0 || parts.some((n) => !Number.isFinite(n))) return undefined;
  return parts.reduce((acc, n) => acc * 60 + n, 0);
}

function textOf(t: any): string | undefined {
  if (!t) return undefined;
  if (typeof t.simpleText === 'string') return t.simpleText;
  if (Array.isArray(t.runs)) return t.runs.map((r: any) => r.text ?? '').join('') || undefined;
  return undefined;
}

export function bestThumbnail(thumbs: { url: string; width?: number; height?: number }[] | undefined): string | undefined {
  if (!thumbs?.length) return undefined;
  const best = [...thumbs].sort((a, b) => (b.width ?? 0) * (b.height ?? 0) - (a.width ?? 0) * (a.height ?? 0))[0];
  return best.url.startsWith('//') ? `https:${best.url}` : best.url.split('?')[0];
}
