/**
 * The parser's public surface. Nothing outside this directory should import from
 * the individual modules — the split is an implementation detail, the three
 * entry points are the contract.
 */

export { parseFeed } from './feed.ts';
export { parseVideoDetail } from './video.ts';
export { parsePlayer } from './player.ts';

export { normaliseRendererName, roleOf } from './vocabulary.ts';
export {
  logUnknownRendererSummary,
  unknownRendererCounts,
  resetUnknownRenderers,
} from '../log.ts';
