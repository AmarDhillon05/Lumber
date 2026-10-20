// SHIM — stand-in for src/sources/localFile.ts (not on any branch yet).
// Delete once the real module lands and point src/app-shims/index.ts at it.

import * as DocumentPicker from 'expo-document-picker';
import { Directory, File, Paths } from 'expo-file-system';
import type { Song } from '../sources/types';

export async function importLocalFile(): Promise<Song | null> {
  const res = await DocumentPicker.getDocumentAsync({ type: 'audio/*', copyToCacheDirectory: true });
  if (res.canceled || !res.assets?.length) return null;
  const asset = res.assets[0];
  const dir = new Directory(Paths.document, 'lumber', 'songs');
  dir.create({ intermediates: true, idempotent: true });
  const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  const ext = (asset.name.match(/\.[a-z0-9]+$/i)?.[0] ?? '.m4a').toLowerCase();
  const dest = new File(dir, `${id}${ext}`);
  new File(asset.uri).copySync(dest);
  return {
    id: `file:${id}`,
    title: asset.name.replace(/\.[^.]+$/, ''),
    source: 'file',
    uri: dest.uri,
  };
}
