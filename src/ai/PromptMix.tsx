// "Describe the sound" box for the Edit screen: type what you want, tap Go,
// and the knobs (and maybe the faders) move. Claude does it when an API key is
// set and the phone is online; otherwise the offline interpreter does. Results
// go through the store's updateMix so the live preview re-renders, and Undo
// steps back through the previous states.

import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Alert, Keyboard, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import type { ProjectAudio } from '../audio/sources';
import { selectProject, useStore } from '../state/store';
import type { MixSettings } from '../state/types';
import { Button } from '../components/ui';
import { theme } from '../theme';
import type { MixAnalysis } from './analyze';
import { DEFAULT_MODEL, MODEL_OPTIONS, type ClaudeModel } from './claude';
import { clearApiKey, loadApiKey, loadModel, looksLikeApiKey, maskKey, saveApiKey, saveModel } from './keyStore';
import { analyzeProject, runPromptMix, type MixSource } from './mixPrompt';

const EXAMPLES = ['punchy and dry like a 90s rock record', 'less boomy, more room', 'warm and vintage', 'brighter, cut through the song'];
const MAX_UNDO = 10;

type Snapshot = Pick<MixSettings, 'values' | 'songGain' | 'drumGain' | 'presetId'>;

interface Result {
  explanation: string;
  source?: MixSource; // unset for status lines (undo, cancel)
  model?: ClaudeModel;
  notice?: string;
}

export function PromptMix({ projectId, audio, drumOffsetSec }: { projectId: string; audio: ProjectAudio; drumOffsetSec: number }) {
  const project = useStore(selectProject(projectId));
  const updateMix = useStore((s) => s.updateMix);

  const [prompt, setPrompt] = useState('');
  const [busy, setBusy] = useState<null | 'listening' | 'thinking'>(null);
  const [result, setResult] = useState<Result | null>(null);
  const [history, setHistory] = useState<Snapshot[]>([]);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [apiKey, setApiKey] = useState<string | null>(null);
  const [model, setModel] = useState<ClaudeModel>(DEFAULT_MODEL);
  const [keyDraft, setKeyDraft] = useState('');

  const analysisRef = useRef<{ audio: ProjectAudio; offset: number; analysis: MixAnalysis } | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const alive = useRef(true);

  useEffect(() => {
    alive.current = true;
    loadApiKey().then((k) => alive.current && setApiKey(k));
    loadModel().then((m) => alive.current && setModel(m));
    return () => {
      alive.current = false;
      abortRef.current?.abort();
    };
  }, []);

  // A different project means a different undo history.
  useEffect(() => {
    setHistory([]);
    setResult(null);
  }, [projectId]);

  const getAnalysis = useCallback(async (): Promise<MixAnalysis | null> => {
    const cached = analysisRef.current;
    if (cached && cached.audio === audio && Math.abs(cached.offset - drumOffsetSec) < 0.5) return cached.analysis;
    // Yield a frame so "Listening…" shows before the (synchronous) analysis.
    await new Promise((r) => setTimeout(r, 16));
    try {
      const analysis = analyzeProject(audio, drumOffsetSec);
      analysisRef.current = { audio, offset: drumOffsetSec, analysis };
      return analysis;
    } catch (e) {
      console.warn('analysis failed', e);
      return null;
    }
  }, [audio, drumOffsetSec]);

  const go = useCallback(async () => {
    const text = prompt.trim();
    const mix = useStore.getState().projects.find((p) => p.id === projectId)?.mix;
    if (!text || !mix || busy) return;
    Keyboard.dismiss();
    setBusy('listening');
    const analysis = await getAnalysis();
    if (!alive.current) return;
    setBusy('thinking');
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    const before: Snapshot = { values: mix.values, songGain: mix.songGain, drumGain: mix.drumGain, presetId: mix.presetId };
    const outcome = await runPromptMix(
      {
        prompt: text,
        values: mix.values,
        songGain: mix.songGain,
        drumGain: mix.drumGain,
        originalDrums: mix.originalDrums,
        hasStems: !!audio.stems,
        analysis,
      },
      { apiKey, model, signal: ctrl.signal },
    );
    abortRef.current = null;
    if (!alive.current) return;
    setBusy(null);
    if (ctrl.signal.aborted) {
      setResult({ explanation: 'Cancelled — nothing changed.' });
      return;
    }
    const s = outcome.suggestion;
    updateMix(projectId, {
      values: s.values,
      presetId: undefined,
      ...(s.songGain !== undefined ? { songGain: s.songGain } : {}),
      ...(s.drumGain !== undefined ? { drumGain: s.drumGain } : {}),
    });
    setHistory((h) => [...h, before].slice(-MAX_UNDO));
    setResult({ explanation: s.explanation, source: outcome.source, model: outcome.source === 'claude' ? model : undefined, notice: outcome.notice });
  }, [prompt, projectId, busy, getAnalysis, apiKey, model, audio, updateMix]);

  const undo = () => {
    const prev = history[history.length - 1];
    if (!prev) return;
    updateMix(projectId, prev);
    setHistory((h) => h.slice(0, -1));
    setResult({ explanation: 'Reverted to the previous settings.' });
  };

  const saveKey = async () => {
    const k = keyDraft.trim();
    if (!k) return;
    const store = async () => {
      try {
        await saveApiKey(k);
        setApiKey(k);
        setKeyDraft('');
      } catch (e) {
        Alert.alert('Couldn’t save the key', String((e as Error).message ?? e));
      }
    };
    if (looksLikeApiKey(k)) return store();
    Alert.alert('That doesn’t look like an Anthropic key', 'Anthropic API keys start with “sk-ant-”. Save it anyway?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Save', onPress: store },
    ]);
  };

  const removeKey = async () => {
    await clearApiKey().catch(() => undefined);
    setApiKey(null);
  };

  const pickModel = (m: ClaudeModel) => {
    setModel(m);
    saveModel(m).catch(() => undefined);
  };

  if (!project) return null;
  const modelLabel = MODEL_OPTIONS.find((o) => o.id === (result?.model ?? model))?.label.split(' (')[0];

  return (
    <View style={st.box}>
      <View style={st.titleRow}>
        <Text style={st.title}>Describe the sound</Text>
        <Pressable onPress={() => setSettingsOpen((o) => !o)} hitSlop={10}>
          <Text style={st.link}>{apiKey ? `Claude · ${modelLabel}` : 'Offline · add key'} ⚙</Text>
        </Pressable>
      </View>

      <View style={st.inputRow}>
        <TextInput
          value={prompt}
          onChangeText={setPrompt}
          placeholder="e.g. punchy and dry, less boomy, more room"
          placeholderTextColor={theme.placeholder}
          style={st.input}
          returnKeyType="go"
          onSubmitEditing={go}
          editable={!busy}
          autoCorrect
        />
        {busy === 'thinking' ? (
          <Button title="Cancel" small onPress={() => abortRef.current?.abort()} />
        ) : (
          <Button title="Go" kind="primary" small onPress={go} disabled={!prompt.trim() || !!busy} />
        )}
      </View>

      {!result && !busy ? (
        <View style={st.examples}>
          {EXAMPLES.map((e) => (
            <Pressable key={e} onPress={() => setPrompt(e)} style={st.example}>
              <Text style={st.exampleText}>{e}</Text>
            </Pressable>
          ))}
        </View>
      ) : null}

      {busy ? (
        <View style={st.status}>
          <ActivityIndicator color={theme.accent} size="small" />
          <Text style={st.hint}>{busy === 'listening' ? 'Listening to the take and the song…' : apiKey ? 'Asking Claude…' : 'Working it out…'}</Text>
        </View>
      ) : null}

      {result && !busy ? (
        <View style={st.result}>
          {result.source ? (
            <Text style={st.badge}>{result.source === 'claude' ? `Claude ${modelLabel ?? ''}`.trim() : 'Offline interpreter'}</Text>
          ) : null}
          <Text style={st.explanation}>{result.explanation}</Text>
          {result.notice ? <Text style={st.notice}>{result.notice}</Text> : null}
        </View>
      ) : null}

      {history.length ? (
        <View style={st.undoRow}>
          <Button title={`Undo${history.length > 1 ? ` (${history.length})` : ''}`} small kind="ghost" onPress={undo} disabled={!!busy} />
        </View>
      ) : null}

      {settingsOpen ? (
        <View style={st.settings}>
          <Text style={st.settingsTitle}>AI settings</Text>
          <Text style={st.hint}>
            {apiKey ? `Anthropic API key: ${maskKey(apiKey)}` : 'No API key: prompts use the offline interpreter.'}
          </Text>
          <View style={st.inputRow}>
            <TextInput
              value={keyDraft}
              onChangeText={setKeyDraft}
              placeholder={apiKey ? 'Paste a new key to replace it' : 'Paste your Anthropic API key (sk-ant-…)'}
              placeholderTextColor={theme.placeholder}
              style={st.input}
              secureTextEntry
              autoCapitalize="none"
              autoCorrect={false}
              textContentType="password"
            />
            <Button title="Save" small onPress={saveKey} disabled={!keyDraft.trim()} />
          </View>
          {apiKey ? <Button title="Remove key" small kind="ghost" onPress={removeKey} style={{ alignSelf: 'flex-start' }} /> : null}
          <Text style={[st.hint, { marginTop: 8 }]}>Model</Text>
          <View style={st.examples}>
            {MODEL_OPTIONS.map((o) => (
              <Pressable key={o.id} onPress={() => pickModel(o.id)} style={[st.example, model === o.id && st.chipOn]}>
                <Text style={[st.exampleText, model === o.id && { color: theme.onAccent }]}>{o.label}</Text>
              </Pressable>
            ))}
          </View>
          <Text style={st.hint}>
            The key is stored in the iOS keychain and sent only to api.anthropic.com; requests are billed to your
            Anthropic account. Claude needs internet; without it (or without a key) the offline interpreter answers.
          </Text>
        </View>
      ) : null}
    </View>
  );
}

const st = StyleSheet.create({
  box: {
    marginTop: 16,
    padding: 12,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: theme.border,
    backgroundColor: theme.card,
    gap: 8,
  },
  titleRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  title: { color: theme.text, fontSize: 15, fontWeight: '700' },
  link: { color: theme.textMuted, fontSize: 12 },
  inputRow: { flexDirection: 'row', gap: 8, alignItems: 'center' },
  input: {
    flex: 1,
    color: theme.text,
    backgroundColor: theme.surfaceDeep,
    borderColor: theme.border,
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 8,
    fontSize: 14,
  },
  examples: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  example: {
    paddingHorizontal: 10,
    paddingVertical: 5,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: theme.border,
    backgroundColor: theme.cardRaised,
  },
  chipOn: { backgroundColor: theme.accent, borderColor: theme.accent },
  exampleText: { color: theme.textSoft, fontSize: 12 },
  status: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  result: { gap: 4 },
  badge: { color: theme.textFaint, fontSize: 11, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  explanation: { color: theme.textSoft, fontSize: 13, lineHeight: 18 },
  notice: { color: theme.warning, fontSize: 12 },
  undoRow: { flexDirection: 'row' },
  settings: { borderTopWidth: 1, borderTopColor: theme.border, paddingTop: 8, gap: 6 },
  settingsTitle: { color: theme.text, fontSize: 13, fontWeight: '700' },
  hint: { color: theme.textFaint, fontSize: 12 },
});
