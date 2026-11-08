// expo-camera and expo-video throw at import time when their native code is
// missing (e.g. new JS on a dev-client build made before video existed), so
// the screens load the video components only when the native side is there.

import { requireOptionalNativeModule } from 'expo';

export const hasCamera = requireOptionalNativeModule('ExpoCamera') != null;
export const hasVideoPlayer = requireOptionalNativeModule('ExpoVideo') != null;

/* eslint-disable @typescript-eslint/no-require-imports */
export const CameraPanel = hasCamera
  ? (require('./CameraPanel') as typeof import('./CameraPanel')).CameraPanel
  : null;

export const VideoPanel = hasVideoPlayer
  ? (require('./VideoPanel') as typeof import('./VideoPanel')).VideoPanel
  : null;
