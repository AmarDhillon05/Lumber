// Offline "Describe the sound" interpreter: a deterministic word → knob-delta
// mapper that runs with no key and no network (e.g. on a plane). It reads the
// prompt clause by clause, picks up direction ("less", "too", "no", "more")
// and intensity ("a bit", "way more") words before each sound word, and nudges
// the current knob values. When analysis is available it scales each move by
// where the audio already is ("brighter" does less on an already-bright take).

import { BLANKET_TERM_KEYS, type BlanketTerm, type BlanketValues } from '../dsp/blanketTerms';
import type { AudioDescriptors, MixAnalysis } from './analyze';
import { clampGain, clampKnob, effectiveValue } from './knobs';

type Delta = Partial<Record<BlanketTerm, number>>;
type Dir = 1 | -1;

interface Scale {
  k: number;
  note?: string;
}

interface Concept {
  id: string;
  more: string; // label when applied in its own direction
  less: string; // label when negated
  patterns: RegExp[];
  delta: Delta | ((a: MixAnalysis | null) => Delta);
  problem?: boolean; // a bare mention ("boxy") means "fix it", i.e. dir −1
  op?: 'natural' | 'reset';
  scale?: (a: MixAnalysis, dir: Dir) => Scale;
}

export interface LocalMixInput {
  prompt: string;
  values: BlanketValues;
  songGain: number;
  drumGain: number;
  analysis?: MixAnalysis | null;
}

export interface MixSuggestion {
  values: BlanketValues;
  songGain?: number;
  drumGain?: number;
  explanation: string;
}

export interface LocalMixResult extends MixSuggestion {
  matched: string[]; // concept ids that fired, in prompt order (with "-" prefix when negated)
}

const words = (...ws: string[]) => new RegExp(`\\b(?:${ws.join('|')})\\b`);

// ---- analysis-aware scaling helpers -------------------------------------

const db10 = (...dbs: number[]) => 10 * Math.log10(dbs.reduce((s, d) => s + Math.pow(10, d / 10), 0));
const lowShare = (d: AudioDescriptors) => db10(d.bands.sub, d.bands.low);

/**
 * Generic "already there" scaler: `x` is a measurement, `hi`/`lo` the levels
 * where it counts as already a lot / very little of the quality being added
 * (sign = +1) or removed (sign = −1).
 */
function along(x: number, lo: number, hi: number, sign: number, notes: { hi: string; lo: string }): Scale {
  if (sign > 0) {
    if (x >= hi) return { k: 0.5, note: notes.hi };
    if (x <= lo) return { k: 1.3, note: notes.lo };
  } else {
    if (x <= lo) return { k: 0.5, note: notes.lo };
    if (x >= hi) return { k: 1.3, note: notes.hi };
  }
  return { k: 1 };
}

const brightScale = (a: MixAnalysis, sign: number) =>
  along(a.drums.centroidHz, 1800, 4500, sign, { hi: 'the take is already bright', lo: 'the take is dull' });
const airScale = (a: MixAnalysis, sign: number) =>
  along(a.drums.bands.air, -26, -12, sign, { hi: 'plenty of top end already', lo: 'little top end to start with' });
const lowScale = (a: MixAnalysis, sign: number) =>
  along(lowShare(a.drums), -12, -4, sign, { hi: 'lots of low end', lo: 'the low end is already lean' });
const lowMidScale = (a: MixAnalysis, sign: number) =>
  along(a.drums.bands.lowMid, -14, -6, sign, { hi: 'heavy low-mids', lo: 'low-mids are already clean' });
const ringScale = (a: MixAnalysis, sign: number) =>
  along(a.drums.decayMs, 90, 250, sign, { hi: 'hits ring out long', lo: 'hits are already short' });
const crestScale = (a: MixAnalysis, sign: number) =>
  along(a.drums.crestDb, 12, 20, sign, { hi: 'the take is very dynamic', lo: 'the take is already squashed' });
const noiseScale = (a: MixAnalysis, dir: number) =>
  along(a.drums.rmsDb - a.drums.noiseFloorDb, 25, 45, -dir, {
    hi: 'the background is already quiet',
    lo: 'there is an audible noise floor',
  });

// ---- vocabulary ---------------------------------------------------------

const CONCEPTS: Concept[] = [
  // whole-state operations
  {
    id: 'reset',
    more: 'reset to flat',
    less: 'reset to flat',
    patterns: [words('reset', 'start over', 'from scratch', 'bypass', 'unprocessed', 'no processing', 'no effects', 'clean slate')],
    delta: {},
    op: 'reset',
  },
  {
    id: 'natural',
    more: 'more natural',
    less: 'more processed',
    patterns: [words('natural', 'naturally', 'transparent', 'realistic', 'honest', 'organic')],
    delta: { naturalness: 0.3 },
    op: 'natural',
  },

  // eras / genres (multi-word phrases first; overlapping shorter matches are dropped)
  {
    id: '90s-rock',
    more: '90s rock',
    less: 'less 90s rock',
    patterns: [/\b(?:90s|1990s) (?:rock|grunge|alt|alternative)\b/, words('grunge')],
    delta: { punch: 0.35, attack: 0.25, kick_presence: 0.2, dynamic_range: 0.3, depth: 0.15, boxiness: 0.2, sustain: 0.15 },
  },
  {
    id: '80s',
    more: '80s',
    less: 'less 80s',
    patterns: [words('80s', '1980s', 'gated reverb', 'gated')],
    delta: { depth: 0.5, punch: 0.3, brightness: 0.2, width: 0.25, sustain: 0.3, dynamic_range: 0.25 },
  },
  {
    id: '70s',
    more: '70s',
    less: 'less 70s',
    patterns: [words('70s', '1970s', 'seventies', '60s', '1960s', 'sixties', 'motown', 'soul')],
    delta: { warmth: 0.35, brightness: -0.25, air: -0.2, sustain: 0.3, depth: -0.3, roominess: 0.15, detail: 0.2 },
  },
  {
    id: 'vintage',
    more: 'vintage',
    less: 'less vintage',
    patterns: [words('vintage', 'old school', 'oldschool', 'retro', 'classic', 'analog', 'analogue', 'tape', 'vinyl', 'old')],
    delta: { warmth: 0.35, brightness: -0.25, air: -0.2, depth: 0.2, detail: 0.2 },
  },
  {
    id: 'lofi',
    more: 'lo-fi',
    less: 'less lo-fi',
    patterns: [words('lofi', 'lo fi', 'crushed', 'dirty', 'gritty', 'grimy', 'distorted', 'saturated', 'trashy', 'garage')],
    delta: { warmth: 0.6, brightness: -0.35, air: -0.4, high_pass_rumble: 0.35, presence: 0.2, naturalness: 0.3 },
  },
  {
    id: 'modern',
    more: 'modern / polished',
    less: 'less polished',
    patterns: [words('modern', 'polished', 'hifi', 'hi fi', 'produced', 'pro', 'professional', 'radio', 'pop', 'slick', 'studio'), /\bclean(?:er)?\b(?! up)/],
    delta: { attack: 0.2, air: 0.2, punch: 0.2, consistency: 0.2, boxiness: 0.15, high_pass_rumble: 0.15, naturalness: 0.4 },
  },
  {
    id: 'metal',
    more: 'metal',
    less: 'less metal',
    patterns: [words('metal', 'heavy', 'djent', 'hardcore')],
    delta: { attack: 0.4, punch: 0.3, consistency: 0.4, dynamic_range: 0.4, boxiness: 0.3, kick_presence: 0.3, sustain: 0.2, naturalness: 0.5 },
  },
  {
    id: 'jazz',
    more: 'jazz',
    less: 'less jazz',
    patterns: [words('jazz', 'jazzy', 'brushes', 'acoustic', 'folk')],
    delta: { depth: 0.3, warmth: 0.2, detail: 0.3, punch: -0.2, dynamic_range: -0.3, consistency: -0.2 },
  },
  {
    id: 'hiphop',
    more: 'hip-hop',
    less: 'less hip-hop',
    patterns: [words('hip hop', 'hiphop', 'boom bap', 'boombap', 'rap', 'trap')],
    delta: { kick_presence: 0.4, punch: 0.3, warmth: 0.3, sustain: 0.2, snare_body: 0.2 },
  },
  {
    id: 'funk',
    more: 'funk',
    less: 'less funk',
    patterns: [words('funk', 'funky', 'disco')],
    delta: { sustain: 0.35, depth: -0.3, punch: 0.3, attack: 0.2, detail: 0.3 },
  },
  {
    id: 'punk',
    more: 'punk',
    less: 'less punk',
    patterns: [words('punk')],
    delta: { attack: 0.3, brightness: 0.2, dynamic_range: 0.35, depth: 0.15, warmth: 0.2 },
  },
  {
    id: 'phone',
    more: 'phone / telephone sound',
    less: 'less phone-like',
    patterns: [words('phone', 'telephone', 'walkie talkie', 'megaphone', 'am radio', 'transistor')],
    delta: { high_pass_rumble: 0.6, fullness: -0.3, kick_presence: -0.35, air: -0.4, presence: 0.3, dynamic_range: 0.3 },
  },
  {
    id: 'rock',
    more: 'rock',
    less: 'less rock',
    patterns: [words('rock', 'rocky', 'indie')],
    delta: { punch: 0.25, kick_presence: 0.15, snare_body: 0.15, depth: 0.15, dynamic_range: 0.2 },
  },

  // tone
  {
    id: 'warm',
    more: 'warmer',
    less: 'less warm',
    patterns: [words('warm', 'warmer', 'warmth', 'cozy', 'round', 'rounder', 'rounded')],
    delta: { warmth: 0.35, fullness: 0.2, brightness: -0.15, harshness: 0.2 },
  },
  {
    id: 'dark',
    more: 'darker',
    less: 'less dark',
    patterns: [words('dark', 'darker', 'darken', 'dull', 'duller', 'muffled', 'mellow', 'mellower')],
    delta: { brightness: -0.35, air: -0.25, harshness: 0.2 },
    scale: (a, d) => brightScale(a, -d),
  },
  {
    id: 'bright',
    more: 'brighter',
    less: 'less bright',
    patterns: [words('bright', 'brighter', 'brighten', 'brightness', 'sizzle', 'sizzly', 'shiny', 'shinier')],
    delta: { brightness: 0.35, air: 0.25, attack: 0.15 },
    scale: (a, d) => brightScale(a, d),
  },
  {
    id: 'air',
    more: 'more air',
    less: 'less air',
    patterns: [words('air', 'airy', 'airier', 'open', 'sparkle', 'sparkly', 'shimmer', 'top end', 'highs', 'treble')],
    delta: { air: 0.4, brightness: 0.1 },
    scale: (a, d) => airScale(a, d),
  },
  {
    id: 'harsh',
    more: 'more bite',
    less: 'less harsh',
    patterns: [words('harsh', 'harshness', 'brittle', 'piercing', 'shrill', 'tinny', 'fizzy', 'ice pick', 'abrasive')],
    delta: { harshness: -0.35, presence: 0.15 },
    problem: true,
    scale: (a, d) => brightScale(a, d),
  },
  {
    id: 'bite',
    more: 'more bite',
    less: 'less bite',
    patterns: [words('bite', 'biting', 'aggressive', 'edge', 'edgy', 'edgier', 'sharp', 'sharper', 'attitude')],
    delta: { harshness: -0.3, presence: 0.25, attack: 0.15 },
    scale: (a, d) => brightScale(a, d),
  },
  {
    id: 'crisp',
    more: 'crisper',
    less: 'less crisp',
    patterns: [words('crisp', 'crisper', 'crispy', 'snappy', 'snappier', 'snap', 'defined', 'definition', 'articulate', 'clicky', 'click', 'stick')],
    delta: { attack: 0.35, detail: 0.2, air: 0.1 },
  },
  {
    id: 'soft',
    more: 'softer',
    less: 'less soft',
    patterns: [words('soft', 'softer', 'gentle', 'gentler', 'smooth', 'smoother', 'silky', 'easy')],
    delta: { attack: -0.25, harshness: 0.25, brightness: -0.1, punch: -0.15 },
  },

  // low end / body
  {
    id: 'boomy',
    more: 'boomier',
    less: 'less boomy',
    patterns: [words('boomy', 'boom', 'boomier', 'boominess', 'bass heavy', 'bassy', 'rumble', 'rumbly', 'woofy', 'tubby', 'flabby')],
    delta: { kick_presence: 0.35, high_pass_rumble: -0.25 },
    problem: true,
    scale: (a, d) => lowScale(a, d),
  },
  {
    id: 'muddy',
    more: 'muddier',
    less: 'less muddy',
    patterns: [words('mud', 'muddy', 'muddier', 'murky', 'murk', 'cloudy', 'congested', 'mush', 'mushy')],
    delta: { boxiness: -0.35, snare_body: 0.15, high_pass_rumble: -0.1 },
    problem: true,
    scale: (a, d) => lowMidScale(a, d),
  },
  {
    id: 'boxy',
    more: 'boxier',
    less: 'less boxy',
    patterns: [words('boxy', 'boxier', 'boxiness', 'box', 'cardboard', 'hollow', 'honky', 'honk', 'papery', 'nasal')],
    delta: { boxiness: -0.4, resonance: -0.2 },
    problem: true,
    scale: (a, d) => lowMidScale(a, d),
  },
  {
    id: 'thin',
    more: 'thinner',
    less: 'less thin',
    patterns: [words('thin', 'thinner', 'weak', 'weedy', 'wimpy', 'lightweight', 'puny')],
    delta: { fullness: -0.3, snare_body: -0.25, kick_presence: -0.2 },
    problem: true,
    scale: (a, d) => lowScale(a, -d),
  },
  {
    id: 'full',
    more: 'fuller',
    less: 'less full',
    patterns: [words('full', 'fuller', 'fullness', 'thick', 'thicker', 'beefy', 'beefier', 'meaty', 'meatier', 'body', 'weight', 'weighty', 'heft', 'chunky')],
    delta: { fullness: 0.35, snare_body: 0.25, kick_presence: 0.15 },
    scale: (a, d) => lowScale(a, d),
  },
  {
    id: 'big',
    more: 'bigger',
    less: 'smaller',
    patterns: [words('big', 'bigger', 'huge', 'massive', 'epic', 'fat', 'fatter', 'larger', 'giant', 'arena', 'stadium', 'cinematic')],
    delta: { fullness: 0.3, kick_presence: 0.25, depth: 0.25, width: 0.25, punch: 0.15 },
  },

  // dynamics
  {
    id: 'punchy',
    more: 'punchier',
    less: 'less punchy',
    patterns: [words('punch', 'punchy', 'punchier', 'impact', 'hard hitting', 'hit harder', 'slam', 'slamming', 'thump', 'thumpy', 'knock')],
    delta: { punch: 0.4, attack: 0.2, kick_presence: 0.15 },
    scale: (a, d) => crestScale(a, d),
  },
  {
    id: 'compressed',
    more: 'more compressed',
    less: 'less compressed',
    patterns: [words('compressed', 'compression', 'compress', 'squashed', 'squash', 'smashed', 'squeezed', 'crushed', 'loud', 'loudness', 'dense', 'glued', 'glue')],
    delta: { dynamic_range: 0.4, consistency: 0.25, punch: 0.15, naturalness: 0.5 },
    scale: (a, d) => crestScale(a, -d),
  },
  {
    id: 'dynamic',
    more: 'more dynamic',
    less: 'less dynamic',
    patterns: [words('dynamic', 'dynamics', 'uncompressed', 'breathing', 'breathe')],
    delta: { dynamic_range: -0.4, consistency: -0.25, detail: 0.15 },
    scale: (a, d) => crestScale(a, d),
  },
  {
    id: 'even',
    more: 'more even',
    less: 'less even',
    patterns: [words('more even', 'evener', 'evened out', 'consistent', 'steady', 'controlled', 'uneven', 'inconsistent')],
    delta: { consistency: 0.4, dynamic_range: 0.15 },
  },
  {
    id: 'detail',
    more: 'more detail',
    less: 'less detail',
    patterns: [words('ghost notes', 'ghost', 'detail', 'detailed', 'nuance', 'nuanced', 'articulation')],
    delta: { detail: 0.4 },
  },
  {
    id: 'pumping',
    more: 'more pumping',
    less: 'less pumping',
    patterns: [words('pumping', 'pumpy', 'pump', 'breathy')],
    delta: { pumping: -0.4 },
    problem: true,
  },

  // room / space
  {
    id: 'dry',
    more: 'drier',
    less: 'less dry',
    patterns: [words('dry', 'drier', 'dryer', 'dead', 'deader', 'close', 'closer', 'intimate', 'in your face', 'upfront', 'up front')],
    delta: { roominess: 0.25, depth: -0.4, sustain: 0.2 },
    scale: (a, d) => ringScale(a, -d),
  },
  {
    id: 'tight',
    more: 'tighter',
    less: 'looser',
    patterns: [words('tight', 'tighter', 'focused', 'short', 'shorter', 'choked')],
    delta: { sustain: 0.35, roominess: 0.1, boxiness: 0.15, high_pass_rumble: 0.15, punch: 0.15 },
    scale: (a, d) => ringScale(a, -d),
  },
  {
    id: 'roomy',
    more: 'more room',
    less: 'less room',
    patterns: [words('room', 'roomy', 'roomier', 'roominess', 'ambient', 'ambience', 'ambiance', 'spacious', 'space', 'reverb', 'reverby', 'verb', 'live', 'distant', 'further back', 'echo', 'wet', 'wetter', 'hall', 'loose', 'looser')],
    delta: { depth: 0.4, roominess: -0.25, sustain: -0.25 },
    scale: (a, d) => ringScale(a, d),
  },
  {
    id: 'ringy',
    more: 'more ring',
    less: 'less ring',
    patterns: [words('ring', 'ringy', 'ringing', 'rings', 'resonant', 'resonance', 'resonances', 'boingy', 'overtones', 'sustain', 'tails')],
    delta: { resonance: -0.4, sustain: -0.2 },
    problem: true,
    scale: (a, d) => ringScale(a, d),
  },
  {
    id: 'wide',
    more: 'wider',
    less: 'narrower',
    patterns: [words('wide', 'wider', 'width', 'stereo', 'spread')],
    delta: { width: 0.4 },
  },
  {
    id: 'narrow',
    more: 'narrower',
    less: 'wider',
    patterns: [words('narrow', 'narrower', 'mono')],
    delta: { width: -0.4 },
  },

  // clean-up / fit
  {
    id: 'noisy',
    more: 'noisier',
    less: 'less noise',
    patterns: [words('noise', 'noisy', 'hiss', 'hissy', 'hum', 'buzz', 'background', 'bleed')],
    delta: { denoise: -0.3 },
    problem: true,
    scale: (a, d) => noiseScale(a, d),
  },
  {
    id: 'clipping',
    more: 'more clipping',
    less: 'less clipping',
    patterns: [words('clipping', 'clipped', 'clip', 'distortion', 'crackle', 'crackly')],
    delta: { clipping: -0.5, naturalness: -0.3 },
    problem: true,
  },
  {
    id: 'present',
    more: 'more present',
    less: 'further back',
    patterns: [words('cut through', 'cuts through', 'present', 'presence', 'forward', 'in front', 'stand out', 'pop out', 'audible')],
    delta: { presence: 0.35, attack: 0.15, depth: -0.2 },
    scale: (a, d) => {
      if (!a.song || d < 0) return { k: 1 };
      return a.song.bands.presence > a.drums.bands.presence + 3
        ? { k: 1.3, note: 'the song is busy in the presence range' }
        : { k: 1 };
    },
  },
  {
    id: 'fit',
    more: 'matched to the song',
    less: 'matched to the song',
    patterns: [
      /\b(?:fit|fits|match|matches|blend|blends|sit|sits|glue|gel|belong)\b.*\b(?:song|mix|track|record|band|music)\b/,
      words('sit in the mix', 'blend in', 'fit in'),
    ],
    delta: (a) => {
      if (!a?.song) return { naturalness: 0.2, presence: 0.1 };
      const ratio = a.song.centroidHz / Math.max(1, a.drums.centroidHz);
      const tilt = ratio > 1.3 ? 0.25 : ratio < 0.77 ? -0.25 : 0;
      const roomGap = a.song.decayMs - a.drums.decayMs;
      return {
        brightness: tilt,
        air: tilt * 0.6,
        depth: roomGap > 80 ? 0.25 : 0,
        roominess: roomGap < -80 ? 0.2 : 0,
        consistency: 0.15,
      };
    },
  },
  {
    id: 'kick',
    more: 'more kick',
    less: 'less kick',
    patterns: [words('kick', 'kicks', 'bass drum', 'low end', 'bottom', 'bottom end', 'lows', 'bass')],
    delta: { kick_presence: 0.4, fullness: 0.1 },
    scale: (a, d) => lowScale(a, d),
  },
  {
    id: 'snare',
    more: 'more snare',
    less: 'less snare',
    patterns: [words('snare', 'snares', 'crack', 'backbeat', 'mids')],
    delta: { snare_body: 0.35, attack: 0.1 },
  },
  {
    id: 'cymbals',
    more: 'more cymbals',
    less: 'softer cymbals',
    patterns: [words('cymbal', 'cymbals', 'hats', 'hi hat', 'hi hats', 'hihat', 'hihats', 'crash', 'ride', 'overheads', 'wash')],
    delta: { air: 0.3, brightness: 0.1, harshness: -0.15 },
  },
];

// ---- prompt parsing -----------------------------------------------------

const LESS = /\b(?:less|fewer|reduce|reduced|lower|cut(?! through)|tame|remove|kill|lose|no|without|not|isn't|isnt|don't|dont|minus|too|dial back|dial down|back off|get rid of|fix|clean up|turn down|pull back|decrease|eliminate|avoid|stop)\b/g;
const MORE = /\b(?:more|add|extra|boost|increase|bring out|bring up|push|enhance|make it|give it|plus|turn up|emphasize|emphasise|accentuate|lots of|tons of|heaps of|lacks|lacking|missing|needs|need|want|wants)\b/g;
const INTENSITY: [RegExp, number][] = [
  [/\b(?:a (?:tiny|wee) bit|a hair|barely|tiny bit|just a touch|ever so slightly)\b/, 0.3],
  [/\b(?:a bit|a little|a touch|slightly|subtly|somewhat|kinda|kind of|a tad|tad|gently|mildly|not too|little)\b/, 0.5],
  [/\b(?:way|much|a lot|lots|really|very|super|seriously|heaps|tons|far|properly|so much|significantly)\b/, 1.7],
  [/\b(?:extremely|massively|insanely|hugely|crazy|ridiculously|maximum|max|totally|completely|all the way)\b/, 2.2],
];

const GAIN_STRONG = /\b(?:louder|quieter|too loud|too quiet|too soft|buried|drowned out|volume|level|turn(?: \w+){0,3} (?:up|down)|(?:up|down) in the mix)\b/;
const GAIN_WEAK = /\b(?:raise|lower|boost|reduce|more|less|up|down|higher|bring(?: \w+){0,3} (?:up|down))\b/;
const GAIN_UP = /\b(?:louder|too quiet|too soft|buried|drowned out|turn(?: \w+){0,3} up|up in the mix|raise|boost|more|higher|bring(?: \w+){0,3} up)\b/;
const GAIN_DOWN = /\b(?:quieter|too loud|turn(?: \w+){0,3} down|down in the mix|lower|less|reduce|bring(?: \w+){0,3} down)\b/;
const SONG_WORDS = /\b(?:song|music|track|backing|band|instrumental|the rest|guitars?|vocals?)\b/;
const DRUM_WORDS = /\b(?:drums?|kit|drumming|take|recording|my playing)\b/;
const GAIN_STEP = 0.15;

function normalize(prompt: string): string {
  return prompt
    .toLowerCase()
    .replace(/[’‘`]/g, "'")
    .replace(/\b(\d0)'s\b/g, '$1s')
    .replace(/\bnineties\b/g, '90s')
    .replace(/\beighties\b/g, '80s')
    .replace(/\bseventies\b/g, '70s')
    .replace(/\bsixties\b/g, '60s')
    .replace(/\b'(\d0)s\b/g, '$1s')
    .replace(/(\w)-(\w)/g, '$1 $2') // lo-fi → lo fi, hi-hat → hi hat
    .replace(/&/g, ' and ')
    .replace(/\s+/g, ' ');
}

const CLAUSE_SPLIT = /[,;.!?\n]+|\b(?:and|but|while|plus|yet|though|although|also|then|whereas)\b/;

interface Hit {
  concept: Concept;
  start: number;
  end: number;
}

function findConcepts(clause: string): Hit[] {
  const hits: Hit[] = [];
  for (const concept of CONCEPTS) {
    for (const re of concept.patterns) {
      const g = new RegExp(re.source, 'g');
      let m: RegExpExecArray | null;
      while ((m = g.exec(clause))) {
        hits.push({ concept, start: m.index, end: m.index + m[0].length });
        if (m[0].length === 0) g.lastIndex++;
      }
    }
  }
  // Longest match wins where matches overlap; one hit per concept per clause.
  hits.sort((a, b) => b.end - b.start - (a.end - a.start) || a.start - b.start);
  const kept: Hit[] = [];
  for (const h of hits) {
    if (kept.some((k) => h.start < k.end && k.start < h.end)) continue;
    if (kept.some((k) => k.concept.id === h.concept.id)) continue;
    kept.push(h);
  }
  return kept.sort((a, b) => a.start - b.start);
}

function lastMatchBefore(re: RegExp, clause: string, pos: number): number {
  let last = -1;
  const g = new RegExp(re.source, 'g');
  let m: RegExpExecArray | null;
  while ((m = g.exec(clause)) && m.index < pos) last = m.index;
  return last;
}

function directionFor(clause: string, hit: Hit): Dir {
  const less = lastMatchBefore(LESS, clause, hit.start);
  const more = lastMatchBefore(MORE, clause, hit.start);
  if (less < 0 && more < 0) return hit.concept.problem ? -1 : 1;
  // "not bright enough" / "isn't punchy enough": a lack, so add it.
  if (less > more && /\benough\b/.test(clause.slice(hit.end))) return 1;
  const negated = less > more;
  // "not too harsh" / "less boxy": a negated problem is still a fix (−1);
  // "more boxy" on a problem word means add it (+1).
  return negated ? -1 : 1;
}

function intensityFor(clause: string): number {
  for (const [re, k] of INTENSITY) if (re.test(clause)) return k;
  return 1;
}

const INTENSITY_WORD = (k: number) => (k <= 0.3 ? 'a touch ' : k < 1 ? 'a bit ' : k > 2 ? 'much much ' : k > 1 ? 'much ' : '');

function gainFor(clause: string, hasConcepts: boolean): { target: 'songGain' | 'drumGain'; dir: Dir } | null {
  const song = clause.search(SONG_WORDS);
  const drums = clause.search(DRUM_WORDS);
  const strong = GAIN_STRONG.test(clause);
  // Weak verbs ("more song", "lower the drums") count only with a target and
  // no sound word in the clause, so "lower the boom" stays an EQ request.
  if (!strong && (hasConcepts || (song < 0 && drums < 0) || !GAIN_WEAK.test(clause))) return null;
  const up = lastMatchBefore(GAIN_UP, clause, Infinity);
  const down = lastMatchBefore(GAIN_DOWN, clause, Infinity);
  if (up < 0 && down < 0) return null;
  return { target: pickTarget(song, drums), dir: up > down ? 1 : -1 };
}

const pickTarget = (song: number, drums: number): 'songGain' | 'drumGain' =>
  song >= 0 && (drums < 0 || song < drums) ? 'songGain' : 'drumGain';

const MAX_TOTAL_DELTA = 0.8;

/** Interpret `prompt` against the current mix. Deterministic; no I/O. */
export function interpretLocally(input: LocalMixInput): LocalMixResult {
  const analysis = input.analysis ?? null;
  const text = normalize(input.prompt);
  const clauses = text.split(CLAUSE_SPLIT).map((c) => c.trim()).filter(Boolean);

  let base: BlanketValues = Object.fromEntries(
    BLANKET_TERM_KEYS.map((k) => [k, effectiveValue(k, input.values[k])]),
  ) as BlanketValues;
  const total: Partial<Record<BlanketTerm, number>> = {};
  const gains = { songGain: input.songGain, drumGain: input.drumGain };
  let gainsTouched = { songGain: false, drumGain: false };
  const matched: string[] = [];
  const parts: string[] = [];
  const notes = new Set<string>();

  for (const clause of clauses) {
    const hits = findConcepts(clause);
    const k = intensityFor(clause);
    // Gain requests that aren't also sound words ("drums louder", "song down a bit").
    const gain = gainFor(clause, hits.length > 0);
    if (gain) {
      gains[gain.target] = clampGain(gains[gain.target] + gain.dir * GAIN_STEP * k);
      gainsTouched = { ...gainsTouched, [gain.target]: true };
      matched.push(`${gain.dir < 0 ? '-' : ''}${gain.target}`);
      parts.push(`${INTENSITY_WORD(k)}${gain.dir > 0 ? 'louder' : 'quieter'} ${gain.target === 'songGain' ? 'song' : 'drums'}`);
    }

    for (const hit of hits) {
      const c = hit.concept;
      // "the song is too loud" is a level request, not "less compressed".
      if (gain && c.id === 'compressed' && /\bloud\b/.test(clause.slice(hit.start, hit.end))) continue;
      const dir = directionFor(clause, hit);
      matched.push(`${dir < 0 ? '-' : ''}${c.id}`);
      if (c.op === 'reset') {
        base = Object.fromEntries(BLANKET_TERM_KEYS.map((t) => [t, 0])) as BlanketValues;
        for (const t of Object.keys(total)) delete total[t as BlanketTerm];
        parts.push(c.more);
        continue;
      }
      if (c.op === 'natural' && dir < 0) {
        parts.push(c.less);
        continue;
      }
      if (c.op === 'natural') {
        const pull = Math.min(0.8, 0.4 * k);
        base = Object.fromEntries(BLANKET_TERM_KEYS.map((t) => [t, base[t] * (1 - pull)])) as BlanketValues;
        for (const t of Object.keys(total)) total[t as BlanketTerm]! *= 1 - pull;
      }
      const s = c.scale && analysis ? c.scale(analysis, dir) : { k: 1 };
      if (s.note) notes.add(s.note);
      const delta = typeof c.delta === 'function' ? c.delta(analysis) : c.delta;
      const sign = dir;
      for (const [t, d] of Object.entries(delta) as [BlanketTerm, number][]) {
        total[t] = (total[t] ?? 0) + d * sign * k * s.k;
      }
      parts.push(`${INTENSITY_WORD(k)}${dir > 0 ? c.more : c.less}${s.note ? ` (${s.k < 1 ? 'gently' : 'more'}: ${s.note})` : ''}`);
    }
  }

  // Width does nothing on a mono take; say so rather than move a dead knob.
  if (analysis && analysis.drums.stereoWidth == null && total.width) {
    delete total.width;
    notes.add('mono take');
    parts.push('(width skipped: the take is mono)');
  }

  const values = Object.fromEntries(
    BLANKET_TERM_KEYS.map((t) => {
      const d = Math.max(-MAX_TOTAL_DELTA, Math.min(MAX_TOTAL_DELTA, total[t] ?? 0));
      return [t, clampKnob(t, base[t] + d)];
    }),
  ) as BlanketValues;

  const explanation = matched.length
    ? `Offline interpreter: ${parts.join(', ')}.`
    : 'The offline interpreter didn’t recognise any sound words. Try e.g. “warmer”, “less boomy”, “more room”, “punchy and dry”, “drums louder”.';

  return {
    values,
    ...(gainsTouched.songGain ? { songGain: gains.songGain } : {}),
    ...(gainsTouched.drumGain ? { drumGain: gains.drumGain } : {}),
    explanation,
    matched,
  };
}

/** Every concept id the interpreter knows (for docs / tests). */
export const LOCAL_VOCABULARY = CONCEPTS.map((c) => c.id);
