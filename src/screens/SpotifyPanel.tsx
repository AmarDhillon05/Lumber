// Spotify in the Library: connect once, then grab what's playing in the Spotify
// app, or browse liked songs and your playlists. Tapping a track finds it on
// YouTube (Spotify audio can't be downloaded) and shows matches to Get.

import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';
import {
  connectSpotify,
  disconnectSpotify,
  findOnYouTube,
  isSpotifyConnected,
  spotify,
  type LinkResults,
  type SpotifyPlaylist,
  type SpotifyTrack,
} from '../sources';
import { SearchResults } from '../components/SearchResults';
import { Button } from '../components/ui';
import { fmtTime, theme } from '../theme';

type View_ =
  | { kind: 'home' }
  | { kind: 'liked' }
  | { kind: 'playlists' }
  | { kind: 'playlist'; id: string; name: string };

type Row = { type: 'track'; track: SpotifyTrack } | { type: 'playlist'; playlist: SpotifyPlaylist };

const message = (e: unknown) => String((e as Error)?.message ?? e);

// How long to wait for the keychain before showing Connect anyway.
const CHECK_TIMEOUT_MS = 4000;

export function SpotifyPanel() {
  // null = still checking the keychain; the section renders (with Connect) meanwhile.
  const [connected, setConnected] = useState<boolean | null>(null);
  const [view, setView] = useState<View_>({ kind: 'home' });
  const [rows, setRows] = useState<Row[]>([]);
  const [next, setNext] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [found, setFound] = useState<LinkResults | null>(null);

  // Ask the keychain whether we're logged in, but never wait on it forever: if
  // it's slow or fails, show Connect and say why. A late "yes" still wins.
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const check = async () => {
    const answer = isSpotifyConnected();
    answer.then(
      (ok) => {
        if (ok && alive.current) {
          setConnected(true);
          setError(null);
        }
      },
      () => {},
    );
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const ok = await Promise.race([
        answer,
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('the keychain did not answer')), CHECK_TIMEOUT_MS);
        }),
      ]);
      if (alive.current) setConnected(ok);
    } catch (e) {
      if (!alive.current) return;
      setConnected(false);
      setError(`Couldn't read the saved Spotify login (${message(e)}). You can still connect.`);
    } finally {
      clearTimeout(timer);
    }
  };

  useEffect(() => {
    check();
  }, []);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(message(e));
      if (/connect again|Not connected|token error 400/.test(message(e))) await check();
    } finally {
      setBusy(false);
    }
  };

  const connect = () =>
    run(async () => {
      if (await connectSpotify()) setConnected(true);
    });

  const disconnect = () =>
    run(async () => {
      await disconnectSpotify();
      setConnected(false);
      setView({ kind: 'home' });
      setRows([]);
      setFound(null);
    });

  const match = (track: SpotifyTrack) =>
    run(async () => {
      setFound(null);
      setFound(await findOnYouTube(track));
    });

  const nowPlaying = () =>
    run(async () => {
      setFound(null);
      const track = await spotify.currentlyPlaying();
      if (!track) throw new Error('Nothing is playing in Spotify right now');
      setFound(await findOnYouTube(track));
    });

  const open = (v: View_, offset = 0) =>
    run(async () => {
      const page =
        v.kind === 'liked'
          ? await spotify.likedTracks(offset)
          : v.kind === 'playlist'
            ? await spotify.playlistTracks(v.id, offset)
            : v.kind === 'playlists'
              ? await spotify.playlists(offset)
              : null;
      if (!page) return;
      const mapped: Row[] =
        v.kind === 'playlists'
          ? (page.items as SpotifyPlaylist[]).map((playlist) => ({ type: 'playlist', playlist }))
          : (page.items as SpotifyTrack[]).map((track) => ({ type: 'track', track }));
      setView(v);
      setRows((old) => (offset === 0 ? mapped : [...old, ...mapped]));
      setNext(page.next);
    });

  if (!connected) {
    return (
      <View>
        <Text style={ss.hint}>
          Connect to grab what you're playing, your liked songs and your playlists. Each track is matched to a
          YouTube upload.
        </Text>
        <Button title="Connect Spotify" kind="primary" onPress={connect} disabled={busy} style={{ marginTop: 8 }} />
        {connected === null ? <Text style={ss.hint}>Checking for a saved login…</Text> : null}
        {busy ? <ActivityIndicator color={theme.accent} style={{ marginTop: 10 }} /> : null}
        {error ? <Text style={ss.error}>{error}</Text> : null}
      </View>
    );
  }

  return (
    <View>
      <View style={ss.row}>
        <Button title="Now playing" kind="primary" small onPress={nowPlaying} disabled={busy} />
        <Button title="Liked" small onPress={() => open({ kind: 'liked' })} disabled={busy} />
        <Button title="Playlists" small onPress={() => open({ kind: 'playlists' })} disabled={busy} />
        <Button title="Disconnect" kind="ghost" small onPress={disconnect} disabled={busy} />
      </View>

      {busy ? <ActivityIndicator color={theme.accent} style={{ marginTop: 10 }} /> : null}
      {error ? <Text style={ss.error}>{error}</Text> : null}
      {found ? <SearchResults results={found.results} label={found.label} /> : null}

      {view.kind !== 'home' ? (
        <View style={{ marginTop: 12 }}>
          <View style={ss.listHeader}>
            <Text style={ss.listTitle}>
              {view.kind === 'liked' ? 'Liked songs' : view.kind === 'playlists' ? 'Your playlists' : view.name}
            </Text>
            <Pressable
              onPress={() => {
                if (view.kind === 'playlist') open({ kind: 'playlists' });
                else {
                  setView({ kind: 'home' });
                  setRows([]);
                }
              }}
            >
              <Text style={ss.link}>{view.kind === 'playlist' ? 'Back' : 'Close'}</Text>
            </Pressable>
          </View>
          {rows.map((r) =>
            r.type === 'track' ? (
              <Pressable key={`t:${r.track.trackId}`} style={ss.item} onPress={() => match(r.track)}>
                <Text style={ss.title} numberOfLines={1}>
                  {r.track.title}
                </Text>
                <Text style={ss.meta} numberOfLines={1}>
                  {[r.track.artists.join(', '), r.track.durationSec ? fmtTime(r.track.durationSec) : null]
                    .filter(Boolean)
                    .join(' · ')}
                </Text>
              </Pressable>
            ) : (
              <Pressable
                key={`p:${r.playlist.id}`}
                style={ss.item}
                onPress={() => open({ kind: 'playlist', id: r.playlist.id, name: r.playlist.name })}
              >
                <Text style={ss.title} numberOfLines={1}>
                  {r.playlist.name}
                </Text>
                {r.playlist.trackCount != null ? <Text style={ss.meta}>{r.playlist.trackCount} songs</Text> : null}
              </Pressable>
            ),
          )}
          {next != null ? (
            <Button title="Load more" small onPress={() => open(view, next)} disabled={busy} style={{ marginTop: 8 }} />
          ) : null}
          {view.kind === 'playlists' ? (
            <Text style={ss.hint}>Spotify only lets apps open playlists you created.</Text>
          ) : null}
        </View>
      ) : null}
    </View>
  );
}

const ss = StyleSheet.create({
  row: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  hint: { color: theme.textFaint, fontSize: 12, marginTop: 6 },
  error: { color: theme.dangerSoft, fontSize: 12, marginTop: 6 },
  listHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 },
  listTitle: { color: theme.text, fontSize: 15, fontWeight: '700' },
  link: { color: theme.accent, fontSize: 14, fontWeight: '600' },
  item: { paddingVertical: 9, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: theme.border },
  title: { color: theme.text, fontSize: 15, fontWeight: '600' },
  meta: { color: theme.textMuted, fontSize: 12, marginTop: 2 },
});
