// Inline "Saved to Recordings" note shown on the Edit screen after an export,
// with Share (the old share-sheet path) and a link to the Recordings screen.

import { Alert, Pressable, StyleSheet, Text, View } from 'react-native';
import { useShallow } from 'zustand/react/shallow';
import { Button } from '../components/ui';
import { useStore } from '../state/store';
import type { Recording, Route } from '../state/types';
import { theme } from '../theme';
import { KIND_LABEL } from './core';
import { shareRecording } from './files';

export function SavedBanner({ saved, back, onDismiss }: { saved: Recording[]; back: Route; onDismiss: () => void }) {
  const live = useStore(
    useShallow((s) => saved.map((r) => s.recordings.find((x) => x.id === r.id)).filter((r): r is Recording => !!r)),
  );
  if (!live.length) return null;
  const go = useStore.getState().go;

  const share = async (rec: Recording) => {
    try {
      await shareRecording(rec);
    } catch (e) {
      Alert.alert('Share failed', String((e as Error).message ?? e));
    }
  };

  return (
    <View style={bs.box}>
      <View style={bs.head}>
        <Text style={bs.title}>✓ Saved to Recordings</Text>
        <Pressable onPress={onDismiss} hitSlop={10} accessibilityLabel="Dismiss">
          <Text style={bs.close}>✕</Text>
        </Pressable>
      </View>
      {live.map((rec) => (
        <View key={rec.id} style={bs.row}>
          <Text style={bs.name} numberOfLines={1}>
            {KIND_LABEL[rec.kind]}
          </Text>
          <Button title="Share" small onPress={() => share(rec)} />
        </View>
      ))}
      <Button
        title="Open Recordings ›"
        small
        kind="ghost"
        onPress={() => go({ name: 'recordings', openId: live.length === 1 ? live[0].id : undefined, back })}
      />
    </View>
  );
}

const bs = StyleSheet.create({
  box: {
    marginTop: 8,
    padding: 10,
    gap: 8,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: theme.success,
    backgroundColor: theme.card,
  },
  head: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  title: { color: theme.success, fontSize: 14, fontWeight: '700' },
  close: { color: theme.textMuted, fontSize: 14 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  name: { flex: 1, color: theme.textSoft, fontSize: 13 },
});
