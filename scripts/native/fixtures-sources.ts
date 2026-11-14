// Golden fixtures for the native LumberCore port of song sources and the AI
// mixer: runs the TypeScript implementations on deterministic inputs and
// writes the results as JSON the Swift tests compare against. Also generates
// the knob table the Swift AI module needs (AI/KnobCatalog.generated.swift).
//
//   npx tsx scripts/native/fixtures-sources.ts     (from the repo root)

import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  CLIENTS,
  bestThumbnail,
  buildPlayerRequest,
  buildSearchRequest,
  chunkUrl,
  isMp4,
  mp4Brand,
  parseClock,
  parsePlayerResponse,
  parseSearchResponse,
  parseVisitorData,
  pickAudioFormat,
  planChunks,
  type AdaptiveFormat,
  type FetchLike,
  type VideoHit,
} from '../../src/sources/youtubeCore';
import { decodeEntities, parseLink, parseSpotifyTrackPage, rankMatches, scoreMatch, type SpotifyTrack } from '../../src/sources/links';
import { buildAuthorizeUrl, exchangeCode, makeVerifier, parseCallback, refreshTokens, toBase64Url } from '../../src/sources/spotifyAuth';
import { SpotifyApi, toTrack } from '../../src/sources/spotifyApi';
import { extensionOf, isSupportedAudioName, storedFileName, titleFromFileName } from '../../src/sources/localFileCore';
import { analyzeAudio, roundDescriptors, type AudioDescriptors, type MixAnalysis } from '../../src/ai/analyze';
import { changedTerms, clampGain, clampKnob, effectiveValue, knobRange, sanitizeValues } from '../../src/ai/knobs';
import { interpretLocally } from '../../src/ai/localMix';
import { buildRequest, buildSystemPrompt, buildUserMessage, knobCatalog, OUTPUT_SCHEMA, parseSuggestion, ClaudeMixError, type ClaudeMixInput } from '../../src/ai/claude';
import { BLANKET_TERMS, BLANKET_TERM_KEYS, CATEGORY_ORDER, zeroValues } from '../../src/dsp/blanketTerms';
import { INTENSITY } from '../../src/dsp/blanketChain';
import { fillValues, PRESETS } from '../../src/dsp/presets';

const ROOT = process.cwd();
const FIX = join(ROOT, 'native/LumberCore/Tests/LumberCoreTests/Fixtures');
const AI_SRC = join(ROOT, 'native/LumberCore/Sources/LumberCore/AI');

function write(rel: string, data: unknown) {
  const path = join(FIX, rel);
  mkdirSync(join(path, '..'), { recursive: true });
  const pretty = JSON.stringify(data, null, 1);
  writeFileSync(path, (pretty.length > 100_000 ? JSON.stringify(data) : pretty) + '\n');
  console.log(`wrote ${rel}`);
}

const catchMsg = (f: () => unknown): { error: string } | { value: unknown } => {
  try {
    return { value: f() };
  } catch (e) {
    return { error: String((e as Error).message) };
  }
};

// ---------------------------------------------------------------------------
// sources/youtube.json

function youtubeFixtures() {
  const vr = (o: Record<string, unknown>) => ({ videoRenderer: o });
  const runs = (...t: (string | undefined)[]) => ({ runs: t.map((text) => (text === undefined ? {} : { text })) });
  const thumbs = (...t: [string, number?, number?][]) => ({ thumbnails: t.map(([url, width, height]) => ({ url, ...(width ? { width } : {}), ...(height ? { height } : {}) })) });

  const search1 = {
    responseContext: { visitorData: 'x' },
    contents: {
      twoColumnSearchResultsRenderer: {
        primaryContents: {
          sectionListRenderer: {
            contents: [
              {
                itemSectionRenderer: {
                  contents: [
                    vr({ videoId: 'pAgnJDJN4VA', title: runs('AC/DC - Back In Black (Official 4K Video)'), ownerText: runs('AC/DC'), lengthText: { simpleText: '4:15' }, thumbnail: thumbs(['https://i.ytimg.com/vi/pAgnJDJN4VA/hq720.jpg?sqp=abc', 720, 404], ['https://i.ytimg.com/vi/pAgnJDJN4VA/hqdefault.jpg?x=1', 360, 202]) }),
                    { adSlotRenderer: { foo: [vr({ videoId: 'adVideo0001', title: { simpleText: 'Ad' }, lengthText: { accessibility: {}, simpleText: '0:30' } })] } },
                    vr({ videoId: 'liveStream1', title: runs('24/7 radio'), ownerText: runs('Radio') }),
                    vr({ videoId: 'longByline1', title: runs('Back', ' In ', 'Black'), longBylineText: runs('Topic Channel'), lengthText: runs('1:02:03'), thumbnail: thumbs(['//i.ytimg.com/a.jpg', 10, 10], ['//i.ytimg.com/b.jpg', 20, 20]) }),
                    {
                      shelfRenderer: {
                        title: { simpleText: 'People also watched' },
                        content: { verticalListRenderer: { items: [vr({ videoId: 'shelfVideo1', title: { simpleText: 'Shelf' }, lengthText: { simpleText: '3:00' } }), vr({ videoId: 'pAgnJDJN4VA', title: runs('dup'), lengthText: { simpleText: '4:15' } })] } },
                      },
                    },
                    vr({ videoId: 'noTitle0001', lengthText: { simpleText: ' 2:05 ' }, ownerText: runs(undefined), thumbnail: { thumbnails: [] } }),
                    vr({ videoId: 'weirdLen001', title: runs('x'), lengthText: { simpleText: 'LIVE' } }),
                  ],
                },
              },
              { continuationItemRenderer: { trigger: 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN' } },
            ],
          },
        },
      },
    },
    zLate: [vr({ videoId: 'lateVideo01', title: { simpleText: 'Late' }, lengthText: { simpleText: '10' } })],
  };
  const search2 = { contents: { a: [{ itemSectionRenderer: { contents: [vr({ videoId: 'a', title: runs('Title a'), ownerText: runs('Chan'), lengthText: { simpleText: '4:14' }, thumbnail: thumbs(['//i.ytimg.com/x.jpg', 10, 10]) }), vr({ videoId: 'live' }), { shelf: { items: [vr({ videoId: 'b', lengthText: { simpleText: '1:00:00' } })] } }] } }] } };

  const fmt = (o: Partial<AdaptiveFormat>): AdaptiveFormat => ({ itag: 0, mimeType: '', url: 'https://g/v?clen=100', ...o });
  const formatSets: AdaptiveFormat[][] = [
    [
      fmt({ itag: 251, mimeType: 'audio/webm; codecs="opus"', bitrate: 160000 }),
      fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, xtags: 'CggKA2RyYxIBMQ', isDrc: true }),
      fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, audioTrack: { audioIsDefault: false } }),
      fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, url: 'https://g/v?clen=100&pick=me' }),
      fmt({ itag: 139, mimeType: 'audio/mp4; codecs="mp4a.40.5"', bitrate: 50000 }),
      fmt({ itag: 141, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 260000, url: undefined, signatureCipher: 's=..' }),
      fmt({ itag: 137, mimeType: 'video/mp4; codecs="avc1"', bitrate: 4000000 }),
    ],
    [fmt({ itag: 251, mimeType: 'audio/webm; codecs="opus"', bitrate: 160000 })],
    [fmt({ itag: 139, mimeType: 'audio/mp4; codecs="mp4a.40.5"', bitrate: 50000 })],
    [
      fmt({ itag: 139, mimeType: 'audio/mp4; codecs="mp4a.40.5"', bitrate: 90000 }),
      fmt({ itag: 141, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 50000, averageBitrate: 40000 }),
      fmt({ itag: 142, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 50000, xtags: 'drc' }),
      fmt({ itag: 143, mimeType: 'audio/mp4; codecs="mp4a.40.2"', averageBitrate: 45000, audioTrack: { audioIsDefault: true, displayName: 'English' } }),
      fmt({ itag: 144, mimeType: 'audio/mp4; codecs="mp4a.40.2"', averageBitrate: 45000, url: 'https://g/tie' }),
    ],
    [],
  ];

  const playerOk = {
    playabilityStatus: { status: 'OK' },
    videoDetails: { title: 'T', author: 'A', lengthSeconds: '252', thumbnail: { thumbnails: [{ url: 'https://i/a.jpg', width: 1, height: 1 }, { url: 'https://i/b.jpg?x=1', width: 9, height: 9 }] } },
    streamingData: { adaptiveFormats: [fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', url: 'https://g/v?clen=4075204&x=1' })] },
  };
  const players: { client: string; videoId: string; input: unknown }[] = [
    { client: 'ANDROID_VR', videoId: 'vid', input: playerOk },
    { client: 'VISIONOS', videoId: 'v2', input: { ...playerOk, videoDetails: { title: 'No length', lengthSeconds: '0' }, streamingData: { adaptiveFormats: [fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', url: 'https://g/v?x=1', contentLength: '3999' })] } } },
    { client: 'IOS', videoId: 'v3', input: { playabilityStatus: { status: 'LOGIN_REQUIRED', reason: 'Sign in to confirm you’re not a bot' } } },
    { client: 'IOS', videoId: 'v4', input: { playabilityStatus: { status: 'UNPLAYABLE', messages: ['Made for kids'] } } },
    { client: 'IOS', videoId: 'v5', input: { playabilityStatus: { status: 'OK' }, streamingData: { adaptiveFormats: [fmt({ itag: 251, mimeType: 'audio/webm' })] } } },
    { client: 'IOS', videoId: 'v6', input: { playabilityStatus: { status: 'OK' }, streamingData: { adaptiveFormats: [fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', url: 'https://g/v?x=1' })] } } },
    { client: 'IOS', videoId: 'v7', input: {} },
    { client: 'ANDROID_VR', videoId: 'v8', input: { playabilityStatus: { status: 'OK' }, videoDetails: { lengthSeconds: 'abc', author: 'Auth' }, streamingData: { adaptiveFormats: [fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', url: 'https://g/v?a=1&clen=77' })] } } },
  ];

  const swData = (vd: unknown) => `)]}'` + JSON.stringify([[null, null, [[[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, vd]]]]]);
  const mp4Bytes = [
    [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x64, 0x61, 0x73, 0x68],
    [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4d, 0x34, 0x41, 0x20, 0, 0],
    [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4d],
    [0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0],
    [0, 0, 0, 0x18, 0x66, 0x74, 0x79],
  ];

  write('sources/youtube.json', {
    clients: Object.values(CLIENTS).map((c) => ({ key: c.key, nameId: c.nameId, userAgent: c.userAgent, context: c.context })),
    visitorData: [swData('CgtVISITOR'), swData(''), swData(5), `)]}'[]`, '[[null,null,[[[0,0,0,0,0,0,0,0,0,0,0,0,0,"NoPrefix"]]]]]'].map((input) => ({ input, ...catchMsg(() => parseVisitorData(input)) })),
    clock: ['4:15', '1:02:03', '0:07', ' 2:05 ', 'LIVE', '1:xx', '', '12', '1:2:3:4', '١:٢'].map((t) => ({ input: t, expected: parseClock(t) ?? null })),
    chunks: [
      [0, 4],
      [10, 4],
      [8, 4],
      [1, 4],
      [4_075_204, undefined],
      [25_000_000, undefined],
      [-5, 4],
    ].map(([n, c]) => ({ contentLength: n, chunkBytes: c ?? null, expected: planChunks(n as number, c as number | undefined) })),
    chunkUrls: [
      ['https://x/v?a=1', 0, 9],
      ['https://x/v', 10, 19],
    ].map(([u, s, e]) => ({ url: u, start: s, end: e, expected: chunkUrl(u as string, { start: s as number, end: e as number }) })),
    thumbnails: [
      [{ url: 'a', width: 1, height: 1 }, { url: 'b', width: 2, height: 2 }],
      [],
      [{ url: '//x/y.jpg?q=1' }],
      [{ url: 'https://i/a.jpg?x=1', width: 5, height: 5 }, { url: 'https://i/b.jpg', width: 5, height: 5 }],
      [{ url: 'https://i/a.jpg', width: 5 }, { url: 'https://i/b.jpg?z', width: 1, height: 1 }],
    ].map((t) => ({ input: t, expected: bestThumbnail(t) ?? null })),
    searchRequest: (() => {
      const r = buildSearchRequest('ac/dc "back in black" — live?', 'CgtVISITOR%3D');
      return { query: 'ac/dc "back in black" — live?', visitorData: 'CgtVISITOR%3D', url: r.url, method: r.init.method, headers: r.init.headers, body: r.init.body };
    })(),
    playerRequests: Object.keys(CLIENTS).map((k) => {
      const r = buildPlayerRequest(CLIENTS[k], 'pAgnJDJN4VA', 'CgtVISITOR');
      return { client: k, videoId: 'pAgnJDJN4VA', visitorData: 'CgtVISITOR', url: r.url, method: r.init.method, headers: r.init.headers, body: r.init.body };
    }),
    searchResponses: [search1, search2, {}, [], { a: null, b: [1, 'x', null] }].map((input) => ({ input, expected: parseSearchResponse(input) })),
    pickFormat: formatSets.map((formats) => {
      const f = pickAudioFormat(formats);
      return { formats, expected: f ? { itag: f.itag, url: f.url } : null };
    }),
    playerResponses: players.map((p) => ({ ...p, expected: parsePlayerResponse(p.videoId, CLIENTS[p.client], p.input) })),
    mp4: mp4Bytes.map((b) => ({ bytes: b, isMp4: isMp4(Uint8Array.from(b)), brand: mp4Brand(Uint8Array.from(b)) ?? null })),
  });
}

// ---------------------------------------------------------------------------
// sources/links.json

const SPOTIFY_PAGE = `<html><head>
<meta property="og:title" content="Don&#x27;t Stop Me Now &amp; More"/>
<meta property="og:description" content="Queen · Jazz · Song · 1978"/>
<meta property="og:image" content="https://i.scdn.co/image/abc"/>
<meta name="music:duration" content="209"/>
<meta name="music:musician_description" content="Queen, Guest Artist"/>
</head></html>`;

function linksFixtures() {
  const linkInputs = [
    'https://www.youtube.com/watch?v=pAgnJDJN4VA&t=10s',
    'youtube.com/watch?feature=share&v=pAgnJDJN4VA',
    'https://youtu.be/pAgnJDJN4VA?si=xyz',
    'https://music.youtube.com/watch?v=pAgnJDJN4VA&list=RD',
    'https://m.youtube.com/shorts/pAgnJDJN4VA',
    'https://www.youtube-nocookie.com/embed/pAgnJDJN4VA?rel=0',
    'https://www.youtube.com/live/pAgnJDJN4VA',
    'HTTPS://WWW.YOUTUBE.COM/watch?v=pAgnJDJN4VA',
    'https://www.youtube.com/watch?v=short',
    'https://www.youtube.com/watch?v',
    'https://youtu.be/abc',
    '  https://youtu.be/pAgnJDJN4VA  ',
    'https://open.spotify.com/track/08mG3Y1vljYA6bvDt4Wqkj?si=abc',
    'https://open.spotify.com/intl-de/track/08mG3Y1vljYA6bvDt4Wqkj',
    'spotify:track:08mG3Y1vljYA6bvDt4Wqkj',
    'spotify:track:08mG3Y1vljYA6bvDt4Wqk',
    'https://play.spotify.com/track/08mG3Y1vljYA6bvDt4Wqkj',
    'https://spotify.link/AbCdEf',
    'spotify.app.link/XyZ?_p=1',
    'back in black',
    'https://open.spotify.com/album/1wOhTFS4m9tbPGlKbwGaBg',
    'https://example.com/watch?v=pAgnJDJN4VA',
    'https://www.youtube.com/watch?v=pAgnJDJN4VA#t=1',
    'youtube.com/watch?list=x&v=pAgnJDJN4VA&v=zzzzzzzzzzz',
    '',
  ];
  const pages: { trackId: string; html: string }[] = [
    { trackId: 'id', html: SPOTIFY_PAGE },
    { trackId: 'fallback', html: '<meta property="og:title" content="Song &quot;Q&quot; &#233;t&eacute;"/><meta property="og:description" content="AC/DC · Back In Black · Song · 1980"/><meta name="music:duration" content="255.5"/>' },
    { trackId: 'nodur', html: '<META PROPERTY="og:title" CONTENT="Upper"/><meta name="music:duration" content="x"/>' },
    { trackId: 'empty', html: '<html></html>' },
    { trackId: 'emptytitle', html: '<meta property="og:title" content=""/>' },
  ];
  const T = (title: string, artists: string[], durationSec?: number): SpotifyTrack => ({ trackId: 'x', title, artists, durationSec });
  const hit = (videoId: string, title: string, channel: string | undefined, durationSec?: number): VideoHit => ({ videoId, title, channel, durationSec });
  const rankCases: { track: SpotifyTrack; hits: VideoHit[] }[] = [
    {
      track: T('Back In Black', ['AC/DC'], 255),
      hits: [
        hit('cover', 'Back In Black - AC/DC (DRUM COVER)', 'Some Drummer', 255),
        hit('live', 'AC/DC - Back In Black (Live At River Plate)', 'AC/DC', 270),
        hit('long', 'AC/DC - Back In Black (Extended)', 'Fan', 400),
        hit('topic', 'Back In Black', 'AC/DC - Topic', 255),
        hit('vevo', 'AC/DC - Back In Black (Official Video)', 'acdcVEVO', 256),
      ],
    },
    {
      track: T('Mr. Brightside', ['The Killers'], 222),
      hits: [
        hit('k1', 'The Killers - Mr. Brightside (Official Music Video)', 'TheKillersMusic', 228),
        hit('k2', 'Mr. Brightside (Live From The Royal Albert Hall)', 'The Killers', 240),
        hit('k3', 'Mr Brightside - lyrics', 'LyricVids', 222),
        hit('k4', 'mr. brightside but it’s slowed + reverb', 'chill', 300),
        hit('k5', 'Mr. Brightside', 'The Killers - Topic', 223),
      ],
    },
    {
      track: T('Señorita (Live)', ['Shawn Mendes', 'Camila Cabello']),
      hits: [hit('s1', 'Shawn Mendes, Camila Cabello - Señorita (Live)', 'ShawnMendesVEVO', 190), hit('s2', 'Senorita', undefined), hit('s3', 'Señorita karaoke version', 'Sing King', 191)],
    },
    { track: T('Untitled', []), hits: [hit('u1', 'Untitled', 'x', 0), hit('u2', 'Untitled', 'x', 0)] },
    { track: T('Song', ['Artist'], 200), hits: [hit('d1', 'Song', 'a', 203), hit('d2', 'Song', 'a', 210), hit('d3', 'Song', 'a', 230), hit('d4', 'Song', 'a', 300), hit('d5', 'Song 8D audio', 'a', 201)] },
  ];
  write('sources/links.json', {
    parseLink: linkInputs.map((input) => ({ input, expected: parseLink(input) })),
    decodeEntities: ['&quot;a&quot; &#65;', '&AMP; &Lt; &nbsp;|&apos;&#x1F600;&#X41;', '&unknown; & &;', '&#xD83D;', 'plain'].map((input) => ({ input, expected: decodeEntities(input) })),
    spotifyPages: pages.map((p) => ({ ...p, ...catchMsg(() => parseSpotifyTrackPage(p.trackId, p.html)) })),
    ranking: rankCases.map((c) => ({ ...c, scores: c.hits.map((h) => scoreMatch(c.track, h)), expected: rankMatches(c.track, c.hits).map((h) => h.videoId) })),
  });
}

// ---------------------------------------------------------------------------
// sources/spotify.json

async function spotifyFixtures() {
  const cfg = { clientId: '5faec3aab4e245f7a29760f019501648', redirectUri: 'lumbernative://spotify-callback' };
  const byteSets = [Array.from({ length: 64 }, (_, i) => i * 4), Array.from({ length: 43 }, (_, i) => 255 - i), Array.from({ length: 128 }, (_, i) => (i * 37) % 256), [1, 2, 3]];
  const verifiers = byteSets.map((bytes) => ({ bytes, ...catchMsg(() => makeVerifier(Uint8Array.from(bytes))) }));
  const challengeOf = (v: string) => toBase64Url(createHash('sha256').update(v).digest('base64'));
  const challenges = ['dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk', ...verifiers.flatMap((v) => ('value' in v ? [v.value as string] : [])), ''].map((verifier) => ({ verifier, challenge: challengeOf(verifier) }));
  const callbacks = [
    ['lumbernative://spotify-callback?code=abc%2B1&state=S', 'S'],
    ['lumbernative://spotify-callback?error=access_denied&state=S', 'S'],
    ['lumbernative://spotify-callback?error=server_error', 'S'],
    ['lumbernative://spotify-callback?code=x&state=EVIL', 'S'],
    ['lumbernative://spotify-callback?state=S', 'S'],
    ['lumbernative://spotify-callback?code=a+b%20c&state=S%20T#frag', 'S T'],
    ['lumbernative://spotify-callback', ''],
    ['lumbernative://spotify-callback?code=x=y&state=S&&', 'S'],
  ].map(([url, state]) => ({ url, state, ...catchMsg(() => parseCallback(url, state)) }));

  // Token requests through a recording fake.
  const calls: { url: string; method?: string; headers?: Record<string, string>; body?: string }[] = [];
  const replyFetch = (status: number, body: unknown): FetchLike => async (url, init) => {
    calls.push({ url, ...init });
    const text = typeof body === 'string' ? body : JSON.stringify(body);
    return { ok: status >= 200 && status < 300, status, json: async () => JSON.parse(text), text: async () => text };
  };
  const tokenCases: unknown[] = [];
  const run = async (name: string, status: number, body: unknown, f: (fetch: FetchLike) => Promise<unknown>) => {
    calls.length = 0;
    let result: unknown;
    try {
      result = { value: await f(replyFetch(status, body)) };
    } catch (e) {
      result = { error: String((e as Error).message) };
    }
    tokenCases.push({ name, status, body: typeof body === 'string' ? body : JSON.stringify(body), request: calls[0], ...(result as object) });
  };
  const prev = { accessToken: 'old', refreshToken: 'r1', expiresAt: 5, scope: 'prev-scope' };
  await run('exchange', 200, { access_token: 'A', refresh_token: 'R', expires_in: 3600, scope: 's' }, (f) => exchangeCode(f, cfg, 'CODE/+=', 'VER~._-', 1000));
  await run('exchange-defaults', 200, { access_token: 'A' }, (f) => exchangeCode(f, cfg, 'C', 'V', 1000));
  await run('refresh-keeps-old', 200, { access_token: 'new', expires_in: 60 }, (f) => refreshTokens(f, cfg, prev, 2000));
  await run('refresh-400', 400, { error: 'invalid_grant', error_description: 'Refresh token revoked' }, (f) => refreshTokens(f, cfg, prev, 2000));
  await run('refresh-500-html', 500, '<html>oops</html>', (f) => refreshTokens(f, cfg, prev, 2000));
  await run('refresh-401-error-only', 401, { error: 'invalid_client' }, (f) => refreshTokens(f, cfg, prev, 2000));

  const trackInputs = [
    { type: 'track', id: 'x', name: 'Song', artists: [{ name: 'A' }, { name: 'B' }, {}, { name: '' }], duration_ms: 204_500, album: { images: [{ url: 'img' }, { url: 'small' }] } },
    { type: 'episode', id: 'e' },
    { id: null, name: 'x' },
    { id: 'l', is_local: true, name: 'x' },
    { id: 'n', name: 'No dur', duration_ms: 0 },
    { id: 'r', name: 'Round', duration_ms: 1500, album: { images: [] } },
    { id: 'r2', name: 'Round2', duration_ms: 2499 },
    null,
  ];

  // API paging / URLs through a fake.
  const apiCalls: string[] = [];
  const apiFetch = (body: unknown): FetchLike => async (url) => {
    apiCalls.push(url);
    const text = JSON.stringify(body);
    return { ok: true, status: 200, json: async () => JSON.parse(text), text: async () => text };
  };
  const tok = async () => 'T';
  const pages: unknown[] = [];
  {
    const body = { items: [{ item: { id: 'a', name: 'One', artists: [] } }, { track: { id: 'b', name: 'Two', artists: [] } }, { item: null }, { item: { type: 'episode', id: 'ep' } }], next: 'https://…' };
    const r = await new SpotifyApi(apiFetch(body), tok).playlistTracks('pl 1/x', 50);
    pages.push({ kind: 'playlistTracks', id: 'pl 1/x', offset: 50, body, url: apiCalls.at(-1), expected: r });
  }
  {
    const body = { items: [{ track: { id: 't1', name: 'Liked', artists: [{ name: 'Z' }], duration_ms: 1000 } }], next: null };
    const r = await new SpotifyApi(apiFetch(body), tok).likedTracks(0);
    pages.push({ kind: 'likedTracks', offset: 0, body, url: apiCalls.at(-1), expected: r });
  }
  {
    const body = { items: [{ id: 'p1', name: 'Mine', items: { total: 12 }, images: [{ url: 'pimg' }] }, { id: 'p2', name: 'Old', tracks: { total: 3 } }, { name: 'no id' }, null], next: 'n' };
    const r = await new SpotifyApi(apiFetch(body), tok).playlists(100);
    pages.push({ kind: 'playlists', offset: 100, body, url: apiCalls.at(-1), expected: r });
  }
  {
    const body = { is_playing: true, item: { type: 'track', id: 'cp', name: 'Now', artists: [{ name: 'Q' }], duration_ms: 99_999 } };
    const r = await new SpotifyApi(apiFetch(body), tok).currentlyPlaying();
    pages.push({ kind: 'currentlyPlaying', body, url: apiCalls.at(-1), expected: r });
  }

  write('sources/spotify.json', {
    config: cfg,
    verifiers,
    challenges,
    authorizeUrl: { challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', state: 'st+ate/1', expected: buildAuthorizeUrl(cfg, 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', 'st+ate/1') },
    callbacks,
    tokens: tokenCases,
    toTrack: trackInputs.map((input) => ({ input, expected: toTrack(input) })),
    pages,
  });
}

// ---------------------------------------------------------------------------
// sources/localfile.json

function localFileFixtures() {
  const names = ['Song.M4A', 'a.aiff', 'a.flac', '01_Back In Black.mp3', 'x.WAV', 'noext', ' spaced.mp3 ', '.mp3', 'a.b.c.aif', '__.wav', 'weird.mp3x', 'trailingdot.'];
  write('sources/localfile.json', {
    names: names.map((n) => ({
      name: n,
      ext: extensionOf(n) ?? null,
      supported: isSupportedAudioName(n),
      title: titleFromFileName(n),
      stored: storedFileName('abcdef0123456789ffff', n),
    })),
    sha256: ['', 'abc', 'The quick brown fox jumps over the lazy dog', 'x'.repeat(1000)].map((s) => ({ input: s, hex: createHash('sha256').update(s).digest('hex') })),
  });
}

// ---------------------------------------------------------------------------
// ai/knobs.json + the generated Swift knob table

function swiftString(s: string): string {
  const j = JSON.stringify(s);
  if (/\\u|\\\//.test(j)) throw new Error(`can't express ${j} as a Swift literal`);
  return j;
}

function swiftNumber(n: number): string {
  return Number.isInteger(n) ? `${n}` : `${n}`;
}

function generateKnobTable() {
  const lines: string[] = [];
  lines.push('// GENERATED by scripts/native/fixtures-sources.ts from src/dsp/blanketTerms.ts,');
  lines.push('// src/dsp/presets.ts and src/dsp/blanketChain.ts (INTENSITY). Do not edit.');
  lines.push('//');
  lines.push('// The AI module only needs knob metadata; this table stands in for the DSP');
  lines.push("// module's Blanket term catalog until the two are unified.");
  lines.push('');
  lines.push('enum KnobTable {');
  lines.push(`    static let intensity: Double = ${INTENSITY}`);
  lines.push('');
  lines.push(`    static let categoryOrder: [String] = [${CATEGORY_ORDER.map(swiftString).join(', ')}]`);
  lines.push('');
  lines.push('    static let terms: [MixKnobInfo] = [');
  for (const k of BLANKET_TERM_KEYS) {
    const t = BLANKET_TERMS[k];
    lines.push(`        MixKnobInfo(key: ${swiftString(k)}, label: ${swiftString(t.label)}, category: ${swiftString(t.category)}, bipolar: ${t.bipolar},`);
    lines.push(`                    description: ${swiftString(t.description)}),`);
  }
  lines.push('    ]');
  lines.push('');
  lines.push('    static let presets: [MixPreset] = [');
  for (const p of PRESETS) {
    lines.push(`        MixPreset(id: ${swiftString(p.id)}, label: ${swiftString(p.label)},`);
    lines.push(`                  description: ${swiftString(p.description)},`);
    lines.push(`                  values: [${Object.entries(p.values).map(([k, v]) => `(${swiftString(k)}, ${swiftNumber(v as number)})`).join(', ')}]),`);
  }
  lines.push('    ]');
  lines.push('}');
  mkdirSync(AI_SRC, { recursive: true });
  writeFileSync(join(AI_SRC, 'KnobCatalog.generated.swift'), lines.join('\n') + '\n');
  console.log('wrote Sources/LumberCore/AI/KnobCatalog.generated.swift');
}

function knobFixtures() {
  const base = fillValues({ warmth: 0.2, air: -0.5 });
  const sanitizeInputs: unknown[] = [
    { punch: 0.5, air: -2, bogus: 1, warmth: 'loud', depth: null },
    null,
    [1, 2],
    'x',
    { denoise: 0.9, roominess: -1, brightness: 0.12345, width: 1e-9, volume: -7, sustain: 1.0005 },
    {},
  ];
  write('ai/knobs.json', {
    keys: BLANKET_TERM_KEYS,
    ranges: BLANKET_TERM_KEYS.map((k) => ({ key: k, ...knobRange(k) })),
    clamp: BLANKET_TERM_KEYS.flatMap((k) => [3, -0.5, -4, 0.1234567, 0.0005, -0.0005, 0.35].map((v) => ({ key: k, input: v, expected: clampKnob(k, v) }))),
    effective: BLANKET_TERM_KEYS.flatMap((k) => [-0.4, 0.4].map((v) => ({ key: k, input: v, expected: effectiveValue(k, v) }))),
    gain: [-1, 0, 0.12345, 1.5, 1.50049, 9].map((g) => ({ input: g, expected: clampGain(g) })),
    base,
    sanitize: sanitizeInputs.map((raw) => {
      const r = sanitizeValues(raw, base);
      return { input: raw, values: r.values, dropped: r.dropped };
    }),
    changed: { a: base, b: fillValues({ warmth: 0.2005, air: -0.5, punch: 0.0011 }), expected: changedTerms(base, fillValues({ warmth: 0.2005, air: -0.5, punch: 0.0011 })) },
  });
}

// ---------------------------------------------------------------------------
// ai/analyze.json: descriptors of synthetic signals the Swift tests rebuild

type Sig =
  | { type: 'tone'; freq: number; amp: number; n: number }
  | { type: 'noise'; n: number; seed: number }
  | { type: 'diff'; of: Sig }
  | { type: 'lowpass'; of: Sig; a: number }
  | { type: 'neg'; of: Sig }
  | { type: 'hits'; sec: number; every: number; tau: number; amp: number }
  | { type: 'zeros'; n: number }
  | { type: 'concat'; parts: Sig[] }
  | { type: 'pulses'; n: number; period: number; width: number; amp: number }
  | { type: 'slowSine'; n: number; amp: number; div: number };

const SR = 48000;

function build(s: Sig): Float32Array {
  switch (s.type) {
    case 'tone': {
      const x = new Float32Array(s.n);
      for (let i = 0; i < s.n; i++) x[i] = s.amp * Math.sin((2 * Math.PI * s.freq * i) / SR);
      return x;
    }
    case 'noise': {
      let st = s.seed >>> 0;
      const x = new Float32Array(s.n);
      for (let i = 0; i < s.n; i++) {
        st = (st * 1664525 + 1013904223) >>> 0;
        x[i] = st / 2 ** 31 - 1;
      }
      return x;
    }
    case 'diff': {
      const x = build(s.of);
      const y = new Float32Array(x.length);
      for (let i = 1; i < x.length; i++) y[i] = 0.5 * (x[i] - x[i - 1]);
      return y;
    }
    case 'lowpass': {
      const x = build(s.of);
      const y = new Float32Array(x.length);
      let p = 0;
      for (let i = 0; i < x.length; i++) y[i] = p = s.a * p + (1 - s.a) * x[i];
      return y;
    }
    case 'neg':
      return build(s.of).map((v) => -v);
    case 'hits': {
      const n = Math.floor(s.sec * SR);
      const x = new Float32Array(n);
      const nz = build({ type: 'noise', n, seed: 7 });
      const period = Math.floor(s.every * SR);
      for (let i = 0; i < n; i++) {
        const t = (i % period) / SR;
        x[i] = s.amp * nz[i] * Math.exp(-t / s.tau);
      }
      return x;
    }
    case 'zeros':
      return new Float32Array(s.n);
    case 'concat': {
      const parts = s.parts.map(build);
      const out = new Float32Array(parts.reduce((a, p) => a + p.length, 0));
      let o = 0;
      for (const p of parts) {
        out.set(p, o);
        o += p.length;
      }
      return out;
    }
    case 'pulses':
      return new Float32Array(s.n).map((_, i) => (i % s.period < s.width ? s.amp : 0));
    case 'slowSine':
      return new Float32Array(s.n).map((_, i) => s.amp * Math.sin(i / s.div));
  }
}

const noiseSig = (sec: number, seed = 1): Sig => ({ type: 'noise', n: Math.round(SR * sec), seed });
const hitsSig = (sec: number, every: number, tau: number, amp = 0.8): Sig => ({ type: 'hits', sec, every, tau, amp });

interface AnalyzeCase {
  name: string;
  channels: Sig[];
  opts?: { startSec?: number; maxSec?: number; fftWindows?: number };
}

const ANALYZE_CASES: AnalyzeCase[] = [
  { name: 'sine1k', channels: [{ type: 'tone', freq: 1000, amp: 0.5, n: SR * 4 }] },
  { name: 'tone80', channels: [{ type: 'tone', freq: 80, amp: 0.5, n: SR * 2 }] },
  { name: 'brightNoise', channels: [{ type: 'diff', of: noiseSig(4) }] },
  { name: 'darkNoise', channels: [{ type: 'lowpass', of: noiseSig(4), a: 0.97 }] },
  { name: 'kit', channels: [hitsSig(8, 0.25, 0.03)] },
  { name: 'ringy', channels: [hitsSig(8, 0.5, 0.12)] },
  { name: 'stereoSame', channels: [noiseSig(2, 3), noiseSig(2, 3)] },
  { name: 'stereoNeg', channels: [noiseSig(2, 3), { type: 'neg', of: noiseSig(2, 3) }] },
  { name: 'stereoIndep', channels: [noiseSig(2, 3), noiseSig(2, 9)] },
  { name: 'silence', channels: [{ type: 'zeros', n: SR }] },
  { name: 'empty', channels: [{ type: 'zeros', n: 0 }] },
  { name: 'short', channels: [{ type: 'tone', freq: 440, amp: 0.3, n: 3000 }] },
  { name: 'firstHalf', channels: [{ type: 'concat', parts: [{ type: 'zeros', n: SR * 5 }, { type: 'tone', freq: 1000, amp: 0.5, n: SR * 5 }] }], opts: { maxSec: 5 } },
  { name: 'secondHalf', channels: [{ type: 'concat', parts: [{ type: 'zeros', n: SR * 5 }, { type: 'tone', freq: 1000, amp: 0.5, n: SR * 5 }] }], opts: { startSec: 5, maxSec: 5 } },
  { name: 'fewWindows', channels: [hitsSig(4, 0.25, 0.05)], opts: { fftWindows: 3, startSec: 0.5 } },
  { name: 'oneWindow', channels: [{ type: 'diff', of: noiseSig(0.1, 5) }] },
  { name: 'pulses', channels: [{ type: 'pulses', n: SR * 4, period: 12000, width: 400, amp: 0.5 }] },
  { name: 'slowSine', channels: [{ type: 'slowSine', n: SR * 6, amp: 0.1, div: 10 }], opts: { startSec: 2, maxSec: 4 } },
  { name: 'threeChannels', channels: [noiseSig(1, 1), noiseSig(1, 2), noiseSig(1, 3)] },
];

function analyzeFixtures() {
  write('ai/analyze.json', {
    sampleRate: SR,
    cases: ANALYZE_CASES.map((c) => {
      const chs = c.channels.map(build);
      const d = analyzeAudio(chs, SR, c.opts);
      return { ...c, opts: c.opts ?? null, firstSamples: chs.map((x) => Array.from(x.slice(0, 4))), descriptors: d, rounded: roundDescriptors(d) };
    }),
  });
}

// ---------------------------------------------------------------------------
// ai/localmix.json

function desc(over: Partial<AudioDescriptors> = {}, bands: Partial<AudioDescriptors['bands']> = {}): AudioDescriptors {
  return {
    durationSec: 20,
    channels: 1,
    rmsDb: -20,
    peakDb: -4,
    crestDb: 16,
    loudnessLufs: -20,
    dynamicRangeDb: 30,
    noiseFloorDb: -55,
    bands: { sub: -18, low: -8, lowMid: -8, mid: -6, presence: -9, air: -18, ...bands },
    centroidHz: 3000,
    onsetsPerSec: 4,
    decayMs: 150,
    stereoWidth: null,
    ...over,
  };
}
const ctx = (drums: AudioDescriptors, song: AudioDescriptors | null = null, songIsDrumless = false): MixAnalysis => ({ drums, song, songIsDrumless });

function localMixFixtures() {
  const analyses: Record<string, MixAnalysis | null> = {
    none: null,
    neutral: ctx(desc()),
    brightTake: ctx(desc({ centroidHz: 6000 }, { air: -8 })),
    dullTake: ctx(desc({ centroidHz: 1200 }, { air: -30 })),
    boomyTake: ctx(desc({}, { sub: -6, low: -2 })),
    leanTake: ctx(desc({}, { sub: -30, low: -20, lowMid: -16 })),
    muddyTake: ctx(desc({}, { lowMid: -4 })),
    ringyTake: ctx(desc({ decayMs: 400 })),
    shortTake: ctx(desc({ decayMs: 60 })),
    squashed: ctx(desc({ crestDb: 9 })),
    spiky: ctx(desc({ crestDb: 24 })),
    hissy: ctx(desc({ rmsDb: -30, noiseFloorDb: -48 })),
    quiet: ctx(desc({ rmsDb: -20, noiseFloorDb: -80 })),
    stereo: ctx(desc({ stereoWidth: 0.2, channels: 2 })),
    brightSong: ctx(desc({ centroidHz: 2000 }), desc({ centroidHz: 4000, decayMs: 400 })),
    darkSong: ctx(desc({ centroidHz: 4000, decayMs: 300 }), desc({ centroidHz: 1500, decayMs: 100 })),
    busySong: ctx(desc({}, { presence: -12 }), desc({}, { presence: -6 }), true),
    similarSong: ctx(desc(), desc({ centroidHz: 3100 })),
    analysed: ctx(
      analyzeAudio([build(hitsSig(4, 0.25, 0.05))], SR),
      analyzeAudio([build({ type: 'lowpass', of: noiseSig(4), a: 0.97 })], SR),
    ),
  };
  const starts: Record<string, Partial<Record<string, number>>> = {
    zero: {},
    warm: { warmth: 0.5, punch: 0.2 },
    mirrored: { punch: -0.4, brightness: -0.4 },
    busy: { warmth: 0.8, punch: 0.8, depth: 0.6 },
    extremes: { warmth: 0.9, air: -0.9, punch: 0.9, denoise: 0.35, width: 1 },
  };
  const prompts = [
    'warmer', 'brighter please', 'less bright', 'darker', 'punchy', 'tight', 'it sounds boomy', 'less boomy', 'more boom',
    'too muddy', 'boxy', 'thin', 'harsh cymbals', 'not bright enough', 'punchy and dry like a 90s rock record',
    'less boomy, more room', 'less boomy more room', 'a bit warmer', 'way warmer', 'much more room', 'more room',
    'slightly less boomy', 'punchier', 'way way punchier, punchy, punch, more punch, extremely punchy',
    'extremely noisy, so much hiss', 'less compressed', 'reset', 'more natural', 'start over, then warm', 'lo-fi', 'vintage',
    'modern and polished', 'modern', "80's", 'big', 'crisp', 'clean up the mud', 'drums louder', 'turn the song down a bit',
    'more song', 'the song is too loud', 'lower the boom', 'extremely louder drums', 'warmer drums', 'asdf qwerty', '',
    'drier', 'more compressed', 'less noise', 'wider', 'make the drums fit the song', 'blend in with the mix',
    'warm vintage jazz with brushes', 'huge 80s gated snare', 'tight funk, ghost notes up', 'lofi hip-hop',
    'modern metal, very tight and clicky', 'not so harsh, a little more air', 'way less ring and no reverb',
    'thick snare, fat kick, softer cymbals', 'cut through the mix', 'make it sound like a phone recording',
    'Less “boomy”; MORE room!', "don't make it harsh", "isn't punchy enough", 'the nineties grunge sound', "'70s soul",
    'give it more air and sparkle', 'remove the hum and the buzz', 'no clipping please', 'sixties motown with tape warmth',
    'turn the drums way up in the mix', 'bring the guitars up', 'song quieter and drums louder', 'less pumping',
    'more even hits', 'mono', 'narrower and drier', 'stadium arena rock', 'kick and snare', 'hi-hats too loud',
    'not too bright, not too dark', 'unprocessed please', 'transparent but punchy', 'less natural', 'more processed and less natural',
    'cleaner', 'clean up', 'the kick needs more weight', 'needs more snap on the snare', 'too much bleed in the background',
    'I want it wetter, like a hall', 'make it boingy', 'tame the overtones', 'distant and spacious', 'upfront and in your face',
    'soft and gentle', 'aggressive edge', 'telephone', 'super crushed and distorted', 'slam!', 'glue it together',
    'ever so slightly brighter', 'a hair warmer', 'totally dry', 'ridiculously huge',
  ];
  const cases: unknown[] = [];
  const g0 = { songGain: 0.8, drumGain: 1 };
  for (const p of prompts) {
    for (const a of ['none', 'neutral', 'analysed']) cases.push({ prompt: p, start: 'zero', analysis: a, ...g0 });
  }
  const extra: [string, string, string, { songGain: number; drumGain: number }?][] = [
    ['warmer', 'warm', 'none'],
    ['punchier', 'mirrored', 'none'],
    ['reset', 'busy', 'none'],
    ['more natural', 'busy', 'none'],
    ['start over, then warm', 'busy', 'none'],
    ['punchy and dry like a 90s rock record', 'extremes', 'analysed'],
    ['way less ring and no reverb', 'extremes', 'analysed'],
    ['extremely louder drums', 'zero', 'none', { songGain: 0.8, drumGain: 1.45 }],
    ['turn the song down a bit', 'zero', 'none', { songGain: 0.05, drumGain: 0 }],
    ['natural and warm', 'busy', 'neutral'],
    ['wider and brighter', 'mirrored', 'stereo'],
  ];
  for (const [p, s, a, g] of extra) cases.push({ prompt: p, start: s, analysis: a, ...(g ?? g0) });
  const scaled = ['brighter', 'darker', 'more air', 'less air', 'less boomy', 'more boom', 'thin', 'fuller', 'muddy', 'boxy', 'drier', 'more room', 'tighter', 'ringy', 'more compressed', 'less compressed', 'punchier', 'more dynamic', 'less noise', 'noisier', 'wider', 'more present', 'fit the song', 'more kick', 'harsh', 'more bite', 'less bite', 'cut through'];
  for (const p of scaled) {
    for (const a of Object.keys(analyses)) if (a !== 'none' && a !== 'neutral' && a !== 'analysed') cases.push({ prompt: p, start: 'zero', analysis: a, ...g0 });
  }
  write('ai/localmix.json', {
    keys: BLANKET_TERM_KEYS,
    analyses,
    starts,
    cases: (cases as { prompt: string; start: string; analysis: string; songGain: number; drumGain: number }[]).map((c) => ({
      ...c,
      expected: interpretLocally({ prompt: c.prompt, values: fillValues(starts[c.start] as never), songGain: c.songGain, drumGain: c.drumGain, analysis: analyses[c.analysis] }),
    })),
  });
}

// ---------------------------------------------------------------------------
// ai/claude.json

function claudeFixtures() {
  const d: AudioDescriptors = {
    durationSec: 20.123,
    channels: 1,
    rmsDb: -21.456,
    peakDb: -3.2,
    crestDb: 18.25,
    loudnessLufs: -19.9,
    dynamicRangeDb: 31,
    noiseFloorDb: -58,
    bands: { sub: -20, low: -7, lowMid: -9, mid: -6, presence: -8, air: -17 },
    centroidHz: 3123.4,
    onsetsPerSec: 4.123,
    decayMs: 140.6,
    stereoWidth: null,
  };
  const neg: AudioDescriptors = { ...d, rmsDb: -0.04, peakDb: -120, crestDb: 0.05, centroidHz: 2.5, decayMs: -0.5, onsetsPerSec: 0.005, stereoWidth: 0.0004, bands: { ...d.bands, air: -0.05 } };
  const inputs: Record<string, ClaudeMixInput> = {
    full: { prompt: '  punchy and dry like a 90s rock record ', values: fillValues({ warmth: 0.3 }), songGain: 0.8, drumGain: 1, analysis: { drums: d, song: { ...d, channels: 2, stereoWidth: 0.21 }, songIsDrumless: true } },
    noAnalysis: { prompt: 'warmer "please"\n\ttabs \\ and \u0001 ctrl — ünïcödé 🥁', values: fillValues({ punch: -0.25, air: 1e-7, depth: 123456789012345680000 }), songGain: 1.5, drumGain: 0, analysis: null },
    noSong: { prompt: 'x', values: zeroValues(), songGain: 0.123456789, drumGain: 1, hasStems: true, analysis: { drums: neg, song: null, songIsDrumless: false } },
    stems: { prompt: 'blend', values: zeroValues(), songGain: 1, drumGain: 1, hasStems: true, originalDrums: 0.35, analysis: { drums: d, song: d, songIsDrumless: false } },
  };
  const requestOf = (input: ClaudeMixInput, model?: 'claude-opus-5-5' | 'claude-haiku-5-5') => {
    const { betas, ...body } = buildRequest(input, model) as ReturnType<typeof buildRequest> & { betas?: string[] };
    return { body: JSON.stringify(body), betas: betas ?? [] };
  };
  const cur = { values: fillValues({ warmth: 0.3 }), songGain: 0.8, drumGain: 1 };
  const replies: string[] = [
    JSON.stringify({ values: { ...fillValues({ punch: 0.6, depth: 2, air: -3, denoise: 0.9 }), bogus: 1 }, songGain: 0.8, drumGain: 1.2, explanation: '  Tighter. ' }),
    JSON.stringify({ values: { punch: 0.5 }, songGain: null, drumGain: 9, explanation: '' }),
    'Sure! Here you go',
    '{"explanation":"x"}',
    '[1,2]',
    'null',
    '{"values":"nope"}',
    JSON.stringify({ values: {}, songGain: 0.8004, drumGain: 1.0011, explanation: 'x'.repeat(450) }),
    JSON.stringify({ values: { warmth: 'hot' }, songGain: '0.5', explanation: 42 }),
    JSON.stringify({ values: { brightness: -0.12345 }, songGain: -1, drumGain: 0.9995, explanation: '  ' + 'word '.repeat(90) }),
  ];
  write('ai/claude.json', {
    systemPrompt: buildSystemPrompt(),
    knobCatalog: JSON.stringify(knobCatalog()),
    outputSchema: JSON.stringify(OUTPUT_SCHEMA),
    inputs,
    userMessages: Object.fromEntries(Object.entries(inputs).map(([k, v]) => [k, buildUserMessage(v)])),
    requests: Object.fromEntries(
      Object.entries(inputs).flatMap(([k, v]) => [
        [`${k}/opus`, requestOf(v)],
        [`${k}/haiku`, requestOf(v, 'claude-haiku-5-5')],
      ]),
    ),
    current: cur,
    replies: replies.map((text) => {
      try {
        return { text, expected: parseSuggestion(text, cur) };
      } catch (e) {
        return { text, errorKind: (e as ClaudeMixError).kind, error: (e as Error).message };
      }
    }),
  });
}

async function main() {
  youtubeFixtures();
  linksFixtures();
  await spotifyFixtures();
  localFileFixtures();
  generateKnobTable();
  knobFixtures();
  analyzeFixtures();
  localMixFixtures();
  claudeFixtures();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
