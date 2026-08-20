/**
 * The user's caption style, the drag offset, and the width table that makes the
 * no-overflow rule possible. Task 19 — `docs/architecture.md` §2.9.
 *
 * ## Why the style is applied here and not through mpv
 *
 * mpv has live properties for most of this (`sub-color`, `sub-font`,
 * `sub-back-color`, …) and they are worthless for it. They act on the ASS
 * `Style`, and `sub-ass-override=force` — the switch that is supposed to make
 * them win — overrides the `Style` too, **not inline override tags**. Task 18
 * emits every styled track's colour, font and size as inline tags, so a user
 * changing the font colour would see it apply to plain tracks and do nothing at
 * all on styled ones, with no error. Measured against the bundled libmpv
 * 2026-08-19.
 *
 * So the overrides are applied where the tags are written. One mechanism, every
 * track type, no control that silently does nothing. It costs a re-render and a
 * `sub-add` per change: measured 2026-08-20 at 1.0–1.3 ms of render on ordinary
 * documents (32.8 ms on a 3 MB outlier — see [CaptionMetrics] for what makes one)
 * plus `sub-add`'s 12–36 ms, so ~15–40 ms end to end. Slider input is debounced
 * on the client.
 *
 * ## Two fields that are not overrides in the usual sense
 *
 * [CaptionStyle.background] and [CaptionStyle.window] are *legibility* controls,
 * and YouTube draws both unconditionally — the background opaque behind each
 * line, the window wrapping the whole frame's captions at 0% opacity until
 * someone turns it up. `null` on either means "whatever the track asked for,
 * falling back to the default", not "off".
 */

import type { RgbaColor } from './cues.ts';

/** The three edge treatments ASS can actually express. See the note in `ass.ts`. */
export type CaptionEdgeStyle = 'none' | 'outline' | 'dropShadow';

/**
 * Everything the caption style menu owns.
 *
 * Every field is nullable and `null` means **the track decides**. That is not the
 * same as "off": an unset [background] still draws, at the default below, because
 * the box is drawn unconditionally and is the drag handle.
 */
export interface CaptionStyle {
  fontFamily: string | null;
  /** Percentage of the document's default size. 100 is unchanged. */
  fontSizePercent: number | null;
  /** Text colour *and* opacity — `a` is the font-opacity control. */
  textColor: RgbaColor | null;
  /** The per-line box. `a: 0` is a user asking for no background. */
  background: RgbaColor | null;
  /** The rectangle around every caption on screen. `a: 0` is YouTube's default. */
  window: RgbaColor | null;
  edgeStyle: CaptionEdgeStyle | null;
}

/** Nothing overridden — what a fresh session and the menu's reset both produce. */
export const NO_CAPTION_STYLE: CaptionStyle = {
  fontFamily: null,
  fontSizePercent: null,
  textColor: null,
  background: null,
  window: null,
  edgeStyle: null,
};

/**
 * Where the user dragged the caption, as a fraction of the frame.
 *
 * **A delta, not a coordinate.** It is added to whatever position the source
 * gives — none, a rolling ASR window, or a per-cue styled position — so one rule
 * covers every kind of track and nothing has to ask which kind it is holding. A
 * fraction rather than pixels so it survives resize, fullscreen and the
 * mini-player.
 */
export interface CaptionOffset {
  dx: number;
  dy: number;
}

export const NO_CAPTION_OFFSET: CaptionOffset = { dx: 0, dy: 0 };

export function isZeroOffset(offset: CaptionOffset | null): boolean {
  return offset === null || (offset.dx === 0 && offset.dy === 0);
}

/**
 * How wide a string will be, per character, in the document's own pixels.
 *
 * **Flutter measures this and sends it, because neither side can do it alone.**
 * The sidecar holds every cue's text and has no font engine; Flutter has the
 * font engine and, under Decision 1, never sees a cue it is not currently
 * displaying. So Flutter measures the *alphabet* once per font and size and
 * sends the table, and the sidecar applies it to the cue texts it already holds.
 *
 * **It is a table and not a single pixels-per-character number**, and that is
 * measured rather than assumed. Advances at Arial 48 through the bundled libass
 * span 8.3 px (`'`) to 40.5 px (`W`) — a 4.9× range — and a scalar calibrated on
 * a representative sentence under-estimates an all-capitals caption by **26%**
 * and a run of `M` by 46%. Under-estimating is the one direction that lets text
 * clip off the edge of the player, which is the failure this whole mechanism
 * exists to prevent. Summing per-character advances lands within +1–2% on every
 * real caption line tried, always on the safe side.
 * `scratch/measure-advances.ts` is the harness.
 */
export interface CaptionMetrics {
  /** Advance width per character, in ASS pixels at the document's font size. */
  advances: Record<string, number>;
  /**
   * What a character outside the table gets — CJK, emoji, accented Latin.
   *
   * The widest advance measured, so an unlisted glyph is over-counted rather
   * than under-counted. A caption in a script the table does not cover ends up
   * with a generous box and a drag that stops early, which is the failure that
   * costs nothing.
   */
  fallbackAdvance: number;
}

/**
 * The table used when a request carries an offset but no metrics.
 *
 * **It should be unreachable, and it exists because "should be" is not a
 * guarantee.** The client cannot measure before it knows the font, and it learns
 * the font from [CaptionLayout] on the *first* `captions.get` for a track — which
 * by definition carries no offset, because the offset resets when the track
 * changes. Every later request has both. What is left is an older client, or a
 * restored offset that outlived the measurement that produced it, and neither is
 * worth failing the request over.
 *
 * Measured on Arial at ASS font size 48 through the bundled libass, then scaled
 * by the caller for whatever size the document actually uses. It is the *right*
 * table whenever the user has not changed the font, which is the overwhelming
 * majority of the time.
 */
export const FALLBACK_ADVANCES: Record<string, number> = {
  '0': 23.8, '1': 23.8, '2': 23.8, '3': 23.8, '4': 23.8, '5': 23.8, '6': 23.8, '7': 23.8,
  '8': 23.8, '9': 23.8, a: 23.8, b: 23.8, c: 21.6, d: 23.8, e: 23.8, f: 12,
  g: 23.8, h: 23.8, i: 9.6, j: 9.6, k: 21.6, l: 9.5, m: 35.8, n: 23.8,
  o: 23.8, p: 23.8, q: 23.8, r: 14.3, s: 21.6, t: 12, u: 23.8, v: 21.6,
  w: 30.9, x: 21.6, y: 21.5, z: 21.6, A: 28.7, B: 28.7, C: 30.9, D: 30.9,
  E: 28.7, F: 26.3, G: 33.4, H: 30.9, I: 12, J: 21.6, K: 28.7, L: 23.8,
  M: 35.8, N: 30.9, O: 33.4, P: 28.7, Q: 33.4, R: 30.9, S: 28.7, T: 26.2,
  U: 30.9, V: 28.7, W: 40.5, X: 28.7, Y: 28.7, Z: 26.3, ' ': 12.6, '.': 12,
  ',': 12, '!': 12, '?': 23.8, "'": 8.3, '"': 15.2, '-': 14.3, ':': 12, ';': 12,
  '(': 14.2, ')': 14.3,
};

/** The widest entry above. What an unlisted character is charged. */
export const FALLBACK_MAX_ADVANCE = 40.5;

/**
 * Everything the client needs to place a hit rectangle over a caption it cannot
 * see the geometry of.
 *
 * libass composites into the video texture and publishes no rectangle, so the
 * hover cursor, the drag ghost and the live clamp all run on a Flutter estimate
 * of the same string. This is what makes that estimate match the document: the
 * numbers `ass.ts` chose, sent rather than duplicated as constants on the client,
 * because two copies of a layout constant are two things that have to agree and
 * eventually will not.
 */
export interface CaptionLayout {
  fontFamily: string;
  /** ASS `Fontsize`, after any user override. */
  fontSize: number;
  playResX: number;
  playResY: number;
  /** The caption area's inset on every side, in `PlayRes` pixels. */
  margin: number;
  /** `\bord` on an outlined cue, and the box's padding on a boxed one. */
  outlineWidth: number;
  boxPadding: number;
  /** ASS numpad alignment an unpositioned cue lands on. */
  defaultAlignment: number;
  /** Where an unpositioned cue's anchor sits, in `PlayRes` pixels. */
  defaultX: number;
  defaultY: number;
  /** Multiple of [fontSize] between the baselines of a wrapped cue. */
  lineSpacing: number;
}
