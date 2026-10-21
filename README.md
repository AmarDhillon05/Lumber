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

GitHub Actions builds an unsigned `.ipa` on a macOS runner on every push to
`main` (or manually, choosing `debug` or `release`). Download the
`Lumber-unsigned-*` artifact from the **iOS build** workflow and sideload it with
a free Apple ID — Sideloadly on Windows, Impactor on Linux. Free signing lasts
7 days. Full steps: [docs/build-without-mac.md](docs/build-without-mac.md).

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
