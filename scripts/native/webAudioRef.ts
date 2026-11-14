// Reference Web Audio implementation (just the parts src/dsp/render.ts uses),
// written from the Web Audio API spec, for generating golden fixtures under Node.
//
// fixtures-dsp.ts installs this as the `react-native-audio-api` module so the
// real src/dsp/render.ts code path runs unchanged. Semantics:
// - BiquadFilterNode: spec coefficient formulas
//   (https://webaudio.github.io/web-audio-api/#filters-characteristics),
//   Q in dB for lowpass/highpass, S = 1 shelves, Direct Form I with
//   double-precision state, float32 output.
// - GainNode: float32 gain AudioParam.
// - ConvolverNode: normalize = true (spec calculateNormalizationScale),
//   direct (time-domain, float64) convolution, mono input × stereo IR → stereo,
//   stereo input → L*IR0, R*IR1.
// - Mixing: inputs of a node are summed after up-mixing to the max channel
//   count ("max" mode, speakers: mono→stereo copies); the destination
//   down-mixes stereo→mono as ½(L+R).
// - Rendering processes the whole buffer at once (equivalent to 128-frame
//   quanta for these LTI nodes) and returns exactly `length` frames.
// AudioParam values are float32 (Math.fround), as in the spec.

type Ch = Float32Array[];

const f32 = Math.fround;

export interface Coeffs {
  b0: number;
  b1: number;
  b2: number;
  a1: number;
  a2: number;
}

export function webAudioBiquadCoeffs(type: string, frequency: number, Q: number, gain: number, sr: number): Coeffs {
  const nyq = sr / 2;
  const f0 = Math.min(Math.max(f32(frequency), 0), nyq);
  const q = f32(Q);
  const G = f32(gain);
  const nf = f0 / nyq;
  const w0 = Math.PI * nf;
  const cw = Math.cos(w0);
  const sw = Math.sin(w0);
  const A = Math.pow(10, G / 40);
  const one = { b0: 1, b1: 0, b2: 0, a1: 0, a2: 0 };
  const zero = { b0: 0, b1: 0, b2: 0, a1: 0, a2: 0 };
  const AA = { b0: A * A, b1: 0, b2: 0, a1: 0, a2: 0 };
  const norm = (b0: number, b1: number, b2: number, a0: number, a1: number, a2: number): Coeffs => ({
    b0: b0 / a0,
    b1: b1 / a0,
    b2: b2 / a0,
    a1: a1 / a0,
    a2: a2 / a0,
  });
  switch (type) {
    case 'lowpass':
    case 'highpass': {
      if (nf >= 1) return type === 'lowpass' ? one : zero;
      if (nf <= 0) return type === 'lowpass' ? zero : one;
      const alpha = sw / (2 * Math.pow(10, q / 20));
      if (type === 'lowpass') return norm((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + alpha, -2 * cw, 1 - alpha);
      return norm((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + alpha, -2 * cw, 1 - alpha);
    }
    case 'bandpass': {
      if (nf <= 0 || nf >= 1) return zero;
      if (q <= 0) return one;
      const alpha = sw / (2 * q);
      return norm(alpha, 0, -alpha, 1 + alpha, -2 * cw, 1 - alpha);
    }
    case 'notch': {
      if (nf <= 0 || nf >= 1) return one;
      if (q <= 0) return zero;
      const alpha = sw / (2 * q);
      return norm(1, -2 * cw, 1, 1 + alpha, -2 * cw, 1 - alpha);
    }
    case 'peaking': {
      if (nf <= 0 || nf >= 1) return one;
      if (q <= 0) return AA;
      const alpha = sw / (2 * q);
      return norm(1 + alpha * A, -2 * cw, 1 - alpha * A, 1 + alpha / A, -2 * cw, 1 - alpha / A);
    }
    case 'lowshelf':
    case 'highshelf': {
      const low = type === 'lowshelf';
      if (nf >= 1) return low ? AA : one;
      if (nf <= 0) return low ? one : AA;
      const alphaS = (sw / 2) * Math.sqrt(2);
      const k = 2 * alphaS * Math.sqrt(A);
      if (low)
        return norm(
          A * (A + 1 - (A - 1) * cw + k),
          2 * A * (A - 1 - (A + 1) * cw),
          A * (A + 1 - (A - 1) * cw - k),
          A + 1 + (A - 1) * cw + k,
          -2 * (A - 1 + (A + 1) * cw),
          A + 1 + (A - 1) * cw - k,
        );
      return norm(
        A * (A + 1 + (A - 1) * cw + k),
        -2 * A * (A - 1 + (A + 1) * cw),
        A * (A + 1 + (A - 1) * cw - k),
        A + 1 - (A - 1) * cw + k,
        2 * (A - 1 - (A + 1) * cw),
        A + 1 - (A - 1) * cw - k,
      );
    }
  }
  throw new Error(`unknown biquad type ${type}`);
}

export function biquadProcess(x: Float32Array, c: Coeffs): Float32Array {
  const y = new Float32Array(x.length);
  let x1 = 0,
    x2 = 0,
    y1 = 0,
    y2 = 0;
  for (let i = 0; i < x.length; i++) {
    const xn = x[i];
    const yn = c.b0 * xn + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
    x2 = x1;
    x1 = xn;
    y2 = y1;
    y1 = yn;
    y[i] = yn;
  }
  return y;
}

export function normalizationScale(ir: AudioBufferRef): number {
  const GainCalibration = 0.00125;
  const GainCalibrationSampleRate = 44100;
  const MinPower = 0.000125;
  let power = 0;
  for (let i = 0; i < ir.numberOfChannels; i++) {
    let p = 0;
    const d = ir.getChannelData(i);
    for (let j = 0; j < ir.length; j++) p += d[j] * d[j];
    power += p;
  }
  power = Math.sqrt(power / (ir.numberOfChannels * ir.length));
  if (!isFinite(power) || isNaN(power) || power < MinPower) power = MinPower;
  let scale = 1 / power;
  scale *= GainCalibration;
  if (ir.sampleRate) scale *= GainCalibrationSampleRate / ir.sampleRate;
  if (ir.numberOfChannels === 4) scale *= 0.5;
  return scale;
}

/** Direct convolution, float64 accumulation, truncated to x.length. */
export function convolveDirect(x: Float32Array, h: Float64Array): Float64Array {
  const n = x.length;
  const m = h.length;
  const y = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    let acc = 0;
    const kmax = Math.min(i, m - 1);
    for (let k = 0; k <= kmax; k++) acc += x[i - k] * h[k];
    y[i] = acc;
  }
  return y;
}

// ---------------------------------------------------------------------------
// Minimal node graph (the react-native-audio-api surface render.ts uses)
// ---------------------------------------------------------------------------

export class AudioBufferRef {
  private data: Float32Array[];
  constructor(
    public numberOfChannels: number,
    public length: number,
    public sampleRate: number,
  ) {
    this.data = Array.from({ length: numberOfChannels }, () => new Float32Array(length));
  }
  getChannelData(c: number): Float32Array {
    return this.data[c];
  }
  copyToChannel(src: Float32Array, c: number): void {
    this.data[c].set(src.subarray(0, this.length));
  }
}

class Param {
  value: number;
  constructor(v: number) {
    this.value = v;
  }
}

function upmix(ch: Ch, n: number): Ch {
  if (ch.length === n) return ch;
  if (ch.length === 1) return Array.from({ length: n }, () => ch[0]);
  if (n === 1 && ch.length === 2) {
    const m = new Float32Array(ch[0].length);
    for (let i = 0; i < m.length; i++) m[i] = 0.5 * (ch[0][i] + ch[1][i]);
    return [m];
  }
  // discrete: copy what fits, zero the rest
  return Array.from({ length: n }, (_, c) => ch[c] ?? new Float32Array(ch[0].length));
}

abstract class Node {
  inputs: Node[] = [];
  constructor(protected ctx: OfflineAudioContext) {}
  connect(dst: Node): void {
    dst.inputs.push(this);
  }
  protected mixedInput(): Ch {
    const outs = this.inputs.map((n) => n.output());
    const nch = Math.max(1, ...outs.map((o) => o.length));
    const len = this.ctx.length;
    const sum: Ch = Array.from({ length: nch }, () => new Float32Array(len));
    for (const o of outs) {
      const u = upmix(o, nch);
      for (let c = 0; c < nch; c++) for (let i = 0; i < len; i++) sum[c][i] += u[c][i];
    }
    return sum;
  }
  private cache: Ch | null = null;
  output(): Ch {
    if (!this.cache) this.cache = this.process(this.mixedInput());
    return this.cache;
  }
  protected abstract process(input: Ch): Ch;
}

class SourceNode extends Node {
  buffer: AudioBufferRef | null = null;
  start(_t: number): void {}
  protected process(): Ch {
    const b = this.buffer!;
    return Array.from({ length: b.numberOfChannels }, (_, c) => Float32Array.from(b.getChannelData(c)));
  }
}

class GainNodeRef extends Node {
  gain = new Param(1);
  protected process(input: Ch): Ch {
    const g = f32(this.gain.value);
    return input.map((x) => x.map((v) => v * g));
  }
}

class BiquadNodeRef extends Node {
  type = 'lowpass';
  frequency = new Param(350);
  Q = new Param(1);
  gain = new Param(0);
  protected process(input: Ch): Ch {
    const c = webAudioBiquadCoeffs(this.type, this.frequency.value, this.Q.value, this.gain.value, this.ctx.sampleRate);
    return input.map((x) => biquadProcess(x, c));
  }
}

class ConvolverNodeRef extends Node {
  buffer: AudioBufferRef | null = null;
  normalize = true;
  protected process(input: Ch): Ch {
    const ir = this.buffer!;
    const scale = this.normalize ? normalizationScale(ir) : 1;
    const h = Array.from({ length: ir.numberOfChannels }, (_, c) =>
      Float64Array.from(ir.getChannelData(c), (v) => v * scale),
    );
    // Input is clamped to 2 channels (channelCountMode clamped-max).
    const inp = input.length > 2 ? input.slice(0, 2) : input;
    const outCh = Math.max(inp.length, Math.min(2, h.length));
    return Array.from({ length: outCh }, (_, c) => {
      const x = inp[Math.min(c, inp.length - 1)];
      const y = convolveDirect(x, h[Math.min(c, h.length - 1)]);
      return Float32Array.from(y);
    });
  }
}

class DestinationNode extends Node {
  protected process(input: Ch): Ch {
    return upmix(input, this.ctx.numberOfChannels);
  }
}

export class OfflineAudioContext {
  numberOfChannels: number;
  length: number;
  sampleRate: number;
  destination: DestinationNode;
  constructor(o: { numberOfChannels: number; length: number; sampleRate: number }) {
    this.numberOfChannels = o.numberOfChannels;
    this.length = o.length;
    this.sampleRate = o.sampleRate;
    this.destination = new DestinationNode(this);
  }
  createBuffer(nch: number, length: number, sr: number): AudioBufferRef {
    return new AudioBufferRef(nch, length, sr);
  }
  createBufferSource(): SourceNode {
    return new SourceNode(this);
  }
  createGain(): GainNodeRef {
    return new GainNodeRef(this);
  }
  createBiquadFilter(): BiquadNodeRef {
    return new BiquadNodeRef(this);
  }
  createConvolver(): ConvolverNodeRef {
    return new ConvolverNodeRef(this);
  }
  async startRendering(): Promise<AudioBufferRef> {
    const out = this.destination.output();
    const b = new AudioBufferRef(this.numberOfChannels, this.length, this.sampleRate);
    for (let c = 0; c < this.numberOfChannels; c++) b.copyToChannel(out[c], c);
    return b;
  }
}

/** Swap Math.random for the seeded LCG LumberCore uses (LCGRandom). Returns a restore function. */
export function seedMathRandom(seed: number): () => void {
  const orig = Math.random;
  let s = seed >>> 0;
  Math.random = () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
  return () => {
    Math.random = orig;
  };
}
