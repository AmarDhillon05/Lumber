// Which build is this? The version comes from app.json; the build number,
// commit and variant are written into buildInfo.json by the iOS CI workflow
// before the JS is bundled (all empty in a local checkout).

import app from '../app.json';
import stamp from './buildInfo.json';

export const appVersion: string = app.expo.version;
export const buildNumber: string = stamp.build;
export const buildCommit: string = stamp.commit;
export const buildVariant: string = stamp.variant;

// "v1.0.0 #42" / "v1.0.0 dev"
export const shortBuildLabel = `v${appVersion} ${buildNumber ? `#${buildNumber}` : 'dev'}`;

// "Lumber 1.0.0 · build 42 · abc1234 · Release" / "Lumber 1.0.0 · local build"
export const buildLabel = [
  `Lumber ${appVersion}`,
  buildNumber ? `build ${buildNumber}` : 'local build',
  buildCommit || null,
  buildVariant || null,
]
  .filter(Boolean)
  .join(' · ');
