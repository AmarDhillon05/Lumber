// SHIM — cachedSeparation() exists on origin/feat/separation but not on main.
// Delete once feat/separation merges and import it from '../separation'.

import type { SeparationResult } from '../separation';

export function cachedSeparation(_songUri: string): SeparationResult | null {
  return null;
}
