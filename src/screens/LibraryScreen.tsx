// Library: saved songs (with their takes), file import, YouTube search +
// download, and per-song "Remove original drums".

import { useEffect, useState } from 'react';
import { ActivityIndicator, Alert, FlatList, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { importLocalFile, resolvePastedLink, youtubeSource } from '../sources';
import { cachedSeparation, separateDrums } from '../separation';
import type { SearchResult } from '../sources/types';
import { useShallow } from 'zustand/react/shallow';
import { useStore } from '../state/store';
import type { LibrarySong } from '../state/types';
import { Button, Header, ProgressBar, Section } from '../components/ui';
import { SearchResults } from '../components/SearchResults';
import { SpotifyPanel } from './SpotifyPanel';
import { fmtTime, theme } from '../theme';

export function LibraryScreen() {
  const songs = useStore((s) => s.songs);
  const addSong = useStore((s) => s.addSong);

  // Pick up stems separated earlier (e.g. before a reinstall of the db).
  useEffect(() => {
    const { songs: all, setStems } = useStore.getState();
    for (const s of all) {
      if (s.stems) continue;
      try {
        const c = cachedSeparation(s.uri);
        if (c) setStems(s.id, c);
      } catch {
        // separation module unavailable — ignore
      }
    }
  }, []);

  const onImport = async () => {
    try {
      const song = await importLocalFile();
      if (song) addSong(song);
    } catch (e) {
      Alert.alert('Import failed', String((e as Error).message ?? e));
    }
  };

  return (
    <View style={{ flex: 1 }}>
      <Header title="Lumber" />
      <FlatList
        data={songs}
        keyExtractor={(s) => s.id}
        contentContainerStyle={{ padding: 16, paddingBottom: 48 }}
        ListHeaderComponent={
          <View>
            <Button title="Import file" kind="primary" onPress={onImport} />
            <YouTubeSearch />
            <SpotifyPanel />
            <Text style={[ls.h2, { marginTop: 22 }]}>Your songs</Text>
            {songs.length === 0 ? (
              <Text style={ls.hint}>Import an MP3/M4A/WAV from Files, search YouTube, or paste a YouTube/Spotify link.</Text>
            ) : null}
          </View>
        }
        renderItem={({ item }) => <SongRow song={item} />}
      />
    </View>
  );
}

function YouTubeSearch() {
  const [query, setQuery] = useState('');
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<SearchResult[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [label, setLabel] = useState<string | null>(null);
  const search = async () => {
    if (!query.trim()) return;
    setBusy(true);
    setError(null);
    setLabel(null);
    try {
      // A pasted YouTube/Spotify link resolves directly; anything else is a search.
      const link = await resolvePastedLink(query);
      if (link) {
        setLabel(link.label);
        setResults(link.results);
      } else {
        setResults(await youtubeSource.search(query.trim()));
      }
    } catch (e) {
      setError(String((e as Error).message ?? e));
      setResults([]);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Section title="YouTube">
      <View style={{ flexDirection: 'row', gap: 8 }}>
        <TextInput
          style={ls.input}
          value={query}
          onChangeText={setQuery}
          placeholder="Search, or paste a YouTube/Spotify link"
          placeholderTextColor={theme.placeholder}
          returnKeyType="search"
          onSubmitEditing={search}
          autoCorrect={false}
        />
        <Button title="Search" onPress={search} disabled={busy} />
      </View>
      {busy ? <ActivityIndicator color={theme.accent} style={{ marginTop: 10 }} /> : null}
      {error ? <Text style={ls.error}>{error}</Text> : null}
      <SearchResults results={results} label={label} />
    </Section>
  );
}

function SongRow({ song }: { song: LibrarySong }) {
  const projects = useStore(useShallow((s) => s.projects.filter((p) => p.songId === song.id)));
  const job = useStore((s) => s.jobs[`sep:${song.id}`]);
  const { go, removeSong, setJob, setStems, removeProject } = useStore.getState();

  const removeDrums = async () => {
    const id = `sep:${song.id}`;
    setJob(id, { label: 'Removing drums', progress: 0 });
    try {
      const stems = await separateDrums(song.uri, (p) => setJob(id, { label: 'Removing drums', progress: p }));
      setStems(song.id, stems);
      setJob(id, null);
    } catch (e) {
      setJob(id, { label: 'Failed', progress: 0, error: String((e as Error).message ?? e) });
    }
  };

  const confirmDelete = () =>
    Alert.alert('Delete song?', `${song.title} and its takes will be removed.`, [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Delete', style: 'destructive', onPress: () => removeSong(song.id) },
    ]);

  const running = job && !job.error;

  return (
    <View style={ls.card}>
      <Pressable onLongPress={confirmDelete}>
        <Text style={ls.title}>{song.title}</Text>
        <Text style={ls.meta}>
          {[song.artist, song.source === 'youtube' ? 'YouTube' : 'File', song.stems ? 'drums removed ✓' : null]
            .filter(Boolean)
            .join(' · ')}
        </Text>
      </Pressable>
      <View style={ls.row}>
        <Button title="Record" kind="primary" small onPress={() => go({ name: 'record', songId: song.id })} />
        {!song.stems ? (
          <Button
            title={running ? `Removing… ${Math.round(job.progress * 100)}%` : 'Remove original drums'}
            small
            disabled={!!running}
            onPress={removeDrums}
          />
        ) : null}
        <Button title="Delete" kind="ghost" small onPress={confirmDelete} />
      </View>
      {running ? (
        <View style={{ marginTop: 8 }}>
          <ProgressBar progress={job.progress} color={theme.drums} />
          <Text style={ls.hint}>Runs on-device; first run downloads the model. Keep the app open.</Text>
        </View>
      ) : null}
      {job?.error ? <Text style={ls.error}>{job.error}</Text> : null}
      {projects.map((p) => (
        <Pressable
          key={p.id}
          style={ls.take}
          onPress={() => go({ name: 'edit', projectId: p.id })}
          onLongPress={() =>
            Alert.alert('Delete take?', p.name, [
              { text: 'Cancel', style: 'cancel' },
              { text: 'Delete', style: 'destructive', onPress: () => removeProject(p.id) },
            ])
          }
        >
          <Text style={ls.takeText} numberOfLines={1}>
            🥁 {p.name}
          </Text>
          <Text style={ls.action}>Edit ›</Text>
        </Pressable>
      ))}
    </View>
  );
}

const ls = StyleSheet.create({
  h2: { color: theme.text, fontSize: 18, fontWeight: '700', marginBottom: 8 },
  hint: { color: theme.textFaint, fontSize: 12, marginTop: 4 },
  error: { color: theme.dangerSoft, fontSize: 12, marginTop: 6 },
  input: {
    flex: 1,
    backgroundColor: theme.card,
    borderColor: theme.border,
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    color: theme.text,
    fontSize: 15,
  },
  result: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  card: {
    backgroundColor: theme.card,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: theme.border,
    padding: 12,
    marginBottom: 12,
  },
  title: { color: theme.text, fontSize: 16, fontWeight: '600' },
  meta: { color: theme.textMuted, fontSize: 12, marginTop: 2 },
  row: { flexDirection: 'row', gap: 8, marginTop: 10, flexWrap: 'wrap' },
  take: {
    flexDirection: 'row',
    alignItems: 'center',
    marginTop: 8,
    paddingTop: 8,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: theme.border,
  },
  takeText: { flex: 1, color: theme.textSoft, fontSize: 14 },
  action: { color: theme.accent, fontSize: 14, fontWeight: '600' },
});
