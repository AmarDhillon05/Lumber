// Synthesized metronome click: a short sine burst with a fast exponential
// decay. Pure (no audio API) so calibration tests can use the same waveform.

export interface ClickOptions {
  freq?: number; // Hz
  durationMs?: number;
  gain?: number;
}

export function makeClick(sampleRate: number, opts: ClickOptions = {}): Float32Array {
  const freq = opts.freq ?? 1000;
  const durationMs = opts.durationMs ?? 30;
  const gain = opts.gain ?? 0.8;
  const n = Math.max(1, Math.round((sampleRate * durationMs) / 1000));
  const out = new Float32Array(n);
  const tau = n / 6; // ~-52 dB by the end
  const attack = Math.max(1, Math.round(sampleRate * 0.0005)); // 0.5 ms ramp, no DC click
  for (let i = 0; i < n; i++) {
    const env = Math.exp(-i / tau) * Math.min(1, i / attack);
    out[i] = gain * env * Math.sin((2 * Math.PI * freq * i) / sampleRate);
  }
  return out;
}

export const ACCENT_CLICK: ClickOptions = { freq: 1600, durationMs: 35, gain: 0.9 };
export const BEAT_CLICK: ClickOptions = { freq: 1000, durationMs: 30, gain: 0.7 };
