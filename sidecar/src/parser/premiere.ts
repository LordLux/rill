/**
 * When a premiere or scheduled stream starts — one copy of the rule.
 *
 * Three parsers need this and each sees a different payload: a feed tile
 * (`items.ts`), a watch page (`video.ts`) and a `/player` response
 * (`player.ts`). Same reasoning as `playback/sabr-detect.ts` — a rule that is
 * read out of three shapes is a rule that drifts if it is written three times.
 *
 * **Searched for anywhere in the payload rather than read from a known path.**
 * YouTube puts this in at least three places depending on surface and renderer
 * generation, none of them documented, and **no premiere exists in the fixture
 * corpus** to pin a path against — so keying on one location would be a guess
 * whose failure is silent: a premiere that reads as an ordinary dead video,
 * which is the bug this exists to prevent. Null is an ordinary answer; the UI
 * falls back to YouTube's own prose ("Premieres in 9 days").
 *
 * Deliberately *not* derived from the "Premieres Aug 22, 2026" text on the tile.
 * That is localised prose, and parsing a date out of the user's locale in order
 * to re-format it is a way to be confidently wrong in a language nobody on this
 * project reads.
 */

import { deepFind, get, isObject, num, str, type Json } from './tree.ts';

/**
 * Unix **seconds** or unix **milliseconds** → milliseconds.
 *
 * Sanity-checked rather than trusted: YouTube sends seconds, but a millisecond
 * value arriving here would render as a date fifty thousand years out and still
 * look like a plausible number on the way through.
 */
function toMillis(value: number): number {
  return value > 1e11 ? Math.round(value) : Math.round(value * 1000);
}

export function premiereStartMs(root: Json): number | null {
  // `upcomingEventData.startTime` — unix seconds in a string, on feed tiles and
  // on some watch payloads.
  const eventNode = deepFind(root, (node) => isObject(node['upcomingEventData']));
  const eventSeconds = num(get(eventNode, 'upcomingEventData', 'startTime'));
  if (eventSeconds !== null) return toMillis(eventSeconds);

  // `scheduledStartTime` — unix seconds, on the `/player` offline slate.
  const slateNode = deepFind(root, (node) => node['scheduledStartTime'] !== undefined);
  const slateSeconds = num(slateNode?.['scheduledStartTime']);
  if (slateSeconds !== null) return toMillis(slateSeconds);

  // `liveBroadcastDetails.startTimestamp` — ISO 8601, on the microformat.
  const isoNode = deepFind(root, (node) => str(node['startTimestamp']) !== null);
  const iso = str(isoNode?.['startTimestamp']);
  if (iso !== null) {
    const parsed = Date.parse(iso);
    if (Number.isFinite(parsed)) return parsed;
  }

  return null;
}
