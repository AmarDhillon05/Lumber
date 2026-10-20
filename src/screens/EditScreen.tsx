// Edit / Export: song + drum lanes with alignment nudge, faders, presets and
// the full Blanket knob set, live preview, and WAV export to the share sheet.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Alert, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { BLANKET_TERMS, BLANKET_TERM_KEYS, CATEGORY_ORDER, type BlanketTerm } from '../dsp/blanketTerms';
import { PRESETS, presetValues } from '../dsp/presets';
import { renderBlanket } from '../dsp/renderBlanket';
import type { Channels } from '../dsp/types';
import { Preview } from '../audio/preview';
import { loadProjectAudio, type ProjectAudio } from '../audio/sources';
import { exportWav, finalOffsetSec, shareFile } from '../audio/export';
import { toMono, windowPeaks } from '../audio/peaks';
import { selectProject, selectSong, useStore } from '../state/store';
import type { MixSettings } from '../state/types';
import { BlanketKnob } from '../components/BlanketKnob';
import { Waveform } from '../components/Waveform';
import { Button, Header, LabeledSlider, Section } from '../components/ui';
import { fmtTime, theme } from '../theme';

const COLUMNS = 90;
const NUDGE_RANGE_MS = 300;
const RENDER_DEBOUNCE_MS = 250;

export function EditScreen({ projectId }: { projectId: string }) {
  const project = useStore(selectProject(projectId));
  const song = useStore(selectSong(project?.songId ?? ''));
  const take = useStore((s) => s.takes.find((t) => t.id === project?.takeId));
  const { go, updateMix } = useStore.getState();

  const [audio, setAudio] = useState<ProjectAudio | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [rendering, setRendering] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [playing, setPlaying] = useState(false);
  const [playhead, setPlayhead] = useState(0);
  const previewRef = useRef<Preview | null>(null);
  const processedRef = useRef<{ sig: string; channels: Channels } | null>(null);

  const mix = project?.mix;
  const setMix = useCallback((patch: Partial<MixSettings>) => updateMix(projectId, patch), [projectId, updateMix]);

  // Load audio and set up the preview player.
  useEffect(() => {
    if (!song || !take) return;
    let alive = true;
    (async () => {
      try {
        const a = await loadProjectAudio(song, take);
        if (!alive) return;
        const p = new Preview();
        const bed = a.song ?? a.stems!.noDrums;
        await p.init(bed, a.stems?.drums ?? null, a.drums, a.sampleRate);
        if (!alive) return p.dispose();
        previewRef.current = p;
        setPlayhead(Math.max(0, take.drumOffsetSec));
        p.seek(Math.max(0, take.drumOffsetSec));
        setAudio(a);
      } catch (e) {
        setLoadError(String((e as Error).message ?? e));
      }
    })();
    return () => {
      alive = false;
      previewRef.current?.dispose();
      previewRef.current = null;
    };
  }, [song?.id, song?.stems?.noDrumsUri, take?.id]);

  // Live levels + offset.
  useEffect(() => {
    const p = previewRef.current;
    if (!p || !mix || !take) return;
    p.setLevels({ songGain: mix.songGain, drumGain: mix.drumGain, originalDrums: mix.originalDrums });
    p.setOffset(finalOffsetSec(take, mix));
  }, [audio, mix?.songGain, mix?.drumGain, mix?.originalDrums, mix?.nudgeMs, take]);

  // Re-render the drum chain when the knobs settle.
  const valuesSig = mix ? JSON.stringify(mix.values) : '';
  useEffect(() => {
    if (!audio || !mix) return;
    let cancelled = false;
    const t = setTimeout(async () => {
      if (processedRef.current?.sig === valuesSig) return;
      setRendering(true);
      try {
        const channels = await renderBlanket(audio.drums, audio.sampleRate, mix.values);
        if (cancelled) return;
        processedRef.current = { sig: valuesSig, channels };
        previewRef.current?.setDrums(channels, audio.sampleRate);
      } catch (e) {
        console.warn('render failed', e);
      } finally {
        if (!cancelled) setRendering(false);
      }
    }, RENDER_DEBOUNCE_MS);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [audio, valuesSig]);

  // Playhead ticker.
  useEffect(() => {
    if (!playing) return;
    const id = setInterval(() => {
      const p = previewRef.current;
      if (!p) return;
      const pos = p.position();
      setPlayhead(pos);
      if (pos >= p.duration) {
        p.stop();
        setPlaying(false);
      }
    }, 100);
    return () => clearInterval(id);
  }, [playing]);

  // Waveforms (window around the take).
  const offset = take && mix ? finalOffsetSec(take, mix) : 0;
  const bedMono = useMemo(() => (audio ? toMono(audio.song ?? audio.stems!.noDrums) : null), [audio]);
  const drumMono = useMemo(() => (audio ? toMono(audio.drums) : null), [audio]);
  const drumDur = audio ? audio.drums[0].length / audio.sampleRate : 0;
  const songDur = bedMono && audio ? bedMono.length / audio.sampleRate : 0;
  const view = useMemo(() => {
    const base = take?.drumOffsetSec ?? 0;
    const start = Math.max(0, base - 1);
    const end = Math.max(start + 1, Math.min(songDur || Infinity, base + drumDur + 1));
    return { start, end };
  }, [take?.drumOffsetSec, drumDur, songDur]);
  const songPeaks = useMemo(
    () => (bedMono && audio ? windowPeaks(bedMono, audio.sampleRate, view.start, view.end, COLUMNS) : null),
    [bedMono, audio, view],
  );
  const drumPeaks = useMemo(
    () => (drumMono && audio ? windowPeaks(drumMono, audio.sampleRate, view.start, view.end, COLUMNS, offset) : null),
    [drumMono, audio, view, offset],
  );
  const playheadFrac = (playhead - view.start) / (view.end - view.start);

  const onKnob = useCallback(
    (term: BlanketTerm, v: number) => {
      const cur = useStore.getState().projects.find((p) => p.id === projectId)?.mix.values;
      if (!cur) return;
      setMix({ values: { ...cur, [term]: v }, presetId: undefined });
    },
    [projectId, setMix],
  );

  const togglePlay = () => {
    const p = previewRef.current;
    if (!p) return;
    if (p.isPlaying) {
      p.stop();
      setPlaying(false);
    } else {
      p.play(playhead);
      setPlaying(true);
    }
  };

  const doExport = async () => {
    if (!audio || !take || !mix || !project) return;
    previewRef.current?.stop();
    setPlaying(false);
    setExporting(true);
    try {
      const processed = processedRef.current?.sig === valuesSig ? processedRef.current.channels : undefined;
      const uri = await exportWav(project.name, audio, take, mix, processed);
      await shareFile(uri);
    } catch (e) {
      Alert.alert('Export failed', String((e as Error).message ?? e));
    } finally {
      setExporting(false);
    }
  };

  if (!project || !song || !take || !mix) {
    return (
      <View style={{ flex: 1 }}>
        <Header title="Take not found" onBack={() => go({ name: 'library' })} />
      </View>
    );
  }

  const nudge = (ms: number) =>
    setMix({ nudgeMs: Math.max(-NUDGE_RANGE_MS, Math.min(NUDGE_RANGE_MS, mix.nudgeMs + ms)) });

  return (
    <View style={{ flex: 1 }}>
      <Header title={project.name} onBack={() => go({ name: 'library' })} />
      {!audio ? (
        <View style={es.center}>
          {loadError ? (
            <Text style={es.error}>{loadError}</Text>
          ) : (
            <>
              <ActivityIndicator color={theme.accent} />
              <Text style={es.hint}>Loading audio…</Text>
            </>
          )}
        </View>
      ) : (
        <ScrollView contentContainerStyle={{ padding: 16, paddingBottom: 60 }}>
          <Waveform peaks={songPeaks} color={theme.song} label={song.stems ? 'SONG (no drums)' : 'SONG'} playhead={playheadFrac} />
          <View style={{ height: 6 }} />
          <Waveform peaks={drumPeaks} color={theme.drums} label="DRUMS" playhead={playheadFrac} />
          <View style={es.timeRow}>
            <Text style={es.hint}>{fmtTime(view.start)}</Text>
            <Text style={es.hint}>{rendering ? 'rendering drums…' : ''}</Text>
            <Text style={es.hint}>{fmtTime(view.end)}</Text>
          </View>

          <View style={es.row}>
            <Button title={playing ? 'Stop' : '▶ Preview'} kind="primary" onPress={togglePlay} style={{ flex: 1 }} />
            <Button title={exporting ? 'Exporting…' : 'Export WAV'} onPress={doExport} disabled={exporting} style={{ flex: 1 }} />
          </View>
          {exporting ? <ActivityIndicator color={theme.accent} style={{ marginTop: 8 }} /> : null}
          <LabeledSlider
            label="Playhead"
            value={playhead}
            min={0}
            max={Math.max(0.1, songDur)}
            onComplete={(v) => {
              setPlayhead(v);
              previewRef.current?.seek(v);
            }}
            format={fmtTime}
          />

          <Section title="Alignment">
            <Text style={es.hint}>
              Drums start at {fmtTime(offset)} (recorded offset {(take.drumOffsetSec * 1000).toFixed(0)} ms incl.{' '}
              {take.latencyMs.toFixed(0)} ms latency; nudge {mix.nudgeMs > 0 ? '+' : ''}
              {mix.nudgeMs} ms)
            </Text>
            <View style={es.row}>
              <Button title="−10" small onPress={() => nudge(-10)} />
              <Button title="−1" small onPress={() => nudge(-1)} />
              <Button title="0" small kind="ghost" onPress={() => setMix({ nudgeMs: 0 })} />
              <Button title="+1" small onPress={() => nudge(1)} />
              <Button title="+10" small onPress={() => nudge(10)} />
            </View>
            <LabeledSlider
              label="Nudge (ms)"
              value={mix.nudgeMs}
              min={-NUDGE_RANGE_MS}
              max={NUDGE_RANGE_MS}
              step={1}
              onComplete={(v) => setMix({ nudgeMs: Math.round(v) })}
              format={(v) => `${Math.round(v)}`}
              color={theme.drums}
            />
          </Section>

          <Section title="Mix">
            <LabeledSlider label="Song" value={mix.songGain} min={0} max={1.5} onChange={(v) => setMix({ songGain: v })} color={theme.song} />
            <LabeledSlider label="Drums" value={mix.drumGain} min={0} max={1.5} onChange={(v) => setMix({ drumGain: v })} color={theme.drums} />
            <LabeledSlider
              label="Original drums"
              value={mix.originalDrums}
              min={0}
              max={1}
              onChange={(v) => setMix({ originalDrums: v })}
              format={(v) => `${Math.round(v * 100)}%`}
              disabled={!audio.stems}
            />
            {!audio.stems ? <Text style={es.hint}>Run “Remove original drums” in the library to enable.</Text> : null}
          </Section>

          <Section title="Presets">
            <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
              {PRESETS.map((p) => (
                <Pressable
                  key={p.id}
                  onPress={() => setMix({ values: presetValues(p), presetId: p.id })}
                  style={[es.chip, mix.presetId === p.id && es.chipOn]}
                >
                  <Text style={[es.chipText, mix.presetId === p.id && { color: theme.onAccent }]}>{p.label}</Text>
                </Pressable>
              ))}
              <Pressable
                onPress={() => setMix({ values: presetValues({ id: '', label: '', description: '', values: {} }), presetId: undefined })}
                style={es.chip}
              >
                <Text style={es.chipText}>Reset</Text>
              </Pressable>
            </ScrollView>
            {mix.presetId ? (
              <Text style={es.hint}>{PRESETS.find((p) => p.id === mix.presetId)?.description}</Text>
            ) : null}
          </Section>

          {CATEGORY_ORDER.map((cat) => {
            const terms = BLANKET_TERM_KEYS.filter((t) => BLANKET_TERMS[t].category === cat);
            if (!terms.length) return null;
            return (
              <Section key={cat} title={cat}>
                <View style={es.knobs}>
                  {terms.map((t) => (
                    <BlanketKnob key={t} term={t} value={mix.values[t] ?? 0} onChange={onKnob} />
                  ))}
                </View>
              </Section>
            );
          })}
        </ScrollView>
      )}
    </View>
  );
}

const es = StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8, padding: 24 },
  error: { color: theme.dangerSoft, textAlign: 'center' },
  hint: { color: theme.textFaint, fontSize: 12, marginVertical: 4 },
  timeRow: { flexDirection: 'row', justifyContent: 'space-between' },
  row: { flexDirection: 'row', gap: 8, marginVertical: 8 },
  chip: {
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: theme.border,
    backgroundColor: theme.card,
  },
  chipOn: { backgroundColor: theme.accent, borderColor: theme.accent },
  chipText: { color: theme.textSoft, fontSize: 13, fontWeight: '600' },
  knobs: { flexDirection: 'row', flexWrap: 'wrap' },
});
