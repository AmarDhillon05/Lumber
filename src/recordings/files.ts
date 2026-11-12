// Files behind the Recordings library (documents/lumber/recordings): saving an
// export or a raw take into it, deleting, sharing, and Save to Photos.

import { requireOptionalNativeModule } from 'expo';
import { File } from 'expo-file-system';
import * as Sharing from 'expo-sharing';
import { newId, subDir } from '../state/persist';
import type { Recording, RecordingKind } from '../state/types';
import { defaultRecordingTitle, extOf, isVideoKind, recordingFileName, shareTypeFor } from './core';

export const recordingsDir = () => subDir('recordings');

/** The recording's file, resolved by name (absolute paths can change between installs). */
export const recordingFile = (rec: Pick<Recording, 'fileName'>): File => new File(recordingsDir(), rec.fileName);

export const thumbnailUri = (rec: Recording): string | undefined =>
  rec.thumbnail ? new File(recordingsDir(), rec.thumbnail).uri : undefined;

const tryDelete = (f: File) => {
  try {
    if (f.exists) f.delete();
  } catch {
    // best effort
  }
};

export function deleteRecordingFiles(rec: Recording): void {
  tryDelete(recordingFile(rec));
  if (rec.thumbnail) tryDelete(new File(recordingsDir(), rec.thumbnail));
}

export interface SaveOptions {
  srcUri: string; // the exported file (or the take's file when copying)
  kind: RecordingKind;
  songTitle?: string;
  songId?: string;
  projectId?: string;
  durationSec: number;
  /** Copy instead of move: for raw takes, whose files the project still uses. */
  copy?: boolean;
}

/**
 * Moves (or copies) a file into recordings/ and returns its library entry.
 * The caller adds it to the store. Video thumbnails are best effort.
 */
export async function saveRecordingFile(opts: SaveOptions): Promise<Recording> {
  const src = new File(opts.srcUri);
  if (!src.exists) throw new Error('The exported file is missing.');
  const id = newId();
  const createdAt = Date.now();
  const title = defaultRecordingTitle(opts.songTitle, createdAt, opts.kind);
  const fileName = recordingFileName(title, id, extOf(opts.srcUri) || 'bin');
  const dest = new File(recordingsDir(), fileName);
  if (opts.copy) src.copySync(dest);
  else src.moveSync(dest);

  const rec: Recording = {
    id,
    kind: opts.kind,
    fileName,
    uri: dest.uri,
    title,
    projectId: opts.projectId,
    songId: opts.songId,
    createdAt,
    durationSec: opts.durationSec,
    size: dest.size ?? 0,
  };
  if (isVideoKind(opts.kind)) {
    const thumbName = fileName.replace(/\.[^.]+$/, '') + '.thumb.jpg';
    if (await makeThumbnail(dest.uri, new File(recordingsDir(), thumbName), opts.durationSec)) rec.thumbnail = thumbName;
  }
  return rec;
}

// Thumbnail: expo-video grabs a frame, expo-image-manipulator writes it as a
// JPEG. Both are native; a build without them just shows a placeholder.
const canThumbnail =
  requireOptionalNativeModule('ExpoVideo') != null && requireOptionalNativeModule('ExpoImageManipulator') != null;

async function makeThumbnail(videoUri: string, dest: File, durationSec: number): Promise<boolean> {
  if (!canThumbnail) return false;
  /* eslint-disable @typescript-eslint/no-require-imports */
  const { createVideoPlayer } = require('expo-video') as typeof import('expo-video');
  const { ImageManipulator, SaveFormat } = require('expo-image-manipulator') as typeof import('expo-image-manipulator');
  /* eslint-enable @typescript-eslint/no-require-imports */
  const player = createVideoPlayer(videoUri);
  try {
    player.muted = true;
    const at = Math.max(0, Math.min(1, durationSec / 2));
    const [thumb] = await player.generateThumbnailsAsync([at], { maxWidth: 360 });
    if (!thumb) return false;
    const image = await ImageManipulator.manipulate(thumb).renderAsync();
    const saved = await image.saveAsync({ format: SaveFormat.JPEG, compress: 0.7 });
    tryDelete(dest);
    new File(saved.uri).moveSync(dest);
    return true;
  } catch (e) {
    console.warn('thumbnail failed', e);
    return false;
  } finally {
    try {
      player.release();
    } catch {
      // ignore
    }
  }
}

export async function shareRecording(rec: Recording): Promise<void> {
  if (!(await Sharing.isAvailableAsync())) throw new Error('Sharing is not available on this device');
  const f = recordingFile(rec);
  if (!f.exists) throw new Error('This recording’s file is missing.');
  await Sharing.shareAsync(f.uri, { ...shareTypeFor(rec.fileName), dialogTitle: rec.title });
}

export const canSaveToPhotos = requireOptionalNativeModule('ExpoMediaLibrary') != null;

export type PhotosResult = 'saved' | 'denied' | 'unavailable';

/** Saves a video into the Photos library (add-only access). */
export async function saveToPhotos(rec: Recording): Promise<PhotosResult> {
  if (!canSaveToPhotos || !isVideoKind(rec.kind)) return 'unavailable';
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const MediaLibrary = require('expo-media-library/legacy') as typeof import('expo-media-library/legacy');
  let perm = await MediaLibrary.getPermissionsAsync(true);
  if (!perm.granted && perm.canAskAgain) perm = await MediaLibrary.requestPermissionsAsync(true);
  if (!perm.granted) return 'denied';
  const f = recordingFile(rec);
  if (!f.exists) throw new Error('This recording’s file is missing.');
  await MediaLibrary.saveToLibraryAsync(f.uri);
  return 'saved';
}
