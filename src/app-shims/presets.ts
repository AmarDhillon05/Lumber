// SHIM — mirrors src/dsp/presets.ts on origin/feat/dsp (not on main yet).
// Delete once feat/dsp merges and point src/app-shims/index.ts at '../dsp/presets'.

import { BLANKET_TERM_KEYS, type BlanketTerm } from '../dsp/blanketTerms';

export type BlanketValues = Record<BlanketTerm, number>;

export interface Preset {
  id: string;
  label: string;
  description: string;
  values: Partial<Record<BlanketTerm, number>>;
}

// Starting points from PLAN.md, tuned by ear later.
export const PRESETS: Preset[] = [
  {
    id: 'warm',
    label: 'Warm',
    description: 'Rounded, saturated, softer top end.',
    values: { warmth: 0.5, fullness: 0.4, brightness: -0.4, harshness: 0.5, dynamic_range: 0.3, depth: 0.2 },
  },
  {
    id: 'bright',
    label: 'Bright / Harsh',
    description: 'Crisp stick attack and open cymbals.',
    values: { attack: 0.8, presence: 0.6, air: 0.6, brightness: 0.5, punch: 0.4 },
  },
  {
    id: 'loud',
    label: 'Loud',
    description: 'Compressed, punchy, limited.',
    values: { punch: 0.8, dynamic_range: 0.8, kick_presence: 0.6, warmth: 0.3, naturalness: 1 },
  },
  {
    id: 'tight',
    label: 'Tight / Dry',
    description: 'Short tails, less room, less box.',
    values: { sustain: 0.6, roominess: 0.3, boxiness: 0.5, punch: 0.5, high_pass_rumble: 0.5 },
  },
  {
    id: 'roomy',
    label: 'Roomy / Vintage',
    description: 'Distant, warm and dark.',
    values: { depth: 0.6, warmth: 0.6, brightness: -0.3, detail: 0.5 },
  },
  {
    id: 'phone',
    label: 'Phone-mic rescue',
    description: 'Cleans up a phone-mic recording.',
    values: { high_pass_rumble: 0.5, denoise: 0.3, boxiness: 0.6, resonance: 0.5, naturalness: 1 },
  },
];

export const getPreset = (id: string): Preset | undefined => PRESETS.find((p) => p.id === id);

export function fillValues(sparse: Partial<BlanketValues>): BlanketValues {
  return Object.fromEntries(BLANKET_TERM_KEYS.map((k) => [k, sparse[k] ?? 0])) as BlanketValues;
}

export const presetValues = (preset: Preset): BlanketValues => fillValues(preset.values);
