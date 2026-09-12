/**
 * The parser's public surface. Nothing outside this directory should import from
 * the individual modules — the split is an implementation detail, the three
 * entry points are the contract.
 */

export { parseFeed } from './feed.ts';
export { parseVideoDetail } from './video.ts';
export { parsePlayer, sheetUrl } from './player.ts';
// The fourth entry point (Task 26). Separate from `parseFeed` because the
// panel it reads is not a renderer and the walker cannot see it — see
// `parser/mix.ts`.
export { parseMixPanel, mixItemIds, type MixPanel } from './mix.ts';

export { normaliseRendererName, roleOf } from './vocabulary.ts';
export {
  logUnknownRendererSummary,
  unknownRendererCounts,
  resetUnknownRenderers,
} from '../log.ts';
