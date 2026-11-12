// Pure helpers for the Recordings library: naming, sorting, sizes, and
// validating entries read back from db.json. No native imports (Node tests).

import type { Recording, RecordingKind } from '../state/types';

export const RECORDING_KINDS: readonly RecordingKind[] = ['video', 'mix-wav', 'mix-m4a', 'take-wav', 'take-video'];

export const isVideoKind = (k: RecordingKind): boolean => k === 'video' || k === 'take-video';

export const KIND_LABEL: Record<RecordingKind, string> = {
  video: 'Video',
  'mix-wav': 'Mix · WAV',
  'mix-m4a': 'Mix · M4A',
  'take-wav': 'Raw take · WAV',
  'take-video': 'Raw take · video',
};

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const pad = (n: number) => (n < 10 ? `0${n}` : `${n}`);

/** "Nov 12, 2026 · 14:05" in local time. */
export function formatRecordingDate(ms: number): string {
  const d = new Date(ms);
  return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()} · ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** Default title: the song title plus the date ("Song — Nov 12, 2026 · 14:05"). */
export function defaultRecordingTitle(songTitle: string | undefined, at: number, kind: RecordingKind): string {
  const base = songTitle?.trim() || 'Lumber';
  const raw = kind === 'take-wav' || kind === 'take-video' ? ' (raw take)' : '';
  return `${base}${raw} — ${formatRecordingDate(at)}`;
}

/** Filesystem-safe, unique file name: `<title>_<id>.<ext>`. */
export function recordingFileName(title: string, id: string, ext: string): string {
  const safe =
    title
      .replace(/[^\w\- ]+/g, '')
      .trim()
      .replace(/\s+/g, '_')
      .slice(0, 60) || 'lumber';
  return `${safe}_${id}.${ext.replace(/^\./, '').toLowerCase()}`;
}

export const extOf = (uri: string): string => uri.split('?')[0].split('#')[0].split('.').pop()?.toLowerCase() ?? '';

/** Newest first; ties broken by id so the order is stable. */
export function sortRecordings(list: readonly Recording[]): Recording[] {
  return [...list].sort((a, b) => b.createdAt - a.createdAt || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
}

export const totalSize = (list: readonly Recording[]): number =>
  list.reduce((sum, r) => sum + (Number.isFinite(r.size) && r.size > 0 ? r.size : 0), 0);

export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '0 KB';
  if (n < 1024 * 1024) return `${Math.max(1, Math.round(n / 1024))} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

/** "1:05" / "12:00" / "1:02:03". */
export function formatDuration(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return '--:--';
  const s = Math.round(sec);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  return h > 0 ? `${h}:${pad(m)}:${pad(r)}` : `${m}:${pad(r)}`;
}

/** Share-sheet type for a recording's file. */
export function shareTypeFor(fileName: string): { mimeType: string; UTI: string } {
  switch (extOf(fileName)) {
    case 'mp4':
      return { mimeType: 'video/mp4', UTI: 'public.mpeg-4' };
    case 'mov':
      return { mimeType: 'video/quicktime', UTI: 'com.apple.quicktime-movie' };
    case 'wav':
      return { mimeType: 'audio/wav', UTI: 'com.microsoft.waveform-audio' };
    default:
      return { mimeType: 'audio/mp4', UTI: 'com.apple.m4a-audio' };
  }
}

const str = (v: unknown): v is string => typeof v === 'string' && v.length > 0;
const num = (v: unknown, fallback = 0): number => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);

/** Validates one entry from db.json; returns null for anything unusable. */
export function normalizeRecording(raw: unknown): Recording | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  if (!str(r.id) || !RECORDING_KINDS.includes(r.kind as RecordingKind)) return null;
  const uri = str(r.uri) ? r.uri : '';
  const fileName = str(r.fileName) ? r.fileName : decodeURIComponent(uri.split('/').pop() ?? '');
  if (!fileName) return null;
  const createdAt = num(r.createdAt, 0);
  return {
    id: r.id,
    kind: r.kind as RecordingKind,
    fileName,
    uri,
    title: str(r.title) ? r.title : defaultRecordingTitle(undefined, createdAt, r.kind as RecordingKind),
    projectId: str(r.projectId) ? r.projectId : undefined,
    songId: str(r.songId) ? r.songId : undefined,
    createdAt,
    durationSec: Math.max(0, num(r.durationSec)),
    size: Math.max(0, num(r.size)),
    thumbnail: str(r.thumbnail) ? r.thumbnail : undefined,
  };
}

export function normalizeRecordings(raw: unknown): Recording[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: Recording[] = [];
  for (const item of raw) {
    const r = normalizeRecording(item);
    if (r && !seen.has(r.id)) {
      seen.add(r.id);
      out.push(r);
    }
  }
  return out;
}
