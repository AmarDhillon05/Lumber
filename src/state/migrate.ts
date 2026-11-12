// Turns whatever db.json holds into a current Db. Pure (Node-tested): fields
// added after a file was written get defaults, so old files keep loading.

import { normalizeRecordings } from '../recordings/core';
import { DEFAULT_SETTINGS, emptyDb, type Db } from './types';

const arr = <T>(v: unknown, fallback: T[]): T[] => (Array.isArray(v) ? (v as T[]) : fallback);

export function migrateDb(raw: unknown): Db {
  const base = emptyDb();
  if (!raw || typeof raw !== 'object') return base;
  const r = raw as Partial<Record<keyof Db, unknown>>;
  const settings = r.settings && typeof r.settings === 'object' ? (r.settings as Partial<Db['settings']>) : {};
  return {
    version: 1,
    songs: arr(r.songs, base.songs),
    takes: arr(r.takes, base.takes),
    projects: arr(r.projects, base.projects),
    recordings: normalizeRecordings(r.recordings),
    settings: { ...DEFAULT_SETTINGS, ...settings },
  };
}
