import { PRESETS, presetValues, fillValues, getPreset } from '../src/dsp/presets';
import {
  BLANKET_RENDER_ORDER,
  buildBlanketChain,
  renderOrderIsComplete,
  INTENSITY,
} from '../src/dsp/blanketChain';
import { BLANKET_TERM_KEYS, BLANKET_TERMS, zeroValues } from '../src/dsp/blanketTerms';
import { ok, section } from './harness';

export function run(): void {
  section('presets + blanket chain');

  ok('render order covers every term once', renderOrderIsComplete());
  ok('naturalness renders last', BLANKET_RENDER_ORDER[BLANKET_RENDER_ORDER.length - 1] === 'naturalness');

  ok('six presets with unique ids', PRESETS.length === 6 && new Set(PRESETS.map((p) => p.id)).size === 6);
  const inRange = PRESETS.every((p) =>
    Object.entries(p.values).every(([term, v]) => {
      const info = BLANKET_TERMS[term as keyof typeof BLANKET_TERMS];
      return info != null && typeof v === 'number' && v <= 1 && v >= (info.bipolar ? -1 : 0);
    }),
  );
  ok('preset values are known terms in slider range', inRange);
  ok('getPreset finds by id', getPreset('warm')?.label === 'Warm' && getPreset('nope') === undefined);

  const full = presetValues(PRESETS[0]);
  ok(
    'presetValues fills every term',
    BLANKET_TERM_KEYS.every((k) => typeof full[k] === 'number') && full.warmth === 0.5 && full.air === 0,
  );

  ok('all-zero values build an empty chain', buildBlanketChain(zeroValues()).length === 0);
  ok('empty map builds an empty chain', buildBlanketChain({}).length === 0);

  // ordering: naturalness after volume after everything else, regardless of map order
  const chain = buildBlanketChain({ naturalness: 1, volume: 0.5, high_pass_rumble: 0.5 });
  const kinds = chain.map((s) => s.kind);
  ok(
    'chain follows render order',
    kinds[0] === 'highpass' && kinds[kinds.length - 2] === 'gain' && kinds[kinds.length - 1] === 'compressor',
    kinds.join(','),
  );

  // scaling: kick_presence .5 → peak_eq gain = .5 * INTENSITY * 3 dB
  const kick = buildBlanketChain({ kick_presence: 0.5 })[0];
  ok(
    'intensity scaling applied',
    kick.kind === 'peaking' && Math.abs((kick.gainDb ?? 0) - 0.5 * INTENSITY * 3) < 1e-9,
  );
  // bipolar sign kept; unipolar uses magnitude
  const bright = buildBlanketChain({ brightness: -0.4 })[0];
  ok('bipolar keeps sign', bright.kind === 'highshelf' && (bright.gainDb ?? 0) < 0);
  const comp = buildBlanketChain({ dynamic_range: -0.5 })[0];
  ok('unipolar uses magnitude', comp.kind === 'compressor' && comp.ratio > 1);

  ok(
    'every preset builds a non-empty chain',
    PRESETS.every((p) => buildBlanketChain(p.values).length > 0),
  );
  ok('fillValues defaults to 0', fillValues({ air: 0.2 }).punch === 0);
}
