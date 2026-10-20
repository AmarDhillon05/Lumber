// Files import: pick an audio file with the system document picker and copy
// it into the app's `songs/` directory. Always available; also the fallback
// when YouTube extraction breaks.

import * as DocumentPicker from 'expo-document-picker';
import { File } from 'expo-file-system';
import type { Song } from './types';
import { AUDIO_MIME_TYPES, isSupportedAudioName, storedFileName, titleFromFileName } from './localFileCore';
import { songsDirectory } from './youtube';

// Returns null when the user cancels. Throws for unsupported file types.
export async function importLocalFile(): Promise<Song | null> {
  const res = await DocumentPicker.getDocumentAsync({
    type: AUDIO_MIME_TYPES,
    copyToCacheDirectory: true, // gives us a readable file:// copy in cache
    multiple: false,
  });
  if (res.canceled || !res.assets?.length) return null;
  const asset = res.assets[0];
  if (!isSupportedAudioName(asset.name)) {
    throw new Error(`Unsupported audio file "${asset.name}" (use mp3, m4a, wav, aac or aiff).`);
  }

  const picked = new File(asset.uri);
  const hash = await picked.digest('SHA-256');
  const dest = new File(songsDirectory(), storedFileName(hash, asset.name));
  if (!dest.exists) {
    picked.copySync(dest);
  }
  try {
    picked.delete(); // the picker's cache copy is no longer needed
  } catch {
    // ignore: cache is cleaned by the OS anyway
  }

  return {
    id: `file:${hash.slice(0, 16)}`,
    title: titleFromFileName(asset.name),
    source: 'file',
    uri: dest.uri,
    // durationSec: filled in by the audio layer after decoding.
  };
}
