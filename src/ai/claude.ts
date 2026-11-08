// Prompt → knob values with Claude, called straight from the phone with the
// user's own Anthropic API key (there is no server). The request carries the
// prompt, the current knobs, the knob catalog, the presets as examples and
// the analysis descriptors; structured outputs (output_config.format with a
// JSON schema) make the reply machine-parseable, and everything it returns is
// validated and clamped before it touches the mix.

import type Anthropic from '@anthropic-ai/sdk';
import { BLANKET_TERMS, BLANKET_TERM_KEYS, type BlanketValues } from '../dsp/blanketTerms';
import { INTENSITY } from '../dsp/blanketChain';
import { PRESETS } from '../dsp/presets';
import { roundDescriptors, type MixAnalysis } from './analyze';
import { clampGain, GAIN_RANGE, knobRange, sanitizeValues } from './knobs';
import type { MixSuggestion } from './localMix';

export type ClaudeModel = 'claude-opus-5-5' | 'claude-haiku-5-5';

export const DEFAULT_MODEL: ClaudeModel = 'claude-opus-5-5';
export const MODEL_OPTIONS: { id: ClaudeModel; label: string }[] = [
  { id: 'claude-opus-5-5', label: 'Opus 5.5 (best)' },
  { id: 'claude-haiku-5-5', label: 'Haiku 5.5 (faster, cheaper)' },
];

// Server-side refusal fallback ("default" routing) — supported on Opus, not on Haiku.
const FALLBACK_BETA = 'server-side-fallback-2026-07-01';
const supportsFallbacks = (m: ClaudeModel) => m !== 'claude-haiku-5-5';

export interface ClaudeMixInput {
  prompt: string;
  values: BlanketValues;
  songGain: number;
  drumGain: number;
  originalDrums?: number;
  hasStems?: boolean;
  analysis?: MixAnalysis | null;
}

export type ClaudeErrorKind =
  | 'no_key'
  | 'bad_key'
  | 'billing'
  | 'network'
  | 'rate_limit'
  | 'overloaded'
  | 'refusal'
  | 'bad_response'
  | 'other';

export class ClaudeMixError extends Error {
  constructor(
    public kind: ClaudeErrorKind,
    message: string,
  ) {
    super(message);
    this.name = 'ClaudeMixError';
  }
}

/** Failures where the offline interpreter is a sensible stand-in. */
export const isTransient = (k: ClaudeErrorKind) => k === 'network' || k === 'rate_limit' || k === 'overloaded';

// ---- request ------------------------------------------------------------

// What each knob's slider value means at render (from src/dsp/README.md).
const CALIBRATION: Record<string, string> = {
  volume: 'track level, about ±12 dB at ±1',
  high_pass_rumble: `high-pass cutoff ≈ 40 Hz + value·${INTENSITY}·40 Hz (0.5 ≈ 100 Hz; 1.0 = 160 Hz removes the kick fundamental)`,
  denoise: 'spectral noise reduction; saturates at ≈0.34, so 0.35 is the max',
  kick_presence: 'peak EQ at 90 Hz',
  snare_body: 'peak EQ at 200 Hz',
  boxiness: 'positive = dip at 350 Hz (less box/mud); negative adds it back',
  attack: 'peak EQ at 4 kHz',
  harshness: 'positive = dip at 6 kHz (smoother); negative adds bite',
  air: 'high shelf at 10 kHz',
  brightness: 'high shelf at 8 kHz (negative darkens)',
  resonance: 'notches up to 5 detected ringing peaks',
  dynamic_range: 'downward compression (4:1 at thr −18 dB per unit)',
  detail: 'upward compression, lifts low-level detail and ghost notes',
  punch: 'slow-attack compression that accentuates transients',
  sustain: 'noise gate: higher = shorter tails, less bleed',
  consistency: 'fast 2:1 compression that evens out hits',
  pumping: 'long-release compression that smooths pumping',
  roominess: 'reduces room reflections; saturates at ≈0.34, so 0.35 is the max',
  width: 'stereo side boost (no effect on a mono take)',
  depth: 'small-room reverb send (pushes the kit back)',
  warmth: 'tanh saturation',
  presence: 'harmonic excitation on 2–8 kHz',
  fullness: '+200 Hz and gentle saturation',
  clipping: 'softens already-clipped peaks',
  naturalness: 'brick-wall limiter guard at −3 dBFS, placed last',
};

export function knobCatalog() {
  return BLANKET_TERM_KEYS.map((name) => {
    const info = BLANKET_TERMS[name];
    const { min, max } = knobRange(name);
    return {
      name,
      label: info.label,
      category: info.category,
      bipolar: info.bipolar,
      range: [min, max],
      description: info.description,
      dsp: CALIBRATION[name],
    };
  });
}

/** Stable system prompt (cache-friendly: no per-request content). */
export function buildSystemPrompt(): string {
  const presets = PRESETS.map((p) => ({ id: p.id, label: p.label, description: p.description, values: p.values }));
  return [
    'You are the mix assistant in Lumber, an iPhone app where a drummer records drums over a song.',
    'The user describes the drum sound they want. You set the drum processing knobs ("Blanket" DSP) and, if useful, the song/drum faders.',
    '',
    'How to work:',
    '- Start from the current knob values and change what the request calls for; keep unrelated knobs as they are unless the request implies a fresh start.',
    '- Use the analysis descriptors to judge where the audio already is. Examples: if the drum take is already bright (high centroid, strong presence/air bands), "brighter" needs only a small move; long decayMs means the take already rings or has room; low crestDb means it is already compressed; a mono take (stereoWidth null) makes width pointless.',
    '- Compare the drums with the song (or its drumless stem) when the request mentions fitting, blending or cutting through.',
    `- Knob values are slider units. At render each is multiplied by INTENSITY = ${INTENSITY}, so 0.3 is already a clear move and 1.0 is heavy. Typical useful values are 0.1–0.6; the presets below are good calibration.`,
    '- Bipolar knobs range −1..1 (negative is the opposite move). One-directional knobs range 0..1. Do not exceed the listed range.',
    `- songGain and drumGain are linear faders ${GAIN_RANGE.min}–${GAIN_RANGE.max} (1 = unity). Return null to leave a fader alone; only change them when the request is about level or balance.`,
    '- explanation: one or two short sentences for the user, plain English, naming the main moves and why (mention the analysis when it changed your decision). No knob dumps.',
    '- Return the complete set of knob values, every knob, in the JSON format requested.',
    '',
    'Knob catalog (JSON):',
    JSON.stringify(knobCatalog()),
    '',
    'Presets (sparse knob maps; unlisted knobs are 0):',
    JSON.stringify(presets),
  ].join('\n');
}

export function buildUserMessage(input: ClaudeMixInput): string {
  const a = input.analysis;
  const payload = {
    request: input.prompt.trim(),
    current: {
      values: input.values,
      songGain: input.songGain,
      drumGain: input.drumGain,
      ...(input.hasStems ? { originalDrumsBlend: input.originalDrums ?? 0 } : {}),
    },
    analysis: a
      ? {
          drums: roundDescriptors(a.drums),
          song: a.song ? roundDescriptors(a.song) : null,
          songSource: a.song ? (a.songIsDrumless ? 'drumless stem (original drums removed)' : 'full song incl. its original drums') : 'unavailable',
          notes: 'Levels in dBFS; bands = share of spectral energy per band in dB (sub 20–60, low 60–250, lowMid 250–800, mid 0.8–2.5k, presence 2.5–6k, air 6–20k Hz); decayMs = median time for a hit to fall 20 dB; stereoWidth = side/(mid+side) energy or null for mono.',
        }
      : null,
  };
  return JSON.stringify(payload);
}

const nullableNumber = { anyOf: [{ type: 'number' }, { type: 'null' }] };

export const OUTPUT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['values', 'songGain', 'drumGain', 'explanation'],
  properties: {
    values: {
      type: 'object',
      additionalProperties: false,
      required: [...BLANKET_TERM_KEYS],
      properties: Object.fromEntries(
        BLANKET_TERM_KEYS.map((k) => {
          const { min, max } = knobRange(k);
          return [k, { type: 'number', description: `${BLANKET_TERMS[k].label}, ${min}..${max}` }];
        }),
      ),
    },
    songGain: { ...nullableNumber, description: `song fader ${GAIN_RANGE.min}..${GAIN_RANGE.max}, or null to keep` },
    drumGain: { ...nullableNumber, description: `drum fader ${GAIN_RANGE.min}..${GAIN_RANGE.max}, or null to keep` },
    explanation: { type: 'string', description: 'one or two sentences for the user' },
  },
} as const;

export function buildRequest(
  input: ClaudeMixInput,
  model: ClaudeModel = DEFAULT_MODEL,
): Anthropic.Beta.Messages.MessageCreateParamsNonStreaming {
  return {
    model,
    max_tokens: 16000,
    // Thinking stays adaptive (the default on these models); effort is set
    // explicitly because the default differs by model.
    output_config: {
      effort: 'medium',
      format: { type: 'json_schema', schema: OUTPUT_SCHEMA as unknown as Record<string, unknown> },
    },
    cache_control: { type: 'ephemeral' },
    system: buildSystemPrompt(),
    messages: [{ role: 'user', content: buildUserMessage(input) }],
    ...(supportsFallbacks(model) ? { betas: [FALLBACK_BETA], fallbacks: 'default' as const } : {}),
  };
}

// ---- response -----------------------------------------------------------

const MAX_EXPLANATION = 400;

/** Validate Claude's JSON on top of the current mix. Throws ClaudeMixError('bad_response'). */
export function parseSuggestion(
  text: string,
  current: { values: BlanketValues; songGain: number; drumGain: number },
): MixSuggestion {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new ClaudeMixError('bad_response', 'Claude’s reply wasn’t valid JSON.');
  }
  if (!raw || typeof raw !== 'object') throw new ClaudeMixError('bad_response', 'Claude’s reply had no knob values.');
  const obj = raw as Record<string, unknown>;
  if (!obj.values || typeof obj.values !== 'object') throw new ClaudeMixError('bad_response', 'Claude’s reply had no knob values.');
  const { values } = sanitizeValues(obj.values, current.values);
  const gain = (g: unknown, cur: number) =>
    typeof g === 'number' && Number.isFinite(g) && Math.abs(clampGain(g) - cur) > 1e-3 ? clampGain(g) : undefined;
  const songGain = gain(obj.songGain, current.songGain);
  const drumGain = gain(obj.drumGain, current.drumGain);
  let explanation = typeof obj.explanation === 'string' ? obj.explanation.trim() : '';
  if (explanation.length > MAX_EXPLANATION) explanation = explanation.slice(0, MAX_EXPLANATION - 1).trimEnd() + '…';
  return {
    values,
    ...(songGain !== undefined ? { songGain } : {}),
    ...(drumGain !== undefined ? { drumGain } : {}),
    explanation: explanation || 'Updated the knobs.',
  };
}

type SDK = typeof Anthropic;

/** Map SDK errors (typed classes, most specific first) to user-facing kinds. */
export function classifyError(e: unknown, sdk: SDK): ClaudeMixError {
  if (e instanceof ClaudeMixError) return e;
  if (e instanceof sdk.APIConnectionTimeoutError) return new ClaudeMixError('network', 'Claude timed out.');
  if (e instanceof sdk.APIConnectionError) return new ClaudeMixError('network', 'No connection to the Anthropic API.');
  if (e instanceof sdk.AuthenticationError) return new ClaudeMixError('bad_key', 'The API key was rejected. Check it in AI settings.');
  if (e instanceof sdk.PermissionDeniedError) return new ClaudeMixError('bad_key', 'This API key isn’t allowed to use that model.');
  if (e instanceof sdk.RateLimitError) return new ClaudeMixError('rate_limit', 'Rate limited by the Anthropic API — try again in a minute.');
  if (e instanceof sdk.APIError) {
    if (e.status === 402) return new ClaudeMixError('billing', 'The Anthropic account is out of credit.');
    if (e.status === 529 || (typeof e.status === 'number' && e.status >= 500))
      return new ClaudeMixError('overloaded', 'The Anthropic API is busy right now.');
    return new ClaudeMixError('other', `Anthropic API error ${e.status ?? ''}: ${e.message}`.trim());
  }
  return new ClaudeMixError('other', String((e as Error)?.message ?? e));
}

export interface ClaudeCallOptions {
  apiKey: string;
  model?: ClaudeModel;
  signal?: AbortSignal;
  fetch?: typeof fetch; // tests inject a fake
}

/** One request to Claude; returns a validated suggestion or throws ClaudeMixError. */
export async function suggestWithClaude(input: ClaudeMixInput, opts: ClaudeCallOptions): Promise<MixSuggestion> {
  if (!opts.apiKey) throw new ClaudeMixError('no_key', 'No API key set.');
  // Loaded lazily so a problem in the SDK can never break app start-up; the
  // offline interpreter still works if this import fails.
  const { default: AnthropicSDK } = await import('@anthropic-ai/sdk');
  const client = new AnthropicSDK({
    apiKey: opts.apiKey,
    baseURL: 'https://api.anthropic.com',
    // The key is the user's own, typed into their own phone; no server holds it.
    dangerouslyAllowBrowser: true,
    timeout: 60_000,
    maxRetries: 1,
    ...(opts.fetch ? { fetch: opts.fetch } : {}),
  });
  let message: Anthropic.Beta.Messages.BetaMessage;
  try {
    message = await client.beta.messages.create(buildRequest(input, opts.model ?? DEFAULT_MODEL), {
      signal: opts.signal,
    });
  } catch (e) {
    throw classifyError(e, AnthropicSDK);
  }
  if (message.stop_reason === 'refusal') {
    throw new ClaudeMixError('refusal', 'Claude declined this request.');
  }
  if (message.stop_reason === 'max_tokens') {
    throw new ClaudeMixError('bad_response', 'Claude’s reply was cut off.');
  }
  const text = message.content
    .filter((b): b is Anthropic.Beta.Messages.BetaTextBlock => b.type === 'text')
    .map((b) => b.text)
    .join('');
  return parseSuggestion(text, input);
}
