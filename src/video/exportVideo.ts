// Video + M4A export. Files land in documents/lumber/exports; the caller
// saves them into the Recordings library (src/recordings). The mix is
// rendered exactly like Export WAV (renderMix: drum chain → place at offset →
// mix → −1 dBFS limiter); the native LumberMedia module then does the
// AVFoundation part.
//
// Video length: the output is the overlap of the clip (placed on the song
// timeline at its offset + nudge) and the mix — both are trimmed to it, so
// there are no black or frozen frames (planVideoExport in ./sync).

import { File } from 'expo-file-system';
import { exportM4A as nativeExportM4A, getVideoInfo, muxVideo } from '../../modules/lumber-media';
import { exportWav, renderMix, type ExportResult } from '../audio/export';
import type { ProjectAudio } from '../audio/sources';
import { encodeWav } from '../dsp/wav';
import type { Channels } from '../dsp/types';
import { subDir } from '../state/persist';
import type { MixSettings, Take } from '../state/types';
import { finalVideoOffsetSec, planVideoExport, sampleRange } from './sync';

const safeName = (name: string) => name.replace(/[^\w\- ]+/g, '').trim().replace(/\s+/g, '_') || 'lumber_mix';

const exportFile = (fileName: string) => {
  const f = new File(subDir('exports'), fileName);
  if (f.exists) f.delete();
  return f;
};

export async function exportVideo(
  name: string,
  audio: ProjectAudio,
  take: Take,
  mix: MixSettings,
  processedDrums?: Channels,
  onProgress?: (p: number) => void,
): Promise<ExportResult> {
  const video = take.video;
  if (!video) throw new Error('This take has no video');
  const info = await getVideoInfo(video.uri);
  const mixed = await renderMix(audio, take, mix, processedDrums);
  const sr = audio.sampleRate;
  const total = mixed[0]?.length ?? 0;
  const plan = planVideoExport(finalVideoOffsetSec(video.offsetSec, mix.videoNudgeMs), info.durationSec, total / sr);
  if (!plan) throw new Error("The video doesn't overlap the song — check the video offset.");
  const [a, b] = sampleRange(plan, sr, total);

  const base = safeName(name);
  const wav = exportFile(`${base}.video-audio.wav`);
  wav.create();
  wav.writeSync(encodeWav(mixed.map((ch) => ch.subarray(a, b)), sr, 24));
  const durationSec = (b - a) / sr;
  try {
    const uri = await muxVideo(
      {
        videoUri: video.uri,
        audioUri: wav.uri,
        outputUri: exportFile(`${base}.mp4`).uri,
        videoStartSec: plan.videoStartSec,
        durationSec,
      },
      onProgress,
    );
    return { uri, durationSec };
  } finally {
    try {
      wav.delete();
    } catch {
      // best effort
    }
  }
}

export async function exportM4a(
  name: string,
  audio: ProjectAudio,
  take: Take,
  mix: MixSettings,
  processedDrums?: Channels,
  onProgress?: (p: number) => void,
): Promise<ExportResult> {
  const wav = await exportWav(name, audio, take, mix, processedDrums);
  try {
    const uri = await nativeExportM4A(wav.uri, exportFile(`${safeName(name)}.m4a`).uri, onProgress);
    return { uri, durationSec: wav.durationSec };
  } finally {
    try {
      const f = new File(wav.uri);
      if (f.exists) f.delete();
    } catch {
      // best effort
    }
  }
}
