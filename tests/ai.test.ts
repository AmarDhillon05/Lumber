// "Describe the sound": analysis descriptors, knob validation and the offline
// interpreter. Pure modules only.

import { analyzeAudio, roundDescriptors, type AudioDescriptors, type MixAnalysis } from '../src/ai/analyze';
import { changedTerms, clampKnob, knobRange, sanitizeValues } from '../src/ai/knobs';
import { interpretLocally, LOCAL_VOCABULARY } from '../src/ai/localMix';
import { BLANKET_TERM_KEYS, BLANKET_TERMS, zeroValues, type BlanketValues } from '../src/dsp/blanketTerms';
import { fillValues } from '../src/dsp/presets';
import { ok, section, tone } from './harness';

const SR = 48000;
const near = (a: number, b: number, tol: number) => Math.abs(a - b) <= tol;

// Deterministic white noise.
function noise(n: number, seed = 1): Float32Array {
  let s = seed >>> 0;
  const x = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    s = (s * 1664525 + 1013904223) >>> 0;
    x[i] = s / 2 ** 31 - 1;
  }
  return x;
}

// Simple one-pole low-pass (dark) / first-difference (bright) colourings.
function lowpass(x: Float32Array, a = 0.97): Float32Array {
  const y = new Float32Array(x.length);
  let p = 0;
  for (let i = 0; i < x.length; i++) y[i] = p = a * p + (1 - a) * x[i];
  return y;
}
function diff(x: Float32Array): Float32Array {
  const y = new Float32Array(x.length);
  for (let i = 1; i < x.length; i++) y[i] = 0.5 * (x[i] - x[i - 1]);
  return y;
}

/** Noise-burst "hits" every `everySec`, exponential decay with time constant tau. */
function hits(sec: number, everySec: number, tauSec: number, amp = 0.8): Float32Array {
  const n = Math.floor(sec * SR);
  const x = new Float32Array(n);
  const nz = noise(n, 7);
  const period = Math.floor(everySec * SR);
  for (let i = 0; i < n; i++) {
    const t = (i % period) / SR;
    x[i] = amp * nz[i] * Math.exp(-t / tauSec);
  }
  return x;
}

function desc(over: Partial<AudioDescriptors> = {}, bands: Partial<AudioDescriptors['bands']> = {}): AudioDescriptors {
  return {
    durationSec: 20,
    channels: 1,
    rmsDb: -20,
    peakDb: -4,
    crestDb: 16,
    loudnessLufs: -20,
    dynamicRangeDb: 30,
    noiseFloorDb: -55,
    bands: { sub: -18, low: -8, lowMid: -8, mid: -6, presence: -9, air: -18, ...bands },
    centroidHz: 3000,
    onsetsPerSec: 4,
    decayMs: 150,
    stereoWidth: null,
    ...over,
  };
}
const ctx = (drums: AudioDescriptors, song: AudioDescriptors | null = null): MixAnalysis => ({
  drums,
  song,
  songIsDrumless: false,
});

const zero = (): BlanketValues => zeroValues();
const lm = (prompt: string, values = zero(), analysis: MixAnalysis | null = null, gains = { songGain: 0.8, drumGain: 1 }) =>
  interpretLocally({ prompt, values, ...gains, analysis });

function inLegalRange(v: BlanketValues): boolean {
  return BLANKET_TERM_KEYS.every((k) => {
    const { min, max } = knobRange(k);
    return typeof v[k] === 'number' && Number.isFinite(v[k]) && v[k] >= min - 1e-9 && v[k] <= max + 1e-9;
  });
}

function runAnalyze(): void {
  section('ai: audio analysis');

  const sine = tone(1000, 0.5, SR * 4, SR);
  const d = analyzeAudio([sine], SR);
  ok('sine RMS ≈ −9 dBFS', near(d.rmsDb, -9.03, 0.2), d.rmsDb.toFixed(2));
  ok('sine peak ≈ −6 dBFS', near(d.peakDb, -6.02, 0.1), d.peakDb.toFixed(2));
  ok('sine crest ≈ 3 dB', near(d.crestDb, 3.01, 0.2), d.crestDb.toFixed(2));
  // BS.1770: a 0 dBFS 1 kHz sine reads −3.01 LUFS, i.e. LUFS ≈ its RMS in dBFS.
  ok('sine loudness ≈ −9 LUFS', near(d.loudnessLufs, -9.03, 0.5), d.loudnessLufs.toFixed(2));
  ok('sine energy sits in the mid band', d.bands.mid > -1 && d.bands.air < -30, JSON.stringify(roundDescriptors(d).bands));
  ok('sine centroid ≈ 1 kHz', near(d.centroidHz, 1000, 60), d.centroidHz.toFixed(0));
  ok('mono → stereoWidth null', d.stereoWidth === null);
  ok('steady tone has no onsets', d.onsetsPerSec < 0.5, d.onsetsPerSec.toFixed(2));

  const low = analyzeAudio([tone(80, 0.5, SR * 2, SR)], SR);
  ok('80 Hz tone lands in the low band', low.bands.low > -1, low.bands.low.toFixed(1));

  const nz = noise(SR * 4);
  const bright = analyzeAudio([diff(nz)], SR);
  const dark = analyzeAudio([lowpass(nz)], SR);
  ok('high-passed noise is brighter than low-passed', bright.centroidHz > dark.centroidHz * 2, `${bright.centroidHz.toFixed(0)} vs ${dark.centroidHz.toFixed(0)}`);
  ok('bright noise has more air', bright.bands.air > dark.bands.air + 10);

  const kit = analyzeAudio([hits(8, 0.25, 0.03)], SR);
  ok('4 hits/s detected', near(kit.onsetsPerSec, 4, 0.5), kit.onsetsPerSec.toFixed(2));
  // −20 dB at τ·ln10 ≈ 69 ms (frame resolution ~11 ms)
  ok('short hits: decay ≈ 70 ms', near(kit.decayMs, 69, 25), kit.decayMs.toFixed(0));
  const ringy = analyzeAudio([hits(8, 0.5, 0.12)], SR);
  ok('ringy hits decay longer', ringy.decayMs > kit.decayMs * 2.5, ringy.decayMs.toFixed(0));
  ok('hits are spikier than a sine', kit.crestDb > 8, kit.crestDb.toFixed(1));
  ok('hits have a wide frame dynamic range', kit.dynamicRangeDb > 20, kit.dynamicRangeDb.toFixed(1));

  const l = noise(SR * 2, 3);
  const r = noise(SR * 2, 9);
  const neg = l.map((v) => -v);
  ok('identical L/R → width 0', analyzeAudio([l, l], SR).stereoWidth === 0);
  ok('L = −R → width 1', near(analyzeAudio([l, neg], SR).stereoWidth ?? 0, 1, 1e-6));
  ok('independent L/R → width ≈ .5', near(analyzeAudio([l, r], SR).stereoWidth ?? 0, 0.5, 0.05));

  const silent = analyzeAudio([new Float32Array(SR)], SR);
  const allFinite = [silent.rmsDb, silent.peakDb, silent.crestDb, silent.loudnessLufs, silent.centroidHz, silent.decayMs, ...Object.values(silent.bands)].every(Number.isFinite);
  ok('silence: finite, no onsets', allFinite && silent.onsetsPerSec === 0 && silent.rmsDb <= -100);
  ok('empty buffer does not throw', analyzeAudio([new Float32Array(0)], SR).durationSec === 0);

  // span control: startSec / maxSec
  const long = new Float32Array(SR * 10);
  long.set(tone(1000, 0.5, SR * 5, SR), SR * 5); // second half only
  const firstHalf = analyzeAudio([long], SR, { maxSec: 5 });
  const secondHalf = analyzeAudio([long], SR, { startSec: 5, maxSec: 5 });
  ok('maxSec caps the span', near(firstHalf.durationSec, 5, 0.01) && firstHalf.rmsDb <= -100);
  ok('startSec selects the region', near(secondHalf.rmsDb, -9.03, 0.3));

  // speed: the default 30 s cap, stereo at 48 kHz
  const big = [noise(SR * 30, 1), noise(SR * 30, 2)];
  const t0 = Date.now();
  analyzeAudio(big, SR);
  const ms = Date.now() - t0;
  ok('30 s stereo analysed quickly (< 1.5 s on Node)', ms < 1500, `${ms} ms`);

  const rd = roundDescriptors(kit);
  ok('rounded descriptors stay JSON-small', JSON.stringify(rd).length < 400, `${JSON.stringify(rd).length} chars`);
}

function runKnobs(): void {
  section('ai: knob validation');
  ok('bipolar range −1..1', knobRange('brightness').min === -1 && knobRange('brightness').max === 1);
  ok('one-directional range 0..1', knobRange('punch').min === 0 && knobRange('punch').max === 1);
  ok('denoise / roominess stop at the clamp', knobRange('denoise').max === 0.35 && knobRange('roominess').max === 0.35);
  ok('clampKnob clamps', clampKnob('punch', 3) === 1 && clampKnob('punch', -0.5) === 0 && clampKnob('air', -4) === -1);

  const base = fillValues({ warmth: 0.2 });
  const { values, dropped } = sanitizeValues({ punch: 0.5, air: -2, bogus: 1, warmth: 'loud', depth: NaN }, base);
  ok('sanitize keeps legal values', values.punch === 0.5 && values.air === -1);
  ok('sanitize drops unknown / non-numeric keys', dropped.sort().join(',') === 'bogus,depth,warmth' && values.warmth === 0.2);
  ok('sanitize returns a full map', BLANKET_TERM_KEYS.every((k) => typeof values[k] === 'number'));
  ok('sanitize of garbage = base', JSON.stringify(sanitizeValues(null, base).values) === JSON.stringify(base));
  ok('changedTerms', changedTerms(base, values).sort().join(',') === 'air,punch');
}

function runLocal(): void {
  section('ai: offline interpreter');

  const vocab = LOCAL_VOCABULARY;
  const required = ['warm', 'dark', 'bright', 'harsh', 'punchy', 'tight', 'dry', 'roomy', 'big', 'boomy', 'muddy', 'boxy', 'thin', 'crisp', 'compressed', 'natural', 'vintage', 'lofi', 'modern'];
  ok('vocabulary covers the core words', required.every((w) => vocab.includes(w)), required.filter((w) => !vocab.includes(w)).join(','));

  // basic directions
  const warm = lm('warmer');
  ok('warmer → warmth up, brightness down', warm.values.warmth > 0 && warm.values.brightness < 0 && warm.matched.includes('warm'));
  const bright = lm('brighter please');
  ok('brighter → brightness + air up', bright.values.brightness > 0 && bright.values.air > 0);
  const lessBright = lm('less bright');
  ok('less bright → brightness down', lessBright.values.brightness < 0 && lessBright.matched.includes('-bright'));
  const darker = lm('darker');
  ok('darker ≈ less bright', darker.values.brightness < 0 && darker.values.air < 0);
  ok('punchy → punch up', lm('punchy').values.punch > 0);
  ok('tight → sustain (gate) up', lm('tight').values.sustain > 0);

  // problem words: bare mention means fix it
  const boomy = lm('it sounds boomy');
  ok('bare "boomy" cuts the kick lows + raises the high-pass', boomy.values.kick_presence < 0 && boomy.values.high_pass_rumble > 0);
  const lessBoomy = lm('less boomy');
  ok('"less boomy" = bare "boomy"', JSON.stringify(lessBoomy.values) === JSON.stringify(boomy.values));
  ok('"more boom" adds low end', lm('more boom').values.kick_presence > 0);
  ok('muddy → boxiness cut up', lm('too muddy').values.boxiness > 0);
  ok('boxy → boxiness + resonance', lm('boxy').values.boxiness > 0 && lm('boxy').values.resonance > 0);
  ok('thin → fuller', lm('thin').values.fullness > 0 && lm('thin').values.snare_body > 0);
  ok('harsh → harshness smoothing up', lm('harsh cymbals').values.harshness > 0);
  ok('"not bright enough" → brighter', lm('not bright enough').values.brightness > 0);

  // the brief's examples
  const rock = lm('punchy and dry like a 90s rock record');
  ok('"punchy and dry like a 90s rock record" → punch up, depth down', rock.values.punch > 0.3 && rock.values.depth === 0 && rock.values.roominess > 0);
  ok('…matches punchy, dry and 90s rock', ['punchy', 'dry', '90s-rock'].every((m) => rock.matched.includes(m)), rock.matched.join(','));
  const room = lm('less boomy, more room');
  ok('"less boomy, more room" → kick cut + depth up', room.values.kick_presence < 0 && room.values.depth > 0);
  ok('…matches -boomy and roomy', room.matched.join(',') === '-boomy,roomy', room.matched.join(','));
  const noComma = lm('less boomy more room');
  ok('modifiers re-scope within one clause', noComma.values.kick_presence < 0 && noComma.values.depth > 0);

  // intensity
  const bit = lm('a bit warmer').values.warmth;
  const plain = lm('warmer').values.warmth;
  const lots = lm('way warmer').values.warmth;
  ok('intensity: a bit < plain < way', bit < plain && plain < lots, `${bit} ${plain} ${lots}`);
  ok('"much more room" > "more room"', lm('much more room').values.depth > lm('more room').values.depth);
  ok('"slightly less boomy" is gentler', lm('slightly less boomy').values.kick_presence > lm('less boomy').values.kick_presence);

  // starts from current values
  const start = fillValues({ warmth: 0.5, punch: 0.2 });
  const fromCur = lm('warmer', start);
  ok('deltas apply on top of current values', fromCur.values.warmth > 0.5 && fromCur.values.punch === 0.2);
  const mirrored = fillValues({ punch: -0.4 });
  ok('negative one-directional values read as |v|', lm('punchier', mirrored).values.punch > 0.4);
  ok('results stay in legal ranges (stacked)', inLegalRange(lm('way way punchier, punchy, punch, more punch, extremely punchy', fillValues({ punch: 0.9 })).values));
  ok('denoise stops at the clamp', lm('extremely noisy, so much hiss').values.denoise <= 0.35);
  ok('"less compressed" never goes below 0', lm('less compressed').values.dynamic_range === 0);

  // reset / natural
  const busy = fillValues({ warmth: 0.8, punch: 0.8, depth: 0.6 });
  const reset = lm('reset', busy);
  ok('reset → all zero', BLANKET_TERM_KEYS.every((k) => reset.values[k] === 0));
  const nat = lm('more natural', busy);
  ok('natural pulls knobs toward 0', nat.values.warmth < 0.8 && nat.values.punch < 0.8 && nat.values.warmth > 0);
  const resetThen = lm('start over, then warm', busy);
  ok('reset then a word applies from flat', resetThen.values.punch === 0 && resetThen.values.warmth > 0);

  // genres / eras
  ok('lo-fi (hyphen) → warmth + dark', lm('lo-fi').values.warmth > 0.3 && lm('lo-fi').values.air < 0);
  ok('vintage → warm + darker', lm('vintage').values.warmth > 0 && lm('vintage').values.brightness < 0);
  ok('modern → naturalness guard + attack', lm('modern and polished').values.naturalness > 0 && lm('modern').values.attack > 0);
  ok("80's (apostrophe) recognised", lm("80's").matched.includes('80s'));
  ok('"big" → fuller + deeper', lm('big').values.fullness > 0 && lm('big').values.depth > 0);
  ok('"crisp" → attack', lm('crisp').values.attack > 0);
  ok('"clean up the mud" → muddy fix, not "modern"', lm('clean up the mud').matched.join(',') === '-muddy', lm('clean up the mud').matched.join(','));

  // gains
  const louder = lm('drums louder');
  ok('"drums louder" → drumGain up', (louder.drumGain ?? 0) > 1 && louder.songGain === undefined);
  const songDown = lm('turn the song down a bit');
  ok('"turn the song down a bit" → songGain down', (songDown.songGain ?? 1) < 0.8 && (songDown.songGain ?? 0) > 0.65);
  ok('"more song" → songGain up', (lm('more song').songGain ?? 0) > 0.8);
  ok('"song is too loud" → songGain down, no knob change', (lm('the song is too loud').songGain ?? 1) < 0.8 && changedTerms(zero(), lm('the song is too loud').values).length === 0);
  ok('"lower the boom" is EQ, not gain', lm('lower the boom').drumGain === undefined && lm('lower the boom').values.kick_presence < 0);
  ok('gain clamps at 1.5', lm('extremely louder drums', zero(), null, { songGain: 0.8, drumGain: 1.45 }).drumGain === 1.5);
  ok('"warmer drums" is not a gain change', lm('warmer drums').drumGain === undefined);

  // nothing recognised
  const none = lm('asdf qwerty');
  ok('unknown prompt: no change + hint', none.matched.length === 0 && JSON.stringify(none.values) === JSON.stringify(zero()) && /didn/.test(none.explanation));
  ok('explanation is labelled offline', /^Offline interpreter:/.test(warm.explanation));

  // analysis-aware
  const brightTake = ctx(desc({ centroidHz: 6000 }, { air: -8 }));
  const dullTake = ctx(desc({ centroidHz: 1200 }, { air: -30 }));
  const bNeutral = lm('brighter').values.brightness;
  const bOnBright = lm('brighter', zero(), brightTake).values.brightness;
  const bOnDull = lm('brighter', zero(), dullTake).values.brightness;
  ok('"brighter" does less on a bright take, more on a dull one', bOnBright < bNeutral && bOnDull > bNeutral, `${bOnBright} ${bNeutral} ${bOnDull}`);
  ok('…and says why', /already bright/.test(lm('brighter', zero(), brightTake).explanation));
  ok('"darker" does less on a dull take', lm('darker', zero(), dullTake).values.brightness > lm('darker').values.brightness);

  const boomyTake = ctx(desc({}, { sub: -6, low: -2 }));
  const leanTake = ctx(desc({}, { sub: -30, low: -20 }));
  ok('"less boomy" cuts harder on a bass-heavy take', lm('less boomy', zero(), boomyTake).values.kick_presence < lm('less boomy', zero(), leanTake).values.kick_presence);
  const ringyTake = ctx(desc({ decayMs: 400 }));
  const shortTake = ctx(desc({ decayMs: 60 }));
  ok('"drier" works harder on a ringy take', lm('drier', zero(), ringyTake).values.sustain > lm('drier', zero(), shortTake).values.sustain);
  ok('"more room" does less when hits already ring', lm('more room', zero(), ringyTake).values.depth < lm('more room', zero(), shortTake).values.depth);
  const squashed = ctx(desc({ crestDb: 9 }));
  const spiky = ctx(desc({ crestDb: 24 }));
  ok('"more compressed" does less on a squashed take', lm('more compressed', zero(), squashed).values.dynamic_range < lm('more compressed', zero(), spiky).values.dynamic_range);
  ok('"punchier" does less on a very dynamic take', lm('punchier', zero(), spiky).values.punch < lm('punchier', zero(), squashed).values.punch);
  const hissy = ctx(desc({ rmsDb: -30, noiseFloorDb: -48 }));
  const quiet = ctx(desc({ rmsDb: -20, noiseFloorDb: -80 }));
  ok('"less noise" denoises more on a noisy take', lm('less noise', zero(), hissy).values.denoise > lm('less noise', zero(), quiet).values.denoise);

  const mono = ctx(desc({ stereoWidth: null }));
  const stereo = ctx(desc({ stereoWidth: 0.2, channels: 2 }));
  ok('width skipped on a mono take', lm('wider', zero(), mono).values.width === 0 && /mono/.test(lm('wider', zero(), mono).explanation));
  ok('width applied on a stereo take', lm('wider', zero(), stereo).values.width > 0);

  const brightSong = ctx(desc({ centroidHz: 2000 }), desc({ centroidHz: 4000, decayMs: 400 }));
  const fit = lm('make the drums fit the song', zero(), brightSong);
  ok('"fit the song" brightens drums toward a brighter, roomier song', fit.values.brightness > 0 && fit.values.depth > 0, fit.matched.join(','));
  const darkSong = ctx(desc({ centroidHz: 4000 }), desc({ centroidHz: 1500 }));
  ok('"blend in with the mix" darkens toward a darker song', lm('blend in with the mix', zero(), darkSong).values.brightness < 0);

  // determinism + safety across a pile of prompts
  const prompts = [
    'punchy and dry like a 90s rock record', 'less boomy, more room', 'warm vintage jazz with brushes', 'huge 80s gated snare',
    'tight funk, ghost notes up', 'lofi hip-hop', 'modern metal, very tight and clicky', 'not so harsh, a little more air',
    'way less ring and no reverb', 'thick snare, fat kick, softer cymbals', 'cut through the mix', 'make it sound like a phone recording',
  ];
  const a = analysisFor();
  ok('all sample prompts give legal values', prompts.every((p) => inLegalRange(lm(p, fillValues({ warmth: 0.9, air: -0.9 }), a).values)));
  ok('interpreter is deterministic', prompts.every((p) => JSON.stringify(lm(p, zero(), a)) === JSON.stringify(lm(p, zero(), a))));
  ok('every sample prompt matches something', prompts.every((p) => lm(p).matched.length > 0), prompts.filter((p) => !lm(p).matched.length).join(' | '));
  ok('no NaN anywhere', prompts.every((p) => BLANKET_TERM_KEYS.every((k) => Number.isFinite(lm(p, zero(), a).values[k]))));
  ok('bipolar/one-directional catalog is consistent', BLANKET_TERM_KEYS.every((k) => (knobRange(k).min < 0) === BLANKET_TERMS[k].bipolar));
}

function analysisFor(): MixAnalysis {
  return ctx(analyzeAudio([hits(4, 0.25, 0.05)], SR), analyzeAudio([lowpass(noise(SR * 4))], SR));
}

export function run(): void {
  runAnalyze();
  runKnobs();
  runLocal();
}
