# Lumber

Drum along to any song on your iPhone. Pick a song, record your drums over it
with headphones, shape them with Timber's DSP or a preset, optionally strip the
song's original drums on-device, and export the mix.

Timber 2.0: the original idea behind [timber](https://github.com/AmarDhillon05/timber),
minus the servers. Everything runs on the phone.

> Status: early. The app builds on CI and the core pieces are tested under Node,
> but it hasn't been exercised on a real iPhone yet.

## Features

- **Songs** — import MP3/M4A/WAV/AAC/AIFF from Files, search YouTube in-app, paste a
  YouTube or Spotify link, or connect Spotify to grab what's playing right now, your
  liked songs, or your own playlists. Spotify audio is DRM'd, so every Spotify track is
  matched to a YouTube upload by title, artist and duration.
- **Record** — the song and the mic share one audio engine and clock. Start
  point, loop region, count-in, headphone warnings, latency calibration and a
  millisecond nudge keep the take aligned.
- **Shape** — Timber's Blanket knobs (EQ, dynamics, room, harmonic) plus presets:
  Warm, Bright, Loud, Tight/Dry, Roomy/Vintage, Phone-mic rescue.
- **Describe the sound** — type what you want ("punchy and dry like a 90s rock record",
  "less boomy, more room") and the knobs move. The app first measures the take and the
  song under it (loudness, crest, band balance, brightness, hit density, decay, stereo
  width, noise floor), then asks Claude (`claude-opus-5-5`, or Haiku 5.5 if you pick it)
  to set the knobs and faders and explain why. Claude needs **your own Anthropic API key**
  (pasted in the box's ⚙ settings, kept in the iOS keychain) and **internet**. With no key
  or no connection, an offline interpreter maps common sound words to knob moves instead,
  and the result is labelled *Offline*. **Undo** steps back.
- **Remove original drums** — Demucs v4 (`htdemucs`) running through ONNX Runtime,
  Core ML first. A fader blends the original drums back in from 0–100%. If a run ever
  crashes the app, the next run automatically steps down to CPU, then to a slow
  single-thread mode, and tells you where the last one died.
- **Export** — drums rendered through the chain, mixed with the song (or the
  drumless stem), peak-limited to −1 dBFS and written as WAV. **Export M4A**
  writes the same mix as AAC. Every export is saved to **Recordings** first; a
  *Saved to Recordings* note then offers **Share** (the iOS share sheet), so
  cancelling the share sheet loses nothing.
- **Video** — flip on **Camera** on the Record screen to film yourself (front or
  back camera) while the take records. The camera records muted — the mic stays
  with the audio engine — and the clip is placed on the song timeline from clock
  samples taken during the take (`src/video/sync.ts`), with a per-project
  **Video offset** nudge in Edit. Edit previews the clip alongside the audio;
  **Export video** renders the same mix as Export WAV and muxes it onto the clip
  with AVFoundation (`modules/lumber-media`, H.264/HEVC `.mp4`, orientation
  kept). The output is trimmed to where the clip and the song overlap.
- **Recordings** — the **Recordings** card at the top of the Library lists
  everything you've saved, newest first, with total storage used. Exports
  (video, WAV, M4A) land here, and **Save raw take** in Edit copies the take as
  recorded (drum WAV, plus the camera clip if you filmed). Tap a row to play it
  in the app (videos with the native controls, audio with play/pause and a
  scrubber); each one has **Share**, **Save to Photos** (videos), **Rename** and
  **Delete**. Files live in `documents/lumber/recordings` (visible in the Files
  app under Lumber); deleting a song or take doesn't delete its recordings.

## How it works

```
Library ──► Record ──► Edit / Export ──► Recordings
  │            │            │                  └─ src/recordings  saved files, thumbnails, player
  │            │            ├─ src/dsp          Timber DSP, presets, mixer, WAV
  │            │            ├─ src/ai           analysis, Claude prompt mix, offline interpreter
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
RN 0.88 in `patches/`) · `expo-file-system` · `expo-video` · `expo-media-library` · zustand

## Install on an iPhone (no Mac needed)

### 1. Download the app

1. Open **[Actions → iOS build](https://github.com/AmarDhillon05/Lumber/actions/workflows/ios.yml)**
   and click the newest run with a green check.
2. Under **Artifacts**, download `Lumber-unsigned-Release-<n>` and unzip it to get
   `Lumber-unsigned.ipa`. (Artifacts expire after 14 days. To make a fresh one, click
   **Run workflow**, choose `release`, and wait ~20 min.)

### Install and update from the phone (SideStore)

Every build on `main` is also published for phone-only installs:

- **Direct download:** each build is a release, `build-<n>`, with `Lumber-<n>.ipa` attached
  ([releases](https://github.com/AmarDhillon05/Lumber/releases)). The 5 newest are kept.
- **SideStore source:** `https://github.com/AmarDhillon05/Lumber/releases/download/sidestore/apps.json`

One-time setup (needs the computer once): install [SideStore](https://sidestore.io) with
your Apple Account and set up its pairing file as SideStore's guide describes. Then, on the
phone, open SideStore → **Sources** → **+** and paste the source URL above. Lumber shows up
there; tap **Get**. New builds appear as updates in SideStore, and SideStore re-signs
installed apps over Wi-Fi before the 7 days run out, so the computer isn't needed again.
Without SideStore, iOS can't install an unsigned app from the phone alone.

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
- [ ] **Spotify:** connecting, "Now playing", Liked and Playlists all need internet —
      grab the songs you want before you lose signal.
- [ ] **Bring wired headphones** (or calibrate your Bluetooth ones — they add delay).
- [ ] **Describe the sound** works offline with the built-in interpreter; the Claude
      version needs internet (and your API key), so it won't work on the plane.
- [ ] If the app is near its 7-day expiry, reinstall it before you leave.

### 4. What to test

1. **Songs:** imported and downloaded songs show up in the Library and play.
2. **Calibrate** (headphones unplugged, quiet room): gives a latency number, about the
   same if you run it twice.
3. **Record** 20–30 s with headphones in: does the take line up with zero nudge? If not,
   note how many ms fixed it.
4. **Edit:** presets and knobs audibly change the drums; preview keeps up; **Export WAV**
   sounds like the preview.
5. **Spotify** (online): **Connect Spotify**, log in, then play a song in the Spotify app,
   come back and tap **Now playing** — the right match should be first. Also try Liked and
   one of your own playlists.
6. **Describe the sound** (Edit screen): with no key, try "less boomy, more room" and
   "a bit warmer" — knobs move, the box says *Offline interpreter*, Undo restores them. Then
   paste an Anthropic API key (⚙), try "punchy and dry like a 90s rock record": note how
   long Claude takes, whether the explanation makes sense and whether the preview changes.
   Try it in airplane mode (should fall back to offline with a "No connection" note) and with
   a wrong key (should say the key was rejected).
7. **Video:** turn on **Camera**, record 20–30 s with a few clear hits (or a stick
   click on the count-in). In Edit the preview should roughly follow the audio;
   tap **Export video** and check in Photos that hits line up with the sound. If
   not, note the **Video offset** (ms) that fixed it, and whether front/back
   differ. Also check portrait orientation and that the audio session still works
   (song + mic) after filming.
8. **Recordings:** do Export WAV, Export M4A and (with a filmed take) Export video. Each
   should show *Saved to Recordings* without opening the share sheet; **Share** from that
   note opens it, and cancelling it keeps the file. Open **Recordings** from the Library:
   newest first, the video row has a thumbnail, sizes add up to the total at the top. Play
   a video (native controls) and an audio file (play/pause, scrub) — check they play out
   of the speaker, and that recording a new take afterwards still works. Try **Save to
   Photos** (allow, then check Photos; also try after denying in Settings — it should
   explain how to allow it), **Rename** (survives an app restart) and **Delete**. Also try
   **Save raw take** in Edit, and check old recordings are still listed after reinstalling
   a new build over the old one.
9. **Remove original drums** on a full song: how long it took, whether it crashed, and how
   clean `original drums = 0` sounds.

Note your iPhone model, the calibration number, any nudge you needed (audio and video), and
the separation time. For crashes, write down the step and what you tapped.

### Spotify setup

Spotify login uses PKCE with the Client ID in `src/sources/spotify.ts` (public by
design; there is no secret). The Spotify account that owns that app needs **Premium**,
and anyone logging in must be listed under the app's **User Management** at
[developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), with
`lumber://spotify-callback` as a redirect URI.

## Develop

```bash
npm install          # also applies patches/ via patch-package
npm run typecheck    # app + Node tests/scripts
npm test             # DSP, timing, separation, sources, link and recordings tests
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
  [sathvik77/htdemucs-core-onnx](https://huggingface.co/sathvik77/htdemucs-core-onnx); the
  app downloads a copy with attention computed in row slices (same output, much lower
  peak memory) that `.github/workflows/model.yml` builds and attaches to the
  `models-v1` release.

Personal, local tool — not distributed.
