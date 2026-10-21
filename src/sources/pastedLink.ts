import { resolveLink, type LinkResults } from './links';
import { youtubeFetch } from './youtubePlatform';

// YouTube or Spotify link from the search box → results, or null for a plain search.
export function resolvePastedLink(text: string): Promise<LinkResults | null> {
  return resolveLink(text, youtubeFetch());
}
