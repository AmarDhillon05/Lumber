// Hand-rolled InnerTube /player request, to see the IP a stream URL is bound to
// for each API host and whether media bytes come back.
const CLIENTS: Record<string, { id: number; ctx: any; ua: string }> = {
  ANDROID_VR: {
    id: 28,
    ua: 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    ctx: { clientName: 'ANDROID_VR', clientVersion: '1.65.10', deviceMake: 'Oculus', deviceModel: 'Quest 3', androidSdkVersion: 32, osName: 'Android', osVersion: '12L' },
  },
  IOS: {
    id: 5,
    ua: 'com.google.ios.youtube/20.11.6 (iPhone10,4; U; CPU iOS 16_7_7 like Mac OS X)',
    ctx: { clientName: 'IOS', clientVersion: '20.11.6', deviceMake: 'Apple', deviceModel: 'iPhone10,4', osName: 'iOS', osVersion: '16.7.7.20H330' },
  },
};

async function main() {
  const id = process.argv[2] ?? 'jNQXAC9IVRw';
  const host = process.argv[3] ?? 'www.youtube.com';
  const name = process.argv[4] ?? 'ANDROID_VR';
  const c = CLIENTS[name];
  const sw = await fetch('https://www.youtube.com/sw.js_data');
  const swj = JSON.parse((await sw.text()).replace(/^\)\]\}'/, ''));
  const visitorData: string = swj[0][2][0][0][13];
  console.log('visitorData', visitorData.slice(0, 16) + '…');
  const r = await fetch(`https://${host}/youtubei/v1/player?prettyPrint=false`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json', 'user-agent': c.ua,
      'x-youtube-client-name': String(c.id), 'x-youtube-client-version': c.ctx.clientVersion, 'x-goog-visitor-id': visitorData,
    },
    body: JSON.stringify({ videoId: id, context: { client: { ...c.ctx, hl: 'en', gl: 'US', visitorData } }, contentCheckOk: true, racyCheckOk: true }),
  });
  const j: any = await r.json();
  console.log(name, host, r.status, j.playabilityStatus?.status, j.playabilityStatus?.reason ?? '');
  const f = j.streamingData?.adaptiveFormats?.find((x: any) => x.itag === 140);
  if (!f) return;
  const u = new URL(f.url);
  console.log('bound ip', u.searchParams.get('ip'), 'n?', u.searchParams.has('n'));
  const m = await fetch(f.url + '&range=0-65535', { headers: { 'user-agent': c.ua } });
  const b = new Uint8Array(await m.arrayBuffer());
  console.log('media', m.status, b.length, new TextDecoder().decode(b.slice(4, 8)));
}
main();
