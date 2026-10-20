// Pure effect-chain builder: the low-level primitives (cookbook filters, EQ,
// gain) that append specs to a chain. Has no audio-engine dependency, so chains
// can be built (and inspected/tested) without react-native-audio-api.
// AudioFile extends this with decode + render.

import { Blanket } from './Blanket';
import { EffectSpec, BiquadKind } from './types';

// Butterworth section Q values per even order (cascaded biquads).
const BUTTER_Q: Record<number, number[]> = {
  2: [0.7071],
  4: [0.5412, 1.3066],
  6: [0.5176, 0.7071, 1.9319],
  8: [0.5098, 0.6013, 0.9000, 2.5629],
};

export class EffectChain {
  chain: EffectSpec[] = [];
  blanket: Blanket;

  constructor() {
    this.blanket = new Blanket(this);
  }

  /** Append a spec to the chain. */
  add(spec: EffectSpec): this {
    this.chain.push(spec);
    return this;
  }

  // --- Filters ---

  private butterworth(kind: BiquadKind, frequency: number, order: number): this {
    const qs = BUTTER_Q[order] ?? BUTTER_Q[4];
    for (const q of qs) this.add({ kind, frequency, q });
    return this;
  }

  high_pass(cutoffHz: number, order = 4): this {
    return this.butterworth('highpass', cutoffHz, order);
  }

  low_pass(cutoffHz: number, order = 4): this {
    return this.butterworth('lowpass', cutoffHz, order);
  }

  band_pass(lowHz: number, highHz: number): this {
    const frequency = Math.sqrt(lowHz * highHz);
    const q = frequency / (highHz - lowHz);
    return this.add({ kind: 'bandpass', frequency, q });
  }

  notch(centerHz: number, q = 30.0): this {
    return this.add({ kind: 'notch', frequency: centerHz, q });
  }

  // --- Parametric / Shelving EQ ---

  peak_eq(centerHz: number, gainDb: number, q: number): this {
    return this.add({ kind: 'peaking', frequency: centerHz, q, gainDb });
  }

  low_shelf(cutoffHz: number, gainDb: number): this {
    return this.add({ kind: 'lowshelf', frequency: cutoffHz, gainDb });
  }

  high_shelf(cutoffHz: number, gainDb: number): this {
    return this.add({ kind: 'highshelf', frequency: cutoffHz, gainDb });
  }

  // --- Gain ---

  gain(db: number): this {
    return this.add({ kind: 'gain', db });
  }
}
