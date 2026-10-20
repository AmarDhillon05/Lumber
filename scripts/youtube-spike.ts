// YouTube spike: search → resolve audio-only m4a → ranged download of the
// first ~2 MB → verify the ISO-BMFF `ftyp` box. Uses the same pure core as the
// app (src/sources/youtubeCore.ts), with Node's global fetch.
//
//   npx tsx scripts/youtube-spike.ts ["query"] [maxBytes]
import {
  CLIENTS,
  DEFAULT_CLIENT_ORDER,
  PlayabilityError,
  chunkUrl,
  getVisitorData,
  isMp4,
  mediaHeaders,
  mp4Brand,
  planChunks,
  resolveAudio,
  searchVideos,
  type FetchLike,
} from '../src/sources/youtubeCore';

const query = process.argv[2] ?? 'ac/dc back in black';
const maxBytes = Number(process.argv[3] ?? 2 * 1024 * 1024);
const fetchLike = fetch as unknown as FetchLike;

async function main() {
  const t0 = Date.now();
  const vd = await getVisitorData(fetchLike);
  console.log(`visitorData ok (${vd.length} chars)`);

  const hits = await searchVideos(query, fetchLike, vd);
  console.log(`search "${query}": ${hits.length} results`);
  for (const h of hits.slice(0, 5)) {
    console.log(`  ${h.videoId}  ${String(h.durationSec).padStart(4)}s  ${h.channel} — ${h.title}`);
  }

  // Resolve: try results in order until one is playable for some client.
  let audio;
  for (const h of hits.slice(0, 8)) {
    try {
      audio = await resolveAudio(h.videoId, fetchLike, { visitorData: vd });
      break;
    } catch (e) {
      if (e instanceof PlayabilityError) console.log(`  skip ${h.videoId}: ${e.attempts.map((a) => `${a.client}=${a.status}`).join(', ')}`);
      else throw e;
    }
  }
  if (!audio) throw new Error('no playable result');
  const urlIp = /[?&]ip=([^&]+)/.exec(audio.url)?.[1];
  console.log(
    `resolved ${audio.videoId} via ${audio.client}: itag=${audio.itag} mime="${audio.mimeType}" ` +
      `size=${audio.contentLength}B dur=${audio.durationSec}s cipher=no n-param=${/[?&]n=/.test(audio.url)} ` +
      `url-bound-ip=${decodeURIComponent(urlIp ?? '?')}`,
  );
  console.log(`  title="${audio.title}" channel="${audio.channel}" thumb=${audio.thumbnailUrl}`);

  // Download the first maxBytes in 512 KiB ranged chunks (the app uses 10 MB).
  const plan = planChunks(Math.min(audio.contentLength, maxBytes), 512 * 1024);
  const parts: Uint8Array[] = [];
  let got = 0;
  for (const c of plan) {
    const res = await fetch(chunkUrl(audio.url, c), { headers: mediaHeaders(audio) });
    const buf = new Uint8Array(await res.arrayBuffer());
    if (res.status !== 200 && res.status !== 206) {
      throw new Error(`media HTTP ${res.status} for range ${c.start}-${c.end} (final url host ${new URL(res.url).host})`);
    }
    if (buf.length !== c.end - c.start + 1) throw new Error(`short chunk: ${buf.length}`);
    parts.push(buf);
    got += buf.length;
    process.stdout.write(`\r  downloaded ${got}/${plan[plan.length - 1].end + 1} B`);
  }
  console.log();
  const head = parts[0];
  console.log(`ftyp check: isMp4=${isMp4(head)} brand=${mp4Brand(head)} first16=${Buffer.from(head.slice(0, 16)).toString('hex')}`);
  console.log(`done in ${Date.now() - t0} ms`);
}

console.log(`clients tried in order: ${DEFAULT_CLIENT_ORDER.map((k) => `${k}(${CLIENTS[k].context.clientVersion})`).join(', ')}`);
main().catch((e) => {
  console.error('SPIKE FAILED:', e.message);
  process.exit(1);
});
