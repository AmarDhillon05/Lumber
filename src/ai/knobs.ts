// Legal knob ranges and validation shared by the Claude path and the offline
// interpreter: whatever produced a suggestion, it goes through here before it
// touches the mix.

import { BLANKET_TERMS, BLANKET_TERM_KEYS, type BlanketTerm, type BlanketValues } from '../dsp/blanketTerms';

// denoise / roominess clamp their spectral-gate amount at slider ≈ .34
// (INTENSITY = 3); higher values sound identical, so suggestions stop there.
const SOFT_MAX: Partial<Record<BlanketTerm, number>> = { denoise: 0.35, roominess: 0.35 };

export const GAIN_RANGE = { min: 0, max: 1.5 } as const;

export interface KnobRange {
  min: number;
  max: number;
}

/** Bipolar terms use −1..1; one-directional terms 0..1 (the knob mirrors negatives). */
export function knobRange(term: BlanketTerm): KnobRange {
  return { min: BLANKET_TERMS[term].bipolar ? -1 : 0, max: SOFT_MAX[term] ?? 1 };
}

const clamp = (x: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, x));
const round3 = (x: number) => Math.round(x * 1000) / 1000;

/** The value a term actually renders with (one-directional terms use |v|). */
export function effectiveValue(term: BlanketTerm, v: number | undefined): number {
  const x = Number.isFinite(v) ? (v as number) : 0;
  return BLANKET_TERMS[term].bipolar ? x : Math.abs(x);
}

export const clampKnob = (term: BlanketTerm, v: number): number => {
  const { min, max } = knobRange(term);
  return round3(clamp(v, min, max));
};

export const clampGain = (g: number): number => round3(clamp(g, GAIN_RANGE.min, GAIN_RANGE.max));

/**
 * Validate an untrusted knob map on top of `base`: unknown keys and
 * non-numbers are dropped, numbers are clamped to the legal range, and every
 * term is present in the result.
 */
export function sanitizeValues(raw: unknown, base: BlanketValues): { values: BlanketValues; dropped: string[] } {
  const values = { ...base } as BlanketValues;
  const dropped: string[] = [];
  if (raw && typeof raw === 'object') {
    for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
      if (!(k in BLANKET_TERMS) || typeof v !== 'number' || !Number.isFinite(v)) {
        dropped.push(k);
        continue;
      }
      values[k as BlanketTerm] = clampKnob(k as BlanketTerm, v);
    }
  }
  return { values, dropped };
}

/** Terms whose value differs between two states (by more than rounding). */
export function changedTerms(a: BlanketValues, b: BlanketValues): BlanketTerm[] {
  return BLANKET_TERM_KEYS.filter((k) => Math.abs((a[k] ?? 0) - (b[k] ?? 0)) > 1e-3);
}
