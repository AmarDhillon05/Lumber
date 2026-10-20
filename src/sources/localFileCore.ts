// Pure helpers for Files import (no Expo imports; tested under Node).

export const AUDIO_EXTENSIONS = ['mp3', 'm4a', 'wav', 'aac', 'aiff', 'aif'] as const;

// MIME types for the document picker. On iOS Expo maps these to UTIs
// (public.mp3, com.apple.m4a-audio, com.microsoft.waveform-audio, public.aac-audio,
// public.aiff-audio); 'audio/*' (public.audio) is the catch-all.
export const AUDIO_MIME_TYPES = [
  'audio/mpeg',
  'audio/mp4',
  'audio/x-m4a',
  'audio/m4a',
  'audio/wav',
  'audio/x-wav',
  'audio/aac',
  'audio/aiff',
  'audio/x-aiff',
  'audio/*',
];

export function extensionOf(name: string): string | undefined {
  const m = /\.([A-Za-z0-9]+)$/.exec(name.trim());
  return m ? m[1].toLowerCase() : undefined;
}

export function isSupportedAudioName(name: string): boolean {
  const ext = extensionOf(name);
  return !!ext && (AUDIO_EXTENSIONS as readonly string[]).includes(ext);
}

// "01 - Back In Black.m4a" -> "01 - Back In Black"
export function titleFromFileName(name: string): string {
  const base = name.replace(/\.[A-Za-z0-9]+$/, '').replace(/_/g, ' ').trim();
  return base || 'Untitled';
}

// Stable on-disk name: `<hash>.<ext>`; the same file imported twice maps to
// the same path and Song.id.
export function storedFileName(hashHex: string, originalName: string): string {
  const ext = extensionOf(originalName) ?? 'audio';
  return `file-${hashHex.slice(0, 16)}.${ext}`;
}
