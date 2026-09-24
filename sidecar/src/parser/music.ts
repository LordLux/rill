/**
 * "Music in this video" — the song credits YouTube attaches to a watch page.
 *
 * Lives on the `/next` response the watch page already fetches, in
 * `engagementPanels`, which no other parser touches:
 *
 * ```
 * engagementPanels[].engagementPanelSectionListRenderer.content
 *   .structuredDescriptionContentRenderer.items[]
 *   .horizontalCardListRenderer.cards[].videoAttributeViewModel
 * ```
 *
 * Found by collecting every `videoAttributeViewModel` in the body rather than
 * by that path: the panel's index moves between responses, and the walker
 * cannot reach it by renderer name because `engagementPanels` is an array of
 * panels rather than a tile tree.
 *
 * **One fixture, one card.** `mix.json` is the only capture in the corpus that
 * carries this, and it carries exactly one. The shape is treated as a list
 * because `cards[]` is one and the header is templated ("1 song"), but nothing
 * here has been seen with two — see `architecture.md`'s note on fixtures being
 * one moment.
 */
import type { MusicTrack } from '../types.ts';
import { get, isObject, str, walk } from './tree.ts';
import { text } from './text.ts';

/**
 * Google's image host sizes on request, and a bare URL serves a small default.
 *
 * `=s1200` is the cap: measured 2026-09-22, `=s1200` returns 1200x1200 and
 * `=s1800` returns the same 1200. Applied here rather than in the client
 * because the client constructs no URLs (`protocol.md` §3.7).
 */
const COVER_SIZE = '=s1200';

/**
 * YouTube's stand-in for a song with no art: a grey square with a white note,
 * at `www.gstatic.com/youtube/img/watch/yt_music_channel.jpeg`.
 *
 * Measured 2026-09-24 over 22 cards: the 6 without art all carried that one
 * URL, byte-identical, and every real cover was on `yt3.googleusercontent.com`.
 * Nothing structural tells them apart — same keys, same shape. **The six were
 * one song credited on six uploads**, so this is one observed case of a
 * generically named static asset, not a survey. Matched on the host rather
 * than the file name, so a renamed stand-in is caught too; being wrong that
 * way costs showing the video's thumbnail instead of a cover.
 */
const STOCK_COVER_HOST = /^https?:\/\/([^/]+\.)?gstatic\.com\//;

function coverUrl(node: unknown): string | null {
  // **Not `bestImageUrl`.** The source carries no `width`, so it scores 0
  // there and loses to anything else in the subtree — including, for a card
  // that has no image at all, some unrelated thumbnail.
  const url = str(get(node as never, 'image', 'sources', '0', 'url'));
  if (url === null || url === '') return null;
  // No art is null, not a picture of no art: the client falls back to the
  // video's own thumbnail, which at least shows this video.
  if (STOCK_COVER_HOST.test(url)) return null;
  // Already sized (or something unexpected) — leave it alone rather than
  // appending a second parameter.
  return /=[sw]\d/.test(url) ? url : `${url}${COVER_SIZE}`;
}

/**
 * One card to one track, or null when it carries no title.
 *
 * Reads only the card's own structural fields. **The `Writers` credit is
 * deliberately not parsed**: it exists only inside the overflow menu's
 * confirm-dialog, keyed by bold *localised* labels ("Song", "Artist", "Album",
 * "Writers"), and keying on a localised label is the mistake the `STATION` and
 * members-only badges exist to warn about. The dialog's artist is richer than
 * the card's — `"Daft Punk, Julian Casablancas"` against `"Daft Punk"` — and
 * the structural one still wins.
 */
function mapTrack(view: unknown): MusicTrack | null {
  if (!isObject(view)) return null;
  const title = text(get(view, 'title')) ?? str(get(view, 'title'));
  if (title === null || title === '') return null;
  return {
    title,
    artist: text(get(view, 'subtitle')) ?? str(get(view, 'subtitle')),
    album:
      text(get(view, 'secondarySubtitle')) ??
      str(get(view, 'secondarySubtitle', 'content')),
    coverUrl: coverUrl(view),
  };
}

/**
 * Every song attributed to this watch page, in the order YouTube lists them.
 *
 * Empty is the ordinary answer — most videos have no music attribution at all,
 * and a caller must not read empty as a failure. Never throws on an
 * unrecognised card: it is skipped and the rest still ship (hard invariant 4).
 */
export function parseMusicTracks(body: unknown): MusicTrack[] {
  if (!isObject(body)) return [];
  const tracks: MusicTrack[] = [];
  walk(body, (node) => {
    const view = node['videoAttributeViewModel'];
    if (view === undefined) return true;
    const track = mapTrack(view);
    if (track !== null) tracks.push(track);
    // Nothing useful below a card, and descending would re-find the same one.
    return false;
  });
  return tracks;
}
