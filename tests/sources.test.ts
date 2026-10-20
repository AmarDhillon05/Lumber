// Node tests for the pure source logic. Run: npx tsx tests/sources.test.ts
// Set YT_LIVE=1 to also hit YouTube (search + resolve, no media download).
import assert from 'node:assert/strict';
import {
  CLIENTS,
  bestThumbnail,
  chunkUrl,
  downloadAudio,
  isMp4,
  mp4Brand,
  parseClock,
  parsePlayerResponse,
  parseSearchResponse,
  parseVisitorData,
  pickAudioFormat,
  planChunks,
  resolveAudio,
  searchVideos,
  type AdaptiveFormat,
  type FetchLike,
} from '../src/sources/youtubeCore';
import { extensionOf, isSupportedAudioName, storedFileName, titleFromFileName } from '../src/sources/localFileCore';

const tests: [string, () => void | Promise<void>][] = [];
const test = (name: string, fn: () => void | Promise<void>) => tests.push([name, fn]);

test('parseClock', () => {
  assert.equal(parseClock('4:15'), 255);
  assert.equal(parseClock('1:02:03'), 3723);
  assert.equal(parseClock('0:07'), 7);
  assert.equal(parseClock(undefined), undefined);
});

test('planChunks covers every byte exactly once', () => {
  assert.deepEqual(planChunks(0), []);
  assert.deepEqual(planChunks(10, 4), [
    { start: 0, end: 3 },
    { start: 4, end: 7 },
    { start: 8, end: 9 },
  ]);
  assert.deepEqual(planChunks(8, 4), [
    { start: 0, end: 3 },
    { start: 4, end: 7 },
  ]);
  const p = planChunks(4_075_204);
  assert.equal(p.length, 1);
  assert.equal(p[0].end, 4_075_203);
});

test('chunkUrl appends range', () => {
  assert.equal(chunkUrl('https://x/v?a=1', { start: 0, end: 9 }), 'https://x/v?a=1&range=0-9');
});

test('isMp4 / brand', () => {
  const b = new Uint8Array([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x64, 0x61, 0x73, 0x68]);
  assert.equal(isMp4(b), true);
  assert.equal(mp4Brand(b), 'dash');
  assert.equal(isMp4(new Uint8Array([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0])), false); // webm
});

const fmt = (o: Partial<AdaptiveFormat>): AdaptiveFormat => ({ itag: 0, mimeType: '', url: 'https://g/v?clen=100', ...o });

test('pickAudioFormat prefers itag 140, skips opus, DRC, ciphered, dubbed', () => {
  const formats = [
    fmt({ itag: 251, mimeType: 'audio/webm; codecs="opus"', bitrate: 160000 }),
    fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, xtags: 'CggKA2RyYxIBMQ', isDrc: true }),
    fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, audioTrack: { audioIsDefault: false } }),
    fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000 }),
    fmt({ itag: 139, mimeType: 'audio/mp4; codecs="mp4a.40.5"', bitrate: 50000 }),
    fmt({ itag: 141, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 260000, url: undefined, signatureCipher: 's=..' }),
    fmt({ itag: 137, mimeType: 'video/mp4; codecs="avc1"', bitrate: 4000000 }),
  ];
  const f = pickAudioFormat(formats)!;
  assert.equal(f.itag, 140);
  assert.equal(f.isDrc, undefined);
  assert.equal(f.audioTrack, undefined);
  assert.equal(pickAudioFormat([formats[0]]), undefined);
  assert.equal(pickAudioFormat([formats[4]])!.itag, 139);
});

test('parsePlayerResponse', () => {
  const ok = parsePlayerResponse('vid', CLIENTS.ANDROID_VR, {
    playabilityStatus: { status: 'OK' },
    videoDetails: { title: 'T', author: 'A', lengthSeconds: '252', thumbnail: { thumbnails: [{ url: 'https://i/a.jpg', width: 1, height: 1 }, { url: 'https://i/b.jpg?x=1', width: 9, height: 9 }] } },
    streamingData: { adaptiveFormats: [fmt({ itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', url: 'https://g/v?clen=4075204&x=1' })] },
  });
  assert.ok('url' in ok);
  if ('url' in ok) {
    assert.equal(ok.contentLength, 4075204);
    assert.equal(ok.durationSec, 252);
    assert.equal(ok.thumbnailUrl, 'https://i/b.jpg');
    assert.equal(ok.client, 'ANDROID_VR');
  }
  const bad = parsePlayerResponse('vid', CLIENTS.IOS, { playabilityStatus: { status: 'LOGIN_REQUIRED', reason: 'bot' } });
  assert.deepEqual(bad, { status: 'LOGIN_REQUIRED', reason: 'bot' });
});

test('parseSearchResponse walks nested renderers, skips live', () => {
  const vr = (id: string, len?: string) => ({
    videoRenderer: {
      videoId: id,
      title: { runs: [{ text: `Title ${id}` }] },
      ownerText: { runs: [{ text: 'Chan' }] },
      ...(len ? { lengthText: { simpleText: len } } : {}),
      thumbnail: { thumbnails: [{ url: '//i.ytimg.com/x.jpg', width: 10, height: 10 }] },
    },
  });
  const json = { contents: { a: [{ itemSectionRenderer: { contents: [vr('a', '4:14'), vr('live'), { shelf: { items: [vr('b', '1:00:00'), vr('a', '4:14')] } }] } }] } };
  const hits = parseSearchResponse(json);
  assert.deepEqual(hits.map((h) => h.videoId), ['a', 'b']);
  assert.equal(hits[0].durationSec, 254);
  assert.equal(hits[0].channel, 'Chan');
  assert.equal(hits[0].thumbnailUrl, 'https://i.ytimg.com/x.jpg');
});

test('parseVisitorData', () => {
  const raw = `)]}'` + JSON.stringify([[null, null, [[[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 'CgtVISITOR']]]]]);
  assert.equal(parseVisitorData(raw), 'CgtVISITOR');
});

test('bestThumbnail picks largest', () => {
  assert.equal(bestThumbnail([{ url: 'a', width: 1, height: 1 }, { url: 'b', width: 2, height: 2 }]), 'b');
  assert.equal(bestThumbnail([]), undefined);
});

test('downloadAudio: chunked, retries, progress, ftyp check', async () => {
  const total = 25;
  const data = new Uint8Array(total).map((_, i) => i);
  data.set([0x66, 0x74, 0x79, 0x70], 4);
  let failOnce = true;
  const out: number[] = [];
  const progress: number[] = [];
  const urls: string[] = [];
  const n = await downloadAudio(
    { url: 'https://g/v?x=1', contentLength: total, userAgent: 'ua' },
    {
      async fetchRange(url, headers) {
        assert.equal(headers['user-agent'], 'ua');
        urls.push(url);
        const [a, b] = /range=(\d+)-(\d+)/.exec(url)!.slice(1).map(Number);
        if (a === 10 && failOnce) {
          failOnce = false;
          throw new Error('HTTP 503');
        }
        return data.slice(a, b + 1);
      },
      async append(bytes) {
        out.push(...bytes);
      },
    },
    { chunkBytes: 10, onProgress: (f) => progress.push(f), sleep: async () => {} },
  );
  assert.equal(n, total);
  assert.deepEqual(out, Array.from(data));
  assert.equal(urls.length, 4); // 3 chunks + 1 retry
  assert.equal(progress[progress.length - 1], 1);

  await assert.rejects(
    downloadAudio(
      { url: 'https://g/v', contentLength: 8, userAgent: 'ua' },
      { fetchRange: async () => new Uint8Array(8), append: async () => {} },
      { retries: 0 },
    ),
    /ftyp/,
  );
});

test('localFile helpers', () => {
  assert.equal(extensionOf('Song.M4A'), 'm4a');
  assert.equal(isSupportedAudioName('a.aiff'), true);
  assert.equal(isSupportedAudioName('a.flac'), false);
  assert.equal(titleFromFileName('01_Back In Black.mp3'), '01 Back In Black');
  assert.equal(storedFileName('abcdef0123456789ffff', 'x.WAV'), 'file-abcdef0123456789.wav');
});

if (process.env.YT_LIVE) {
  const f = fetch as unknown as FetchLike;
  test('LIVE: search + resolve m4a', async () => {
    const hits = await searchVideos('ac/dc back in black', f);
    assert.ok(hits.length > 3);
    let resolved;
    for (const h of hits.slice(0, 5)) {
      try {
        resolved = await resolveAudio(h.videoId, f);
        break;
      } catch {}
    }
    assert.ok(resolved, 'no playable result');
    assert.equal(resolved!.itag, 140);
    assert.match(resolved!.mimeType, /^audio\/mp4/);
  });
}

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`ok   ${name}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}\n     ${(e as Error).message}`);
    }
  }
  console.log(`${tests.length - failed}/${tests.length} passed`);
  if (failed) process.exit(1);
})();
