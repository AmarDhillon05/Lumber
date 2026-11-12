// Recordings: everything saved from Edit (mixes, videos, raw takes), newest
// first, with total storage. Tap a row to play it in place; its actions are
// Share, Save to Photos (videos), Rename and Delete.

import { useMemo, useState } from 'react';
import { Alert, FlatList, Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { Button, Header } from '../components/ui';
import { useStore } from '../state/store';
import type { Recording, Route } from '../state/types';
import { theme } from '../theme';
import { formatBytes, formatDuration, formatRecordingDate, isVideoKind, KIND_LABEL, sortRecordings, totalSize } from '../recordings/core';
import { canSaveToPhotos, recordingFile, saveToPhotos, shareRecording, thumbnailUri } from '../recordings/files';
import { RecordingPlayer } from '../recordings/lazy';

export function RecordingsScreen({ openId, back }: { openId?: string; back?: Route }) {
  const recordings = useStore((s) => s.recordings);
  const go = useStore((s) => s.go);
  const sorted = useMemo(() => sortRecordings(recordings), [recordings]);
  const [openRow, setOpenRow] = useState<string | null>(openId ?? null);

  const count = sorted.length;
  const summary = `${count} recording${count === 1 ? '' : 's'} · ${formatBytes(totalSize(sorted))}`;

  return (
    <View style={{ flex: 1 }}>
      <Header title="Recordings" onBack={() => go(back ?? { name: 'library' })} />
      <FlatList
        data={sorted}
        keyExtractor={(r) => r.id}
        contentContainerStyle={{ padding: 16, paddingBottom: 48 }}
        ListHeaderComponent={
          <View style={rs.summary}>
            <Text style={rs.summaryText}>{summary}</Text>
            <Text style={rs.hint}>Stored on this iPhone. Delete what you don’t need to free space.</Text>
          </View>
        }
        ListEmptyComponent={
          <Text style={rs.empty}>
            Nothing saved yet. In a take’s Edit screen, Export WAV, Export M4A or Export video — or Save raw take — and
            it shows up here.
          </Text>
        }
        renderItem={({ item }) => (
          <RecordingRow rec={item} open={openRow === item.id} onToggle={() => setOpenRow(openRow === item.id ? null : item.id)} />
        )}
      />
    </View>
  );
}

function RecordingRow({ rec, open, onToggle }: { rec: Recording; open: boolean; onToggle: () => void }) {
  const { renameRecording, removeRecording } = useStore.getState();
  const video = isVideoKind(rec.kind);
  const file = recordingFile(rec);
  const missing = !file.exists;
  const thumb = video ? thumbnailUri(rec) : undefined;
  const [savingPhotos, setSavingPhotos] = useState(false);

  const share = async () => {
    try {
      await shareRecording(rec);
    } catch (e) {
      Alert.alert('Share failed', String((e as Error).message ?? e));
    }
  };

  const toPhotos = async () => {
    setSavingPhotos(true);
    try {
      const r = await saveToPhotos(rec);
      if (r === 'saved') Alert.alert('Saved to Photos', rec.title);
      else if (r === 'denied')
        Alert.alert(
          'No access to Photos',
          'Allow Lumber to add to Photos in Settings → Privacy & Security → Photos → Lumber, then try again. You can also use Share → Save Video.',
        );
      else Alert.alert('Save to Photos', 'This build can’t save to Photos — use Share → Save Video instead.');
    } catch (e) {
      Alert.alert('Save to Photos failed', String((e as Error).message ?? e));
    } finally {
      setSavingPhotos(false);
    }
  };

  const rename = () =>
    Alert.prompt(
      'Rename recording',
      undefined,
      [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Save', onPress: (t?: string) => t?.trim() && renameRecording(rec.id, t) },
      ],
      'plain-text',
      rec.title,
    );

  const remove = () =>
    Alert.alert('Delete recording?', `${rec.title} will be deleted from this iPhone.`, [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Delete', style: 'destructive', onPress: () => removeRecording(rec.id) },
    ]);

  return (
    <View style={[rs.card, open && rs.cardOpen]}>
      <Pressable onPress={onToggle} style={rs.rowHead} accessibilityRole="button" accessibilityState={{ expanded: open }}>
        <View style={rs.thumb}>
          {thumb ? (
            <Image source={{ uri: thumb }} style={StyleSheet.absoluteFill} resizeMode="cover" />
          ) : (
            <Text style={rs.thumbGlyph}>{video ? '▶' : '♪'}</Text>
          )}
        </View>
        <View style={{ flex: 1 }}>
          <Text style={rs.title} numberOfLines={2}>
            {rec.title}
          </Text>
          <Text style={rs.meta} numberOfLines={1}>
            {[KIND_LABEL[rec.kind], formatDuration(rec.durationSec), formatBytes(rec.size)].join(' · ')}
          </Text>
          <Text style={rs.meta}>{formatRecordingDate(rec.createdAt)}</Text>
        </View>
        <Text style={rs.chevron}>{open ? '⌄' : '›'}</Text>
      </Pressable>

      {open ? (
        <View style={{ marginTop: 10, gap: 10 }}>
          {missing ? (
            <Text style={rs.error}>The file for this recording is missing. Delete it from the list.</Text>
          ) : RecordingPlayer ? (
            <RecordingPlayer uri={file.uri} video={video} durationSec={rec.durationSec} />
          ) : (
            <Text style={rs.hint}>This build can’t play recordings in the app — use Share.</Text>
          )}
          <View style={rs.actions}>
            <Button title="Share" small kind="primary" onPress={share} disabled={missing} />
            {video && canSaveToPhotos ? (
              <Button title={savingPhotos ? 'Saving…' : 'Save to Photos'} small onPress={toPhotos} disabled={missing || savingPhotos} />
            ) : null}
            <Button title="Rename" small onPress={rename} />
            <Button title="Delete" small kind="danger" onPress={remove} />
          </View>
        </View>
      ) : null}
    </View>
  );
}

const rs = StyleSheet.create({
  summary: { marginBottom: 12 },
  summaryText: { color: theme.text, fontSize: 16, fontWeight: '700' },
  hint: { color: theme.textFaint, fontSize: 12, marginTop: 4 },
  empty: { color: theme.textMuted, fontSize: 14, lineHeight: 20, marginTop: 12 },
  error: { color: theme.dangerSoft, fontSize: 13 },
  card: {
    backgroundColor: theme.card,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: theme.border,
    padding: 10,
    marginBottom: 10,
  },
  cardOpen: { borderColor: theme.accent },
  rowHead: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  thumb: {
    width: 56,
    height: 56,
    borderRadius: 8,
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.surfaceDeep,
    borderWidth: 1,
    borderColor: theme.border,
  },
  thumbGlyph: { color: theme.textMuted, fontSize: 20 },
  title: { color: theme.text, fontSize: 15, fontWeight: '600' },
  meta: { color: theme.textMuted, fontSize: 12, marginTop: 2 },
  chevron: { color: theme.accent, fontSize: 20, paddingHorizontal: 4 },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
});
