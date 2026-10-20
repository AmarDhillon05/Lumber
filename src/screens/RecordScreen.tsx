// Record: transport for one song — start position, loop region, 1-bar
// count-in, Play / Record / Stop — plus latency calibration and the
// headphone warning.

import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Alert, ScrollView, StyleSheet, Switch, Text, TextInput, View } from 'react-native';
import { AudioManager } from 'react-native-audio-api';
import { engine, type RouteInfo } from '../audio/engine';
import { isReliable, runCalibration } from '../audio/calibration';
import { clampBpm } from '../audio/offsets';
import { selectSong, useStore } from '../state/store';
import { Button, Header, LabeledSlider, Section } from '../components/ui';
import { fmtTime, theme } from '../theme';

// Used until a route has been calibrated.
const DEFAULT_LATENCY_MS = { wired: 15, bluetooth: 200 };

type Mode = 'idle' | 'loading' | 'playing' | 'recording' | 'calibrating';

export function RecordScreen({ songId }: { songId: string }) {
  const song = useStore(selectSong(songId));
  const settings = useStore((s) => s.settings);
  const { go, updateSettings, addTake } = useStore.getState();

  const [duration, setDuration] = useState(0);
  const [startSec, setStartSec] = useState(0);
  const [loopOn, setLoopOn] = useState(false);
  const [loop, setLoop] = useState({ start: 0, end: 0 });
  const [bpmText, setBpmText] = useState(String(settings.bpm));
  const [mode, setMode] = useState<Mode>('loading');
  const [pos, setPos] = useState(0);
  const [countIn, setCountIn] = useState(0);
  const [route, setRoute] = useState<RouteInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const modeRef = useRef(mode);
  modeRef.current = mode;

  const refreshRoute = useCallback(async () => setRoute(await engine.currentRoute()), []);

  // Load the song, watch the output route, stop on leave.
  useEffect(() => {
    if (!song) return;
    let alive = true;
    (async () => {
      try {
        await engine.ensureReady();
        const buf = await engine.loadSong(song.uri);
        if (!alive) return;
        setDuration(buf.duration);
        // Local imports arrive without a duration; fill it from the decode.
        if (!song.durationSec) useStore.getState().updateSong(song.id, { durationSec: buf.duration });
        setLoop({ start: 0, end: Math.min(buf.duration, 30) });
        setMode('idle');
        refreshRoute();
      } catch (e) {
        setError(`Could not load song: ${String((e as Error).message ?? e)}`);
        setMode('idle');
      }
    })();
    const sub = AudioManager.addSystemEventListener('routeChange', () => refreshRoute());
    return () => {
      alive = false;
      sub?.remove();
      engine.onAutoStop = null;
      if (engine.isRunning) engine.stop().catch(() => {});
    };
  }, [song?.uri, refreshRoute]);

  // Playhead.
  useEffect(() => {
    if (mode !== 'playing' && mode !== 'recording') return;
    const id = setInterval(() => {
      const p = engine.position();
      if (p != null) setPos(p);
      setCountIn(engine.countInRemaining());
    }, 80);
    return () => clearInterval(id);
  }, [mode]);

  const latencyKey = route?.key ?? 'unknown';
  const calibrated = settings.latencyByRoute[latencyKey];
  const baseLatency = calibrated ?? (route?.isBluetooth ? DEFAULT_LATENCY_MS.bluetooth : DEFAULT_LATENCY_MS.wired);
  const latencyMs = baseLatency + settings.latencyNudgeMs;

  const bpm = clampBpm(parseFloat(bpmText));

  const start = async (record: boolean) => {
    if (!song) return;
    setError(null);
    updateSettings({ bpm });
    try {
      engine.onAutoStop = () => stop();
      const from = loopOn ? loop.start : startSec;
      setPos(from);
      await engine.start({
        songId: song.id,
        songUri: song.uri,
        startSec: from,
        loop: loopOn ? loop : null,
        countIn: settings.countIn ? { bpm, beats: 4 } : null,
        record,
        latencyMs,
      });
      setMode(record ? 'recording' : 'playing');
    } catch (e) {
      setMode('idle');
      setError(String((e as Error).message ?? e));
    }
  };

  const stop = async () => {
    const wasRecording = modeRef.current === 'recording';
    setMode('idle');
    try {
      const take = await engine.stop();
      if (take && wasRecording) {
        const project = addTake(take);
        go({ name: 'edit', projectId: project.id });
      }
    } catch (e) {
      setError(String((e as Error).message ?? e));
    }
  };

  const calibrate = () => {
    Alert.alert(
      'Calibrate latency',
      'Unplug headphones (or hold an earbud right at the bottom mic) and keep the room quiet. Lumber will play 8 clicks and listen for them.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Start',
          onPress: async () => {
            setMode('calibrating');
            setError(null);
            try {
              const r = await runCalibration(engine);
              if (!isReliable(r)) {
                setError(
                  `Clicks not detected clearly (confidence ${r.confidence.toFixed(1)}, spread ${r.spreadMs.toFixed(1)} ms). Turn the volume up and try again.`,
                );
              } else {
                updateSettings({
                  latencyByRoute: { ...useStore.getState().settings.latencyByRoute, [r.routeKey]: Math.round(r.latencyMs * 10) / 10 },
                });
                await refreshRoute();
              }
            } catch (e) {
              setError(String((e as Error).message ?? e));
            } finally {
              setMode('idle');
            }
          },
        },
      ],
    );
  };

  if (!song) {
    return (
      <View style={{ flex: 1 }}>
        <Header title="Song not found" onBack={() => go({ name: 'library' })} />
      </View>
    );
  }

  const busy = mode !== 'idle';
  const running = mode === 'playing' || mode === 'recording';

  return (
    <View style={{ flex: 1 }}>
      <Header title={song.title} onBack={() => go({ name: 'library' })} />
      <ScrollView contentContainerStyle={{ padding: 16, paddingBottom: 48 }}>
        {route && !route.isHeadphones ? (
          <View style={rs.warn}>
            <Text style={rs.warnText}>
              🎧 Plug in headphones before recording — otherwise the song bleeds into the drum mic.
            </Text>
          </View>
        ) : null}
        {route?.isBluetooth ? (
          <View style={[rs.warn, { borderColor: theme.border }]}>
            <Text style={rs.warnText}>
              Bluetooth adds 150–250 ms of delay. Calibrate for this output, or prefer wired headphones.
            </Text>
          </View>
        ) : null}

        <View style={rs.transport}>
          <Text style={rs.pos}>{fmtTime(running ? pos : loopOn ? loop.start : startSec)}</Text>
          <Text style={rs.dur}>/ {fmtTime(duration)}</Text>
          {running && countIn > 0 ? <Text style={rs.countIn}>count-in {Math.ceil(countIn / (60 / bpm))}</Text> : null}
          {mode === 'recording' ? <Text style={rs.rec}>● REC</Text> : null}
        </View>

        <View style={rs.buttons}>
          {running ? (
            <Button title="Stop" kind="danger" onPress={stop} style={{ flex: 1 }} />
          ) : (
            <>
              <Button title="Play" onPress={() => start(false)} disabled={busy || !duration} style={{ flex: 1 }} />
              <Button title="● Record" kind="danger" onPress={() => start(true)} disabled={busy || !duration} style={{ flex: 1 }} />
            </>
          )}
        </View>
        {mode === 'loading' || mode === 'calibrating' ? (
          <ActivityIndicator color={theme.accent} style={{ marginTop: 12 }} />
        ) : null}
        {error ? <Text style={rs.error}>{error}</Text> : null}

        <Section title="Start">
          <LabeledSlider
            label="Start at"
            value={startSec}
            min={0}
            max={Math.max(0.1, duration)}
            onComplete={setStartSec}
            format={fmtTime}
            disabled={running || loopOn}
          />
        </Section>

        <Section title="Loop">
          <View style={rs.toggleRow}>
            <Text style={rs.toggleLabel}>Loop region (records one pass)</Text>
            <Switch value={loopOn} onValueChange={setLoopOn} disabled={running} />
          </View>
          {loopOn ? (
            <>
              <LabeledSlider
                label="Loop start"
                value={loop.start}
                min={0}
                max={Math.max(0.1, duration)}
                onComplete={(v) => setLoop((l) => ({ start: Math.min(v, l.end - 0.5), end: l.end }))}
                format={fmtTime}
                disabled={running}
              />
              <LabeledSlider
                label="Loop end"
                value={loop.end}
                min={0}
                max={Math.max(0.1, duration)}
                onComplete={(v) => setLoop((l) => ({ start: l.start, end: Math.max(v, l.start + 0.5) }))}
                format={fmtTime}
                disabled={running}
              />
            </>
          ) : null}
        </Section>

        <Section title="Count-in">
          <View style={rs.toggleRow}>
            <Text style={rs.toggleLabel}>1 bar (4 clicks) before the song</Text>
            <Switch value={settings.countIn} onValueChange={(v) => updateSettings({ countIn: v })} disabled={running} />
          </View>
          <View style={rs.toggleRow}>
            <Text style={rs.toggleLabel}>Tempo (BPM)</Text>
            <TextInput
              style={rs.bpm}
              value={bpmText}
              onChangeText={setBpmText}
              onEndEditing={() => setBpmText(String(bpm))}
              keyboardType="decimal-pad"
              editable={!running}
            />
          </View>
        </Section>

        <Section title="Latency">
          <Text style={rs.info}>
            Output: {route?.name ?? '…'} — {calibrated != null ? `${calibrated} ms (calibrated)` : `${baseLatency} ms (estimate, not calibrated)`}
          </Text>
          <Text style={rs.info}>
            Manual nudge: {settings.latencyNudgeMs > 0 ? '+' : ''}
            {settings.latencyNudgeMs} ms → compensating {latencyMs.toFixed(1)} ms
          </Text>
          <View style={rs.buttons}>
            <Button title="−5 ms" small onPress={() => updateSettings({ latencyNudgeMs: settings.latencyNudgeMs - 5 })} />
            <Button title="−1" small onPress={() => updateSettings({ latencyNudgeMs: settings.latencyNudgeMs - 1 })} />
            <Button title="+1" small onPress={() => updateSettings({ latencyNudgeMs: settings.latencyNudgeMs + 1 })} />
            <Button title="+5 ms" small onPress={() => updateSettings({ latencyNudgeMs: settings.latencyNudgeMs + 5 })} />
          </View>
          <Button title="Calibrate this output" onPress={calibrate} disabled={busy} style={{ marginTop: 8 }} />
        </Section>
      </ScrollView>
    </View>
  );
}

const rs = StyleSheet.create({
  warn: {
    borderWidth: 1,
    borderColor: theme.warning,
    backgroundColor: 'rgba(232,197,71,0.08)',
    borderRadius: 10,
    padding: 10,
    marginBottom: 10,
  },
  warnText: { color: theme.textSoft, fontSize: 13 },
  transport: { flexDirection: 'row', alignItems: 'baseline', gap: 8, marginVertical: 12 },
  pos: { color: theme.text, fontSize: 40, fontWeight: '700', fontVariant: ['tabular-nums'] },
  dur: { color: theme.textMuted, fontSize: 16 },
  countIn: { color: theme.warning, fontSize: 14, marginLeft: 'auto' },
  rec: { color: theme.danger, fontSize: 14, fontWeight: '700', marginLeft: 'auto' },
  buttons: { flexDirection: 'row', gap: 8, marginTop: 4 },
  error: { color: theme.dangerSoft, marginTop: 10, fontSize: 13 },
  toggleRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingVertical: 6 },
  toggleLabel: { color: theme.textSoft, fontSize: 14 },
  bpm: {
    color: theme.text,
    backgroundColor: theme.card,
    borderColor: theme.border,
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 6,
    width: 80,
    textAlign: 'right',
  },
  info: { color: theme.textSoft, fontSize: 13, marginBottom: 6 },
});
