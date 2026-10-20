# Lumber — plan

Timber 2.0, back to the original idea: pick any song on your iPhone, drum along
to it, make the drums sound right, export the mix. Everything runs on the phone
— no server.

## Constraints that shape the design

- **The app owns playback.** Spotify/Apple Music audio is DRM'd and iOS won't let
  one app capture another's output, so every song becomes a local file the app
  plays itself. Upside: playback and the mic share one audio clock, so the song
  position during a take is known to the sample.
- **iPhone only, no server.** Song fetching, DSP and drum separation all run
  on-device. Drum separation uses Core ML.
- **Headphones while recording**, otherwise the song bleeds into the drum mic.

## Stack

| Layer | Choice | Why |
|---|---|---|
| App | Expo (dev client) + TypeScript, iOS only | Same stack as Timber; reuses its DSP and UI pieces. |
| Audio | `react-native-audio-api` | Plays the song and records the mic on one `AudioContext`; Timber's DSP already runs on it. |
| DSP | Timber `mobile/src/dsp` copied as-is (+ its `__dsptest__` tests) | Blanket knobs, offline render, preview. |
| Drum removal | Local Expo Module in Swift wrapping Core ML HTDemucs | Core ML can't be reached from JS; one small native module is the only native code. |
| YouTube | In-app InnerTube client (`youtubei.js`, fallback `ytdl-native`) | No yt-dlp without a server; spike first, Files import is the fallback. |
| Spotify | Web API search → YouTube match (later, once credentials exist) | Search/metadata only. |

Considered: a full SwiftUI app (AVAudioEngine + Core ML). Tighter audio and no
JS bridge, but it throws away Timber's tested TypeScript DSP and needs a port to
Swift. Expo + one Swift module keeps the DSP and limits native code to the
model. Revisit only if recording sync on `react-native-audio-api` proves
unreliable in the Phase 2 prototype.

Building needs a Mac with Xcode (`npx expo run:ios --device`).

## Is Core ML drum removal possible? Yes.

- HTDemucs has already been converted to Core ML (MIT, from
  facebookresearch/demucs): `schism-audio/htdemucs-coreml` (fp16 for the Neural
  Engine, fp32 fallback), plus a fine-tuned bag and a 6-stem variant. An
  independent FP32 CPU-only conversion also exists (`mlboydaisuke/HTDemucs-CoreML`,
  iOS 17+, ~1 GB peak RAM).
- The Core ML graph covers the network only. STFT/iSTFT, segmenting (~7.8 s
  chunks with overlap-add) and stem summing run on the host — in Swift with
  Accelerate/vDSP. The same publisher ships a Swift frontend tested against
  reference vectors, so we port/adapt that rather than write it from scratch.
- Use plain 4-stem `htdemucs` fp16: `no_drums = bass + other + vocals`. The
  fine-tuned bag is ~4× the compute — try it only if quality falls short.
- Model is downloaded on first use (not bundled) and cached in app storage.
  `.mlpackage` must be copied as real files (the HF cache uses symlinks, which
  the Core ML compiler rejects), then compiled on device once.
- Published speed/memory numbers are from Macs, not iPhones — Phase 5 starts by
  measuring on your phone. Separation runs once per song and is cached.

## Phases

### 0 — Scaffold
Expo app (iOS, dev client), zustand, `react-native-audio-api`; copy Timber's
`dsp/`, `BlanketKnob`, `wav.ts`, preview hook; DSP tests in CI.

### 1 — Songs
- **YouTube (spike):** search + fetch an audio-only stream in-app with
  `youtubei.js` (InnerTube; needs its signature deciphering to work on Hermes).
  Download to app storage, decode to 48 kHz. If it can't be made reliable, drop
  it and move on.
- **Files:** import MP3/M4A/WAV via the document picker (always available; also
  the fallback for YouTube).
- **Spotify (when credentials arrive):** Web API search → match on YouTube by
  "artist – title" + duration ±3 s, show top 3 candidates to correct.

### 2 — Play + record (riskiest; prototype first)
- One `AudioContext`: schedule song start at a known context time, start the
  mic recorder, log its start time → exact offset. Audio session play-and-record.
- Latency calibration: clicks out of the speaker, recorded by the mic,
  cross-correlated → round-trip latency per output route (Bluetooth separate,
  ~150–250 ms). Manual ms nudge on top.
- Transport: start anywhere, loop region, count-in, punch-in retakes.
- Take = drums WAV + `{ songId, songStartSec, recordStartCtxTime, latencyMs }`.

### 3 — Merge + DSP
- Two-lane editor (song / drums), waveforms, drag/nudge alignment; auto-align by
  cross-correlating drum onsets with the separated drum stem (after Phase 5).
- Faders: song, drums, "original drums" (0–100 %, after Phase 5).
- Full Blanket knob set on the drum track with live preview.
- **Presets** (replace Timber's AI suggest). A preset is a `BlanketValues` map;
  pick one, then tweak. Starting points, tuned by ear:

| Preset | Main moves |
|---|---|
| Warm | warmth .5, fullness .4, brightness −.4, harshness .5, dynamic_range .3, depth .2 |
| Bright / Harsh | attack .8, presence .6, air .6, brightness .5, punch .4 |
| Loud | punch .8, dynamic_range .8, kick_presence .6, warmth .3, naturalness 1 |
| Tight / Dry | sustain .6, roominess .6, boxiness .5, punch .5, high_pass_rumble .5 |
| Roomy / Vintage | depth .6, warmth .6, brightness −.3, detail .5 |
| Phone-mic rescue | high_pass_rumble 1, denoise .5, boxiness .6, resonance .5, naturalness 1 |

  User presets can be saved.

### 4 — Export
Offline render: drum chain → place at offset → mix with song (or no-drums stem)
→ brick-wall limiter → WAV / M4A → iOS share sheet. Projects saved locally and
reopenable.

### 5 — Drum removal (Core ML)
- Expo Module `modules/lumber-separator` (Swift): load compiled model, vDSP
  STFT, chunked inference with overlap-add, iSTFT, write `drums.wav` +
  `no_drums.wav`; progress events to JS.
- Measure time/memory on device (fp16 Neural Engine vs CPU fallback); listen at
  0 % original drums on 5 songs you actually play to.
- Wire the "original drums" slider and auto-align to the stems.

## Order
0 → 1 (YouTube spike + Files) → **2** → 3 → 4 gives the full loop; then 5;
Spotify when credentials exist.

## Risks
- Recording sync on iOS — the throwaway play-and-record prototype comes before UI.
- YouTube extraction breaks when YouTube changes; Files import always works.
- Core ML port numerics/memory on older iPhones — fp32 CPU fallback, shorter chunks.

## References
- https://huggingface.co/schism-audio/htdemucs-coreml
- https://huggingface.co/schism-audio/htdemucs-ft-coreml
- https://huggingface.co/mlboydaisuke/HTDemucs-CoreML
- https://github.com/facebookresearch/demucs
- https://github.com/AmarDhillon05/timber (DSP source)
