/**
 * `json3` → cues.
 *
 * Chosen over `srv3`, `ttml` and `vtt` after fetching all of them against real
 * tracks (2026-08-18; the measurements are in the task report). `json3` and
 * `srv3` carry identical data — `srv3` is the same document as XML — and `json3`
 * is the one that needs no XML parser. `vtt` arrives pre-grouped but with
 * YouTube's karaoke markup inlined as `<00:00:19.039><c> no</c>`, which would
 * have to be stripped and re-derived; `ttml` is the same content again, longer.
 *
 * **`fmt=ytt` answers HTTP 404.** YTT is not a fourth format to fetch: its
 * styling model *is* the `pens` / `wsWinStyles` / `wpWinPositions` arrays at the
 * top of this document, empty for a plain track and populated for a styled one.
 * A YTT parser is therefore an extension of this file — read the arrays, resolve
 * the per-event `pPenId` / `wsWinStyleId` / `wpWinPosId` references into a
 * `CueStyle` — and not a new pipeline. Nothing else in the chain changes.
 *
 * ## The shape, for the two kinds of track
 *
 * A **manual** track is already cue-level. Every event is one line:
 *
 * ```json
 * { "tStartMs": 22640, "dDurationMs": 4320,
 *   "segs": [{ "utf8": "♪ You know the rules\nand so do I ♪" }] }
 * ```
 *
 * An **ASR** track is a two-row window that text scrolls through, and it uses
 * three kinds of event that all have to be told apart:
 *
 * ```json
 * { "tStartMs": 0, "dDurationMs": 211879, "id": 1,
 *   "wpWinPosId": 1, "wsWinStyleId": 1 }                     // window definition
 * { "tStartMs": 21790, "dDurationMs": 4170, "wWinId": 1,
 *   "aAppend": 1, "segs": [{ "utf8": "\n" }] }               // roll marker
 * { "tStartMs": 21800, "dDurationMs": 7319, "wWinId": 1,
 *   "segs": [{ "utf8": "love." },
 *            { "utf8": " You", "tOffsetMs": 1000 }, …] }     // the line
 * ```
 *
 * Only the third is a cue. The first two are structure, and emitting them is how
 * a caption track acquires blank flickering lines. The declared 7319 ms overlaps
 * the next event by design — see `groupAsrCues`, which is where that is resolved.
 */

import { logger } from '../log.ts';
import type { Cue, CueSegment } from './cues.ts';
import { asArray, get, isObject, num, type Json } from '../parser/tree.ts';

const log = logger('captions');

/**
 * Parse a `json3` document into raw, ungrouped cues.
 *
 * Tolerant in the same way the renderer parser is (hard invariant 4): an event
 * this does not understand is skipped and counted, never thrown over. A caption
 * track that loses one line is worth far more than one that fails to load.
 */
export function parseJson3(raw: unknown): Cue[] {
  const events = asArray(get(raw as Json, 'events'));
  if (events.length === 0) {
    log.debug('json3: no events');
    return [];
  }

  const cues: Cue[] = [];
  let skipped = 0;

  for (const event of events) {
    if (!isObject(event)) {
      skipped++;
      continue;
    }

    // A window definition carries no `segs` at all. It is the ASR track's
    // header, and it declares the duration of the *whole track* — 211879 ms on a
    // 3½ minute video — so mistaking it for a cue puts one caption on screen for
    // the entire runtime.
    const segs = get(event, 'segs');
    if (segs === undefined || segs === null) continue;

    // The roll marker: `aAppend: 1` with a lone newline. It advances the window
    // rather than saying anything, and it is why a naive parser produces a blank
    // cue between every real one.
    if (event['aAppend'] === 1) continue;

    const startMs = num(event['tStartMs']);
    if (startMs === null) {
      skipped++;
      continue;
    }

    const segments: CueSegment[] = [];
    for (const seg of asArray(segs)) {
      if (!isObject(seg)) continue;
      // **Read raw, not through `str()`.** The tree helper trims, which is right
      // for renderer text and wrong here: an ASR segment carries its own leading
      // space (`"We're"`, `" no"`, `" strangers"`), and that space is the only
      // word separator in the document. Trimming produces
      // "We'renostrangersto" — every word rendered, nothing missing, and
      // completely unreadable, which is the kind of bug that survives review.
      const text = seg['utf8'];
      if (typeof text !== 'string') continue;
      segments.push({ text, offsetMs: num(seg['tOffsetMs']) });
    }
    if (segments.length === 0) continue;

    const durationMs = num(event['dDurationMs']);
    cues.push({
      startMs,
      // `0` rather than a guess: `normalizeCues` owns the "no duration declared"
      // rule, so there is one copy of it rather than one per format parser.
      endMs: durationMs === null ? 0 : startMs + durationMs,
      segments,
      // json3 populates no styling. A YTT parser resolves `pPenId`,
      // `wsWinStyleId` and `wpWinPosId` here; everything downstream already
      // handles a non-null style.
      style: null,
    });
  }

  if (skipped > 0) log.warn(`json3: skipped ${skipped} unreadable event(s)`);
  return cues;
}
