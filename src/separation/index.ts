import type { SeparationProgress, SeparationResult } from './types';

export type { SeparationProgress, SeparationResult } from './types';

// Placeholder until feat/separation lands.
export async function separateDrums(
  _songUri: string,
  _onProgress?: SeparationProgress,
): Promise<SeparationResult> {
  throw new Error('separateDrums: not implemented yet');
}
