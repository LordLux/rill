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
 */

import {
  cueText,
  DEFAULT_FONT_SIZE_PERCENT,
  type Cue,
  type CueEdgeStyle,
  type CueStyle,
  type CueTrack,
  type RgbaColor,
} from './cues.ts';

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

/**
 * Inline overrides for one cue, or `''` when it wants the default style.
 *
 * Everything is expressed as an override rather than as a named `Style`, because
 * YTT styles individual cues: a style table would have to be synthesised from
 * the cues, deduplicated, and named, to produce output libass treats identically.
 */
function overrides(style: CueStyle | null): string {
  if (style === null) return '';
  const tags: string[] = [];

  if (style.alignment !== null) tags.push(`\\an${style.alignment}`);
  if (style.positionX !== null && style.positionY !== null) {
    tags.push(`\\pos(${position(style.positionX, PLAY_RES_X)},${position(style.positionY, PLAY_RES_Y)})`);
  }
  if (style.fontFamily !== null) tags.push(`\\fn${style.fontFamily}`);
  if (style.fontSizePercent !== null) {
    tags.push(
      `\\fs${Math.round((style.fontSizePercent / DEFAULT_FONT_SIZE_PERCENT) * DEFAULT_FONT_SIZE)}`,
    );
  }
  if (style.textColor !== null) {
    tags.push(`\\c${assColorInline(style.textColor)}`);
    if (style.textColor.a < 1) tags.push(`\\1a${assAlpha(style.textColor.a)}`);
  }

  // A background is a *box*, which classic ASS makes a `Style` property and not
  // a tag — so [hasBox] is what sends the Dialogue to the `Boxed` style, and the
  // box is then drawn in the *outline* colour. Measured, because it is not what
  // the names suggest: under `BorderStyle: 3` libass fills from `\3c`, not `\4c`.
  const boxed = hasBox(style);
  if (boxed && style.backgroundColor !== null) {
    tags.push(`\\3c${assColorInline(style.backgroundColor)}`);
    tags.push(`\\3a${assAlpha(style.backgroundColor.a)}`);
  } else if (style.edgeColor !== null) {
    tags.push(`\\3c${assColorInline(style.edgeColor)}`);
    tags.push(`\\4c${assColorInline(style.edgeColor)}`);
  }

  if (style.edgeStyles !== null && !boxed) {
    // `\bord` and `\shad` are the two knobs libass has for this, and they are
    // independent — which is the whole point of `edgeStyles` being a set. A
    // caption that YouTube composites from an outline layer and a shadow layer
    // is one line carrying both. "raised" and "depressed" are drop shadows in
    // opposite directions, which ASS cannot express as a direction, so both
    // become a shadow — what mpv's own WebVTT converter does with the same CSS.
    tags.push(`\\bord${style.edgeStyles.includes('outline') ? OUTLINE_WIDTH : 0}`);
    tags.push(`\\shad${style.edgeStyles.some(isShadow) ? SHADOW_DEPTH : 0}`);
  }

  if (style.bold !== null) tags.push(`\\b${style.bold ? 1 : 0}`);
  if (style.italic !== null) tags.push(`\\i${style.italic ? 1 : 0}`);
  if (style.underline !== null) tags.push(`\\u${style.underline ? 1 : 0}`);

  return tags.length === 0 ? '' : `{${tags.join('')}}`;
}

function isShadow(edge: CueEdgeStyle): boolean {
  return edge === 'dropShadow' || edge === 'raised' || edge === 'depressed';
}

/** A background only counts when it is actually going to be seen. */
function hasBox(style: CueStyle): boolean {
  return style.backgroundColor !== null && style.backgroundColor.a > 0;
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

/** Matches the `Default` style below, so `\fs` can be expressed as a percentage of it. */
const DEFAULT_FONT_SIZE = 48;

/** `\bord` and `\shad` for a cue that asks for one. Match the `Style`'s own outline. */
const OUTLINE_WIDTH = 2.5;
const SHADOW_DEPTH = 2;

/** The `BorderStyle: 3` style, for cues carrying a background. */
const BOXED_STYLE = 'Boxed';

/** How far the box extends past the glyphs. `\bord` means padding under `BorderStyle: 3`. */
const BOX_PADDING = 6;

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
export function renderAss(track: CueTrack): string {
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
    'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, ' +
      'BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, ' +
      'BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
    // White text, opaque black outline, no shadow, bottom-centre, 60px of bottom
    // margin so a caption clears the player's own controls.
    `Style: Default,Arial,${DEFAULT_FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,` +
      `&H80000000,0,0,0,0,100,100,0,0,1,${OUTLINE_WIDTH},0,2,${MARGIN},${MARGIN},${MARGIN},1`,
    // Identical but for `BorderStyle: 3`, the opaque box — the only way classic
    // ASS renders a caption background, and not something a tag can switch on.
    //
    // **Emitted only when a cue actually wants one.** A caption track that
    // declares no styling has to produce the document it produced before styling
    // existed, byte for byte; an unconditional second `Style` would change the
    // header of every plain track for a feature none of them use.
    ...(track.cues.some((cue) => cue.style !== null && hasBox(cue.style))
      ? [
          `Style: ${BOXED_STYLE},Arial,${DEFAULT_FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,` +
            `&H80000000,0,0,0,0,100,100,0,0,3,${BOX_PADDING},0,2,${MARGIN},${MARGIN},${MARGIN},1`,
        ]
      : []),
    '',
    '[Events]',
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
  ];

  for (const cue of track.cues) {
    lines.push(dialogue(cue));
  }

  return lines.join('\n') + '\n';
}

/**
 * One `Dialogue` line: the cue's overrides, then a run per segment.
 *
 * **A run is how a karaoke highlight is drawn**, and it needs no `\k`: YouTube
 * moves the split between two differently-penned segments from one event to the
 * next, so the stepping is already in the timings. See [CueSegment.style].
 *
 * Escaping is per run rather than over the joined text, because `escapeAssText`
 * protects the *leading* space of what it is given — and a segment's leading
 * space is a word boundary in the middle of a line, not an indent to preserve.
 */
function dialogue(cue: Cue): string {
  const style = cue.style !== null && hasBox(cue.style) ? BOXED_STYLE : 'Default';
  const runs = cue.segments.some((segment) => segment.style !== null)
    ? cue.segments.map((segment) => `${overrides(segment.style)}${escapeAssText(segment.text)}`).join('')
    : escapeAssText(cueText(cue));
  return (
    `Dialogue: 0,${assTime(cue.startMs)},${assTime(cue.endMs)},${style},,0,0,0,,` +
    `${overrides(cue.style)}${runs}`
  );
}
