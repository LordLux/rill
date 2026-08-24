/**
 * Cues → ASS (Advanced SubStation Alpha), the one renderer for every format.
 *
 * **Why ASS and not a Flutter overlay** — `architecture.md` §2.9. The short
 * version: YouTube's own caption format positions text anywhere in the frame and
 * carries colours, fonts, edge effects and karaoke, and libass renders exactly
 * that class of styling natively. Drawing captions in Flutter means writing a
 * subtitle layout engine, and then throwing it away.
 *
 * The bundled libmpv (mpv v0.36.0-403 / FFmpeg n6.0, F12/F15) links libass
 * statically alongside HarfBuzz and FriBidi — verified against the artefact the
 * build actually loads, per hard invariant 8, not against a version number.
 *
 * ## The three things ASS gets backwards
 *
 * **Colour** is `&HAABBGGRR`: byte-reversed, and `AA` is *transparency*, so
 * opaque is `00` and invisible is `FF`. [assColor] is the only place that knows.
 *
 * **Colour again, inline.** `\c` and friends take `&HBBGGRR` — *six* digits, no
 * alpha — and alpha rides on separate `\1a` / `\3a` / `\4a` tags. Handing an
 * eight-digit value to `\c` looks like it works, because a fully opaque one
 * (`&H00…`) renders correctly; a *translucent* one silently comes out opaque and
 * the wrong hue. Measured against the bundled libmpv 2026-08-19, which is the
 * only reason it is known: nothing errors and nothing logs. [assColorInline] and
 * [assAlpha] are the pair that keeps it right.
 *
 * **Time** is `H:MM:SS.cc` — one digit of hours, two of centiseconds. Not
 * milliseconds, and not zero-padded hours. A three-digit fraction parses as
 * something else entirely and the whole line lands at the wrong moment.
 *
 * ## Task 19: the user's style, the drag, and the frame
 *
 * Three things now reach this module from outside the caption document, and all
 * three arrive here rather than at mpv because mpv cannot apply them — see
 * `style.ts` for the measurement that settled it.
 *
 * A [CaptionStyle] is folded into the `Style` lines and into the inline tags, so
 * a user override and an authored tag never both survive. A [CaptionOffset] is
 * added to every cue's position, whatever that position was. And [CaptionMetrics]
 * is what makes the last requirement possible at all: a positioned line wider
 * than the frame **runs straight off the edge** — libass does not clamp it and
 * does not wrap it — so a caption dragged into a corner would clip the moment a
 * longer line arrived. Nothing here can measure text, so the client measures and
 * sends a table, and [estimateWidth] is where it lands.
 */

import {
  cueText,
  DEFAULT_FONT_SIZE_PERCENT,
  type Cue,
  type CueAlignment,
  type CueEdgeStyle,
  type CueStyle,
  type CueTrack,
  type RgbaColor,
} from './cues.ts';
import {
  FALLBACK_ADVANCES,
  FALLBACK_MAX_ADVANCE,
  isZeroOffset,
  type CaptionLayout,
  type CaptionMetrics,
  type CaptionOffset,
  type CaptionStyle,
} from './style.ts';

/**
 * The virtual frame the script is authored against.
 *
 * `PlayResX`/`PlayResY` do not have to match the video: libass scales the script
 * to the real frame, and fixing them means a caption is the same relative size
 * on a 360p stream and a 2160p one. 1920×1080 rather than something smaller
 * because YTT positions are fractions and a larger canvas rounds better.
 */
const PLAY_RES_X = 1920;
const PLAY_RES_Y = 1080;

/**
 * The caption area, inset from the frame. Also the `Style`'s margins, and the
 * two have to stay equal — see [position] for why.
 */
const MARGIN = 60;

/** `H:MM:SS.cc`. Centiseconds — see the header. */
export function assTime(ms: number): string {
  const clamped = Math.max(0, Math.round(ms));
  const cs = Math.floor(clamped / 10) % 100;
  const seconds = Math.floor(clamped / 1000) % 60;
  const minutes = Math.floor(clamped / 60_000) % 60;
  const hours = Math.floor(clamped / 3_600_000);
  const pad = (value: number) => String(value).padStart(2, '0');
  return `${hours}:${pad(minutes)}:${pad(seconds)}.${pad(cs)}`;
}

function byte(value: number): string {
  return Math.max(0, Math.min(255, Math.round(value)))
    .toString(16)
    .toUpperCase()
    .padStart(2, '0');
}

/**
 * `&HAABBGGRR` — reversed channel order, and alpha inverted into transparency.
 *
 * **For a `Style` line only.** Inline overrides take [assColorInline]; see the
 * header for the failure an eight-digit `\c` produces.
 */
export function assColor(color: RgbaColor): string {
  return `&H${byte((1 - Math.max(0, Math.min(1, color.a))) * 255)}${assColorInline(color).slice(2)}`;
}

/** `&HBBGGRR` — what `\c`, `\3c` and `\4c` accept. No alpha. */
export function assColorInline(color: RgbaColor): string {
  return `&H${byte(color.b)}${byte(color.g)}${byte(color.r)}`;
}

/** `&HAA&` — what `\1a`, `\3a` and `\4a` accept. Transparency, so opaque is `00`. */
export function assAlpha(alpha: number): string {
  return `&H${byte((1 - Math.max(0, Math.min(1, alpha))) * 255)}&`;
}

/**
 * Escape one cue's text for a `Dialogue` line.
 *
 * Four separate hazards, and three of them are silent:
 *
 *  - **A newline** ends the event. `\N` is ASS's hard line break.
 *  - **A brace** opens an override block, so a caption containing `{` swallows
 *    text up to the next `}` and shows nothing where it was.
 *  - **A backslash** starts an escape; a literal one has to be neutralised or
 *    `C:\temp` renders as `C:` followed by whatever `\t` means.
 *  - **A leading space** is trimmed by the format. `\h` is the hard space.
 */
export function escapeAssText(text: string): string {
  return text
    .replace(/\\/g, '\u2216') // set minus — visually a backslash, inert to ASS
    .replace(/[{}]/g, (brace) => (brace === '{' ? '\uFF5B' : '\uFF5D'))
    .replace(/\r\n|\r|\n/g, '\\N')
    .replace(/^ /, '\\h')
    .replace(/ $/, '\\h');
}

// ---------------------------------------------------------------------------
// Constants the document is built from
// ---------------------------------------------------------------------------

/** Matches the `Default` style below, so `\fs` can be expressed as a percentage of it. */
const DEFAULT_FONT_SIZE = 48;
const DEFAULT_FONT = 'Arial';

/** `\bord` and `\shad` for a cue that asks for one. Match the `Style`'s own outline. */
const OUTLINE_WIDTH = 2.5;
const SHADOW_DEPTH = 2;

/** How far the box extends past the glyphs. `\bord` means padding under `BorderStyle: 3`. */
const BOX_PADDING = 6;

/** ASS numpad alignment for an unpositioned cue: bottom-centre. */
const DEFAULT_ALIGNMENT: CueAlignment = 2;

/** Baseline-to-baseline spacing of a wrapped cue, as a multiple of the font size. */
const LINE_SPACING = 1.2;

/**
 * YouTube's own default caption background: black at 75%.
 *
 * **Drawn unless something says otherwise**, which is a change from task 18 and
 * is deliberate: it is what YouTube draws, and task 19 makes it the drag handle.
 * "Something" is either the user, through the style menu, or the cue itself —
 * a styled track that declares a transparent background has said what it wants
 * and is not overruled. Only a cue that never mentions a background gets this.
 */
const DEFAULT_BACKGROUND: RgbaColor = { r: 0, g: 0, b: 0, a: 0.75 };

const TRANSPARENT: RgbaColor = { r: 0, g: 0, b: 0, a: 0 };
const OPAQUE_BLACK: RgbaColor = { r: 0, g: 0, b: 0, a: 1 };
const HALF_BLACK: RgbaColor = { r: 0, g: 0, b: 0, a: 0.5 };
const OPAQUE_WHITE: RgbaColor = { r: 255, g: 255, b: 255, a: 1 };

/**
 * How far outside the estimate the clamp keeps the caption.
 *
 * The width comes from summing per-character advances, which lands within +1–2%
 * of what libass draws (`style.ts`), and every rounding in this path rounds
 * outward on purpose: an over-estimate stops the drag a few pixels short of the
 * corner, an under-estimate lets the text clip off the edge of the player. Only
 * one of those is a bug.
 */
const ESTIMATE_INFLATION = 1.04;

/**
 * A caption is up to three events, one per layer, and that is not an
 * optimisation — it is the only way both halves of the style menu can work.
 *
 * ASS makes the background a `BorderStyle` on the `Style`, and `BorderStyle: 3`
 * (the box) **replaces the outline** rather than sitting behind it: `\bord`
 * becomes the box's padding and no outline is drawn at all. So a document that
 * puts the box on the text event cannot draw an edge style — and since the box
 * is now on by default, every *Character edge style* the menu offers, and every
 * edge a styled track authored, would silently stop working.
 *
 * Splitting them fixes it. The box is its own event with invisible glyphs
 * (`\1a&HFF&`), sized by the same text at the same `\pos`, on the layer below;
 * the text event keeps `BorderStyle: 1` and its outline. The window is a third
 * event, lower still — `BorderStyle: 4` draws a rectangle round the whole block
 * from `\4c`, with its own per-line box made transparent.
 *
 * This is the compositing YouTube transmits and that task 18 spent its length
 * *undoing*, which is worth being explicit about. The difference is what the two
 * events are: YouTube's duplicates were two halves of one line's styling, which
 * belong merged; these are a backdrop and a line, which belong apart.
 *
 * A document that draws neither emits neither, and no layer numbers, so it is
 * byte-identical to what task 17 rendered.
 */
const LAYER_WINDOW = 0;
const LAYER_BOX = 1;
const LAYER_TEXT = 2;

/** `BorderStyle: 3`, invisible text — the per-line background. */
const BOX_STYLE = 'Box';
/** `BorderStyle: 4`, invisible text and a transparent per-line box — the window. */
const WINDOW_STYLE = 'Window';

// ---------------------------------------------------------------------------
// One user style folded into one track's defaults
// ---------------------------------------------------------------------------

interface Resolved {
  style: CaptionStyle | null;
  offset: CaptionOffset | null;
  metrics: CaptionMetrics | null;
  fontFamily: string;
  fontSize: number;
  textColor: RgbaColor;
  /** The background for a cue that does not declare one of its own. */
  background: RgbaColor;
  window: RgbaColor;
  /** Whether any cue draws a box. Decides whether the extra `Style` line exists. */
  anyBox: boolean;
  hasWindow: boolean;
  /** Whether events carry an explicit layer. False keeps task 17's bytes. */
  layered: boolean;
}

function resolve(options: RenderOptions, cues: readonly Cue[] = []): Resolved {
  const style = options.style ?? null;
  const window = style?.window ?? TRANSPARENT;
  const resolved: Resolved = {
    style,
    offset: options.offset ?? null,
    metrics: options.metrics ?? null,
    fontFamily: style?.fontFamily ?? DEFAULT_FONT,
    fontSize: Math.round(
      (DEFAULT_FONT_SIZE * (style?.fontSizePercent ?? DEFAULT_FONT_SIZE_PERCENT)) /
        DEFAULT_FONT_SIZE_PERCENT,
    ),
    textColor: style?.textColor ?? OPAQUE_WHITE,
    background: style?.background ?? DEFAULT_BACKGROUND,
    window,
    anyBox: false,
    hasWindow: window.a > 0,
    layered: false,
  };
  resolved.anyBox = cues.some((cue) => cueBackground(cue.style, resolved).a > 0);
  resolved.layered = resolved.anyBox || resolved.hasWindow;
  return resolved;
}

/**
 * The box one cue draws. `a: 0` is a cue that draws none.
 *
 * Three sources in precedence order, and the middle one is the reason this is
 * not a `??` chain: **a cue that declares a transparent background has said
 * something**, and the document default must not overrule it. Task 18's styled
 * tracks turn their backgrounds off explicitly, and a default that ignored that
 * would put a black box behind every caption-art frame.
 */
function cueBackground(style: CueStyle | null, resolved: Resolved): RgbaColor {
  if (resolved.style?.background != null) return resolved.style.background;
  if (style?.backgroundColor != null) return style.backgroundColor;
  return resolved.background;
}

/**
 * The geometry the client needs to place an invisible hit rectangle over a
 * caption whose real rectangle nothing publishes.
 *
 * Derived from the same constants the document is written with rather than
 * copied into the client, because two copies of a layout constant are two things
 * that have to agree and eventually will not.
 */
export function assLayout(options: RenderOptions = {}): CaptionLayout {
  const resolved = resolve(options);
  return {
    fontFamily: resolved.fontFamily,
    fontSize: resolved.fontSize,
    playResX: PLAY_RES_X,
    playResY: PLAY_RES_Y,
    margin: MARGIN,
    outlineWidth: OUTLINE_WIDTH,
    boxPadding: BOX_PADDING,
    defaultAlignment: DEFAULT_ALIGNMENT,
    defaultX: position(0.5, PLAY_RES_X),
    defaultY: position(1, PLAY_RES_Y),
    lineSpacing: LINE_SPACING,
  };
}

// ---------------------------------------------------------------------------
// Width, and the clamp it exists for
// ---------------------------------------------------------------------------

/**
 * The widest line of a cue, in `PlayRes` pixels, biased large.
 *
 * The table comes from the client, which is the only side with a font engine.
 * When one did not arrive, [FALLBACK_ADVANCES] stands in — measured on Arial at
 * font size 48 and scaled to whatever size this document uses, so it is the
 * right table for every user who has not changed the font. See `style.ts` for
 * why this is a table and not one pixels-per-character number: a scalar
 * calibrated on a representative sentence under-estimates an all-capitals line
 * by 26%, and under-estimating is the direction that clips text off the screen.
 */
export function estimateWidth(
  text: string,
  metrics: CaptionMetrics | null,
  fontSize: number,
): number {
  const scale = metrics === null ? fontSize / DEFAULT_FONT_SIZE : 1;
  const advances = metrics?.advances ?? FALLBACK_ADVANCES;
  const fallback = (metrics?.fallbackAdvance ?? FALLBACK_MAX_ADVANCE) * scale;

  let widest = 0;
  for (const line of text.split(/\r\n|\r|\n/)) {
    let width = 0;
    for (const character of line) {
      const advance = advances[character];
      width += advance === undefined ? fallback : advance * scale;
    }
    if (width > widest) widest = width;
  }
  return widest * ESTIMATE_INFLATION;
}

function lineCount(text: string): number {
  return text.split(/\r\n|\r|\n/).length;
}

/**
 * Slide a span of [extent] anchored at [anchor] back inside `[pad, limit - pad]`.
 *
 * `align` is the fraction of the span that sits before the anchor — 0 for a left
 * or top anchor, 0.5 for a centred one, 1 for a right or bottom one. Returns the
 * anchor's new value.
 *
 * A span too large for the frame is pinned to the low edge rather than centred:
 * libass wraps a positioned line at the frame width, so wherever the estimate
 * exceeds the frame the real text is narrower than it, and pinning keeps the
 * start of the line on screen.
 */
function clampSpan(
  anchor: number,
  extent: number,
  align: number,
  limit: number,
  pad: number,
): number {
  const low = pad;
  const high = limit - pad;
  if (extent >= high - low) return low + extent * align;
  const start = Math.min(Math.max(anchor - extent * align, low), high - extent);
  return start + extent * align;
}

/** The fraction of a box that sits left of its `\an` anchor. */
function horizontalAlign(alignment: CueAlignment): number {
  const column = alignment % 3; // 1 left, 2 centre, 0 right
  return column === 1 ? 0 : column === 2 ? 0.5 : 1;
}

/** The fraction of a box that sits above its `\an` anchor. */
function verticalAlign(alignment: CueAlignment): number {
  return alignment <= 3 ? 1 : alignment <= 6 ? 0.5 : 0;
}

/**
 * Where one cue's anchor ends up: its own position, plus the drag, pulled back
 * inside the frame.
 *
 * Returns `null` when there is nothing to write — no drag and no authored
 * position — so a plain track renders exactly the document it rendered before
 * any of this existed.
 */
function placement(cue: Cue, resolved: Resolved): { x: number; y: number } | null {
  const positioned = cue.style?.positionX != null && cue.style.positionY != null;
  if (!positioned && isZeroOffset(resolved.offset)) return null;

  const alignment = cue.style?.alignment ?? DEFAULT_ALIGNMENT;
  const baseX = positioned ? position(cue.style!.positionX!, PLAY_RES_X) : position(0.5, PLAY_RES_X);
  const baseY = positioned ? position(cue.style!.positionY!, PLAY_RES_Y) : position(1, PLAY_RES_Y);

  const offset = resolved.offset;
  const shiftedX = baseX + (offset?.dx ?? 0) * PLAY_RES_X;
  const shiftedY = baseY + (offset?.dy ?? 0) * PLAY_RES_Y;

  // The estimate is of the *glyphs*; whatever is drawn around them has to be
  // paid for too, or a caption dragged flush to the edge clips its own box.
  const drawn = cueBackground(cue.style, resolved).a > 0 ? BOX_PADDING : OUTLINE_WIDTH;
  const text = cueText(cue);
  const width = estimateWidth(text, resolved.metrics, resolved.fontSize) + 2 * drawn;
  const height = lineCount(text) * resolved.fontSize * LINE_SPACING;

  return {
    x: Math.round(clampSpan(shiftedX, width, horizontalAlign(alignment), PLAY_RES_X, drawn)),
    y: Math.round(clampSpan(shiftedY, height, verticalAlign(alignment), PLAY_RES_Y, drawn)),
  };
}

/**
 * A fraction of the frame → a `\pos` pixel, **inside the caption area** rather
 * than the whole frame.
 *
 * YTT's percentages are relative to the video, and taken literally
 * `avVerPos: 100` — which is the default window every manual track uses — puts a
 * caption's baseline flush against the bottom edge, underneath the player's own
 * controls. The `Style` below already reserves [MARGIN] on every side for
 * exactly that reason, so positions are mapped into the same box.
 *
 * The property that makes this the right inset rather than an arbitrary one: a
 * cue at the default window (`50%`, `100%`, bottom-centre) lands on exactly the
 * pixel an *unpositioned* cue lands on. A styled track and a plain one sit at
 * the same height, and turning styling on moves nothing that did not ask to move.
 */
function position(fraction: number, extent: number): number {
  return Math.round(MARGIN + fraction * (extent - 2 * MARGIN));
}

// ---------------------------------------------------------------------------
// Inline overrides
// ---------------------------------------------------------------------------

interface OverrideContext {
  /** The `\pos` this event carries, or `null` for none. */
  placement?: { x: number; y: number } | null;
  /**
   * Set on a *run* inside a cue, to the line's base colour.
   *
   * Its presence is also what marks the call as a run rather than a line, and a
   * run has no box and no edges of its own — task 18's `CueSegment.style` carries
   * colour and nothing else for exactly that reason.
   */
  baseTextColor?: RgbaColor | null;
}

/**
 * Inline overrides for one cue or one run, or `''` when it wants the default.
 *
 * Everything is expressed as an override rather than as a named `Style`, because
 * YTT styles individual cues: a style table would have to be synthesised from
 * the cues, deduplicated, and named, to produce output libass treats identically.
 *
 * **A user override suppresses the authored tag rather than fighting it.** If the
 * user has chosen a font, no `\fn` is emitted at all; the `Style` line carries
 * their choice and there is nothing left for it to lose to. The alternative —
 * emit both and rely on order — puts the answer in libass's precedence rules
 * rather than in this file.
 */
function overrides(
  style: CueStyle | null,
  resolved: Resolved,
  context: OverrideContext = {},
): string {
  const isRun = context.baseTextColor !== undefined;
  const tags: string[] = [];
  const user = resolved.style;

  if (style?.alignment != null) tags.push(`\\an${style.alignment}`);
  if (context.placement != null) {
    tags.push(`\\pos(${context.placement.x},${context.placement.y})`);
  }

  if (style !== null) {
    if (style.fontFamily !== null && user?.fontFamily == null) tags.push(`\\fn${style.fontFamily}`);
    if (style.fontSizePercent !== null && user?.fontSizePercent == null) {
      tags.push(
        `\\fs${Math.round((style.fontSizePercent / DEFAULT_FONT_SIZE_PERCENT) * resolved.fontSize)}`,
      );
    }
  }

  const textColor = effectiveTextColor(style?.textColor ?? null, resolved, context.baseTextColor);
  if (textColor !== null) {
    tags.push(`\\c${assColorInline(textColor)}`);
    if (textColor.a < 1) tags.push(`\\1a${assAlpha(textColor.a)}`);
  }

  if (!isRun) {
    // The edge colour is the outline *and* the shadow. It only reaches the text
    // event, because the box event has neither.
    if (style?.edgeColor != null && user?.edgeStyle == null) {
      tags.push(`\\3c${assColorInline(style.edgeColor)}`);
      tags.push(`\\4c${assColorInline(style.edgeColor)}`);
    }
    const edges = edgeStylesFor(style, resolved);
    if (edges !== null) {
      // `\bord` and `\shad` are the two knobs libass has for this, and they are
      // independent — which is the whole point of `edgeStyles` being a set. A
      // caption that YouTube composites from an outline layer and a shadow layer
      // is one line carrying both. "raised" and "depressed" are drop shadows in
      // opposite directions, which ASS cannot express as a direction, so both
      // become a shadow — what mpv's own WebVTT converter does with the same CSS.
      tags.push(`\\bord${edges.includes('outline') ? OUTLINE_WIDTH : 0}`);
      tags.push(`\\shad${edges.some(isShadow) ? SHADOW_DEPTH : 0}`);
    }
  }

  if (style !== null) {
    if (style.bold !== null) tags.push(`\\b${style.bold ? 1 : 0}`);
    if (style.italic !== null) tags.push(`\\i${style.italic ? 1 : 0}`);
    if (style.underline !== null) tags.push(`\\u${style.underline ? 1 : 0}`);
  }

  return tags.length === 0 ? '' : `{${tags.join('')}}`;
}

/**
 * The colour one run actually gets, or `null` to inherit the `Style`.
 *
 * **The karaoke rule lives here, and it is why this is not a one-liner.** A user
 * font colour replaces the *line's base colour* and nothing else. On a karaoke
 * track the sung and unsung runs are two inline colours; replacing both flattens
 * the highlight into one colour, so the caption looks broken while the setting
 * looks like it worked — the silent class of failure this project keeps finding.
 * So a run whose colour differs from the line's base is left exactly as authored,
 * and only the base follows the user.
 *
 * It generalises past karaoke without having to detect it: on a plain track every
 * run is the base and everything changes, and on a track that colours one word
 * for emphasis the emphasis survives while the rest follows the user.
 */
function effectiveTextColor(
  authored: RgbaColor | null,
  resolved: Resolved,
  baseTextColor: RgbaColor | null | undefined,
): RgbaColor | null {
  const user = resolved.style?.textColor ?? null;
  if (user === null) return authored;
  if (baseTextColor !== undefined) {
    if (authored !== null && !sameColor(authored, baseTextColor)) return authored;
    // Explicitly, rather than by falling through: an ASS override persists to
    // the end of its event, so a base run that emitted nothing after a
    // highlighted one would inherit the highlight — the very distinction this
    // function exists to keep.
    return user;
  }
  // The line itself. The `Style` already carries the user's colour, so there is
  // nothing to say.
  return null;
}

function sameColor(a: RgbaColor, b: RgbaColor | null): boolean {
  if (b === null) return false;
  return a.r === b.r && a.g === b.g && a.b === b.b && a.a === b.a;
}

/** What edges this cue draws, or `null` to leave the `Style`'s alone. */
function edgeStylesFor(style: CueStyle | null, resolved: Resolved): CueEdgeStyle[] | null {
  const user = resolved.style?.edgeStyle ?? null;
  if (user !== null) return user === 'none' ? ['none'] : [user];
  return style?.edgeStyles ?? null;
}

function isShadow(edge: CueEdgeStyle): boolean {
  return edge === 'dropShadow' || edge === 'raised' || edge === 'depressed';
}

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

export interface RenderOptions {
  /** The caption style menu's current state, or `null` for an untouched one. */
  style?: CaptionStyle | null;
  /** Where the user dragged the caption, as a fraction of the frame. */
  offset?: CaptionOffset | null;
  /** The client's width table, for the no-overflow clamp. */
  metrics?: CaptionMetrics | null;
  /** Which renderer the client is using (controls whether box events are emitted). */
  renderer?: 'mpv' | 'libass_layer';
}

const STYLE_FORMAT =
  'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, ' +
  'BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, ' +
  'BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding';

/**
 * A whole ASS document for one track.
 *
 * `ScaledBorderAndShadow: yes` is load-bearing and easy to leave out: without it
 * the outline stays a fixed pixel width while the text scales, so captions on a
 * 2160p stream get a hairline that disappears against bright video.
 *
 * `WrapStyle: 0` is smart wrapping with the lower line wider — the subtitling
 * convention, and what YouTube does.
 */
export function renderAss(track: CueTrack, options: RenderOptions = {}): string {
  const resolved = resolve(options, track.cues);

  const styleLine = (
    name: string,
    borderStyle: number,
    outline: number,
    colours: { primary: RgbaColor; outlineColour: RgbaColor; back: RgbaColor },
  ) =>
    `Style: ${name},${resolved.fontFamily},${resolved.fontSize},${assColor(colours.primary)},` +
    `&H000000FF,${assColor(colours.outlineColour)},${assColor(colours.back)},` +
    `0,0,0,0,100,100,0,0,${borderStyle},${outline},0,${DEFAULT_ALIGNMENT},` +
    `${MARGIN},${MARGIN},${MARGIN},1`;

  const lines: string[] = [
    '[Script Info]',
    '; Generated by Rill from YouTube timed text. Do not edit.',
    `; source: ${track.isAutoGenerated ? 'asr' : 'manual'} ${track.languageCode}`,
    'ScriptType: v4.00+',
    'WrapStyle: 0',
    'ScaledBorderAndShadow: yes',
    'YCbCr Matrix: None',
    `PlayResX: ${PLAY_RES_X}`,
    `PlayResY: ${PLAY_RES_Y}`,
    '',
    '[V4+ Styles]',
    STYLE_FORMAT,
    // White text, opaque black outline, no shadow, bottom-centre, 60px of bottom
    // margin so a caption clears the player's own controls.
    styleLine('Default', 1, OUTLINE_WIDTH, {
      primary: resolved.textColor,
      outlineColour: OPAQUE_BLACK,
      back: HALF_BLACK,
    }),
    // **Emitted only when something actually draws one.** A caption track whose
    // background and window are both off has to produce the document it produced
    // before either existed, byte for byte; an unconditional extra `Style` would
    // change the header of every such track for a feature it does not use.
    ...(resolved.anyBox && options.renderer !== 'libass_layer'
      ? [
          styleLine(BOX_STYLE, 3, BOX_PADDING, {
            primary: TRANSPARENT,
            outlineColour: resolved.background,
            back: HALF_BLACK,
          }),
        ]
      : []),
    ...(resolved.hasWindow && options.renderer !== 'libass_layer'
      ? [
          styleLine(WINDOW_STYLE, 4, BOX_PADDING, {
            primary: TRANSPARENT,
            outlineColour: TRANSPARENT,
            back: resolved.window,
          }),
        ]
      : []),
    '',
    '[Events]',
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
  ];

  for (const cue of track.cues) {
    lines.push(...events(cue, resolved, options));
  }

  return lines.join('\n') + '\n';
}

/**
 * The one to three `Dialogue` lines one cue becomes: window, box, text.
 *
 * The backdrops carry the same text as the line they sit behind, with invisible
 * glyphs, because that is what makes them the right size — ASS has no rectangle
 * primitive outside a drawing command, and a drawing command would need the
 * width nothing here can measure.
 */
function events(cue: Cue, resolved: Resolved, options: RenderOptions): string[] {
  const at = placement(cue, resolved);
  const layer = (value: number) => (resolved.layered && options.renderer !== 'libass_layer' ? value : 0);
  const out: string[] = [];

  const anchor = cue.style?.alignment != null ? `\\an${cue.style.alignment}` : '';
  const positionTag = at != null ? `\\pos(${at.x},${at.y})` : '';
  const flat = escapeAssText(cueText(cue));

  if (resolved.hasWindow && options.renderer !== 'libass_layer') {
    out.push(
      `Dialogue: ${layer(LAYER_WINDOW)},${assTime(cue.startMs)},${assTime(cue.endMs)},` +
        `${WINDOW_STYLE},,0,0,0,,{${anchor}${positionTag}\\1a&HFF&\\3a&HFF&` +
        `\\4c${assColorInline(resolved.window)}\\4a${assAlpha(resolved.window.a)}}${flat}`,
    );
  }

  const background = cueBackground(cue.style, resolved);
  if (background.a > 0 && options.renderer !== 'libass_layer') {
    out.push(
      `Dialogue: ${layer(LAYER_BOX)},${assTime(cue.startMs)},${assTime(cue.endMs)},` +
        `${BOX_STYLE},,0,0,0,,{${anchor}${positionTag}\\1a&HFF&` +
        `\\3c${assColorInline(background)}\\3a${assAlpha(background.a)}}${flat}`,
    );
  }

  out.push(
    `Dialogue: ${layer(LAYER_TEXT)},${assTime(cue.startMs)},${assTime(cue.endMs)},Default,,0,0,0,,` +
      `${overrides(cue.style, resolved, { placement: at })}${runs(cue, resolved)}`,
  );
  return out;
}

/**
 * A cue's text, as one escaped string or as a run per segment.
 *
 * **A run is how a karaoke highlight is drawn**, and it needs no `\k`: YouTube
 * moves the split between two differently-penned segments from one event to the
 * next, so the stepping is already in the timings. See [CueSegment.style].
 *
 * Escaping is per run rather than over the joined text, because `escapeAssText`
 * protects the *leading* space of what it is given — and a segment's leading
 * space is a word boundary in the middle of a line, not an indent to preserve.
 */
function runs(cue: Cue, resolved: Resolved): string {
  if (!cue.segments.some((segment) => segment.style !== null)) {
    return escapeAssText(cueText(cue));
  }
  const baseTextColor = cue.style?.textColor ?? resolved.textColor;
  return cue.segments
    .map(
      (segment) =>
        `${overrides(segment.style, resolved, { baseTextColor })}${escapeAssText(segment.text)}`,
    )
    .join('');
}
