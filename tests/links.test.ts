// Offline tests for pasted-link handling. Run: npx tsx tests/links.test.ts
import { decodeEntities, parseLink, parseSpotifyTrackPage, rankMatches, resolveLink } from '../src/sources/links';
import type { FetchLike, VideoHit } from '../src/sources/youtubeCore';

const fail = (msg: string): never => {
  throw new Error(msg);
};
const eq = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) fail(`${JSON.stringify(a)} != ${JSON.stringify(b)}`);
};

const PAGE = `<html><head>
<meta property="og:title" content="Don&#x27;t Stop Me Now &amp; More"/>
<meta property="og:description" content="Queen · Jazz · Song · 1978"/>
<meta property="og:image" content="https://i.scdn.co/image/abc"/>
<meta name="music:duration" content="209"/>
<meta name="music:musician_description" content="Queen, Guest Artist"/>
</head></html>`;

const hit = (videoId: string, title: string, channel: string, durationSec: number): VideoHit => ({ videoId, title, channel, durationSec });

const tests: [string, () => void | Promise<void>][] = [
  [
    'parses YouTube link shapes',
    () => {
      for (const l of [
        'https://www.youtube.com/watch?v=pAgnJDJN4VA&t=10s',
        'youtube.com/watch?feature=share&v=pAgnJDJN4VA',
        'https://youtu.be/pAgnJDJN4VA?si=xyz',
        'https://music.youtube.com/watch?v=pAgnJDJN4VA&list=RD',
        'https://m.youtube.com/shorts/pAgnJDJN4VA',
      ])
        eq(parseLink(l), { kind: 'youtube', videoId: 'pAgnJDJN4VA' });
    },
  ],
  [
    'parses Spotify link shapes',
    () => {
      for (const l of [
        'https://open.spotify.com/track/08mG3Y1vljYA6bvDt4Wqkj?si=abc',
        'https://open.spotify.com/intl-de/track/08mG3Y1vljYA6bvDt4Wqkj',
        'spotify:track:08mG3Y1vljYA6bvDt4Wqkj',
      ])
        eq(parseLink(l), { kind: 'spotify', trackId: '08mG3Y1vljYA6bvDt4Wqkj' });
      eq(parseLink('https://spotify.link/AbCdEf'), { kind: 'spotify-short', url: 'https://spotify.link/AbCdEf' });
    },
  ],
  [
    'ignores plain searches and unsupported links',
    () => {
      eq(parseLink('back in black'), null);
      eq(parseLink('https://open.spotify.com/album/1wOhTFS4m9tbPGlKbwGaBg'), null);
      eq(parseLink('https://example.com/watch?v=pAgnJDJN4VA'), null);
    },
  ],
  [
    'reads a Spotify track page',
    () => {
      const t = parseSpotifyTrackPage('id', PAGE);
      eq(t.title, "Don't Stop Me Now & More");
      eq(t.artists, ['Queen', 'Guest Artist']);
      eq(t.durationSec, 209);
      eq(t.artworkUrl, 'https://i.scdn.co/image/abc');
      eq(decodeEntities('&quot;a&quot; &#65;'), '"a" A');
    },
  ],
  [
    'ranks the studio upload over covers, live and wrong-length versions',
    () => {
      const track = { trackId: 'x', title: 'Back In Black', artists: ['AC/DC'], durationSec: 255 };
      const ranked = rankMatches(track, [
        hit('cover', 'Back In Black - AC/DC (DRUM COVER)', 'Some Drummer', 255),
        hit('live', 'AC/DC - Back In Black (Live At River Plate)', 'AC/DC', 270),
        hit('long', 'AC/DC - Back In Black (Extended)', 'Fan', 400),
        hit('topic', 'Back In Black', 'AC/DC - Topic', 255),
        hit('vevo', 'AC/DC - Back In Black (Official Video)', 'acdcVEVO', 256),
      ]);
      eq(ranked.slice(0, 2).map((h) => h.videoId), ['topic', 'vevo']);
      eq(ranked[ranked.length - 1].videoId, 'long');
    },
  ],
  [
    'resolves a Spotify link end to end with a fake network',
    async () => {
      const calls: string[] = [];
      const fake: FetchLike = async (url) => {
        calls.push(url);
        const ok = (body: unknown) => ({
          ok: true,
          status: 200,
          json: async () => body,
          text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
        });
        if (url.includes('open.spotify.com/track/')) return ok(PAGE);
        if (url.includes('sw.js_data')) {
          const inner: unknown[] = [];
          inner[13] = 'VISITOR123'; // parseVisitorData reads [0][2][0][0][13]
          return ok(`)]}'` + JSON.stringify([[null, null, [[inner]]]]));
        }
        if (url.includes('/youtubei/v1/search')) {
          const vr = (videoId: string, title: string, owner: string, len: string) => ({
            videoRenderer: { videoId, title: { runs: [{ text: title }] }, ownerText: { runs: [{ text: owner }] }, lengthText: { simpleText: len } },
          });
          return ok({ contents: [vr('a', "Don't Stop Me Now (Live)", 'Queen', '3:45'), vr('b', "Queen - Don't Stop Me Now (Official Video)", 'Queen Official', '3:29')] });
        }
        return { ok: false, status: 404, json: async () => ({}), text: async () => '' };
      };
      const r = await resolveLink('https://open.spotify.com/track/7hQJA50XrCWABAu5v6QZ4i', fake);
      if (!r) fail('expected results');
      eq(r!.label, "Spotify: Queen, Guest Artist – Don't Stop Me Now & More");
      eq(r!.results[0].externalId, 'b');
      if (!calls.some((c) => c.includes('/search'))) fail('expected a YouTube search');
    },
  ],
];

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`  ok  ${name}`);
    } catch (e) {
      failed++;
      console.log(`  FAIL ${name}: ${(e as Error).message}`);
    }
  }
  console.log(`${tests.length - failed}/${tests.length} link tests passed`);
  if (failed) process.exit(1);
})();
