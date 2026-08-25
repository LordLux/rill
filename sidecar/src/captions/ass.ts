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
 * ## Task 19: the user's style and the drag
 *
 * Two things reach this module from outside the caption document, and both
 * arrive here rather than at mpv because mpv cannot apply them — see `style.ts`
 * for the measurement that settled it.
 *
 * A [CaptionStyle] is folded into the `Style` lines and into the inline tags, so
 * a user override and an authored tag never both survive. A [CaptionOffset] is
 * added to every cue's position, whatever that position was.
 *
 * ## What this module no longer does, and why that is not a loss
 *
 * It used to estimate every cue's rendered width from a client-measured advance
 * table and clamp the `\pos` back inside the frame, because libass does not
 * clamp a positioned line and the *mpv* pipeline could not see what libass drew
 * — so both sides had to approximate a box neither could reach. `LibassLayer`
 * calls `ass_render_frame` and gets the real boxes, and clamps against them
 * every frame. The estimate was the right answer to that problem; phase 5
 * removed the problem. Backgrounds and windows left with it — the client paints
 * those now — so every cue here is exactly one `Dialogue`, on layer 0.
 * `architecture.md` §2.9.
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
  isZeroOffset,
  type CaptionLayout,
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

/**
 * How far a background box extends past the glyphs.
 *
 * Nothing in this file draws one any more — the client paints backgrounds from
 * [CaptionStyle] — but it is still published on [CaptionLayout] so the padding
 * the client uses is the document's number rather than a second copy of it.
 */
const BOX_PADDING = 6;

/** ASS numpad alignment for an unpositioned cue: bottom-centre. */
const DEFAULT_ALIGNMENT: CueAlignment = 2;

/** Baseline-to-baseline spacing of a wrapped cue, as a multiple of the font size. */
const LINE_SPACING = 1.2;

const OPAQUE_BLACK: RgbaColor = { r: 0, g: 0, b: 0, a: 1 };
const HALF_BLACK: RgbaColor = { r: 0, g: 0, b: 0, a: 0.5 };
const OPAQUE_WHITE: RgbaColor = { r: 255, g: 255, b: 255, a: 1 };

// ---------------------------------------------------------------------------
// One user style folded into one track's defaults
// ---------------------------------------------------------------------------

interface Resolved {
  style: CaptionStyle | null;
  offset: CaptionOffset | null;
  fontFamily: string;
  fontSize: number;
  textColor: RgbaColor;
}

function resolve(options: RenderOptions): Resolved {
  const style = options.style ?? null;
  return {
    style,
    offset: options.offset ?? null,
    fontFamily: style?.fontFamily ?? DEFAULT_FONT,
    fontSize: Math.round(
      (DEFAULT_FONT_SIZE * (style?.fontSizePercent ?? DEFAULT_FONT_SIZE_PERCENT)) /
        DEFAULT_FONT_SIZE_PERCENT,
    ),
    textColor: style?.textColor ?? OPAQUE_WHITE,
  };
}

/**
 * The numbers this document was written with, published rather than duplicated
 * as constants on the client — two copies of a layout constant are two things
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
// Where a cue lands
// ---------------------------------------------------------------------------

/**
 * Where one cue's anchor ends up: its own position, plus the drag.
 *
 * Returns `null` when there is nothing to write — no drag and no authored
 * position — so a plain track renders exactly the document it rendered before
 * any of this existed. **That null is a guarantee, not an optimisation**, and it
 * is what the byte-identity test in `captions.test.ts` pins.
 *
 * **No clamp.** This used to pull the anchor back inside the frame against an
 * estimated text width, because libass will not clamp a positioned line and the
 * mpv pipeline could not see where the line actually was. `LibassLayer` reads
 * the rendered boxes out of `ass_render_frame` and clamps against those, at rest
 * and mid-drag alike, so an approximation here would only be a second, worse
 * answer to a question already answered exactly. See `architecture.md` §2.9.
 */
function placement(cue: Cue, resolved: Resolved): { x: number; y: number } | null {
  const positioned = cue.style?.positionX != null && cue.style.positionY != null;
  if (!positioned && isZeroOffset(resolved.offset)) return null;

  const baseX = positioned ? position(cue.style!.positionX!, PLAY_RES_X) : position(0.5, PLAY_RES_X);
  const baseY = positioned ? position(cue.style!.positionY!, PLAY_RES_Y) : position(1, PLAY_RES_Y);

  const offset = resolved.offset;
  return {
    x: Math.round(baseX + (offset?.dx ?? 0) * PLAY_RES_X),
    y: Math.round(baseY + (offset?.dy ?? 0) * PLAY_RES_Y),
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
    if (style.fontFamily !== null && (user?.fontFamily == null || user?.forceFontFamily === false)) {
      tags.push(`\\fn${style.fontFamily}`);
    }
    if (style.fontSizePercent !== null && (user?.fontSizePercent == null || user?.forceFontSize === false)) {
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
    if (style?.edgeColor != null && (user?.edgeStyle == null || user?.forceEdgeStyle === false)) {
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
  const forceColor = resolved.style?.forceTextColor ?? true;
  const forceAlpha = resolved.style?.forceTextOpacity ?? true;

  if (user === null) return authored;

  const isHighlight = baseTextColor !== undefined && authored !== null && !sameColor(authored, baseTextColor);

  let r = user.r, g = user.g, b = user.b, a = user.a;
  if (!forceColor && authored !== null) {
    r = authored.r; g = authored.g; b = authored.b;
  }
  if (!forceAlpha && authored !== null) {
    a = authored.a;
  }

  if (baseTextColor !== undefined) {
    if (isHighlight) return authored;
    return { r, g, b, a };
  }
  
  if (r === user.r && g === user.g && b === user.b && a === user.a) {
    return null;
  }
  return { r, g, b, a };
}

function sameColor(a: RgbaColor, b: RgbaColor | null): boolean {
  if (b === null) return false;
  return a.r === b.r && a.g === b.g && a.b === b.b && a.a === b.a;
}

/** What edges this cue draws, or `null` to leave the `Style`'s alone. */
function edgeStylesFor(style: CueStyle | null, resolved: Resolved): CueEdgeStyle[] | null {
  const user = resolved.style?.edgeStyle ?? null;
  const force = resolved.style?.forceEdgeStyle ?? true;
  
  if (user !== null) {
    if (!force && style?.edgeStyles != null) return style.edgeStyles;
    return user === 'none' ? ['none'] : [user];
  }
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
  const resolved = resolve(options);

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
    '',
    '[Events]',
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
  ];

  for (const cue of track.cues) {
    lines.push(event(cue, resolved));
  }

  return lines.join('\n') + '\n';
}

/**
 * The one `Dialogue` line a cue becomes. Always layer 0.
 *
 * It used to be up to three — a `BorderStyle: 4` window and a `BorderStyle: 3`
 * per-line box under the text, each an invisible-glyph copy of the same string
 * on its own layer, because ASS makes a background a property of the `Style` and
 * `BorderStyle: 3` *replaces* the outline rather than sitting behind it. The
 * client draws both backdrops now, from the same [CaptionStyle] this function
 * reads, over boxes it measured rather than under text it had to re-emit to
 * size them. So the layer numbers went with them, and every document is back to
 * one event per cue.
 */
function event(cue: Cue, resolved: Resolved): string {
  const at = placement(cue, resolved);
  return (
    `Dialogue: 0,${assTime(cue.startMs)},${assTime(cue.endMs)},Default,,0,0,0,,` +
    `${overrides(cue.style, resolved, { placement: at })}${runs(cue, resolved)}`
  );
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
