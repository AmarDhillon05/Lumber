// Knob values → effect chain, in a fixed processing order. Pure (no audio
// engine), so the same chain drives the offline render, preview, usage tallies
// and tests.

import { EffectChain } from './chain';
import { BLANKET_TERMS, BLANKET_TERM_KEYS, type BlanketTerm, type BlanketValues } from './blanketTerms';
import type { EffectSpec } from './types';

// Slider values are −1..1; this widens them so the effects are clearly audible.
// Each Blanket method already multiplies its amount by a fixed coefficient, so
// the effective swing is value × INTENSITY × that coefficient.
export const INTENSITY = 3;

// Processing order, independent of how knobs are grouped in the UI:
// clean-up first (so later gain stages don't lift rumble/noise/room), then
// corrective → tonal EQ, dynamics (gate before compressors, upward compression
// last), harmonic colour, space, the level fader, and finally the naturalness
// brick-wall guard. Every term must appear exactly once (renderOrderIsComplete,
// checked by the tests).
export const BLANKET_RENDER_ORDER: readonly BlanketTerm[] = [
  // clean-up
  'high_pass_rumble',
  'denoise',
  'roominess',
  'resonance',
  // corrective EQ
  'boxiness',
  'harshness',
  // tonal EQ
  'kick_presence',
  'snare_body',
  'attack',
  'brightness',
  'air',
  // dynamics
  'sustain',
  'punch',
  'dynamic_range',
  'consistency',
  'pumping',
  'detail',
  // harmonic
  'fullness',
  'warmth',
  'presence',
  'clipping',
  // space
  'width',
  'depth',
  // level + guard
  'volume',
  'naturalness',
];

/**
 * Append the Blanket chain for `values` to `target` (an EffectChain or an
 * AudioFile). Terms at 0 or missing are skipped, so an empty map is a clean
 * pass-through. Bipolar terms keep their sign (boost/cut); the rest use |value|.
 */
export function applyBlanket<T extends EffectChain>(
  target: T,
  values: Partial<BlanketValues>,
  intensity = INTENSITY,
): T {
  for (const term of BLANKET_RENDER_ORDER) {
    const value = values[term] ?? 0;
    if (value === 0 || !Number.isFinite(value)) continue;
    const signed = BLANKET_TERMS[term].bipolar ? value : Math.abs(value);
    target.blanket[term](signed * intensity);
  }
  return target;
}

/** Knob values → the effect specs they expand into (in render order). */
export function buildBlanketChain(values: Partial<BlanketValues>, intensity = INTENSITY): EffectSpec[] {
  return applyBlanket(new EffectChain(), values, intensity).chain;
}

/** True if every term in BLANKET_TERM_KEYS is in the render order exactly once. */
export function renderOrderIsComplete(): boolean {
  const seen = new Set(BLANKET_RENDER_ORDER);
  return (
    seen.size === BLANKET_RENDER_ORDER.length &&
    BLANKET_RENDER_ORDER.length === BLANKET_TERM_KEYS.length &&
    BLANKET_TERM_KEYS.every((k) => seen.has(k))
  );
}
