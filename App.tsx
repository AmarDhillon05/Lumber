// Lumber: Library → Record → Edit/Export. A tiny state-driven navigator (the
// route lives in the zustand store) — three screens don't need a router.

import { useEffect } from 'react';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { useStore } from './src/state/store';
import { LibraryScreen } from './src/screens/LibraryScreen';
import { RecordScreen } from './src/screens/RecordScreen';
import { EditScreen } from './src/screens/EditScreen';
import { theme } from './src/theme';

export default function App() {
  const loaded = useStore((s) => s.loaded);
  const route = useStore((s) => s.route);

  useEffect(() => {
    useStore.getState().init();
  }, []);

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.root}>
        <StatusBar style="light" />
        {!loaded ? (
          <View style={styles.center}>
            <ActivityIndicator color={theme.accent} />
          </View>
        ) : route.name === 'record' ? (
          <RecordScreen key={route.songId} songId={route.songId} />
        ) : route.name === 'edit' ? (
          <EditScreen key={route.projectId} projectId={route.projectId} />
        ) : (
          <LibraryScreen />
        )}
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: theme.surface },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
});
