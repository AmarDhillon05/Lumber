# YouTube source

Status (Oct 2026): **best effort, not yet proven end to end.** Search and
stream-URL resolution are verified under Node. Downloading the media bytes
could not be verified from the dev machine, because of how that machine reaches
YouTube (see "Evidence"). It has to be checked on a phone. Files import
(`importLocalFile`) is the fallback that always works.

## How it works

Everything runs inside the app with plain `fetch` + JSON. There is no server,
no `youtubei.js` at runtime and no player JS.

1. **Visitor data:** `GET https://www.youtube.com/sw.js_data`, field
   `[0][2][0][0][13]`. Without it the player endpoint answers `LOGIN_REQUIRED`
   ("Sign in to confirm you're not a bot").
2. **Search:** `POST /youtubei/v1/search` as the `WEB` client with
   `params: 'EgIQAQ=='` (videos only). The code collects every `videoRenderer`
   from the response and skips live streams.
3. **Resolve:** `POST /youtubei/v1/player` and try clients in this order:
   - `VISIONOS` 1.02. This is the first choice and yt-dlp's default JS-less
     client. It returns direct URLs: no `signatureCipher`, no `n` param, no PO
     token policy.
   - `ANDROID_VR` 1.65.10. It also returns direct URLs, but yt-dlp now marks
     its HTTPS streams as needing a GVS PO token.
   - `IOS` 20.11.6. It returns direct URLs, but needs a GVS PO token for
     downloads.
4. **Format:** audio-only `audio/mp4` (AAC). The order of preference is itag
   140 (AAC-LC 128 kbps, about 1 MB/min), then other AAC formats by bitrate.
   The code skips opus/webm (iOS can't decode it natively), DRC variants,
   non-default (dubbed) audio tracks and ciphered URLs.
5. **Download:** ranged requests with `&range=a-b`, in 10 MB chunks (a song is
   usually one chunk). Each chunk goes through expo-file-system's native
   downloader and is appended to `Paths.cache/youtube-<id>.m4a.part`. The first
   chunk must start with an `ftyp` box. Each chunk is retried up to 3 times
   with backoff of 1, 2 and 4 s. The finished file is moved to
   `Paths.document/songs/youtube-<id>.m4a`. If a complete file is already
   there, it is reused.

### Code layout

- `src/sources/youtubeCore.ts`: pure logic with no RN/Expo imports and an
  injected `fetch`. It holds the clients, request builders, response parsers,
  format choice, chunk plan, the `ftyp` check and the download loop.
- `src/sources/youtube.ts`: `youtubeSource: SongSource`, the thin
  expo-file-system layer.
- `src/sources/youtubePlatform.ts`: holds the fetch implementation
  (`setYouTubeFetch` to override it). No polyfills are needed.
- `scripts/youtube-spike.ts`: an end-to-end run under Node.
  `scripts/probe-clients.ts` checks every youtubei.js client.
  `scripts/probe-raw.ts` sends one raw `/player` request.
- `tests/sources.test.ts`: offline tests. Run them with
  `npx tsx tests/sources.test.ts`. `YT_LIVE=1` adds a live search and
  resolve.

## Why not youtubei.js in the app

youtubei.js 18.2 has a `react-native` entry, but on Hermes it has problems:

- It needs a user-supplied JS evaluator for signature/n deciphering on
  WEB/TV/MWEB clients. In practice that means `new Function` over YouTube's
  player code. Hermes supports global `eval`/`new Function` only in a limited
  way, it runs slowly, and it is the first thing to break.
- It expects `ReadableStream`, `CustomEvent`/`EventTarget`, `crypto.subtle`
  (SHA-1), a full `URL`/`URLSearchParams` (RN's URL has no `searchParams`) and
  `globalThis.mmkvStorage` for caching.
- `Player.js` imports `package.json` `with { type: 'json' }`. Metro may not
  handle that.

We only need two endpoints. The JS-less clients make deciphering unnecessary,
so a small hand-written client avoids all of the above. The `youtubei.js`
dependency is now used only by `scripts/probe-clients.ts` for research and can
be removed from `dependencies`.

## Evidence (spike, 2026-10-20, from the dev machine)

```
search "ac/dc back in black": 20 results
  skip pAgnJDJN4VA: VISIONOS=UNPLAYABLE, ANDROID_VR=UNPLAYABLE, IOS=UNPLAYABLE
resolved rrim6_9VSeM via VISIONOS: itag=140 mime="audio/mp4; codecs="mp4a.40.2"" size=4075204B dur=252s
  cipher=no n-param=false url-bound-ip=fda3:e722:ac3:10:11d:6275:a02:10
SPIKE FAILED: media HTTP 403 for range 0-524287 (final url host rr1---sn-vgqsrnzd.googlevideo.com)
```

These results are specific to the dev environment. They do not show that the
approach fails on a phone:

- The dev machine is in Google Cloud. YouTube's frontends see its requests
  from a **Google-internal IPv6 ULA** (`fda3:…`), and stream URLs are signed
  for that address (`ip=` in the URL). googlevideo sees the public NAT IPv4
  (`34.x`/`35.x`/`160.79.x`, which changes per connection). The URL is bound
  to one IP and the download comes from another, so the cache node returns
  403. All three clients, every User-Agent, query-param or Range-header
  ranges, direct or through the proxy, and curl as well as Node all failed the
  same way. A phone uses one public IP for both requests.
- For the same reason, label-owned videos (the official AC/DC upload) come
  back `UNPLAYABLE` "This video is not available" on every client: the
  internal address doesn't geolocate. The spike moves on to the next result.
  On a phone, expect official uploads to resolve normally.
- yt-dlp 2026.08.19 on the same machine also fails (bot check / 429). Its
  client table is the source for the client order and PO-token notes above.

**First on-device check:** search for a song, fetch it, and confirm that the
file plays and that the first bytes are `....ftypdash` or `....ftypM4A `.

## Known failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `LOGIN_REQUIRED` "confirm you're not a bot" | Missing or stale visitor data, or a flagged IP | Make sure `sw.js_data` parses. Change network (Wi-Fi vs cellular). |
| `UNPLAYABLE` / "not available" | Region block, made-for-kids video (VISIONOS/ANDROID_VR can't play those), or private video | Pick another result. |
| 403 on the media download | URL used from a different IP than resolved it, URL expired (~6 h), or a client that now needs a GVS PO token | Re-resolve just before downloading (we already do). Change the client order. |
| `NO_FORMAT` | The client only offers SABR/ciphered formats now | Move that client down the order or remove it. |
| Download stalls or is slow | Throttling on large requests | Lower `CHUNK_BYTES`. |
| `no ftyp box` | Got an HTML error page or webm | Check the format filter. |
| HTTP 400 from `/player` | Client version too old | Bump the version (see below). |

## When YouTube breaks it

1. Run `npx tsx scripts/probe-clients.ts <videoId>` (needs a residential
   network for the media column) and `npx tsx scripts/youtube-spike.ts`.
2. Compare with the current client table in yt-dlp
   (`yt_dlp/extractor/youtube/_base.py`, `INNERTUBE_CLIENTS`). Look at
   `REQUIRE_JS_PLAYER: False` and `GVS_PO_TOKEN_POLICY` for HTTPS, and copy
   the version, UA and context fields of any working JS-less client into
   `CLIENTS` in `youtubeCore.ts`. Also compare with youtubei.js
   `Constants.CLIENTS`.
3. Reorder `DEFAULT_CLIENT_ORDER`.
4. If no JS-less client is left, the options are: (a) evaluate player JS with
   `new Function` on Hermes, which is fragile; (b) generate a PO token, which
   needs BotGuard in a WebView; (c) give up and use Files import.
5. Run `npx tsx tests/sources.test.ts` and update the fixtures if the response
   shapes changed.
