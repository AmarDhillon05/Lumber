// Video + M4A export. The mix is rendered exactly like Export WAV
// (renderMix: drum chain → place at offset → mix → −1 dBFS limiter); the
// native LumberMedia module then does the AVFoundation part.
//
// Video length: the output is the overlap of the clip (placed on the song
// timeline at its offset + nudge) and the mix — both are trimmed to it, so
// there are no black or frozen frames (planVideoExport in ./sync).

import * as Sharing from 'expo-sharing';
import { File } from 'expo-file-system';
import { exportM4A as nativeExportM4A, getVideoInfo, muxVideo } from '../../modules/lumber-media';
import { exportWav, renderMix } from '../audio/export';
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
): Promise<string> {
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
  try {
    return await muxVideo(
      {
        videoUri: video.uri,
        audioUri: wav.uri,
        outputUri: exportFile(`${base}.mp4`).uri,
        videoStartSec: plan.videoStartSec,
        durationSec: (b - a) / sr,
      },
      onProgress,
    );
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
): Promise<string> {
  const wavUri = await exportWav(name, audio, take, mix, processedDrums);
  return nativeExportM4A(wavUri, exportFile(`${safeName(name)}.m4a`).uri, onProgress);
}

export async function shareMedia(uri: string): Promise<void> {
  if (!(await Sharing.isAvailableAsync())) throw new Error('Sharing is not available on this device');
  const ext = uri.split('?')[0].split('.').pop()?.toLowerCase();
  const type =
    ext === 'mp4'
      ? { mimeType: 'video/mp4', UTI: 'public.mpeg-4' }
      : ext === 'mov'
        ? { mimeType: 'video/quicktime', UTI: 'com.apple.quicktime-movie' }
        : { mimeType: 'audio/mp4', UTI: 'com.apple.m4a-audio' };
  await Sharing.shareAsync(uri, { ...type, dialogTitle: 'Export' });
}
