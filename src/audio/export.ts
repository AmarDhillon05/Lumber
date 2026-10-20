// Export: drum chain → place at offset → mix with the song (or stems) →
// −1 dBFS limiter (inside mixTake) → WAV → iOS share sheet.
//
// WAV only: react-native-audio-api 0.13 can write M4A/AAC only from the mic
// recorder (AudioRecorder file output); it has no API to encode a buffer we
// rendered offline, so M4A export would need a native module (AVAudioFile).

import * as Sharing from 'expo-sharing';
import { File } from 'expo-file-system';
import { mixTake } from '../dsp/mix';
import { renderBlanket } from '../dsp/renderBlanket';
import { encodeWav } from '../dsp/wav';
import type { Channels } from '../dsp/types';
import { subDir } from '../state/persist';
import type { MixSettings, Take } from '../state/types';
import type { ProjectAudio } from './sources';

export function finalOffsetSec(take: Take, mix: MixSettings): number {
  return take.drumOffsetSec + mix.nudgeMs / 1000;
}

export async function renderMix(audio: ProjectAudio, take: Take, mix: MixSettings, processedDrums?: Channels): Promise<Channels> {
  const drums = processedDrums ?? (await renderBlanket(audio.drums, audio.sampleRate, mix.values));
  return mixTake({
    song: audio.song ?? audio.stems!.noDrums,
    drums,
    sampleRate: audio.sampleRate,
    drumOffsetSec: finalOffsetSec(take, mix),
    songGain: mix.songGain,
    drumGain: mix.drumGain,
    originalDrums: audio.stems
      ? { drums: audio.stems.drums, noDrums: audio.stems.noDrums, amount: mix.originalDrums }
      : undefined,
  });
}

export async function exportWav(
  name: string,
  audio: ProjectAudio,
  take: Take,
  mix: MixSettings,
  processedDrums?: Channels,
): Promise<string> {
  const mixed = await renderMix(audio, take, mix, processedDrums);
  const bytes = encodeWav(mixed, audio.sampleRate, 24);
  const safe = name.replace(/[^\w\- ]+/g, '').trim().replace(/\s+/g, '_') || 'lumber_mix';
  const file = new File(subDir('exports'), `${safe}.wav`);
  if (file.exists) file.delete();
  file.create();
  file.writeSync(bytes);
  return file.uri;
}

export async function shareFile(uri: string): Promise<void> {
  if (!(await Sharing.isAvailableAsync())) throw new Error('Sharing is not available on this device');
  await Sharing.shareAsync(uri, { mimeType: 'audio/wav', UTI: 'com.microsoft.waveform-audio', dialogTitle: 'Export mix' });
}
