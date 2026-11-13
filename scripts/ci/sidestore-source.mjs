// Builds the SideStore / AltStore source (apps.json) that lists Lumber builds,
// so new CI builds show up as updates in SideStore on the phone.
//
//   node scripts/ci/sidestore-source.mjs <previous.json|-> <out.json> \
//        <buildNumber> <downloadURL> <ipaSize> <commitMessage>
//
// Keeps the newest KEEP versions; the matching release assets are pruned by
// the workflow.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';

const KEEP = 5;
const REPO = 'AmarDhillon05/Lumber';
const [prevPath, outPath, build, downloadURL, size, message = ''] = process.argv.slice(2);
if (!outPath || !build || !downloadURL || !size) {
  console.error('usage: sidestore-source.mjs <previous.json|-> <out.json> <build> <downloadURL> <size> [message]');
  process.exit(2);
}

const app = JSON.parse(readFileSync('app.json', 'utf8')).expo;
const infoPlist = app.ios?.infoPlist ?? {};
const iconURL = `https://raw.githubusercontent.com/${REPO}/main/assets/icon.png`;

const previous = prevPath !== '-' && existsSync(prevPath) ? JSON.parse(readFileSync(prevPath, 'utf8')) : null;
const oldVersions = previous?.apps?.[0]?.versions ?? [];

const version = {
  version: app.version,
  buildVersion: String(build),
  date: new Date().toISOString(),
  localizedDescription: `Build ${build}: ${message.split('\n')[0]}`.trim(),
  downloadURL,
  size: Number(size),
  minOSVersion: '16.4',
};

const versions = [version, ...oldVersions.filter((v) => v.buildVersion !== version.buildVersion)].slice(0, KEEP);

// Usage strings shown by SideStore before install; taken from the app config
// plus the ones config plugins add.
const privacy = {
  NSMicrophoneUsageDescription: 'Lumber records your drums while the song plays.',
  NSCameraUsageDescription: 'Lumber films you drumming while you record a take.',
  NSPhotoLibraryAddUsageDescription: 'Lumber saves your exported videos to Photos.',
  ...Object.fromEntries(Object.entries(infoPlist).filter(([k]) => k.endsWith('UsageDescription'))),
};

const source = {
  name: 'Lumber',
  identifier: 'com.amardhillon.lumber.source',
  sourceURL: `https://github.com/${REPO}/releases/download/sidestore/apps.json`,
  iconURL,
  website: `https://github.com/${REPO}`,
  apps: [
    {
      name: 'Lumber',
      bundleIdentifier: app.ios.bundleIdentifier,
      developerName: 'Amar Dhillon',
      subtitle: 'Drum along to any song',
      localizedDescription:
        'Pick a song, record your drums over it, shape them with DSP presets or a prompt, remove the original drums on-device, and export audio or video.',
      iconURL,
      tintColor: '8b5cf6',
      versions,
      appPermissions: { entitlements: [], privacy },
    },
  ],
  news: [],
};

writeFileSync(outPath, JSON.stringify(source, null, 2) + '\n');
console.log(`wrote ${outPath}: ${versions.map((v) => v.buildVersion).join(', ')}`);
