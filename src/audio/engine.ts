// The play + record engine. One AudioContext plays the song (and count-in
// clicks); the AudioRecorder captures the mic on the same native AVAudioEngine.
//
// Sync strategy (react-native-audio-api 0.13 has no "recorder start time in
// context time" API):
//   1. Start the recorder first and wait until frames are actually flowing.
//   2. While recording, sample (ctx.currentTime, recorder.getCurrentDuration())
//      pairs every ~25 ms. Both clocks are driven by the same audio I/O cycle,
//      so ctxTime - recSec is constant up to buffer jitter; its median is the
//      ctx time of the recording's first sample (recStartCtx).
//   3. Schedule count-in + song at a known ctx time well in the future.
//   4. drumOffsetSec = songStartSec + (recStartCtx - songCtxStart) - latency.
// Calibration uses this exact path, so any constant bias in step 2 is folded
// into the measured latency.

import {
  AudioContext,
  AudioManager,
  AudioRecorder,
  FileDirectory,
  FileFormat,
  FilePreset,
  decodeAudioData,
} from 'react-native-audio-api';
import type { AudioBuffer, AudioBufferSourceNode, GainNode } from 'react-native-audio-api';
import { File } from 'expo-file-system';
import { ACCENT_CLICK, BEAT_CLICK, makeClick } from './click';
import {
  type ClockSample,
  computeDrumOffset,
  estimateRecorderStartCtx,
  scheduleCountIn,
  transportPosition,
} from './offsets';
import { toMono } from './peaks';
import type { Take } from '../state/types';

export const ENGINE_SAMPLE_RATE = 48000;
const LEAD_SEC = 0.35; // scheduling headroom after "now"
const CLOCK_POLL_MS = 25;
const FLOW_TIMEOUT_MS = 3000;

export interface TransportOptions {
  songId: string;
  songUri: string;
  startSec: number;
  loop?: { start: number; end: number } | null;
  countIn?: { bpm: number; beats: number } | null;
  record: boolean;
  latencyMs: number; // compensated into the take's drumOffsetSec
}

export interface RouteInfo {
  key: string; // stable per output route, used for the latency table
  name: string;
  isHeadphones: boolean;
  isBluetooth: boolean;
}

const HEADPHONE_PORTS = ['Headphones', 'BluetoothA2DPOutput', 'BluetoothHFP', 'BluetoothLE', 'USBAudio', 'LineOut'];

const toUri = (p: string) => (p.startsWith('file://') ? p : `file://${p}`);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class Engine {
  private ctx: AudioContext | null = null;
  private sessionReady = false;
  private songCache: { uri: string; buffer: AudioBuffer } | null = null;
  private clickBuffers: { accent: AudioBuffer; beat: AudioBuffer } | null = null;

  private sources: AudioBufferSourceNode[] = [];
  private songGain: GainNode | null = null;
  private recorder: AudioRecorder | null = null;
  private clockSamples: ClockSample[] = [];
  private clockTimer: ReturnType<typeof setInterval> | null = null;
  private autoStopTimer: ReturnType<typeof setTimeout> | null = null;
  private transport: (TransportOptions & { songCtxStart: number; endCtx: number }) | null = null;

  /** Called when a transport reaches its end (song end, or loop end while recording). */
  onAutoStop: (() => void) | null = null;

  async ensureReady(): Promise<AudioContext> {
    if (!this.sessionReady) {
      // playAndRecord so the mic and playback run together; defaultToSpeaker
      // keeps output off the earpiece when no headphones are connected;
      // A2DP allows Bluetooth headphones for output (mic stays built-in).
      // 'measurement' mode turns off the input AGC/voice processing that
      // would squash drum transients.
      AudioManager.setAudioSessionOptions({
        iosCategory: 'playAndRecord',
        iosMode: 'measurement',
        iosOptions: ['defaultToSpeaker', 'allowBluetoothA2DP'],
      });
      await AudioManager.setAudioSessionActivity(true);
      this.sessionReady = true;
    }
    if (!this.ctx || this.ctx.state === 'closed') {
      this.ctx = new AudioContext({ sampleRate: ENGINE_SAMPLE_RATE });
      this.clickBuffers = null;
    }
    if (this.ctx.state === 'suspended') await this.ctx.resume();
    return this.ctx;
  }

  get context(): AudioContext | null {
    return this.ctx;
  }

  async requestMic(): Promise<boolean> {
    const status = await AudioManager.requestRecordingPermissions();
    return status === 'Granted';
  }

  async currentRoute(): Promise<RouteInfo> {
    try {
      const info = await AudioManager.getDevicesInfo();
      const out = info.currentOutputs[0];
      if (!out) return { key: 'Speaker', name: 'Speaker', isHeadphones: false, isBluetooth: false };
      return {
        key: out.category === 'Speaker' ? 'Speaker' : `${out.category}:${out.name}`,
        name: out.name,
        isHeadphones: HEADPHONE_PORTS.includes(out.category),
        isBluetooth: out.category.startsWith('Bluetooth'),
      };
    } catch {
      return { key: 'unknown', name: 'Unknown output', isHeadphones: false, isBluetooth: false };
    }
  }

  async loadSong(uri: string): Promise<AudioBuffer> {
    if (this.songCache?.uri === uri) return this.songCache.buffer;
    await this.ensureReady();
    const buffer = await decodeAudioData(uri, ENGINE_SAMPLE_RATE);
    this.songCache = { uri, buffer };
    return buffer;
  }

  get isRunning(): boolean {
    return this.transport !== null;
  }

  get isRecording(): boolean {
    return this.recorder !== null;
  }

  /** Current song position (seconds), or null when stopped. Negative-free; during count-in returns the start. */
  position(): number | null {
    if (!this.transport || !this.ctx) return null;
    return transportPosition(
      this.ctx.currentTime,
      this.transport.songCtxStart,
      this.transport.startSec,
      this.transport.record ? null : this.transport.loop,
    );
  }

  /** Seconds until the song starts (count-in remaining), 0 once playing. */
  countInRemaining(): number {
    if (!this.transport || !this.ctx) return 0;
    return Math.max(0, this.transport.songCtxStart - this.ctx.currentTime);
  }

  async start(opts: TransportOptions): Promise<void> {
    if (this.transport) await this.stop();
    const ctx = await this.ensureReady();
    const song = await this.loadSong(opts.songUri);

    if (opts.record) await this.startRecorder();

    const beats = opts.countIn ? opts.countIn.beats : 0;
    const sched = scheduleCountIn(ctx.currentTime, LEAD_SEC, opts.countIn?.bpm ?? 120, beats);
    this.scheduleClicks(ctx, sched.clickTimes);

    const loop = opts.loop && opts.loop.end > opts.loop.start ? opts.loop : null;
    const startSec = Math.max(0, Math.min(opts.startSec, song.duration - 0.05));
    const src = ctx.createBufferSource();
    src.buffer = song;
    const gain = ctx.createGain();
    src.connect(gain);
    gain.connect(ctx.destination);
    this.songGain = gain;
    if (loop && !opts.record) {
      src.loop = true;
      src.loopStart = loop.start;
      src.loopEnd = Math.min(loop.end, song.duration);
    }
    src.start(sched.songCtxStart, startSec);
    this.sources.push(src);

    // When recording with a loop region, record one pass and stop at loop end.
    const endSongSec = loop && opts.record ? Math.min(loop.end, song.duration) : song.duration;
    const endCtx = loop && !opts.record ? Infinity : sched.songCtxStart + (endSongSec - startSec);
    this.transport = { ...opts, startSec, loop, songCtxStart: sched.songCtxStart, endCtx };
    if (Number.isFinite(endCtx)) {
      const ms = (endCtx - ctx.currentTime) * 1000 + 50;
      this.autoStopTimer = setTimeout(() => this.onAutoStop?.(), ms);
    }
  }

  /** Stops playback; when recording, finalizes and returns the take. */
  async stop(): Promise<Take | null> {
    if (this.autoStopTimer) clearTimeout(this.autoStopTimer);
    this.autoStopTimer = null;
    for (const s of this.sources) {
      try {
        s.stop();
      } catch {
        // already ended
      }
    }
    this.sources = [];
    this.songGain?.disconnect();
    this.songGain = null;
    const t = this.transport;
    this.transport = null;
    if (!this.recorder || !t) {
      await this.stopRecorder();
      return null;
    }
    const rec = await this.stopRecorder();
    if (!rec) return null;
    const latencySec = t.latencyMs / 1000;
    return {
      id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
      songId: t.songId,
      drumsUri: rec.uri,
      songStartSec: t.startSec,
      drumOffsetSec: computeDrumOffset({
        songStartSec: t.startSec,
        songCtxStart: t.songCtxStart,
        recStartCtx: rec.recStartCtx,
        latencySec,
      }),
      latencyMs: t.latencyMs,
      sampleRate: ENGINE_SAMPLE_RATE,
      createdAt: Date.now(),
    };
  }

  /**
   * Calibration: play `count` clicks `intervalSec` apart through the current
   * output while recording, and return the mono recording plus where each
   * click would sit in it with zero latency.
   */
  async recordClickTrain(count: number, intervalSec: number) {
    if (this.transport) await this.stop();
    const ctx = await this.ensureReady();
    const route = await this.currentRoute();
    await this.startRecorder();
    const t0 = ctx.currentTime + LEAD_SEC;
    const times = Array.from({ length: count }, (_, i) => t0 + i * intervalSec);
    this.scheduleClicks(ctx, times, false);
    const waitMs = (times[times.length - 1] - ctx.currentTime + 0.8) * 1000;
    await sleep(waitMs);
    const rec = await this.stopRecorder();
    if (!rec) throw new Error('Calibration recording failed');
    const buf = await decodeAudioData(rec.uri, ENGINE_SAMPLE_RATE);
    const channels = Array.from({ length: buf.numberOfChannels }, (_, c) => buf.getChannelData(c).slice());
    try {
      new File(rec.uri).delete();
    } catch {
      // ignore
    }
    return {
      samples: toMono(channels),
      sampleRate: buf.sampleRate,
      clickFileTimes: times.map((t) => t - rec.recStartCtx),
      routeKey: route.key,
    };
  }

  // --- internals ---

  private ensureClicks(ctx: AudioContext) {
    if (this.clickBuffers) return this.clickBuffers;
    const mk = (data: Float32Array) => {
      const b = ctx.createBuffer(1, data.length, ctx.sampleRate);
      b.copyToChannel(data as Float32Array<ArrayBuffer>, 0);
      return b;
    };
    this.clickBuffers = {
      accent: mk(makeClick(ctx.sampleRate, ACCENT_CLICK)),
      beat: mk(makeClick(ctx.sampleRate, BEAT_CLICK)),
    };
    return this.clickBuffers;
  }

  private scheduleClicks(ctx: AudioContext, times: number[], accentFirst = true) {
    const { accent, beat } = this.ensureClicks(ctx);
    times.forEach((t, i) => {
      const s = ctx.createBufferSource();
      s.buffer = accentFirst && i === 0 ? accent : beat;
      s.connect(ctx.destination);
      s.start(t);
      this.sources.push(s);
    });
  }

  private async startRecorder() {
    if (!(await this.requestMic())) throw new Error('Microphone permission denied');
    const rec = new AudioRecorder();
    const cfg = rec.enableFileOutput({
      format: FileFormat.Wav,
      preset: FilePreset.High, // 48 kHz / 24-bit
      channelCount: 1,
      directory: FileDirectory.Document,
      subDirectory: 'lumber/takes',
      fileNamePrefix: 'take',
    });
    if (cfg.status !== 'success') throw new Error(`Recorder setup failed: ${cfg.message}`);
    const started = await rec.start();
    if (started.status !== 'success') throw new Error(`Recorder failed to start: ${started.message}`);
    this.recorder = rec;

    // Wait for audio to actually flow before trusting the clocks.
    const t0 = Date.now();
    while (rec.getCurrentDuration() <= 0) {
      if (Date.now() - t0 > FLOW_TIMEOUT_MS) {
        await this.stopRecorder();
        throw new Error('Microphone produced no audio');
      }
      await sleep(5);
    }
    this.clockSamples = [];
    const sample = () => {
      if (!this.ctx || !this.recorder) return;
      this.clockSamples.push({ ctxTime: this.ctx.currentTime, recSec: this.recorder.getCurrentDuration() });
      if (this.clockSamples.length > 4000) this.clockSamples.splice(0, 2000);
    };
    sample();
    this.clockTimer = setInterval(sample, CLOCK_POLL_MS);
  }

  private async stopRecorder(): Promise<{ uri: string; recStartCtx: number } | null> {
    if (this.clockTimer) clearInterval(this.clockTimer);
    this.clockTimer = null;
    const rec = this.recorder;
    this.recorder = null;
    if (!rec) return null;
    const recStartCtx = estimateRecorderStartCtx(this.clockSamples);
    const res = await rec.stop();
    if (res.status !== 'success' || !res.paths.length) throw new Error('Recorder failed to stop');
    if (recStartCtx === null) throw new Error('Could not align recording to playback');
    return { uri: toUri(res.paths[0]), recStartCtx };
  }
}

export const engine = new Engine();
