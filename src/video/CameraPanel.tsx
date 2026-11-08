// Record screen: optional camera. A toggle (off by default) shows a front
// camera preview (flip to back). While a take records, the camera films
// *muted* — the mic belongs to the audio engine — and we collect the clock
// samples src/video/sync.ts needs to place the clip on the song timeline.
//
// RecordScreen drives it through the ref: start() right before the engine
// starts, stop() (not awaited) right before the engine stops.

import { useEffect, useImperativeHandle, useRef, useState, type Ref } from 'react';
import { StyleSheet, Switch, Text, View } from 'react-native';
import { CameraView, useCameraPermissions, type CameraType } from 'expo-camera';
import { File } from 'expo-file-system';
import { engine } from '../audio/engine';
import { subDir, newId } from '../state/persist';
import { Button, Section } from '../components/ui';
import { theme } from '../theme';
import type { ProgressSample, WallCtxPair } from './sync';
import type { CameraClip, CameraPanelHandle } from './takeVideo';

const PAIR_POLL_MS = 50;
const STOP_TIMEOUT_MS = 3000;
const TIMEOUT = Symbol('timeout');
const withTimeout = <T,>(p: Promise<T>, ms: number): Promise<T | typeof TIMEOUT> =>
  Promise.race([p, new Promise<typeof TIMEOUT>((r) => setTimeout(() => r(TIMEOUT), ms))]);
const now = () => globalThis.performance?.now?.() ?? Date.now();

interface Recording {
  promise: Promise<{ uri: string } | undefined>;
  facing: CameraType;
  recordCallWallMs: number;
  progress: ProgressSample[];
  pairs: WallCtxPair[];
  timer: ReturnType<typeof setInterval>;
}

export function CameraPanel({ ref, disabled }: { ref?: Ref<CameraPanelHandle>; disabled?: boolean }) {
  const [permission, requestPermission] = useCameraPermissions();
  const [on, setOn] = useState(false);
  const [facing, setFacing] = useState<CameraType>('front');
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const camRef = useRef<CameraView>(null);
  const recRef = useRef<Recording | null>(null);
  const live = useRef({ on, ready, facing });
  live.current = { on, ready, facing };

  const samplePair = (rec: Recording) => {
    const ctx = engine.context;
    if (!ctx) return;
    const wallMs = now();
    rec.pairs.push({ wallMs, ctxSec: ctx.currentTime });
    if (rec.pairs.length > 4000) rec.pairs.splice(0, 2000);
  };

  useImperativeHandle(
    ref,
    () => ({
      start() {
        const cam = camRef.current;
        if (!live.current.on || recRef.current) return false;
        if (!live.current.ready || !cam) {
          setError("Camera wasn't ready, so this take has no video.");
          return false;
        }
        setError(null);
        const rec: Recording = {
          promise: Promise.resolve(undefined),
          facing: live.current.facing,
          recordCallWallMs: now(),
          progress: [],
          pairs: [],
          timer: setInterval(() => samplePair(rec), PAIR_POLL_MS),
        };
        rec.promise = cam.recordAsync({ progressUpdateInterval: 0.1 }) ?? Promise.resolve(undefined);
        rec.promise.catch(() => {}); // surfaced in stop()
        recRef.current = rec;
        samplePair(rec);
        return true;
      },
      async stop() {
        const rec = recRef.current;
        if (!rec) return null;
        samplePair(rec);
        clearInterval(rec.timer);
        const stopCamera = () => {
          try {
            camRef.current?.stopRecording();
          } catch {
            // not recording
          }
        };
        stopCamera();
        try {
          // A stop that lands before the native recording has started is a
          // no-op; ask again rather than waiting forever.
          let res = await withTimeout(rec.promise, STOP_TIMEOUT_MS);
          if (res === TIMEOUT) {
            stopCamera();
            res = await withTimeout(rec.promise, STOP_TIMEOUT_MS);
          }
          if (res === TIMEOUT || !res?.uri) return null;
          const src = new File(res.uri);
          const dest = new File(subDir('videos'), `take-${newId()}.mov`);
          src.moveSync(dest);
          return { uri: dest.uri, facing: rec.facing, recordCallWallMs: rec.recordCallWallMs, progress: rec.progress, pairs: rec.pairs };
        } catch (e) {
          setError(`Video not saved: ${String((e as Error).message ?? e)}`);
          return null;
        } finally {
          recRef.current = null;
        }
      },
    }),
    [],
  );

  // Never leave the camera filming when the screen goes away.
  useEffect(
    () => () => {
      const rec = recRef.current;
      if (rec) clearInterval(rec.timer);
      recRef.current = null;
    },
    [],
  );

  const toggle = async (v: boolean) => {
    setError(null);
    if (v && !permission?.granted) {
      const res = await requestPermission();
      if (!res.granted) {
        setError('Camera access is off. Allow it in Settings → Lumber → Camera.');
        return;
      }
    }
    setReady(false);
    setOn(v);
  };

  return (
    <Section title="Camera">
      <View style={cs.row}>
        <Text style={cs.label}>Film yourself while recording</Text>
        <Switch value={on} onValueChange={toggle} disabled={disabled} />
      </View>
      {on ? (
        <>
          <View style={cs.preview}>
            <CameraView
              ref={camRef}
              style={StyleSheet.absoluteFill}
              mode="video"
              mute
              facing={facing}
              videoQuality="1080p"
              onCameraReady={() => setReady(true)}
              onMountError={(e) => setError(`Camera failed: ${e.message}`)}
              onRecordingProgress={(e) => {
                const rec = recRef.current;
                if (rec) rec.progress.push({ wallMs: now(), durationSec: e.duration });
              }}
            />
          </View>
          <View style={cs.row}>
            <Text style={cs.hint}>
              {ready ? 'Video is muted; the drums come from the mic recording.' : 'Starting camera…'}
            </Text>
            <Button
              title="Flip"
              small
              // onCameraReady fires once per mounted view, so a flip keeps `ready`.
              onPress={() => setFacing((f) => (f === 'front' ? 'back' : 'front'))}
              disabled={disabled}
            />
          </View>
        </>
      ) : null}
      {error ? <Text style={cs.error}>{error}</Text> : null}
    </Section>
  );
}

const cs = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingVertical: 6, gap: 8 },
  label: { color: theme.textSoft, fontSize: 14 },
  hint: { color: theme.textFaint, fontSize: 12, flex: 1 },
  error: { color: theme.dangerSoft, fontSize: 13, marginTop: 6 },
  preview: {
    height: 260,
    borderRadius: 10,
    overflow: 'hidden',
    backgroundColor: theme.surfaceDeep,
    borderWidth: 1,
    borderColor: theme.border,
  },
});
