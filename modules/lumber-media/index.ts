// JS side of the LumberMedia native module (ios/LumberMediaModule.swift).
// Optional: a dev-client build made before this module existed simply has no
// video export; callers check `isAvailable` first.

import { requireOptionalNativeModule, type NativeModule } from 'expo';

export interface VideoInfo {
  durationSec: number;
  width?: number; // display size (after the clip's rotation)
  height?: number;
  frameRate?: number;
}

export interface MuxVideoOptions {
  videoUri: string; // camera clip
  audioUri: string; // mix WAV, already cut to start at the output's start
  outputUri: string; // .mp4 to write (becomes .mov if mp4 is unavailable)
  videoStartSec: number; // seconds into the clip where the output starts
  durationSec: number; // output length
}

type Events = {
  onExportProgress: (e: { progress: number }) => void;
};

declare class LumberMediaModule extends NativeModule<Events> {
  getVideoInfo(uri: string): Promise<VideoInfo>;
  muxVideo(options: MuxVideoOptions): Promise<string>;
  exportM4A(wavUri: string, outputUri: string): Promise<string>;
}

const native = requireOptionalNativeModule<LumberMediaModule>('LumberMedia');

export const isAvailable = native != null;

function mod(): LumberMediaModule {
  if (!native) throw new Error('This build has no video export yet — install a newer Lumber build.');
  return native;
}

export const getVideoInfo = (uri: string) => mod().getVideoInfo(uri);

/** Runs `fn` with progress reporting (both exports emit onExportProgress). */
async function withProgress<T>(onProgress: ((p: number) => void) | undefined, fn: () => Promise<T>): Promise<T> {
  const sub = onProgress ? mod().addListener('onExportProgress', (e) => onProgress(e.progress)) : null;
  try {
    return await fn();
  } finally {
    sub?.remove();
  }
}

export const muxVideo = (options: MuxVideoOptions, onProgress?: (p: number) => void) =>
  withProgress(onProgress, () => mod().muxVideo(options));

export const exportM4A = (wavUri: string, outputUri: string, onProgress?: (p: number) => void) =>
  withProgress(onProgress, () => mod().exportM4A(wavUri, outputUri));
