// Offline tests for Spotify login (PKCE) and the API client. Run: npx tsx tests/spotify.test.ts
import { createHash } from 'node:crypto';
import { SpotifyApi, toTrack } from '../src/sources/spotifyApi';
import {
  buildAuthorizeUrl,
  exchangeCode,
  makeVerifier,
  parseCallback,
  SpotifySession,
  toBase64Url,
  type SpotifyTokens,
  type TokenStore,
} from '../src/sources/spotifyAuth';
import type { FetchLike } from '../src/sources/youtubeCore';

const fail = (msg: string): never => {
  throw new Error(msg);
};
const eq = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) fail(`${JSON.stringify(a)} != ${JSON.stringify(b)}`);
};
const rejects = async (p: Promise<unknown>, re: RegExp) => {
  try {
    await p;
  } catch (e) {
    if (!re.test(String((e as Error).message))) fail(`wrong error: ${(e as Error).message}`);
    return;
  }
  fail('expected rejection');
};

const cfg = { clientId: 'cid', redirectUri: 'lumber://spotify-callback' };

type Call = { url: string; init?: { method?: string; headers?: Record<string, string>; body?: string } };
function fakeFetch(handler: (c: Call) => { status: number; body?: unknown }): FetchLike & { calls: Call[] } {
  const calls: Call[] = [];
  const f = (async (url: string, init?: Call['init']) => {
    calls.push({ url, init });
    const { status, body } = handler({ url, init });
    const text = body === undefined ? '' : typeof body === 'string' ? body : JSON.stringify(body);
    return { ok: status >= 200 && status < 300, status, json: async () => JSON.parse(text || '{}'), text: async () => text };
  }) as FetchLike & { calls: Call[] };
  f.calls = calls;
  return f;
}

function memoryStore(initial: SpotifyTokens | null): TokenStore & { value: SpotifyTokens | null } {
  const s = {
    value: initial,
    load: async () => s.value,
    save: async (t: SpotifyTokens) => {
      s.value = t;
    },
    clear: async () => {
      s.value = null;
    },
  };
  return s;
}

const tokens = (expiresAt: number): SpotifyTokens => ({ accessToken: 'old', refreshToken: 'r1', expiresAt, scope: 's' });

const tests: [string, () => void | Promise<void>][] = [
  [
    'PKCE challenge matches the RFC 7636 test vector',
    () => {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const challenge = toBase64Url(createHash('sha256').update(verifier).digest('base64'));
      eq(challenge, 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    },
  ],
  [
    'verifier uses only unreserved characters and keeps the byte count',
    () => {
      const v = makeVerifier(Uint8Array.from({ length: 64 }, (_, i) => i * 4));
      eq(v.length, 64);
      if (!/^[A-Za-z0-9\-._~]+$/.test(v)) fail(v);
    },
  ],
  [
    'authorize URL carries client, redirect, S256 challenge, scopes and state',
    () => {
      const u = new URL(buildAuthorizeUrl(cfg, 'CHAL', 'STATE'));
      eq(u.origin + u.pathname, 'https://accounts.spotify.com/authorize');
      eq(u.searchParams.get('client_id'), 'cid');
      eq(u.searchParams.get('redirect_uri'), 'lumber://spotify-callback');
      eq(u.searchParams.get('code_challenge_method'), 'S256');
      eq(u.searchParams.get('code_challenge'), 'CHAL');
      eq(u.searchParams.get('state'), 'STATE');
      if (!u.searchParams.get('scope')!.includes('user-read-currently-playing')) fail('scope');
    },
  ],
  [
    'callback parsing: code, cancel, state mismatch',
    () => {
      eq(parseCallback('lumber://spotify-callback?code=abc%2B1&state=S', 'S'), 'abc+1');
      try {
        parseCallback('lumber://spotify-callback?error=access_denied&state=S', 'S');
        fail('no throw');
      } catch (e) {
        if (!/cancelled/.test(String(e))) throw e;
      }
      try {
        parseCallback('lumber://spotify-callback?code=x&state=EVIL', 'S');
        fail('no throw');
      } catch (e) {
        if (!/state mismatch/.test(String(e))) throw e;
      }
    },
  ],
  [
    'code exchange posts the verifier and no secret',
    async () => {
      const f = fakeFetch(() => ({ status: 200, body: { access_token: 'A', refresh_token: 'R', expires_in: 3600, scope: 's' } }));
      const t = await exchangeCode(f, cfg, 'CODE', 'VER', 1000);
      eq(t, { accessToken: 'A', refreshToken: 'R', expiresAt: 1000 + 3600_000, scope: 's' });
      const body = f.calls[0].init!.body!;
      if (!body.includes('code_verifier=VER') || !body.includes('grant_type=authorization_code')) fail(body);
      if (body.includes('secret')) fail('sent a secret');
    },
  ],
  [
    'session refreshes near expiry and keeps the old refresh token if none is returned',
    async () => {
      const store = memoryStore(tokens(1_000_000 + 30_000));
      const f = fakeFetch(() => ({ status: 200, body: { access_token: 'new', expires_in: 3600 } }));
      const s = new SpotifySession(f, cfg, store, () => 1_000_000);
      eq(await s.accessToken(), 'new');
      eq(store.value!.refreshToken, 'r1');
      eq(f.calls.length, 1);
      eq(await s.accessToken(), 'new'); // now fresh: no second refresh
      eq(f.calls.length, 1);
    },
  ],
  [
    'revoked refresh token clears the session',
    async () => {
      const store = memoryStore(tokens(0));
      const f = fakeFetch(() => ({ status: 400, body: { error: 'invalid_grant' } }));
      await rejects(new SpotifySession(f, cfg, store, () => 1).accessToken(), /token error 400/);
      eq(store.value, null);
    },
  ],
  [
    'API: nothing playing, podcasts, and a playing track',
    async () => {
      let status = 204;
      let body: unknown;
      const api = new SpotifyApi(fakeFetch(() => ({ status, body })), async () => 'T');
      eq(await api.currentlyPlaying(), null);
      status = 200;
      body = { item: { type: 'episode', id: 'e' } };
      eq(await api.currentlyPlaying(), null);
      body = { item: { type: 'track', id: 'x', name: 'Song', artists: [{ name: 'A' }, { name: 'B' }], duration_ms: 204_500, album: { images: [{ url: 'img' }] } } };
      eq(await api.currentlyPlaying(), { trackId: 'x', title: 'Song', artists: ['A', 'B'], durationSec: 205, artworkUrl: 'img' });
    },
  ],
  [
    'API: retries once with a refreshed token on 401',
    async () => {
      const seen: string[] = [];
      const f = fakeFetch((c) => {
        seen.push(c.init!.headers!.authorization);
        return seen.length === 1 ? { status: 401 } : { status: 200, body: { items: [], next: null } };
      });
      const api = new SpotifyApi(f, async (force) => (force ? 'fresh' : 'stale'));
      await api.likedTracks();
      eq(seen, ['Bearer stale', 'Bearer fresh']);
    },
  ],
  [
    'API: playlist items use the 2026 `item` field and paging offsets',
    async () => {
      const f = fakeFetch(() => ({
        status: 200,
        body: { items: [{ item: { id: 'a', name: 'One', artists: [] } }, { track: { id: 'b', name: 'Two', artists: [] } }, { item: null }], next: 'https://…' },
      }));
      const page = await new SpotifyApi(f, async () => 'T').playlistTracks('pl1', 50);
      eq(page.items.map((t) => t.trackId), ['a', 'b']);
      eq(page.next, 53);
      if (!f.calls[0].url.includes('/playlists/pl1/items?limit=50&offset=50')) fail(f.calls[0].url);
    },
  ],
  [
    'API: 403 on a playlist explains the own-playlists rule',
    async () => {
      const api = new SpotifyApi(fakeFetch(() => ({ status: 403 })), async () => 'T');
      await rejects(api.playlistTracks('x'), /your own playlists/);
    },
  ],
  [
    'local files and missing ids are skipped',
    () => {
      eq(toTrack({ id: null, name: 'x' }), null);
      eq(toTrack({ id: 'l', is_local: true, name: 'x' }), null);
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
  console.log(`${tests.length - failed}/${tests.length} spotify tests passed`);
  if (failed) process.exit(1);
})();
