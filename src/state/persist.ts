// JSON persistence in the app's documents directory. One small file holds the
// library, takes, projects and settings; audio lives next to it as files.

import { Directory, File, Paths } from 'expo-file-system';
import { emptyDb, DEFAULT_SETTINGS, type Db } from './types';

export const appDir = (): Directory => {
  const d = new Directory(Paths.document, 'lumber');
  d.create({ intermediates: true, idempotent: true });
  return d;
};

export const subDir = (name: string): Directory => {
  const d = new Directory(appDir(), name);
  d.create({ intermediates: true, idempotent: true });
  return d;
};

const dbFile = () => new File(appDir(), 'db.json');

export async function loadDb(): Promise<Db> {
  try {
    const f = dbFile();
    if (!f.exists) return emptyDb();
    const raw = JSON.parse(await f.text()) as Partial<Db>;
    return {
      ...emptyDb(),
      ...raw,
      version: 1,
      settings: { ...DEFAULT_SETTINGS, ...(raw.settings ?? {}) },
    };
  } catch (e) {
    console.warn('loadDb failed, starting empty', e);
    return emptyDb();
  }
}

export function saveDb(db: Db): void {
  // Write to a temp file then move over, so a crash mid-write can't truncate.
  const tmp = new File(appDir(), 'db.json.tmp');
  tmp.writeSync(JSON.stringify(db));
  tmp.moveSync(dbFile(), { overwrite: true });
}

export const newId = (): string => Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
