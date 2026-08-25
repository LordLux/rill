/**
 * The user's caption style and the drag offset. Task 19 —
 * `docs/architecture.md` §2.9.
 *
 * This file also carried a per-character advance table, so the sidecar could
 * estimate how wide a cue would render and clamp a dragged `\pos` back inside
 * the frame. Phase 5 retired it with the mpv pipeline it was built for: the
 * client now renders the document itself through `ass_render_frame` and clamps
 * against the boxes libass actually produced. The estimate was accurate — within
 * +1–2%, measured — and it is gone because the thing it approximated became
 * directly readable, not because it was wrong.
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
 * documents (32.8 ms on a 3 MB outlier — segments per cue is what makes one)
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
  forceFontFamily?: boolean;
  
  /** Percentage of the document's default size. 100 is unchanged. */
  fontSizePercent: number | null;
  forceFontSize?: boolean;
  
  /** Text colour *and* opacity — `a` is the font-opacity control. */
  textColor: RgbaColor | null;
  forceTextColor?: boolean;
  forceTextOpacity?: boolean;
  
  /** The per-line box. `a: 0` is a user asking for no background. */
  background: RgbaColor | null;
  forceBackgroundColor?: boolean;
  forceBackgroundOpacity?: boolean;
  
  /** The rectangle around every caption on screen. `a: 0` is YouTube's default. */
  window: RgbaColor | null;
  forceWindowColor?: boolean;
  forceWindowOpacity?: boolean;
  
  edgeStyle: CaptionEdgeStyle | null;
  forceEdgeStyle?: boolean;
}

/** Nothing overridden — what a fresh session and the menu's reset both produce. */
export const NO_CAPTION_STYLE: CaptionStyle = {
  fontFamily: null,
  forceFontFamily: true,
  fontSizePercent: null,
  forceFontSize: true,
  textColor: null,
  forceTextColor: true,
  forceTextOpacity: true,
  background: null,
  forceBackgroundColor: true,
  forceBackgroundOpacity: true,
  window: null,
  forceWindowColor: true,
  forceWindowOpacity: true,
  edgeStyle: null,
  forceEdgeStyle: true,
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
 * The numbers `ass.ts` wrote the document with.
 *
 * Sent rather than duplicated as constants on the client, because two copies of
 * a layout constant are two things that have to agree and eventually will not.
 * Always populated on a `captions.get` result — the document is in hand, so it
 * costs nothing — whether or not the caller reads it.
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
