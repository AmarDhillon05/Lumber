# Lumber

Drum along to any song on your iPhone. Pick a song, record your drums over it
with headphones, shape them with Timber's DSP or a preset, optionally strip the
song's original drums on-device, and export the mix.

Timber 2.0: the original idea behind [timber](https://github.com/AmarDhillon05/timber),
minus the servers. Everything runs on the phone.

> Status: early. The app builds on CI and the core pieces are tested under Node,
> but it hasn't been exercised on a real iPhone yet.

## Features

- **Songs** — import MP3/M4A/WAV/AAC/AIFF from Files, search YouTube in-app, or
  paste a YouTube or Spotify link (Spotify tracks are matched to a YouTube upload
  by title, artist and duration — no login needed).
- **Record** — the song and the mic share one audio engine and clock. Start
  point, loop region, count-in, headphone warnings, latency calibration and a
  millisecond nudge keep the take aligned.
- **Shape** — Timber's Blanket knobs (EQ, dynamics, room, harmonic) plus presets:
  Warm, Bright, Loud, Tight/Dry, Roomy/Vintage, Phone-mic rescue.
- **Remove original drums** — Demucs v4 (`htdemucs`) running through ONNX Runtime
  with the Core ML backend. A fader blends the original drums back in from 0–100%.
- **Export** — drums rendered through the chain, mixed with the song (or the
  drumless stem), peak-limited to −1 dBFS, written as WAV and shared via the
  iOS share sheet.

## How it works

```
Library ──► Record ──► Edit / Export
  │            │            │
  │            │            ├─ src/dsp          Timber DSP, presets, mixer, WAV
  │            └─ src/audio  engine, calibration, offsets, preview, export
  ├─ src/sources             Files import, YouTube client, pasted links
  └─ src/separation          Demucs pipeline, ONNX runner, stem cache
```

**Drum removal.** The ONNX graph excludes Demucs' STFT/iSTFT, so those, the 7.8 s
chunking with overlap-add, and the input normalization are reimplemented in
TypeScript (`src/separation/demucs.ts`). Under Node with the same model, the
output matches PyTorch Demucs at ~95 dB SNR. The ~171 MB model downloads on first
use; stems are streamed to WAV and cached per song.

**YouTube.** A small InnerTube client (`src/sources/youtubeCore.ts`) that needs
only `fetch` — no player JS, no polyfills. See [docs/youtube.md](docs/youtube.md)
for the client choice and how to update it when YouTube changes.

## Stack

Expo SDK 58 · React Native 0.88 (Hermes) · TypeScript ·
`react-native-audio-api` · `onnxruntime-react-native` (Core ML EP, patched for
RN 0.88 in `patches/`) · `expo-file-system` · zustand

## Install on an iPhone (no Mac needed)

### 1. Download the app

1. Open **[Actions → iOS build](https://github.com/AmarDhillon05/Lumber/actions/workflows/ios.yml)**
   and click the newest run with a green check.
2. Under **Artifacts**, download `Lumber-unsigned-Release-<n>` and unzip it to get
   `Lumber-unsigned.ipa`. (Artifacts expire after 14 days. To make a fresh one, click
   **Run workflow**, choose `release`, and wait ~20 min.)

### 2. Put it on the phone

Sign with a free Apple Account. Windows: **Sideloadly**. Linux: **Impactor**
(`flatpak install --user dev.khcrysalis.PlumeImpactor.flatpakref`).

1. Plug in the iPhone, unlock it, tap **Trust**. On Linux, run `idevicepair pair` first.
2. In the sideloading tool, sign in with your Apple Account, pick the `.ipa`, Install.
3. On the iPhone: **Settings → Privacy & Security → Developer Mode → On** (restarts),
   then **Settings → General → VPN & Device Management →** your Apple ID → **Trust**.
4. Open Lumber.

Free signing expires after **7 days**: reinstall the same way to keep using it.
Troubleshooting (No Device, login errors): [docs/build-without-mac.md](docs/build-without-mac.md).

### 3. Before going offline (e.g. a flight)

Lumber runs fully offline once these are on the phone. Do them on Wi-Fi first:

- [ ] **Get songs in.** Download a few from YouTube / pasted links, or import MP3/M4A files
      from the Files app (put them in Files beforehand). Searching and downloading need
      internet; playing them doesn't.
- [ ] **Download the drum-removal model.** Tap **Remove original drums** on one song —
      the first run downloads ~171 MB. After that, separating more songs works offline.
- [ ] **Bring wired headphones** (or calibrate your Bluetooth ones — they add delay).
- [ ] If the app is near its 7-day expiry, reinstall it before you leave.

### 4. What to test

1. **Songs:** imported and downloaded songs show up in the Library and play.
2. **Calibrate** (headphones unplugged, quiet room): gives a latency number, about the
   same if you run it twice.
3. **Record** 20–30 s with headphones in: does the take line up with zero nudge? If not,
   note how many ms fixed it.
4. **Edit:** presets and knobs audibly change the drums; preview keeps up; **Export WAV**
   sounds like the preview.
5. **Remove original drums** on a full song: how long it took, whether it crashed, and how
   clean `original drums = 0` sounds.

Note your iPhone model, the calibration number, any nudge you needed, and the separation
time. For crashes, write down the step and what you tapped.

## Develop

```bash
npm install          # also applies patches/ via patch-package
npm run typecheck    # app + Node tests/scripts
npm test             # DSP, timing, separation, sources and link tests
```

With the debug build installed on the phone, `npx expo start --dev-client` on
your computer pushes JS changes over the LAN; only native changes need a new CI
build.

**Hear the drum removal on a desktop** — same code, `onnxruntime-node` instead of
Core ML (needs ffmpeg for non-WAV input):

```bash
npm run separate -- path/to/song.mp3      # → separated/<song>/drums.wav, no_drums.wav
```

## Credits

- DSP ported from [timber](https://github.com/AmarDhillon05/timber).
- [Demucs](https://github.com/facebookresearch/demucs) by Meta AI (code MIT; the
  `htdemucs` weights are CC-BY-NC 4.0, so non-commercial use only). ONNX export:
  [sathvik77/htdemucs-core-onnx](https://huggingface.co/sathvik77/htdemucs-core-onnx).

Personal, local tool — not distributed.
