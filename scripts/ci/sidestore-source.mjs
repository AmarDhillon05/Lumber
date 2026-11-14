// Builds the SideStore / AltStore source (apps.json) that lists Lumber builds,
// so new CI builds show up as updates in SideStore on the phone. The source
// holds several apps (the RN "Lumber" and "Lumber (native)"); each run updates
// only its own entry, matched by bundleIdentifier, and keeps the others.
//
//   node scripts/ci/sidestore-source.mjs <previous.json|-> <out.json> \
//        <buildNumber> <downloadURL> <ipaSize> [commitMessage] [--flag=value ...]
//
// Without flags the app comes from app.json (the RN app). Flags for other apps:
//   --bundle-id=com.example.app   bundleIdentifier (required with --info-json)
//   --name="App name"             display name in SideStore
//   --info-json=Info.json         the built app's Info.plist as JSON
//                                 (plutil -convert json); gives the version
//                                 and the *UsageDescription strings
//   --version=1.2.3               overrides the version
//   --subtitle=... --description=... --min-os=17.0
//
// Keeps the newest KEEP versions per app; the matching release assets are
// pruned by the workflow.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';

const KEEP = 5;
const REPO = 'AmarDhillon05/Lumber';

const flags = {};
const positional = [];
for (const arg of process.argv.slice(2)) {
  const m = /^--([a-z-]+)=(.*)$/s.exec(arg);
  if (m) flags[m[1]] = m[2];
  else positional.push(arg);
}
const [prevPath, outPath, build, downloadURL, size, message = ''] = positional;
if (!outPath || !build || !downloadURL || !size) {
  console.error(
    'usage: sidestore-source.mjs <previous.json|-> <out.json> <build> <downloadURL> <size> [message] [--bundle-id=… --name=… --info-json=…]',
  );
  process.exit(2);
}

const iconURL = `https://raw.githubusercontent.com/${REPO}/main/assets/icon.png`;
const DEFAULT_DESCRIPTION =
  'Pick a song, record your drums over it, shape them with DSP presets or a prompt, remove the original drums on-device, and export audio or video.';

// Usage strings shown by SideStore before install.
const BASE_PRIVACY = {
  NSMicrophoneUsageDescription: 'Lumber records your drums while the song plays.',
  NSCameraUsageDescription: 'Lumber films you drumming while you record a take.',
  NSPhotoLibraryAddUsageDescription: 'Lumber saves your exported videos to Photos.',
};
const usageStrings = (dict) => Object.fromEntries(Object.entries(dict ?? {}).filter(([k]) => k.endsWith('UsageDescription')));

function appMeta() {
  if (flags['info-json']) {
    const info = JSON.parse(readFileSync(flags['info-json'], 'utf8'));
    const bundleIdentifier = flags['bundle-id'] || info.CFBundleIdentifier;
    if (!bundleIdentifier) throw new Error('--bundle-id is required');
    return {
      name: flags.name || info.CFBundleDisplayName || info.CFBundleName || bundleIdentifier,
      bundleIdentifier,
      version: flags.version || info.CFBundleShortVersionString || '1.0.0',
      minOSVersion: flags['min-os'] || info.MinimumOSVersion || '17.0',
      subtitle: flags.subtitle || 'Drum along to any song',
      localizedDescription: flags.description || DEFAULT_DESCRIPTION,
      privacy: { ...BASE_PRIVACY, ...usageStrings(info) },
    };
  }
  // The RN app, described by app.json (config plugins add the base strings).
  const app = JSON.parse(readFileSync('app.json', 'utf8')).expo;
  return {
    name: flags.name || 'Lumber',
    bundleIdentifier: flags['bundle-id'] || app.ios.bundleIdentifier,
    version: flags.version || app.version,
    minOSVersion: flags['min-os'] || '16.4',
    subtitle: flags.subtitle || 'Drum along to any song',
    localizedDescription: flags.description || DEFAULT_DESCRIPTION,
    privacy: { ...BASE_PRIVACY, ...usageStrings(app.ios?.infoPlist) },
  };
}

const meta = appMeta();
const previous = prevPath !== '-' && existsSync(prevPath) ? JSON.parse(readFileSync(prevPath, 'utf8')) : null;
const previousApps = Array.isArray(previous?.apps) ? previous.apps : [];
const existing = previousApps.find((a) => a?.bundleIdentifier === meta.bundleIdentifier);
const oldVersions = Array.isArray(existing?.versions) ? existing.versions : [];

const version = {
  version: meta.version,
  buildVersion: String(build),
  date: new Date().toISOString(),
  localizedDescription: `Build ${build}: ${message.split('\n')[0]}`.trim(),
  downloadURL,
  size: Number(size),
  minOSVersion: meta.minOSVersion,
};

const versions = [version, ...oldVersions.filter((v) => v.buildVersion !== version.buildVersion)].slice(0, KEEP);

const entry = {
  name: meta.name,
  bundleIdentifier: meta.bundleIdentifier,
  developerName: 'Amar Dhillon',
  subtitle: meta.subtitle,
  localizedDescription: meta.localizedDescription,
  iconURL,
  tintColor: '8b5cf6',
  versions,
  appPermissions: { entitlements: [], privacy: meta.privacy },
};

// Replace this app in place (keeps the order); append it when new.
const apps = existing
  ? previousApps.map((a) => (a?.bundleIdentifier === meta.bundleIdentifier ? entry : a))
  : [...previousApps, entry];

const source = {
  name: 'Lumber',
  identifier: 'com.amardhillon.lumber.source',
  sourceURL: `https://github.com/${REPO}/releases/download/sidestore/apps.json`,
  iconURL,
  website: `https://github.com/${REPO}`,
  apps,
  news: Array.isArray(previous?.news) ? previous.news : [],
};

writeFileSync(outPath, JSON.stringify(source, null, 2) + '\n');
console.log(
  `wrote ${outPath}: ${apps.map((a) => `${a.bundleIdentifier} [${(a.versions ?? []).map((v) => v.buildVersion).join(', ')}]`).join('; ')}`,
);
