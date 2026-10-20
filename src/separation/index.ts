// On-device drum removal: HTDemucs through ONNX Runtime with the Core ML
// execution provider (CPU fallback). The model (~171 MB) downloads once on
// first use; stems are cached per song, so each song is separated only once.

import { Directory, File, Paths } from 'expo-file-system';
import { createDownloadResumable } from 'expo-file-system/legacy';
import { InferenceSession, Tensor } from 'onnxruntime-react-native';
import { decodeAudioData } from 'react-native-audio-api';
import { SAMPLE_RATE, separate } from './demucs';
import { ortRunner } from './ort';
import type { SeparationProgress, SeparationResult } from './types';
import { WavStream } from './wavStream';

export type { SeparationProgress, SeparationResult } from './types';

// Demucs v4 htdemucs exported without STFT/iSTFT (weights CC-BY-NC 4.0, Meta).
export const MODEL_URL =
  'https://huggingface.co/sathvik77/htdemucs-core-onnx/resolve/main/htdemucs_core.onnx';
const MODEL_BYTES = 170_992_246;

const modelFile = () => new File(new Directory(Paths.document, 'models'), 'htdemucs_core.onnx');
const stemsDir = (key: string) => new Directory(Paths.document, 'stems', key);

const toPath = (uri: string) => decodeURIComponent(uri.replace(/^file:\/\//, ''));

// Stable short key for a song URI (FNV-1a).
function cacheKey(uri: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < uri.length; i++) {
    h ^= uri.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, '0');
}

export function isModelDownloaded(): boolean {
  const f = modelFile();
  return f.exists && f.size === MODEL_BYTES;
}

export async function ensureModel(onProgress?: SeparationProgress): Promise<string> {
  const f = modelFile();
  if (isModelDownloaded()) return f.uri;
  f.parentDirectory.create({ intermediates: true, idempotent: true });
  if (f.exists) f.delete();
  const task = createDownloadResumable(MODEL_URL, f.uri, {}, (p) =>
    onProgress?.(p.totalBytesWritten / (p.totalBytesExpectedToWrite || MODEL_BYTES)),
  );
  const res = await task.downloadAsync();
  if (!res || res.status !== 200) throw new Error(`model download failed (${res?.status})`);
  return f.uri;
}

let session: Promise<InferenceSession> | null = null;

function getSession(modelUri: string): Promise<InferenceSession> {
  session ??= InferenceSession.create(toPath(modelUri), {
    executionProviders: [{ name: 'coreml', useCPUAndGPU: true }, 'cpu'],
  }).catch(() => InferenceSession.create(toPath(modelUri), { executionProviders: ['cpu'] }));
  session.catch(() => {
    session = null;
  });
  return session;
}

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

  const needsModel = !isModelDownloaded();
  const split = needsModel ? 0.2 : 0;
  const modelUri = await ensureModel((f) => onProgress?.(f * split));
  const runner = ortRunner(await getSession(modelUri), Tensor);

  const audio = await decodeAudioData(songUri, SAMPLE_RATE);
  const input = [audio.getChannelData(0)];
  if (audio.numberOfChannels > 1) input.push(audio.getChannelData(1));

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
    const drums = await WavStream.open(drumsHandle, SAMPLE_RATE, 2);
    const noDrums = await WavStream.open(noDrumsHandle, SAMPLE_RATE, 2);
    await separate(
      input,
      runner,
      {
        async write(d, n) {
          await drums.write(d);
          await noDrums.write(n);
        },
      },
      (f) => onProgress?.(split + f * (1 - split)),
    );
    await drums.finish();
    await noDrums.finish();
  } finally {
    drumsHandle.close();
    noDrumsHandle.close();
  }
  new File(dir, 'done.json').write(JSON.stringify({ songUri, createdAt: Date.now() }));
  return {
    drumsUri: drumsFile.uri,
    noDrumsUri: noDrumsFile.uri,
    sampleRate: SAMPLE_RATE,
  };
}
