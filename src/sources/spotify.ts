// Spotify on the phone: login through the system auth sheet (ASWebAuthenticationSession),
// tokens in the iOS keychain, and helpers that turn Spotify tracks into YouTube
// matches. Needs the Spotify account that owns the Client ID to have Premium.

import { CryptoDigestAlgorithm, CryptoEncoding, digestStringAsync, getRandomBytes } from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';
import * as WebBrowser from 'expo-web-browser';
import { findSpotifyTrackOnYouTube, type LinkResults, type SpotifyTrack } from './links';
import { SpotifyApi } from './spotifyApi';
import {
  buildAuthorizeUrl,
  exchangeCode,
  makeVerifier,
  parseCallback,
  SpotifySession,
  toBase64Url,
  type SpotifyConfig,
  type SpotifyTokens,
  type TokenStore,
} from './spotifyAuth';
import { youtubeFetch } from './youtubePlatform';

// Public by design: PKCE apps have no secret. Registered at developer.spotify.com
// with this redirect URI; only accounts under the app's User Management can log in.
export const SPOTIFY_CONFIG: SpotifyConfig = {
  clientId: '5faec3aab4e245f7a29760f019501648',
  redirectUri: 'lumber://spotify-callback',
};

const KEY = 'spotify.tokens';
const KEYCHAIN_TIMEOUT_MS = 8000;

// Fail loudly instead of leaving the UI spinning if the keychain never answers.
function keychainCall<T>(what: string, p: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([
    p.catch((e) => {
      throw new Error(`Keychain ${what} failed: ${String((e as Error)?.message ?? e)}`);
    }),
    new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Keychain ${what} timed out`)), KEYCHAIN_TIMEOUT_MS);
    }),
  ]).finally(() => clearTimeout(timer));
}

const keychain: TokenStore = {
  async load() {
    const raw = await keychainCall('read', SecureStore.getItemAsync(KEY));
    if (!raw) return null;
    try {
      return JSON.parse(raw) as SpotifyTokens;
    } catch {
      return null; // unreadable entry: treat as logged out
    }
  },
  save: (t) => keychainCall('write', SecureStore.setItemAsync(KEY, JSON.stringify(t))),
  clear: () => keychainCall('delete', SecureStore.deleteItemAsync(KEY)),
};

const session = new SpotifySession((...a) => youtubeFetch()(...a), SPOTIFY_CONFIG, keychain);
export const spotify = new SpotifyApi((...a) => youtubeFetch()(...a), (force) => session.accessToken(force));

export const isSpotifyConnected = () => session.connected();

// Opens Spotify's login page; resolves false if the user backs out.
export async function connectSpotify(): Promise<boolean> {
  const verifier = makeVerifier(getRandomBytes(64));
  const challenge = toBase64Url(
    await digestStringAsync(CryptoDigestAlgorithm.SHA256, verifier, { encoding: CryptoEncoding.BASE64 }),
  );
  const state = makeVerifier(getRandomBytes(48));
  const result = await WebBrowser.openAuthSessionAsync(
    buildAuthorizeUrl(SPOTIFY_CONFIG, challenge, state),
    SPOTIFY_CONFIG.redirectUri,
  );
  if (result.type !== 'success') return false;
  const code = parseCallback(result.url, state);
  await keychain.save(await exchangeCode(youtubeFetch(), SPOTIFY_CONFIG, code, verifier));
  return true;
}

export const disconnectSpotify = () => keychain.clear();

export function findOnYouTube(track: SpotifyTrack): Promise<LinkResults> {
  return findSpotifyTrackOnYouTube(track, youtubeFetch());
}
