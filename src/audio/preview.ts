// Editor preview, modeled on Timber's usePreview but simpler: instead of
// pre-mixing, play the backing and the processed drums as separate buffer
// sources through gain nodes, so faders are instant and only knob changes
// need an offline re-render (of the drums alone). Alignment changes just
// restart the sources at the current playhead.

import type { AudioBuffer, AudioBufferSourceNode, AudioContext, GainNode } from 'react-native-audio-api';
import type { Channels } from '../dsp/types';
import { engine } from './engine';
import { drumStartFor } from './offsets';

export interface PreviewLevels {
  songGain: number;
  drumGain: number;
  originalDrums: number; // 0..1 (only with stems)
}

export class Preview {
  private ctx: AudioContext | null = null;
  private bed: AudioBuffer | null = null; // song, or no-drums stem
  private orig: AudioBuffer | null = null; // separated original drums
  private drums: AudioBuffer | null = null; // processed take
  private nodes: { bed: GainNode; orig: GainNode; drums: GainNode } | null = null;
  private sources: AudioBufferSourceNode[] = [];
  private startCtx = 0;
  private startSong = 0;
  private playing = false;
  private offsetSec = 0;
  private levels: PreviewLevels = { songGain: 1, drumGain: 1, originalDrums: 0 };

  async init(bed: Channels, orig: Channels | null, drums: Channels, sampleRate: number) {
    const ctx = await engine.ensureReady();
    this.ctx = ctx;
    this.bed = toBuffer(ctx, bed, sampleRate);
    this.orig = orig ? toBuffer(ctx, orig, sampleRate) : null;
    this.drums = toBuffer(ctx, drums, sampleRate);
    const mk = () => {
      const g = ctx.createGain();
      g.connect(ctx.destination);
      return g;
    };
    this.nodes = { bed: mk(), orig: mk(), drums: mk() };
    this.applyLevels();
  }

  get duration(): number {
    return this.bed?.duration ?? 0;
  }

  get isPlaying(): boolean {
    return this.playing;
  }

  position(): number {
    if (!this.playing || !this.ctx) return this.startSong;
    return this.startSong + Math.max(0, this.ctx.currentTime - this.startCtx);
  }

  setLevels(l: PreviewLevels) {
    this.levels = l;
    this.applyLevels();
  }

  setOffset(offsetSec: number) {
    if (offsetSec === this.offsetSec) return;
    this.offsetSec = offsetSec;
    if (this.playing) this.play(this.position());
  }

  setDrums(channels: Channels, sampleRate: number) {
    if (!this.ctx) return;
    this.drums = toBuffer(this.ctx, channels, sampleRate);
    if (this.playing) this.play(this.position());
  }

  play(fromSongSec: number) {
    const ctx = this.ctx;
    if (!ctx || !this.bed || !this.nodes) return;
    this.stopSources();
    const from = Math.max(0, Math.min(fromSongSec, this.bed.duration - 0.05));
    const when = ctx.currentTime + 0.05;
    const start = (buf: AudioBuffer | null, node: GainNode, delay: number, offset: number) => {
      if (!buf || offset >= buf.duration) return;
      const s = ctx.createBufferSource();
      s.buffer = buf;
      s.connect(node);
      s.start(when + delay, offset);
      this.sources.push(s);
    };
    start(this.bed, this.nodes.bed, 0, from);
    start(this.orig, this.nodes.orig, 0, from);
    const d = drumStartFor(from, this.offsetSec);
    start(this.drums, this.nodes.drums, d.delaySec, d.offsetSec);
    this.startCtx = when;
    this.startSong = from;
    this.playing = true;
  }

  stop() {
    this.startSong = this.position();
    this.stopSources();
    this.playing = false;
  }

  /** Move the playhead without playing (or jump while playing). */
  seek(songSec: number) {
    if (this.playing) this.play(songSec);
    else this.startSong = songSec;
  }

  dispose() {
    this.stopSources();
    this.playing = false;
    if (this.nodes) for (const n of Object.values(this.nodes)) n.disconnect();
    this.nodes = null;
    this.bed = this.orig = this.drums = null;
  }

  private applyLevels() {
    if (!this.nodes) return;
    const { songGain, drumGain, originalDrums } = this.levels;
    this.nodes.bed.gain.value = songGain;
    // Same as mixTake: backing = noDrums·songGain + originalDrums·amount·songGain.
    this.nodes.orig.gain.value = this.orig ? songGain * originalDrums : 0;
    this.nodes.drums.gain.value = drumGain;
  }

  private stopSources() {
    for (const s of this.sources) {
      try {
        s.stop();
      } catch {
        // already ended
      }
    }
    this.sources = [];
  }
}

function toBuffer(ctx: AudioContext, channels: Channels, sampleRate: number): AudioBuffer {
  const len = Math.max(1, channels[0]?.length ?? 1);
  const b = ctx.createBuffer(channels.length, len, sampleRate);
  channels.forEach((c, i) => b.copyToChannel(c as Float32Array<ArrayBuffer>, i));
  return b;
}
