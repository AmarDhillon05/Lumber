// Claude prompt-mix request/response handling, against a fake fetch (no
// network, no key). Run: npx tsx tests/claude.test.ts

import Anthropic from '@anthropic-ai/sdk';
import {
  buildRequest,
  buildSystemPrompt,
  buildUserMessage,
  classifyError,
  ClaudeMixError,
  isTransient,
  OUTPUT_SCHEMA,
  parseSuggestion,
  suggestWithClaude,
  type ClaudeMixInput,
} from '../src/ai/claude';
import type { MixAnalysis, AudioDescriptors } from '../src/ai/analyze';
import { BLANKET_TERM_KEYS } from '../src/dsp/blanketTerms';
import { fillValues } from '../src/dsp/presets';
import { counts, ok, section } from './harness';

const d: AudioDescriptors = {
  durationSec: 20.123,
  channels: 1,
  rmsDb: -21.456,
  peakDb: -3.2,
  crestDb: 18.25,
  loudnessLufs: -19.9,
  dynamicRangeDb: 31,
  noiseFloorDb: -58,
  bands: { sub: -20, low: -7, lowMid: -9, mid: -6, presence: -8, air: -17 },
  centroidHz: 3123.4,
  onsetsPerSec: 4.123,
  decayMs: 140.6,
  stereoWidth: null,
};
const analysis: MixAnalysis = { drums: d, song: { ...d, channels: 2, stereoWidth: 0.21 }, songIsDrumless: true };

const input: ClaudeMixInput = {
  prompt: '  punchy and dry like a 90s rock record ',
  values: fillValues({ warmth: 0.3 }),
  songGain: 0.8,
  drumGain: 1,
  analysis,
};

function replyWith(body: unknown, status = 200, headers: Record<string, string> = {}) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fake = (async (url: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify(body), {
      status,
      headers: { 'content-type': 'application/json', 'request-id': 'req_test', ...headers },
    });
  }) as typeof fetch;
  return { fake, calls };
}

const message = (json: unknown, stop_reason = 'end_turn') => ({
  id: 'msg_1',
  type: 'message',
  role: 'assistant',
  model: 'claude-opus-5-5',
  content: [
    { type: 'thinking', thinking: '', signature: 'sig' },
    { type: 'text', text: typeof json === 'string' ? json : JSON.stringify(json) },
  ],
  stop_reason,
  stop_sequence: null,
  usage: { input_tokens: 10, output_tokens: 10 },
});

async function main() {
  section('ai: Claude request');
  const req = buildRequest(input);
  ok('default model is claude-opus-5-5', req.model === 'claude-opus-5-5');
  ok('structured output via output_config.format json_schema', req.output_config?.format?.type === 'json_schema');
  ok('effort set explicitly', req.output_config?.effort === 'medium');
  ok('no forced tool_choice / no sampling params', !('tool_choice' in req) && !('temperature' in req));
  ok('opus uses server-side refusal fallback', req.fallbacks === 'default' && (req.betas ?? []).includes('server-side-fallback-2026-07-01'));
  const haiku = buildRequest(input, 'claude-haiku-5-5');
  ok('haiku option: no fallbacks param', haiku.model === 'claude-haiku-5-5' && haiku.fallbacks === undefined && haiku.betas === undefined);

  const schema = OUTPUT_SCHEMA;
  ok('schema lists every knob as required', BLANKET_TERM_KEYS.every((k) => (schema.properties.values.required as readonly string[]).includes(k)));
  ok('schema objects are closed', schema.additionalProperties === false && schema.properties.values.additionalProperties === false);
  ok('schema avoids unsupported numeric constraints', !/"(minimum|maximum)"/.test(JSON.stringify(schema)));

  const sys = buildSystemPrompt();
  ok('system prompt carries the catalog and presets', BLANKET_TERM_KEYS.every((k) => sys.includes(`"${k}"`)) && sys.includes('Phone-mic rescue'));
  ok('system prompt is stable (cacheable)', sys === buildSystemPrompt());
  const user = JSON.parse(buildUserMessage(input));
  ok('user message: trimmed prompt + current values', user.request === 'punchy and dry like a 90s rock record' && user.current.values.warmth === 0.3);
  ok('user message: rounded analysis for drums and song', user.analysis.drums.rmsDb === -21.5 && user.analysis.song.stereoWidth === 0.21 && /drumless/.test(user.analysis.songSource));
  ok('user message without analysis', JSON.parse(buildUserMessage({ ...input, analysis: null })).analysis === null);

  section('ai: Claude response validation');
  const cur = { values: fillValues({ warmth: 0.3 }), songGain: 0.8, drumGain: 1 };
  const good = parseSuggestion(
    JSON.stringify({ values: { ...fillValues({ punch: 0.6, depth: 2, air: -3, denoise: 0.9 }), bogus: 1 }, songGain: 0.8, drumGain: 1.2, explanation: '  Tighter. ' }),
    cur,
  );
  ok('values clamped to legal ranges', good.values.punch === 0.6 && good.values.depth === 1 && good.values.air === -1 && good.values.denoise === 0.35);
  ok('unknown keys dropped', !('bogus' in good.values));
  ok('unchanged gain omitted, changed gain kept', good.songGain === undefined && good.drumGain === 1.2);
  ok('explanation trimmed', good.explanation === 'Tighter.');
  const partial = parseSuggestion(JSON.stringify({ values: { punch: 0.5 }, songGain: null, drumGain: 9, explanation: '' }), cur);
  ok('missing knobs keep current values', partial.values.warmth === 0.3 && partial.values.punch === 0.5);
  ok('gain clamped to 1.5; null ignored', partial.drumGain === 1.5 && partial.songGain === undefined);
  const throwsKind = (f: () => unknown, kind: string) => {
    try {
      f();
      return false;
    } catch (e) {
      return e instanceof ClaudeMixError && e.kind === kind;
    }
  };
  ok('non-JSON → bad_response', throwsKind(() => parseSuggestion('Sure! Here you go', cur), 'bad_response'));
  ok('no values → bad_response', throwsKind(() => parseSuggestion('{"explanation":"x"}', cur), 'bad_response'));

  section('ai: Claude call (fake fetch)');
  {
    const { fake, calls } = replyWith(message({ values: fillValues({ punch: 0.7, sustain: 0.4 }), songGain: null, drumGain: null, explanation: 'Punchier and drier.' }));
    const s = await suggestWithClaude(input, { apiKey: 'sk-ant-test', fetch: fake });
    ok('round trip returns validated values', s.values.punch === 0.7 && s.values.sustain === 0.4 && s.explanation === 'Punchier and drier.');
    const c = calls[0];
    const h = new Headers(c.init.headers as HeadersInit);
    const body = JSON.parse(String(c.init.body));
    ok('POST /v1/messages', c.url.endsWith('/v1/messages') && c.init.method === 'POST', c.url);
    ok('sends the user key (Authorization: Bearer)', h.get('authorization') === 'Bearer sk-ant-test' || h.get('x-api-key') === 'sk-ant-test');
    ok('targets api.anthropic.com', c.url.startsWith('https://api.anthropic.com/'), c.url);
    ok('sends the fallback beta header', (h.get('anthropic-beta') ?? '').includes('server-side-fallback-2026-07-01'));
    ok('body has model, schema, system and the prompt', body.model === 'claude-opus-5-5' && body.output_config.format.type === 'json_schema' && typeof body.system === 'string' && body.messages[0].content.includes('90s rock'));
  }
  {
    const { fake } = replyWith(message('{}', 'refusal'));
    const e = await suggestWithClaude(input, { apiKey: 'k', fetch: fake }).catch((x) => x);
    ok('refusal → ClaudeMixError(refusal)', e instanceof ClaudeMixError && e.kind === 'refusal');
  }
  {
    const { fake } = replyWith(message('{"values":{', 'max_tokens'));
    const e = await suggestWithClaude(input, { apiKey: 'k', fetch: fake }).catch((x) => x);
    ok('truncated → bad_response', e instanceof ClaudeMixError && e.kind === 'bad_response');
  }
  const errFor = async (status: number, type: string) => {
    const { fake } = replyWith({ type: 'error', error: { type, message: 'nope' } }, status, { 'retry-after-ms': '1', 'x-should-retry': 'false' });
    return suggestWithClaude(input, { apiKey: 'k', fetch: fake }).catch((x) => x);
  };
  const e401 = await errFor(401, 'authentication_error');
  ok('401 → bad_key', e401 instanceof ClaudeMixError && e401.kind === 'bad_key');
  const e429 = await errFor(429, 'rate_limit_error');
  ok('429 → rate_limit (transient)', e429.kind === 'rate_limit' && isTransient(e429.kind));
  const e529 = await errFor(529, 'overloaded_error');
  ok('529 → overloaded (transient)', e529.kind === 'overloaded' && isTransient(e529.kind));
  const e402 = await errFor(402, 'billing_error');
  ok('402 → billing', e402.kind === 'billing' && !isTransient(e402.kind));
  {
    const fake = (async () => {
      throw new TypeError('Network request failed');
    }) as typeof fetch;
    const e = await suggestWithClaude(input, { apiKey: 'k', fetch: fake }).catch((x) => x);
    ok('fetch failure → network (transient)', e instanceof ClaudeMixError && e.kind === 'network' && isTransient(e.kind), String(e?.message));
  }
  const noKey = await suggestWithClaude(input, { apiKey: '' }).catch((x) => x);
  ok('empty key → no_key without a request', noKey instanceof ClaudeMixError && noKey.kind === 'no_key');
  ok('classifyError passes ClaudeMixError through', classifyError(new ClaudeMixError('refusal', 'x'), Anthropic).kind === 'refusal');

  const { passes, failures } = counts();
  console.log(failures === 0 ? `\nALL PASS (${passes} claude checks)` : `\n${failures} FAILED, ${passes} passed`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
