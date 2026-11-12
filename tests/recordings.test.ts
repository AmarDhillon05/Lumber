import { ok, section } from './harness';
import {
  defaultRecordingTitle,
  extOf,
  formatBytes,
  formatDuration,
  formatRecordingDate,
  isVideoKind,
  normalizeRecording,
  recordingFileName,
  shareTypeFor,
  sortRecordings,
  totalSize,
} from '../src/recordings/core';
import { migrateDb } from '../src/state/migrate';
import { DEFAULT_SETTINGS, type Recording } from '../src/state/types';

const rec = (id: string, createdAt: number, size = 0, extra: Partial<Recording> = {}): Recording => ({
  id,
  kind: 'mix-wav',
  fileName: `${id}.wav`,
  uri: `file:///docs/lumber/recordings/${id}.wav`,
  title: id,
  createdAt,
  durationSec: 10,
  size,
  ...extra,
});

export function run(): void {
  section('recordings: migration');
  {
    // A db.json written before recordings existed.
    const old = {
      version: 1,
      songs: [{ id: 's1', title: 'Song', source: 'file', uri: 'file:///a.mp3', addedAt: 1 }],
      takes: [],
      projects: [],
      settings: { bpm: 90 },
    };
    const db = migrateDb(old);
    ok('old db: recordings default to []', Array.isArray(db.recordings) && db.recordings.length === 0);
    ok('old db: songs kept', db.songs.length === 1 && db.songs[0].id === 's1');
    ok('old db: settings merged with defaults', db.settings.bpm === 90 && db.settings.countIn === DEFAULT_SETTINGS.countIn);

    const empty = migrateDb(null);
    ok('null → empty db', empty.songs.length === 0 && empty.recordings.length === 0 && empty.version === 1);
    ok('garbage arrays → defaults', migrateDb({ songs: 'x', recordings: { a: 1 } }).songs.length === 0);

    const withRecs = migrateDb({
      recordings: [
        rec('a', 100, 10),
        rec('a', 200, 10), // duplicate id dropped
        { id: 'b', kind: 'nope', fileName: 'b.wav' }, // unknown kind
        { kind: 'video', fileName: 'c.mp4' }, // no id
        { id: 'd', kind: 'video', uri: 'file:///x/recordings/My%20clip_d.mp4', createdAt: 5 }, // no fileName
        null,
      ],
    });
    ok('invalid recordings dropped, duplicates removed', withRecs.recordings.map((r) => r.id).join(',') === 'a,d');
    const d = withRecs.recordings[1];
    ok('fileName recovered from uri', d.fileName === 'My clip_d.mp4', d.fileName);
    ok('missing title gets a default', d.title.startsWith('Lumber — '), d.title);
    ok('missing size/duration → 0', d.size === 0 && d.durationSec === 0);
    ok('normalizeRecording rejects non-objects', normalizeRecording('x') === null && normalizeRecording(undefined) === null);
    const n = normalizeRecording({ ...rec('e', 1), size: -5, durationSec: NaN, thumbnail: '' });
    ok('negative size / NaN duration / empty thumbnail cleaned', !!n && n.size === 0 && n.durationSec === 0 && n.thumbnail === undefined);
  }

  section('recordings: naming');
  {
    const at = new Date(2026, 10, 12, 9, 5).getTime(); // local time
    ok('date format', formatRecordingDate(at) === 'Nov 12, 2026 · 09:05', formatRecordingDate(at));
    ok('title = song + date', defaultRecordingTitle('Hey Jude', at, 'video') === 'Hey Jude — Nov 12, 2026 · 09:05');
    ok('raw take marked', defaultRecordingTitle('Hey Jude', at, 'take-wav') === 'Hey Jude (raw take) — Nov 12, 2026 · 09:05');
    ok('no song → Lumber', defaultRecordingTitle(undefined, at, 'mix-m4a').startsWith('Lumber — '));
    ok('blank song → Lumber', defaultRecordingTitle('  ', at, 'mix-m4a').startsWith('Lumber — '));

    const fn = recordingFileName('Hey Jude — Nov 12, 2026 · 09:05', 'abc123', '.MP4');
    ok('file name is safe + unique', fn === 'Hey_Jude_Nov_12_2026_0905_abc123.mp4', fn);
    ok('file name of symbols only falls back', recordingFileName('★★★', 'id1', 'wav') === 'lumber_id1.wav');
    ok('long titles are cut', recordingFileName('x'.repeat(200), 'id', 'wav').length <= 60 + '_id.wav'.length);

    ok('extOf', extOf('file:///a/b.c/clip.MOV?x=1') === 'mov' && extOf('a.m4a') === 'm4a');
    ok('share types', shareTypeFor('a.mp4').mimeType === 'video/mp4' && shareTypeFor('a.wav').UTI === 'com.microsoft.waveform-audio' && shareTypeFor('a.m4a').mimeType === 'audio/mp4' && shareTypeFor('a.mov').UTI === 'com.apple.quicktime-movie');
    ok('video kinds', isVideoKind('video') && isVideoKind('take-video') && !isVideoKind('mix-wav') && !isVideoKind('take-wav'));
  }

  section('recordings: sorting + storage');
  {
    const list = [rec('a', 100, 1000), rec('b', 300, 2048), rec('c', 200, 0), rec('d', 300, 5)];
    const sorted = sortRecordings(list);
    ok('newest first, stable ties', sorted.map((r) => r.id).join(',') === 'd,b,c,a', sorted.map((r) => r.id).join(','));
    ok('sort does not mutate', list[0].id === 'a');
    ok('total size', totalSize(list) === 3053);
    ok('total size ignores bad values', totalSize([rec('x', 1, NaN), rec('y', 1, -3), rec('z', 1, 7)]) === 7);
    ok('formatBytes', formatBytes(0) === '0 KB' && formatBytes(100) === '1 KB' && formatBytes(5 * 1024 * 1024) === '5.0 MB' && formatBytes(3 * 1024 ** 3) === '3.00 GB');
    ok('formatDuration', formatDuration(65) === '1:05' && formatDuration(3723) === '1:02:03' && formatDuration(NaN) === '--:--' && formatDuration(0.4) === '0:00');
  }
}
