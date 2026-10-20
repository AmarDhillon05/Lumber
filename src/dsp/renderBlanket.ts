import { renderChain } from './render';
import { buildBlanketChain, INTENSITY } from './blanketChain';
import type { BlanketValues } from './blanketTerms';
import type { Channels } from './types';

export { INTENSITY };

// Build the Blanket chain from the current slider values (in
// BLANKET_RENDER_ORDER, naturalness last) and render it to processed PCM.
// Terms at 0 or missing are skipped, so an all-zero set renders a clean
// pass-through copy of the source. Bipolar terms keep their sign (boost/cut);
// the rest use magnitude.
export async function renderBlanket(
  pcm: Channels,
  sampleRate: number,
  values: Partial<BlanketValues>,
): Promise<Channels> {
  const { channels } = await renderChain(pcm, sampleRate, buildBlanketChain(values));
  return channels;
}
