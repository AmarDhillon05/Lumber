// Drum presets: named starting points for the Blanket knobs (replacing
// Timber's AI suggest). A preset is a sparse BlanketValues map in slider units
// (−1..1; each is later scaled by INTENSITY). Pick one, then tweak.

import { BLANKET_TERM_KEYS, type BlanketTerm, type BlanketValues } from './blanketTerms';

export interface Preset {
  id: string;
  label: string;
  description: string;
  values: Partial<Record<BlanketTerm, number>>;
}

// Notes on tuning vs. the plan's starting table:
// - denoise / roominess clamp their spectral-gate amount at 1, which with
//   INTENSITY = 3 is reached at slider ≈ .34; higher values all sound the same,
//   so those presets sit just under the clamp instead of past it.
// - high_pass_rumble spans 40 Hz + value·3·40 Hz; 1.0 would be a 160 Hz
//   4th-order cut (removes the kick's fundamental), so Phone-mic rescue uses
//   .5 (100 Hz).
export const PRESETS: Preset[] = [
  {
    id: 'warm',
    label: 'Warm',
    description: 'Rounded, saturated kit with softened cymbals and a touch of room.',
    values: {
      warmth: 0.5,
      fullness: 0.4,
      brightness: -0.4,
      harshness: 0.5,
      dynamic_range: 0.3,
      depth: 0.2,
    },
  },
  {
    id: 'bright',
    label: 'Bright / Harsh',
    description: 'Crisp stick attack and open top end that cuts through a dense mix.',
    values: {
      attack: 0.8,
      presence: 0.6,
      air: 0.6,
      brightness: 0.5,
      punch: 0.4,
    },
  },
  {
    id: 'loud',
    label: 'Loud',
    description: 'Heavily compressed, punchy and up-front, with a big kick.',
    values: {
      punch: 0.8,
      dynamic_range: 0.8,
      kick_presence: 0.6,
      warmth: 0.3,
      naturalness: 1,
    },
  },
  {
    id: 'tight',
    label: 'Tight / Dry',
    description: 'Short tails, less room and mud, controlled low end.',
    values: {
      sustain: 0.6,
      roominess: 0.3,
      boxiness: 0.5,
      punch: 0.5,
      high_pass_rumble: 0.5,
    },
  },
  {
    id: 'roomy',
    label: 'Roomy / Vintage',
    description: 'Darker, warmer kit set back in a small room, ghost notes lifted.',
    values: {
      depth: 0.6,
      warmth: 0.6,
      brightness: -0.3,
      detail: 0.5,
    },
  },
  {
    id: 'phone',
    label: 'Phone-mic rescue',
    description: 'Cleans up a phone recording: rumble, hiss, boxiness and ringing.',
    values: {
      high_pass_rumble: 0.5,
      denoise: 0.3,
      boxiness: 0.6,
      resonance: 0.5,
      naturalness: 1,
    },
  },
];

export const getPreset = (id: string): Preset | undefined => PRESETS.find((p) => p.id === id);

/** Expand a sparse map to a full BlanketValues map, 0 for missing terms. */
export function fillValues(sparse: Partial<BlanketValues>): BlanketValues {
  return Object.fromEntries(BLANKET_TERM_KEYS.map((k) => [k, sparse[k] ?? 0])) as BlanketValues;
}

/** A preset's full knob state (what the editor loads when it's picked). */
export const presetValues = (preset: Preset): BlanketValues => fillValues(preset.values);

export { applyBlanket, buildBlanketChain, BLANKET_RENDER_ORDER, INTENSITY } from './blanketChain';
export type { BlanketValues } from './blanketTerms';
