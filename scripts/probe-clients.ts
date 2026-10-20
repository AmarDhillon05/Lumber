// Probe: which InnerTube clients return directly playable audio URLs (no
// deciphering, no PO token)? Usage: npx tsx scripts/probe-clients.ts [videoId]
import { Innertube } from 'youtubei.js';

const CLIENTS = [
  'IOS', 'ANDROID', 'ANDROID_VR', 'VISIONOS', 'TV', 'TV_SIMPLY', 'TV_EMBEDDED',
  'WEB_EMBEDDED', 'MWEB', 'WEB', 'YTMUSIC_ANDROID',
] as const;

async function main() {
  const yt = await Innertube.create({ retrieve_player: false });
  const s = await yt.search('ac/dc back in black', { type: 'video' });
  const v: any = s.videos.find((x: any) => x.id);
  const id = process.argv[2] ?? v.id;
  console.log('video', id, v?.title?.toString());
  for (const c of CLIENTS) {
    try {
      const info: any = await yt.getBasicInfo(id, { client: c as any });
      const ps = info.playability_status?.status;
      const af = (info.streaming_data?.adaptive_formats ?? []).filter((f: any) => f.has_audio && !f.has_video);
      const m4a = af.filter((f: any) => f.mime_type.startsWith('audio/mp4'));
      const f = m4a.sort((a: any, b: any) => b.bitrate - a.bitrate)[0];
      let probe = '-';
      if (f?.url) {
        const u = new URL(f.url);
        const r = await fetch(f.url + '&range=0-65535');
        const b = new Uint8Array(await r.arrayBuffer());
        probe = `${r.status} ${b.length}B box=${new TextDecoder().decode(b.slice(4, 8))} n=${u.searchParams.has('n')} c=${u.searchParams.get('c')} sabr=${u.searchParams.get('sabr')}`;
      }
      console.log(
        c.padEnd(16), ps, `audio=${af.length} m4a=${m4a.length}`,
        f ? `itag=${f.itag} url=${!!f.url} cipher=${!!f.signature_cipher}` : '',
        probe, info.playability_status?.reason ?? '',
      );
    } catch (e: any) {
      console.log(c.padEnd(16), 'ERR', String(e.message).slice(0, 150));
    }
  }
}
main();
