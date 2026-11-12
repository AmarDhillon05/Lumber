// Store glue: put a file into the Recordings library and list it.

import { useStore } from '../state/store';
import type { LibrarySong, Project, Recording, RecordingKind, Take } from '../state/types';
import { saveRecordingFile } from './files';

export async function saveExport(
  kind: RecordingKind,
  result: { uri: string; durationSec: number },
  project: Project,
  song?: LibrarySong,
): Promise<Recording> {
  const rec = await saveRecordingFile({
    srcUri: result.uri,
    kind,
    songTitle: song?.title,
    songId: project.songId,
    projectId: project.id,
    durationSec: result.durationSec,
  });
  useStore.getState().addRecording(rec);
  return rec;
}

/** Copies the take as recorded (drums WAV, plus the camera clip if filmed). */
export async function saveRawTake(
  project: Project,
  take: Take,
  song: LibrarySong | undefined,
  drumsDurationSec: number,
): Promise<Recording[]> {
  const base = { songTitle: song?.title, songId: project.songId, projectId: project.id, copy: true };
  const out: Recording[] = [];
  out.push(await saveRecordingFile({ ...base, srcUri: take.drumsUri, kind: 'take-wav', durationSec: drumsDurationSec }));
  if (take.video) {
    out.push(
      await saveRecordingFile({ ...base, srcUri: take.video.uri, kind: 'take-video', durationSec: take.video.durationSec }),
    );
  }
  const { addRecording } = useStore.getState();
  out.forEach(addRecording);
  return out;
}
