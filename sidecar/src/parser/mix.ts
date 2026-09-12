/**
 * The watch page's playlist/mix panel — Task 26.
 *
 * **The panel is a bare object, not a renderer, and that is why this file
 * exists.** Measured 2026-09-12: `/next` returns it at
 * `contents.twoColumnWatchNextResults.playlist.playlist`, with no wrapping
 * renderer key at all — `playlistId`, `title`, `isInfinite`, `currentIndex`
 * and a `contents[]` of `playlistPanelVideoRenderer`. `playlistPanelRenderer`
 * appears nowhere in the response, for a mix or for an ordinary `PL…`
 * playlist. The renderer walker keys every decision off the *key* a value
 * arrived under (`isRendererKey` requires a `Renderer`/`ViewModel`/`Model`
 * suffix), so a bare `playlist` key is invisible to it: the walker descends
 * through the panel as ordinary JSON and its rows surface interleaved with the
 * related rail's. That is exactly what `parseFeed` on a whole `/next` body
 * does — 45 items for a page whose panel holds 25 — which is why the panel is
 * reached by path here rather than found by the vocabulary.
 *
 * Its *rows* are ordinary renderers and go through the ordinary mappers, so a
 * mix entry and a home-feed tile are the same DTO. Only the container is
 * special.
 */

import { logger } from '../log.ts';
import type { FeedItem } from '../types.ts';
import { parseFeed } from './feed.ts';
import { text } from './text.ts';
import { get, isObject, num, str, type Json } from './tree.ts';

const log = logger('parser');

export interface MixPanel {
  playlistId: string;
  /** "Mix - Rick Astley…", "My Mix", "Chroma: Today's Dance Hits". */
  title: string | null;
  /** Where the anchor video sits in {@link items}. `-1` when the panel omits it. */
  currentIndex: number;
  /**
   * YouTube's own claim that the radio never ends.
   *
   * **Do not trust it as an end condition.** Measured `true` on every mix
   * sampled 2026-09-12 — including curated `RDCLAK…` lists that demonstrably
   * run out after ~51 items. Carried because it is what the response says, not
   * because anything should branch on it; `mix/service.ts` derives exhaustion
   * from whether a fetch actually yielded anything instead.
   */
  isInfinite: boolean;
  items: FeedItem[];
}

/**
 * The mix/playlist panel on a `/next` response, or `null` when there is none.
 *
 * `null` is the ordinary answer for a plain watch page: a `/next` issued
 * without a `playlistId` carries no panel at all (measured — the video's own
 * `RD<id>` appears nowhere in it either), so this is "not a playlist context",
 * never "the parse failed".
 */
export function parseMixPanel(raw: Json, context = 'mix'): MixPanel | null {
  const holder = get(raw, 'contents', 'twoColumnWatchNextResults', 'playlist');
  const panel = get(holder, 'playlist');
  if (!isObject(panel)) return null;

  const playlistId = str(panel['playlistId']);
  if (!playlistId) {
    // A panel with no id is one nothing can extend or report against. Logged
    // rather than thrown (hard invariant 4) — the caller treats it as "no
    // panel" and the watch still plays.
    log.warn(`${context}: playlist panel carried no playlistId — ignoring it`);
    return null;
  }

  // `contents` is passed to `parseFeed` directly rather than the whole body:
  // `contentRoots` returns a non-object value unchanged, so an array walks as
  // itself, and scoping it here is what keeps the related rail out. Same
  // discipline as `video.related`'s `secondaryResults` scoping.
  const rows = parseFeed(panel['contents'] as Json, context);

  return {
    playlistId,
    // `title` is a plain string here, not a renderer text node — one of the
    // several ways this object is not shaped like a renderer. `titleText` is
    // the runs/simpleText sibling, kept as the fallback.
    title: str(panel['title']) ?? text(panel['titleText']),
    currentIndex: num(panel['currentIndex']) ?? -1,
    isInfinite: panel['isInfinite'] === true,
    items: rows.items,
  };
}

/** The panel's ids in order, for the anchor arithmetic in `mix/service.ts`. */
export function mixItemIds(panel: MixPanel): string[] {
  return panel.items.map((item) => item.id);
}
