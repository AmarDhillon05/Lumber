// Decoding the audio a project needs, at the engine rate. Shared by the
// editor preview and export so both hear exactly the same inputs.

import { AudioFile } from '../dsp/AudioFile';
import type { Channels } from '../dsp/types';
import type { LibrarySong, Take } from '../state/types';
import { ENGINE_SAMPLE_RATE } from './engine';

export interface ProjectAudio {
  sampleRate: number;
  drums: Channels; // raw take
  song: Channels | null; // full song (when no stems)
  stems: { drums: Channels; noDrums: Channels } | null;
}

const decode = async (uri: string): Promise<Channels> => (await AudioFile.decode(uri, ENGINE_SAMPLE_RATE)).data;

export async function loadProjectAudio(song: LibrarySong, take: Take): Promise<ProjectAudio> {
  const drums = await decode(take.drumsUri);
  if (song.stems) {
    try {
      const [sd, nd] = await Promise.all([decode(song.stems.drumsUri), decode(song.stems.noDrumsUri)]);
      return { sampleRate: ENGINE_SAMPLE_RATE, drums, song: null, stems: { drums: sd, noDrums: nd } };
    } catch (e) {
      console.warn('stems failed to decode; using the full song', e);
    }
  }
  return { sampleRate: ENGINE_SAMPLE_RATE, drums, song: await decode(song.uri), stems: null };
}
