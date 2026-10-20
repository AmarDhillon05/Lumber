// App state: library, takes, projects, settings and the current screen.
// Everything except `route`, `jobs` and `loaded` is persisted to db.json
// (debounced) on change.

import { create } from 'zustand';
import { File } from 'expo-file-system';
import { fillValues } from '../app-shims';
import type { SeparationResult } from '../separation';
import { loadDb, newId, saveDb } from './persist';
import {
  emptyDb,
  type Db,
  type LibrarySong,
  type MixSettings,
  type Project,
  type Route,
  type Settings,
  type Take,
} from './types';

// Progress of long-running per-song jobs (download, separation), keyed by id.
export interface Job {
  label: string;
  progress: number; // 0..1
  error?: string;
}

interface State extends Db {
  loaded: boolean;
  route: Route;
  jobs: Record<string, Job>;

  init(): Promise<void>;
  go(route: Route): void;

  addSong(song: Omit<LibrarySong, 'addedAt'>): void;
  removeSong(id: string): void;
  setStems(songId: string, stems: SeparationResult): void;

  addTake(take: Take): Project; // creates a project for it
  removeProject(id: string): void;
  updateMix(projectId: string, patch: Partial<MixSettings>): void;
  renameProject(projectId: string, name: string): void;

  updateSettings(patch: Partial<Settings>): void;
  setJob(id: string, job: Job | null): void;
}

export const defaultMix = (): MixSettings => ({
  nudgeMs: 0,
  songGain: 0.8,
  drumGain: 1,
  originalDrums: 0,
  values: fillValues({}),
});

let saveTimer: ReturnType<typeof setTimeout> | null = null;
function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const s = useStore.getState();
    try {
      saveDb({ version: 1, songs: s.songs, takes: s.takes, projects: s.projects, settings: s.settings });
    } catch (e) {
      console.warn('saveDb failed', e);
    }
  }, 300);
}

const tryDelete = (uri?: string) => {
  if (!uri) return;
  try {
    const f = new File(uri);
    if (f.exists) f.delete();
  } catch {
    // best effort
  }
};

export const useStore = create<State>()((set, get) => ({
  ...emptyDb(),
  loaded: false,
  route: { name: 'library' },
  jobs: {},

  async init() {
    const db = await loadDb();
    set({ ...db, loaded: true });
  },

  go(route) {
    set({ route });
  },

  addSong(song) {
    if (get().songs.some((s) => s.id === song.id)) return;
    set((s) => ({ songs: [{ ...song, addedAt: Date.now() }, ...s.songs] }));
    scheduleSave();
  },

  removeSong(id) {
    const s = get();
    const song = s.songs.find((x) => x.id === id);
    const takes = s.takes.filter((t) => t.songId === id);
    takes.forEach((t) => tryDelete(t.drumsUri));
    tryDelete(song?.uri);
    set({
      songs: s.songs.filter((x) => x.id !== id),
      takes: s.takes.filter((t) => t.songId !== id),
      projects: s.projects.filter((p) => p.songId !== id),
    });
    scheduleSave();
  },

  setStems(songId, stems) {
    set((s) => ({ songs: s.songs.map((x) => (x.id === songId ? { ...x, stems } : x)) }));
    scheduleSave();
  },

  addTake(take) {
    const song = get().songs.find((s) => s.id === take.songId);
    const n = get().projects.filter((p) => p.songId === take.songId).length + 1;
    const now = Date.now();
    const project: Project = {
      id: newId(),
      songId: take.songId,
      takeId: take.id,
      name: `${song?.title ?? 'Take'} — take ${n}`,
      mix: defaultMix(),
      createdAt: now,
      updatedAt: now,
    };
    set((s) => ({ takes: [...s.takes, take], projects: [project, ...s.projects] }));
    scheduleSave();
    return project;
  },

  removeProject(id) {
    const s = get();
    const p = s.projects.find((x) => x.id === id);
    if (!p) return;
    const take = s.takes.find((t) => t.id === p.takeId);
    const stillUsed = s.projects.some((x) => x.id !== id && x.takeId === p.takeId);
    if (take && !stillUsed) tryDelete(take.drumsUri);
    set({
      projects: s.projects.filter((x) => x.id !== id),
      takes: stillUsed ? s.takes : s.takes.filter((t) => t.id !== p.takeId),
    });
    scheduleSave();
  },

  updateMix(projectId, patch) {
    set((s) => ({
      projects: s.projects.map((p) =>
        p.id === projectId ? { ...p, mix: { ...p.mix, ...patch }, updatedAt: Date.now() } : p,
      ),
    }));
    scheduleSave();
  },

  renameProject(projectId, name) {
    set((s) => ({ projects: s.projects.map((p) => (p.id === projectId ? { ...p, name } : p)) }));
    scheduleSave();
  },

  updateSettings(patch) {
    set((s) => ({ settings: { ...s.settings, ...patch } }));
    scheduleSave();
  },

  setJob(id, job) {
    set((s) => {
      const jobs = { ...s.jobs };
      if (job) jobs[id] = job;
      else delete jobs[id];
      return { jobs };
    });
  },
}));

export const selectSong = (id: string) => (s: State) => s.songs.find((x) => x.id === id);
export const selectProject = (id: string) => (s: State) => s.projects.find((x) => x.id === id);
