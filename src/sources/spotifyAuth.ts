// Spotify login with Authorization Code + PKCE — the flow for apps that can't
// keep a client secret. Pure: randomness, hashing, the browser and storage are
// injected, so this runs under Node tests and in the app.

import type { FetchLike } from './youtubeCore';

export const SPOTIFY_ACCOUNTS = 'https://accounts.spotify.com';

export const SPOTIFY_SCOPES = [
  'user-read-currently-playing',
  'user-library-read',
  'playlist-read-private',
  'playlist-read-collaborative',
];

export interface SpotifyConfig {
  clientId: string;
  redirectUri: string;
}

export interface SpotifyTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number; // ms since epoch
  scope: string;
}

// RFC 7636 unreserved characters.
const UNRESERVED = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

export function makeVerifier(randomBytes: Uint8Array): string {
  if (randomBytes.length < 43 || randomBytes.length > 128) throw new Error('verifier needs 43-128 bytes');
  let s = '';
  for (const b of randomBytes) s += UNRESERVED[b % UNRESERVED.length];
  return s;
}

// base64 (as returned by a SHA-256 digest) → base64url without padding.
export function toBase64Url(base64: string): string {
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const form = (params: Record<string, string>) =>
  Object.entries(params)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&');

export function buildAuthorizeUrl(cfg: SpotifyConfig, challenge: string, state: string): string {
  return `${SPOTIFY_ACCOUNTS}/authorize?${form({
    response_type: 'code',
    client_id: cfg.clientId,
    redirect_uri: cfg.redirectUri,
    code_challenge_method: 'S256',
    code_challenge: challenge,
    scope: SPOTIFY_SCOPES.join(' '),
    state,
  })}`;
}

// lumber://spotify-callback?code=...&state=...  (or ?error=access_denied)
export function parseCallback(url: string, expectedState: string): string {
  const query = url.includes('?') ? url.slice(url.indexOf('?') + 1).split('#')[0] : '';
  const params: Record<string, string> = {};
  for (const kv of query.split('&')) {
    const [k, v = ''] = kv.split('=');
    if (k) params[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' '));
  }
  if (params.error) throw new Error(params.error === 'access_denied' ? 'Spotify login was cancelled' : `Spotify login failed: ${params.error}`);
  if (params.state !== expectedState) throw new Error('Spotify login failed: state mismatch');
  if (!params.code) throw new Error('Spotify login failed: no code returned');
  return params.code;
}

async function tokenRequest(fetch: FetchLike, params: Record<string, string>, previous?: SpotifyTokens, now = Date.now()): Promise<SpotifyTokens> {
  const res = await fetch(`${SPOTIFY_ACCOUNTS}/api/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: form(params),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Spotify token error ${res.status}: ${json.error_description ?? json.error ?? 'unknown'}`);
  return {
    accessToken: json.access_token,
    // Refresh responses may omit refresh_token; keep the old one then.
    refreshToken: json.refresh_token ?? previous?.refreshToken ?? '',
    expiresAt: now + (json.expires_in ?? 3600) * 1000,
    scope: json.scope ?? previous?.scope ?? '',
  };
}

export function exchangeCode(fetch: FetchLike, cfg: SpotifyConfig, code: string, verifier: string, now?: number) {
  return tokenRequest(
    fetch,
    { grant_type: 'authorization_code', code, redirect_uri: cfg.redirectUri, client_id: cfg.clientId, code_verifier: verifier },
    undefined,
    now,
  );
}

export function refreshTokens(fetch: FetchLike, cfg: SpotifyConfig, tokens: SpotifyTokens, now?: number) {
  return tokenRequest(fetch, { grant_type: 'refresh_token', refresh_token: tokens.refreshToken, client_id: cfg.clientId }, tokens, now);
}

export interface TokenStore {
  load(): Promise<SpotifyTokens | null>;
  save(tokens: SpotifyTokens): Promise<void>;
  clear(): Promise<void>;
}

// Hands out a valid access token, refreshing a minute before expiry. A refresh
// that Spotify rejects (revoked access) clears the store so the UI asks to
// connect again.
export class SpotifySession {
  private refreshing: Promise<SpotifyTokens> | null = null;

  constructor(
    private fetch: FetchLike,
    private cfg: SpotifyConfig,
    private store: TokenStore,
    private now: () => number = Date.now,
  ) {}

  async connected(): Promise<boolean> {
    return (await this.store.load()) !== null;
  }

  async accessToken(forceRefresh = false): Promise<string> {
    const tokens = await this.store.load();
    if (!tokens) throw new Error('Not connected to Spotify');
    if (!forceRefresh && tokens.expiresAt - 60_000 > this.now()) return tokens.accessToken;
    this.refreshing ??= refreshTokens(this.fetch, this.cfg, tokens, this.now())
      .then(async (t) => {
        await this.store.save(t);
        return t;
      })
      .catch(async (e) => {
        if (/token error 400/.test(String(e))) await this.store.clear();
        throw e;
      })
      .finally(() => {
        this.refreshing = null;
      });
    return (await this.refreshing).accessToken;
  }
}
