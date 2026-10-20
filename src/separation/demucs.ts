// HTDemucs (4-stem) separation around an ONNX graph that excludes the STFT.
//
// The graph (`htdemucs_core.onnx`) takes one 7.8 s stereo segment plus its
// complex-as-channels spectrogram and returns per-source spectrograms and
// time-branch waveforms. Everything around it — the STFT/iSTFT exactly as
// demucs computes them, overlap-add chunking as in `demucs.apply.apply_model`
// (overlap 0.25, shifts 0), and the input normalization from `demucs.api` —
// lives here so it can be checked against PyTorch under Node and run unchanged
// on the phone.
//
// Only two outputs are kept: drums, and everything else summed (bass + other +
// vocals). The iSTFT is linear, so the three non-drum spectrograms are summed
// before inverting, and the two real outputs share one complex inverse FFT.

import { FFT } from './fft';

export const SAMPLE_RATE = 44100;
export const NFFT = 4096;
export const HOP = 1024;
export const SEGMENT = 343980; // int(44100 * 39/5), the model's training segment
export const FRAMES = Math.ceil(SEGMENT / HOP); // 336
export const BINS = NFFT / 2; // 2048 (demucs drops the Nyquist bin)
export const SOURCES = ['drums', 'bass', 'other', 'vocals'] as const;
export const OVERLAP = 0.25;
export const STRIDE = Math.floor((1 - OVERLAP) * SEGMENT);

const PAD = (HOP / 2) * 3; // demucs re-pads by 1536 so frames line up with the hop
const NORM = 1 / Math.sqrt(NFFT); // torch.stft(normalized=True)

export interface DemucsOutputs {
  spec: Float32Array; // (4 sources, 4 cac, BINS, FRAMES)
  wave: Float32Array; // (4 sources, 2 channels, SEGMENT)
}

// One inference over a segment. `mix` is (2, SEGMENT), `mag` is (4, BINS, FRAMES).
export interface DemucsRunner {
  run(mix: Float32Array, mag: Float32Array): Promise<DemucsOutputs>;
}

// Receives finished audio in order, block after block, so a whole song never
// has to be held as stems in memory.
export interface StemSink {
  write(drums: Float32Array[], noDrums: Float32Array[]): Promise<void> | void;
}

let fft: FFT | null = null;
let hann: Float64Array | null = null;
let olaEnvelope: Float64Array | null = null;

function tables() {
  if (!fft || !hann || !olaEnvelope) {
    fft = new FFT(NFFT);
    hann = new Float64Array(NFFT);
    for (let i = 0; i < NFFT; i++) hann[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / NFFT);
    // Sum of squared windows that torch.istft divides by, over every frame
    // including the zero frames demucs pads on each side.
    olaEnvelope = new Float64Array(SEGMENT);
    const totalFrames = FRAMES + 4;
    for (let s = 0; s < SEGMENT; s++) {
      const p = s + NFFT / 2 + PAD;
      let e = 0;
      for (let j = 0; j < totalFrames; j++) {
        const q = p - j * HOP;
        if (q >= 0 && q < NFFT) e += hann[q] * hann[q];
      }
      olaEnvelope[s] = e;
    }
  }
  return { fft, hann, olaEnvelope };
}

function reflect(i: number, length: number): number {
  if (i < 0) return -i;
  if (i >= length) return 2 * (length - 1) - i;
  return i;
}

// demucs HTDemucs._spec + _magnitude for a stereo segment of exactly SEGMENT
// samples → (4, BINS, FRAMES) with channels [L.re, L.im, R.re, R.im].
export function spectrogram(left: Float32Array, right: Float32Array): Float32Array {
  const { fft, hann } = tables();
  const out = new Float32Array(4 * BINS * FRAMES);
  const re = new Float64Array(NFFT);
  const im = new Float64Array(NFFT);
  const plane = BINS * FRAMES;
  for (let t = 0; t < FRAMES; t++) {
    const start = t * HOP - PAD;
    for (let q = 0; q < NFFT; q++) {
      const i = reflect(start + q, SEGMENT);
      re[q] = left[i] * hann[q];
      im[q] = right[i] * hann[q];
    }
    fft.transform(re, im);
    // Unpack the two real transforms from the one complex transform.
    for (let k = 0; k < BINS; k++) {
      const m = (NFFT - k) % NFFT;
      const o = k * FRAMES + t;
      out[o] = 0.5 * (re[k] + re[m]) * NORM;
      out[plane + o] = 0.5 * (im[k] - im[m]) * NORM;
      out[2 * plane + o] = 0.5 * (im[k] + im[m]) * NORM;
      out[3 * plane + o] = 0.5 * (re[m] - re[k]) * NORM;
    }
  }
  return out;
}

// demucs HTDemucs._ispec for two real signals at once. `a` and `b` are
// (2 cac, BINS, FRAMES) views: [re plane, im plane]. Results are added into
// outA/outB (length SEGMENT).
function inverseSpectrogramPair(
  aRe: Float32Array,
  aIm: Float32Array,
  bRe: Float32Array,
  bIm: Float32Array,
  outA: Float32Array,
  outB: Float32Array,
): void {
  const { fft, hann, olaEnvelope } = tables();
  const re = new Float64Array(NFFT);
  const im = new Float64Array(NFFT);
  const accA = new Float64Array(SEGMENT);
  const accB = new Float64Array(SEGMENT);
  const scale = 1 / (NORM * NFFT); // undo 1/n of the inverse FFT, then ×sqrt(n)
  for (let t = 0; t < FRAMES; t++) {
    // Y = A + iB as a full Hermitian-pair spectrum; C2R ignores imag at DC.
    re[0] = aRe[t];
    im[0] = bRe[t];
    for (let k = 1; k < BINS; k++) {
      const o = k * FRAMES + t;
      const ar = aRe[o];
      const ai = aIm[o];
      const br = bRe[o];
      const bi = bIm[o];
      re[k] = ar - bi;
      im[k] = ai + br;
      re[NFFT - k] = ar + bi;
      im[NFFT - k] = br - ai;
    }
    re[BINS] = 0; // Nyquist bin was dropped → zero
    im[BINS] = 0;
    fft.transform(re, im, true);
    const start = t * HOP - PAD;
    const q0 = Math.max(0, -start);
    const q1 = Math.min(NFFT, SEGMENT - start);
    for (let q = q0; q < q1; q++) {
      const w = hann[q] * scale;
      accA[start + q] += re[q] * w;
      accB[start + q] += im[q] * w;
    }
  }
  for (let s = 0; s < SEGMENT; s++) {
    outA[s] += accA[s] / olaEnvelope[s];
    outB[s] += accB[s] / olaEnvelope[s];
  }
}

// One model call on a normalized SEGMENT-long stereo chunk → drums and
// no-drums (normalized domain), each [left, right].
export async function separateSegment(
  left: Float32Array,
  right: Float32Array,
  runner: DemucsRunner,
): Promise<{ drums: Float32Array[]; noDrums: Float32Array[] }> {
  const mix = new Float32Array(2 * SEGMENT);
  mix.set(left, 0);
  mix.set(right, SEGMENT);
  const { spec, wave } = await runner.run(mix, spectrogram(left, right));

  const plane = BINS * FRAMES;
  const at = (source: number, cac: number) =>
    spec.subarray((source * 4 + cac) * plane, (source * 4 + cac + 1) * plane);

  const drums = [new Float32Array(SEGMENT), new Float32Array(SEGMENT)];
  const noDrums = [new Float32Array(SEGMENT), new Float32Array(SEGMENT)];
  for (let ch = 0; ch < 2; ch++) {
    const restRe = new Float32Array(plane);
    const restIm = new Float32Array(plane);
    for (let s = 1; s < SOURCES.length; s++) {
      const r = at(s, 2 * ch);
      const i = at(s, 2 * ch + 1);
      for (let x = 0; x < plane; x++) {
        restRe[x] += r[x];
        restIm[x] += i[x];
      }
    }
    inverseSpectrogramPair(at(0, 2 * ch), at(0, 2 * ch + 1), restRe, restIm, drums[ch], noDrums[ch]);
    // Time branch.
    const d = drums[ch];
    const n = noDrums[ch];
    const w0 = wave.subarray(ch * SEGMENT, (ch + 1) * SEGMENT);
    for (let x = 0; x < SEGMENT; x++) d[x] += w0[x];
    for (let s = 1; s < SOURCES.length; s++) {
      const ws = wave.subarray((s * 2 + ch) * SEGMENT, (s * 2 + ch + 1) * SEGMENT);
      for (let x = 0; x < SEGMENT; x++) n[x] += ws[x];
    }
  }
  return { drums, noDrums };
}

// Full-song separation: demucs.api normalization + apply_model chunking.
// `input` is 1 or 2 channels at SAMPLE_RATE. Output is streamed to `sink` in
// order; total samples written equals the input length.
export async function separate(
  input: Float32Array[],
  runner: DemucsRunner,
  sink: StemSink,
  onProgress?: (fraction: number) => void,
): Promise<void> {
  const left = input[0];
  const right = input[1] ?? input[0];
  const length = left.length;
  if (!length) return;

  // Normalize by the mono mix's mean / (unbiased) std, as demucs.api does.
  let sum = 0;
  for (let i = 0; i < length; i++) sum += 0.5 * (left[i] + right[i]);
  const mean = sum / length;
  let sq = 0;
  for (let i = 0; i < length; i++) {
    const d = 0.5 * (left[i] + right[i]) - mean;
    sq += d * d;
  }
  const std = Math.sqrt(sq / Math.max(1, length - 1)) || 1;

  // Triangular cross-fade weight, peak 1 in the middle of the segment.
  const halfSeg = Math.floor(SEGMENT / 2);
  const weight = new Float32Array(SEGMENT);
  for (let i = 0; i < SEGMENT; i++) weight[i] = (i < halfSeg ? i + 1 : SEGMENT - i) / halfSeg;

  // Accumulator window starting at the current chunk offset.
  const acc = [0, 1, 2, 3].map(() => new Float64Array(SEGMENT)); // dL dR nL nR
  const accW = new Float64Array(SEGMENT);

  const offsets: number[] = [];
  for (let o = 0; o < length; o += STRIDE) offsets.push(o);

  const chunkL = new Float32Array(SEGMENT);
  const chunkR = new Float32Array(SEGMENT);
  for (let c = 0; c < offsets.length; c++) {
    const offset = offsets[c];
    const chunkLen = Math.min(SEGMENT, length - offset);
    // TensorChunk.padded: centre the chunk, real audio as context, zeros past the ends.
    const lead = Math.floor((SEGMENT - chunkLen) / 2);
    const start = offset - lead;
    for (let i = 0; i < SEGMENT; i++) {
      const j = start + i;
      const inside = j >= 0 && j < length;
      chunkL[i] = inside ? (left[j] - mean) / std : 0;
      chunkR[i] = inside ? (right[j] - mean) / std : 0;
    }
    const { drums, noDrums } = await separateSegment(chunkL, chunkR, runner);
    const outs = [drums[0], drums[1], noDrums[0], noDrums[1]];
    for (let i = 0; i < chunkLen; i++) {
      const w = weight[i];
      for (let k = 0; k < 4; k++) acc[k][i] += w * outs[k][lead + i];
      accW[i] += w;
    }

    const isLast = c === offsets.length - 1;
    const emit = isLast ? chunkLen : STRIDE;
    const block = [0, 1, 2, 3].map(() => new Float32Array(emit));
    for (let i = 0; i < emit; i++) {
      for (let k = 0; k < 4; k++) {
        const v = acc[k][i] / accW[i];
        // drums: v*std + mean; no-drums is three stems summed → 3*mean.
        block[k][i] = v * std + (k < 2 ? mean : 3 * mean);
      }
    }
    await sink.write([block[0], block[1]], [block[2], block[3]]);

    if (!isLast) {
      for (const a of acc) {
        a.copyWithin(0, STRIDE);
        a.fill(0, SEGMENT - STRIDE);
      }
      accW.copyWithin(0, STRIDE);
      accW.fill(0, SEGMENT - STRIDE);
    }
    onProgress?.((c + 1) / offsets.length);
  }
}
