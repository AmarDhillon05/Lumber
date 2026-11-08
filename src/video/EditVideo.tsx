// Edit screen add-ons, each mounted by EditScreen with one line:
//   ExportMoreRow — Export M4A / Export video, under Preview / Export WAV.
//   VideoSection  — the clip preview and the per-project "Video offset" nudge.

import { useState } from 'react';
import { ActivityIndicator, Alert, StyleSheet, Text, View } from 'react-native';
import type { ProjectAudio } from '../audio/sources';
import type { Channels } from '../dsp/types';
import type { MixSettings, Project, Take } from '../state/types';
import { Button, LabeledSlider, Section } from '../components/ui';
import { fmtTime, theme } from '../theme';
import { exportM4a, exportVideo, shareMedia } from './exportVideo';
import { VideoPanel } from './lazy';
import { finalVideoOffsetSec } from './sync';

const VIDEO_NUDGE_RANGE_MS = 1500;
const FRAME_MS = 33; // one frame at 30 fps

export function ExportMoreRow({
  project,
  take,
  mix,
  audio,
  getProcessedDrums,
  beforeExport,
}: {
  project: Project;
  take: Take;
  mix: MixSettings;
  audio: ProjectAudio;
  getProcessedDrums: () => Channels | undefined;
  beforeExport: () => void;
}) {
  const [busy, setBusy] = useState<null | 'video' | 'm4a'>(null);
  const [progress, setProgress] = useState(0);

  const run = async (kind: 'video' | 'm4a') => {
    beforeExport();
    setBusy(kind);
    setProgress(0);
    try {
      const fn = kind === 'video' ? exportVideo : exportM4a;
      const uri = await fn(project.name, audio, take, mix, getProcessedDrums(), setProgress);
      await shareMedia(uri);
    } catch (e) {
      Alert.alert('Export failed', String((e as Error).message ?? e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <>
      <View style={vs.row}>
        <Button title={busy === 'm4a' ? 'Exporting…' : 'Export M4A'} onPress={() => run('m4a')} disabled={!!busy} style={{ flex: 1 }} />
        {take.video ? (
          <Button
            title={busy === 'video' ? `Video ${Math.round(progress * 100)}%` : 'Export video'}
            onPress={() => run('video')}
            disabled={!!busy}
            style={{ flex: 1 }}
          />
        ) : null}
      </View>
      {busy ? <ActivityIndicator color={theme.accent} style={{ marginTop: 4 }} /> : null}
    </>
  );
}

export function VideoSection({
  take,
  mix,
  setMix,
  playing,
  playhead,
  getPosition,
}: {
  take: Take;
  mix: MixSettings;
  setMix: (patch: Partial<MixSettings>) => void;
  playing: boolean;
  playhead: number;
  getPosition: () => number;
}) {
  const video = take.video;
  if (!video) return null;
  const nudgeMs = mix.videoNudgeMs ?? 0;
  const offset = finalVideoOffsetSec(video.offsetSec, nudgeMs);
  const nudge = (ms: number) =>
    setMix({ videoNudgeMs: Math.max(-VIDEO_NUDGE_RANGE_MS, Math.min(VIDEO_NUDGE_RANGE_MS, nudgeMs + ms)) });

  return (
    <Section title="Video">
      {VideoPanel ? (
        <VideoPanel
          uri={video.uri}
          offsetSec={offset}
          durationSec={video.durationSec}
          playing={playing}
          playhead={playhead}
          getPosition={getPosition}
        />
      ) : (
        <Text style={vs.hint}>This build can't play video — install a newer Lumber build.</Text>
      )}
      <Text style={vs.hint}>
        Video starts at {fmtTime(offset)} (recorded {(video.offsetSec * 1000).toFixed(0)} ms
        {video.syncSource === 'call' ? ', rough estimate' : ''}; nudge {nudgeMs > 0 ? '+' : ''}
        {nudgeMs} ms). Positive moves the picture later.
      </Text>
      <View style={vs.row}>
        <Button title="−1 fr" small onPress={() => nudge(-FRAME_MS)} />
        <Button title="−10" small onPress={() => nudge(-10)} />
        <Button title="0" small kind="ghost" onPress={() => setMix({ videoNudgeMs: 0 })} />
        <Button title="+10" small onPress={() => nudge(10)} />
        <Button title="+1 fr" small onPress={() => nudge(FRAME_MS)} />
      </View>
      <LabeledSlider
        label="Video offset (ms)"
        value={nudgeMs}
        min={-VIDEO_NUDGE_RANGE_MS}
        max={VIDEO_NUDGE_RANGE_MS}
        step={1}
        onComplete={(v) => setMix({ videoNudgeMs: Math.round(v) })}
        format={(v) => `${Math.round(v)}`}
      />
    </Section>
  );
}

const vs = StyleSheet.create({
  row: { flexDirection: 'row', gap: 8, marginVertical: 8 },
  hint: { color: theme.textFaint, fontSize: 12, marginVertical: 4 },
});
