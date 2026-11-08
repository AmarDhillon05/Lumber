// Glue for "Describe the sound": analyse the project's audio once, then turn
// a prompt into a mix suggestion with Claude when there's a key and a
// connection, or with the offline interpreter otherwise. No React, no storage.

import type { ProjectAudio } from '../audio/sources';
import { analyzeAudio, type MixAnalysis } from './analyze';
import { ClaudeMixError, suggestWithClaude, type ClaudeMixInput, type ClaudeModel } from './claude';
import { interpretLocally, type MixSuggestion } from './localMix';

/**
 * Descriptors for the take and the part of the song under it (the drumless
 * stem when the song has been separated, since that's what the take plays against).
 */
export function analyzeProject(audio: ProjectAudio, drumOffsetSec: number): MixAnalysis {
  const sr = audio.sampleRate;
  const drums = analyzeAudio(audio.drums, sr);
  const bed = audio.stems?.noDrums ?? audio.song;
  let song = null;
  if (bed && bed[0]?.length) {
    const bedSec = bed[0].length / sr;
    const takeSec = audio.drums[0].length / sr;
    // Song region under the take; fall back to the start when the take runs past the end.
    let start = Math.max(0, drumOffsetSec);
    if (start >= bedSec - 1) start = 0;
    song = analyzeAudio(bed, sr, { startSec: start, maxSec: Math.max(5, Math.min(30, takeSec)) });
  }
  return { drums, song, songIsDrumless: !!audio.stems };
}

export type MixSource = 'claude' | 'offline';

export interface PromptMixOutcome {
  suggestion: MixSuggestion;
  source: MixSource;
  notice?: string; // why the offline interpreter was used, or a Claude error
}

export interface RunPromptMixOptions {
  apiKey: string | null;
  model?: ClaudeModel;
  signal?: AbortSignal;
  fetch?: typeof fetch;
}

/**
 * Claude first when a key is set; on any failure the offline interpreter
 * answers instead and `notice` says why (bad key, no network, rate limit…).
 */
export async function runPromptMix(input: ClaudeMixInput, opts: RunPromptMixOptions): Promise<PromptMixOutcome> {
  const offline = (notice?: string): PromptMixOutcome => ({
    suggestion: interpretLocally(input),
    source: 'offline',
    ...(notice ? { notice } : {}),
  });
  if (!opts.apiKey) return offline('No Anthropic API key — used the offline interpreter. Add a key in AI settings to use Claude.');
  try {
    const suggestion = await suggestWithClaude(input, {
      apiKey: opts.apiKey,
      model: opts.model,
      signal: opts.signal,
      fetch: opts.fetch,
    });
    return { suggestion, source: 'claude' };
  } catch (e) {
    const err = e instanceof ClaudeMixError ? e : new ClaudeMixError('other', String((e as Error)?.message ?? e));
    return offline(`${err.message} Used the offline interpreter instead.`);
  }
}
