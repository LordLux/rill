/**
 * Chapters — the uploader's own division of a video, with start times.
 *
 * On a music mix each chapter is a song, and that is what the now-playing view
 * uses them for: the song credits (`parser/music.ts`) carry no timestamps at
 * all and stop at 10 cards, so *when* a song starts can only come from here.
 *
 * Two sources, in order:
 *
 *  1. **YouTube's own chapters** — `engagementPanels[]` with a
 *     `panelIdentifier` of `engagement-panel-macro-markers-description-chapters`,
 *     holding `macroMarkersListRenderer.contents[].macroMarkersListItemRenderer`.
 *     YouTube has already parsed the uploader's description timestamps into
 *     these (and applied its own rules: a `0:00` start, at least three,
 *     ten seconds apart), so re-parsing the description when they exist would
 *     only be a worse copy.
 *  2. **The description**, as the last resort, when YouTube declined to make
 *     chapters from it — [chaptersFromDescription].
 *
 * **The `…-auto-chapters` panel is deliberately not read.** Those are machine
 * summaries of the content ("Key moments"), not the uploader's segmentation, and
 * as a song title they would be confidently wrong.
 *
 * The same chapter list appears twice in a response — the chapters panel and
 * the structured description's own card list — so this reads the first, by
 * panel, and never collects by renderer name across the body.
 */
import type { Chapter } from '../types.ts';
import { bestImageUrl, text } from './text.ts';
import { asArray, get, isObject, num, str } from './tree.ts';

const CHAPTERS_PANEL = /description-chapters/;

/**
 * The description's own timestamps are only believed when the first one is at
 * (or near) the start. YouTube requires exactly `0:00`; a few seconds of slack
 * is the difference between a tracklist that opens on a short intro and a
 * stray "see 12:30" in prose.
 */
const MAX_FIRST_START_SECONDS = 30;

/** YouTube will not make chapters from fewer than three, and neither do we. */
const MIN_CHAPTERS = 3;

/** "8:35" → 515, "1:02:03" → 3723. Anything else → null. */
function clockToSeconds(value: string): number | null {
  const parts = value.split(':').map(Number);
  if (parts.some((part) => !Number.isFinite(part))) return null;
  if (parts.length === 2) {
    const [minutes, seconds] = parts as [number, number];
    return seconds < 60 ? minutes * 60 + seconds : null;
  }
  if (parts.length === 3) {
    const [hours, minutes, seconds] = parts as [number, number, number];
    return minutes < 60 && seconds < 60 ? hours * 3600 + minutes * 60 + seconds : null;
  }
  return null;
}

/**
 * Ascending by start, one per start time, none empty — and empty unless what
 * is left is still a list of chapters. A list that fails this is not a
 * segmentation, so it ships as nothing rather than as a wrong one.
 */
function tidy(chapters: Chapter[], firstStartCap: number): Chapter[] {
  const kept: Chapter[] = [];
  for (const chapter of chapters) {
    if (chapter.title === '') continue;
    // Strictly ascending: a repeated or out-of-order timestamp is prose that
    // happens to look like one, not the next chapter.
    if (kept.length > 0 && chapter.startSeconds <= kept[kept.length - 1]!.startSeconds) continue;
    kept.push(chapter);
  }
  if (kept.length < MIN_CHAPTERS) return [];
  if (kept[0]!.startSeconds > firstStartCap) return [];
  return kept;
}

function panelChapters(body: unknown): Chapter[] {
  for (const panel of asArray(get(body, 'engagementPanels'))) {
    const renderer = get(panel, 'engagementPanelSectionListRenderer');
    if (!isObject(renderer)) continue;
    // Either spelling — the two carry the same string today, and the one that
    // moves is the one that would otherwise take the feature with it.
    const identifier = str(renderer['panelIdentifier']) ?? str(renderer['targetId']) ?? '';
    if (!CHAPTERS_PANEL.test(identifier)) continue;

    const chapters: Chapter[] = [];
    for (const entry of asArray(get(renderer, 'content', 'macroMarkersListRenderer', 'contents'))) {
      const item = get(entry, 'macroMarkersListItemRenderer');
      if (!isObject(item)) continue;
      const title = text(item['title']);
      // `startTimeSeconds` is the structural field; the "8:35" label is the
      // fallback, and what the label says is the same moment.
      const startSeconds =
        num(get(item, 'onTap', 'watchEndpoint', 'startTimeSeconds')) ??
        clockToSeconds(text(item['timeDescription']) ?? '');
      if (title === null || startSeconds === null) continue;
      chapters.push({
        title: title.trim(),
        startSeconds,
        thumbnailUrl: bestImageUrl(item['thumbnail']),
      });
    }
    return tidy(chapters, Number.POSITIVE_INFINITY);
  }
  return [];
}

const CLOCK = String.raw`(?:\d{1,2}:)?\d{1,2}:\d{2}`;
const SEPARATORS = String.raw`[\s\-–—:|•·~>]*`;
/** "1. ", "01) " — a numbered list in front of the timestamp. */
const NUMBERING = String.raw`(?:\d{1,3}[.)]\s+)?`;
const BRACKETS_OPEN = String.raw`[(\[]?`;
const BRACKETS_CLOSE = String.raw`[)\]]?`;

/** `0:00 Artist – Song`, `[3:42] Song`, `2. 8:35 - Song`. */
const LEADING = new RegExp(
  String.raw`^\s*${NUMBERING}${BRACKETS_OPEN}(${CLOCK})${BRACKETS_CLOSE}${SEPARATORS}(.+)$`,
);
/** `Artist – Song 3:42` — the timestamp last, which some tracklists prefer. */
const TRAILING = new RegExp(
  String.raw`^\s*(.+?)${SEPARATORS}${BRACKETS_OPEN}(${CLOCK})${BRACKETS_CLOSE}\s*$`,
);

function cleanTitle(raw: string): string {
  const cleaned = raw.replace(/^[\s\-–—:|•·~>]+|[\s\-–—:|•·~>]+$/g, '').trim();
  // A "title" that is only symbols is the residue of a line that was not one.
  return /[\p{L}\p{N}]/u.test(cleaned) ? cleaned.slice(0, 200) : '';
}

/**
 * Chapters from a description's own timestamps.
 *
 * The last resort, for an uploader who wrote a tracklist and whose video
 * YouTube did not turn into chapters (no `0:00`, fewer than three, too close
 * together). Leading timestamps are read first, and trailing ones only when
 * that finds nothing — mixing the two in one pass would read a leading
 * timestamp's *duration* suffix as a second chapter.
 *
 * Carries no thumbnail: the description does not either.
 */
export function chaptersFromDescription(description: string | null): Chapter[] {
  if (description === null || description === '') return [];
  const lines = description.split(/\r?\n/);

  for (const pattern of [LEADING, TRAILING]) {
    const chapters: Chapter[] = [];
    for (const line of lines) {
      const match = pattern.exec(line);
      if (match === null) continue;
      const [clock, title] = pattern === LEADING ? [match[1], match[2]] : [match[2], match[1]];
      const startSeconds = clockToSeconds(clock ?? '');
      if (startSeconds === null) continue;
      chapters.push({ title: cleanTitle(title ?? ''), startSeconds, thumbnailUrl: null });
    }
    const tidied = tidy(chapters, MAX_FIRST_START_SECONDS);
    if (tidied.length > 0) return tidied;
  }
  return [];
}

/**
 * Every chapter the uploader gave this video, ascending — YouTube's, else the
 * description's. Empty is the ordinary answer: most videos have none.
 */
export function parseChapters(body: unknown, description: string | null): Chapter[] {
  const fromPanel = panelChapters(body);
  return fromPanel.length > 0 ? fromPanel : chaptersFromDescription(description);
}
