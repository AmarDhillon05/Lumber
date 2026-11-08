// On-device drum removal: HTDemucs through ONNX Runtime. Tries Core ML first;
// if a run crashes the app (iOS kills it for memory), the next run steps down
// to CPU and then to a slow single-thread mode (see modes.ts). The model
// (~171 MB) downloads once; stems are cached per song.

import { Directory, File, Paths } from 'expo-file-system';
import { createDownloadResumable } from 'expo-file-system/legacy';
import { InferenceSession, Tensor } from 'onnxruntime-react-native';
import { decodeAudioData } from 'react-native-audio-api';
import { SAMPLE_RATE, separate } from './demucs';
import { MODEL_FILENAME, MODEL_URL } from './model';
import {
  crashMessage,
  describeMode,
  initialState,
  pauseBetweenChunksMs,
  recoverFromCrash,
  sessionOptions,
  type Breadcrumb,
  type ModeState,
} from './modes';
import { ortRunner } from './ort';
import type { SeparationProgress, SeparationResult } from './types';
import { WavStream } from './wavStream';

export type { SeparationProgress, SeparationResult } from './types';
export { MODEL_URL } from './model';

const modelsDir = () => new Directory(Paths.document, 'models');
const modelFile = () => new File(modelsDir(), MODEL_FILENAME);
const modelDoneMarker = () => new File(modelsDir(), `${MODEL_FILENAME}.done`);
const stateFile = () => new File(modelsDir(), 'separation-state.json');
const stemsDir = (key: string) => new Directory(Paths.document, 'stems', key);

const toPath = (uri: string) => decodeURIComponent(uri.replace(/^file:\/\//, ''));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Stable short key for a song URI (FNV-1a).
function cacheKey(uri: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < uri.length; i++) {
    h ^= uri.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, '0');
}

// ---------------------------------------------------------------------------
// Crash breadcrumbs

function readState(): ModeState {
  try {
    const f = stateFile();
    return f.exists ? { ...initialState(), ...JSON.parse(f.textSync()) } : initialState();
  } catch {
    return initialState();
  }
}

function writeState(state: ModeState): void {
  modelsDir().create({ intermediates: true, idempotent: true });
  stateFile().write(JSON.stringify(state));
}

// If the last run never finished, step down a mode. Returns a message for the
// user when that happened.
export function checkForCrash(): string | null {
  const { state, crashed } = recoverFromCrash(readState());
  if (!crashed) return null;
  writeState(state);
  return crashMessage(crashed, state.mode);
}

export function separationMode(): string {
  return describeMode(readState().mode);
}

// ---------------------------------------------------------------------------
// Model

export function isModelDownloaded(): boolean {
  return modelFile().exists && modelDoneMarker().exists;
}

export async function ensureModel(onProgress?: SeparationProgress): Promise<string> {
  const f = modelFile();
  if (isModelDownloaded()) return f.uri;
  modelsDir().create({ intermediates: true, idempotent: true });
  if (f.exists) f.delete();
  // Older builds downloaded a different model file; free that space.
  const legacy = new File(modelsDir(), 'htdemucs_core.onnx');
  if (legacy.exists) legacy.delete();
  const task = createDownloadResumable(MODEL_URL, f.uri, {}, (p) =>
    onProgress?.(p.totalBytesExpectedToWrite > 0 ? p.totalBytesWritten / p.totalBytesExpectedToWrite : 0),
  );
  const res = await task.downloadAsync();
  if (!res || res.status !== 200) {
    if (f.exists) f.delete();
    throw new Error(`model download failed (${res?.status ?? 'no response'})`);
  }
  modelDoneMarker().write(String(Date.now()));
  return f.uri;
}

// ---------------------------------------------------------------------------
// Separation

export function cachedSeparation(songUri: string): SeparationResult | null {
  const dir = stemsDir(cacheKey(songUri));
  const done = new File(dir, 'done.json');
  if (!done.exists) return null;
  return {
    drumsUri: new File(dir, 'drums.wav').uri,
    noDrumsUri: new File(dir, 'no_drums.wav').uri,
    sampleRate: SAMPLE_RATE,
  };
}

// Progress: model download (if needed) fills the first 20 %, separation the rest.
export async function separateDrums(
  songUri: string,
  onProgress?: SeparationProgress,
): Promise<SeparationResult> {
  const cached = cachedSeparation(songUri);
  if (cached) return cached;

  checkForCrash();
  const needsModel = !isModelDownloaded();
  const split = needsModel ? 0.2 : 0;
  const modelUri = await ensureModel((f) => onProgress?.(f * split));

  const state = readState();
  const mode = state.mode;
  const crumb = (b: Omit<Breadcrumb, 'mode' | 'startedAt'>) =>
    writeState({ ...state, inProgress: { mode, startedAt: Date.now(), ...b } });

  // Decode first, so the song and the model aren't both being set up at once.
  crumb({ stage: 'decode' });
  const audio = await decodeAudioData(songUri, SAMPLE_RATE);
  const input = [audio.getChannelData(0)];
  if (audio.numberOfChannels > 1) input.push(audio.getChannelData(1));

  crumb({ stage: 'load' });
  const session = await InferenceSession.create(toPath(modelUri), sessionOptions(mode) as InferenceSession.SessionOptions);

  const dir = stemsDir(cacheKey(songUri));
  if (dir.exists) dir.delete();
  dir.create({ intermediates: true });
  const drumsFile = new File(dir, 'drums.wav');
  const noDrumsFile = new File(dir, 'no_drums.wav');
  drumsFile.create();
  noDrumsFile.create();
  const drumsHandle = drumsFile.open();
  const noDrumsHandle = noDrumsFile.open();
  try {
    crumb({ stage: 'run', chunk: 0 });
    const drums = await WavStream.open(drumsHandle, SAMPLE_RATE, 2);
    const noDrums = await WavStream.open(noDrumsHandle, SAMPLE_RATE, 2);
    const pause = pauseBetweenChunksMs(mode);
    await separate(
      input,
      ortRunner(session, Tensor),
      {
        async write(d, n) {
          await drums.write(d);
          await noDrums.write(n);
        },
      },
      (f) => onProgress?.(split + f * (1 - split)),
      async (chunk, total) => {
        crumb({ stage: 'run', chunk, total });
        // Let the UI and garbage collector catch up between chunks.
        await sleep(pause);
      },
    );
    await drums.finish();
    await noDrums.finish();
  } catch (e) {
    if (dir.exists) dir.delete();
    throw e;
  } finally {
    drumsHandle.close();
    noDrumsHandle.close();
    await session.release().catch(() => {});
    // A thrown JS error isn't a crash: clear the breadcrumb either way.
    writeState({ ...readState(), inProgress: null });
  }
  new File(dir, 'done.json').write(JSON.stringify({ songUri, createdAt: Date.now(), mode }));
  return {
    drumsUri: drumsFile.uri,
    noDrumsUri: noDrumsFile.uri,
    sampleRate: SAMPLE_RATE,
  };
}
