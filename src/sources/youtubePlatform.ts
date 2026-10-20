// React Native / Hermes setup for the YouTube source. Import once at app
// startup (e.g. `import './src/sources/youtubePlatform';` in index.ts) — it is
// also imported by youtube.ts, so forgetting it is harmless.
//
// The core (youtubeCore.ts) was written to need nothing beyond what Hermes +
// React Native already provide:
//   - global `fetch` with `text()`/`json()` (RN built-in) for InnerTube JSON;
//   - media bytes go through expo-file-system's native downloader, not JS fetch
//     (RN's whatwg-fetch has no streaming and a weak `arrayBuffer()`);
//   - no `URL.searchParams` (RN's URL lacks it), no TextEncoder/TextDecoder,
//     no ReadableStream, no EventTarget, no WebCrypto;
//   - no `eval` / `new Function`: the clients we use return already-signed
//     stream URLs, so YouTube's player JS (signature / n-param) is never run.
// So there are no polyfills to install. This module only validates the
// environment and holds the fetch implementation (overridable for tests or
// for routing through a proxy).

import type { FetchLike } from './youtubeCore';

let fetchImpl: FetchLike | undefined;

export function setYouTubeFetch(f: FetchLike): void {
  fetchImpl = f;
}

export function youtubeFetch(): FetchLike {
  if (fetchImpl) return fetchImpl;
  if (typeof globalThis.fetch !== 'function') {
    throw new Error('YouTube source needs a global fetch (React Native provides one).');
  }
  // Bind so RN's fetch keeps its `this`.
  fetchImpl = globalThis.fetch.bind(globalThis) as unknown as FetchLike;
  return fetchImpl;
}
