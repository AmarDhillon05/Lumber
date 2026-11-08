import type { Song } from '../sources/types';
import type { SeparationResult } from '../separation';
import type { BlanketValues } from '../dsp/blanketTerms';

export interface LibrarySong extends Song {
  addedAt: number;
  stems?: SeparationResult; // set once "Remove original drums" has run
}

export interface Take {
  id: string;
  songId: string;
  drumsUri: string; // file:// WAV of the mic recording
  songStartSec: number; // song position playback started from
  drumOffsetSec: number; // song time where drum-file sample 0 belongs (latency-compensated)
  latencyMs: number; // round-trip latency that was compensated
  sampleRate: number;
  createdAt: number;
  video?: TakeVideo; // camera clip filmed during the take
}

export interface TakeVideo {
  uri: string; // file:// .mov in documents/lumber/videos (no audio track)
  offsetSec: number; // song time where video time 0 belongs (see src/video/sync.ts)
  durationSec: number; // approximate, from the last progress event
  facing: 'front' | 'back';
  syncSource: 'progress' | 'call'; // how the start time was estimated
}

export interface MixSettings {
  nudgeMs: number; // manual alignment on top of take.drumOffsetSec
  songGain: number; // 0..1.5
  drumGain: number; // 0..1.5
  originalDrums: number; // 0..1, only used when the song has stems
  values: BlanketValues;
  presetId?: string;
  videoNudgeMs?: number; // manual video alignment on top of take.video.offsetSec
}

export interface Project {
  id: string;
  songId: string;
  takeId: string;
  name: string;
  mix: MixSettings;
  createdAt: number;
  updatedAt: number;
}

export interface Settings {
  latencyByRoute: Record<string, number>; // ms, measured by calibration
  latencyNudgeMs: number; // manual global nudge on top
  bpm: number;
  countIn: boolean;
}

export interface Db {
  version: 1;
  songs: LibrarySong[];
  takes: Take[];
  projects: Project[];
  settings: Settings;
}

export const DEFAULT_SETTINGS: Settings = {
  latencyByRoute: {},
  latencyNudgeMs: 0,
  bpm: 120,
  countIn: true,
};

export const emptyDb = (): Db => ({
  version: 1,
  songs: [],
  takes: [],
  projects: [],
  settings: { ...DEFAULT_SETTINGS },
});

export type Route =
  | { name: 'library' }
  | { name: 'record'; songId: string }
  | { name: 'edit'; projectId: string };
