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
 * ## The two things ASS gets backwards
 *
 * **Colour** is `&HAABBGGRR`: byte-reversed, and `AA` is *transparency*, so
 * opaque is `00` and invisible is `FF`. [assColor] is the only place that knows.
 *
 * **Time** is `H:MM:SS.cc` — one digit of hours, two of centiseconds. Not
 * milliseconds, and not zero-padded hours. A three-digit fraction parses as
 * something else entirely and the whole line lands at the wrong moment.
 */

import { cueText, type Cue, type CueStyle, type CueTrack, type RgbaColor } from './cues.ts';

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

/** `&HAABBGGRR` — reversed channel order, and alpha inverted into transparency. */
export function assColor(color: RgbaColor): string {
  const byte = (value: number) =>
    Math.max(0, Math.min(255, Math.round(value)))
      .toString(16)
      .toUpperCase()
      .padStart(2, '0');
  const transparency = byte((1 - Math.max(0, Math.min(1, color.a))) * 255);
  return `&H${transparency}${byte(color.b)}${byte(color.g)}${byte(color.r)}`;
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
    tags.push(
      `\\pos(${Math.round(style.positionX * PLAY_RES_X)},${Math.round(style.positionY * PLAY_RES_Y)})`,
    );
  }
  if (style.fontFamily !== null) tags.push(`\\fn${style.fontFamily}`);
  if (style.fontSizePercent !== null) {
    tags.push(`\\fs${Math.round((style.fontSizePercent / 100) * DEFAULT_FONT_SIZE)}`);
  }
  if (style.textColor !== null) tags.push(`\\c${assColor(style.textColor)}`);
  if (style.edgeColor !== null) tags.push(`\\3c${assColor(style.edgeColor)}`);
  if (style.backgroundColor !== null) tags.push(`\\4c${assColor(style.backgroundColor)}`);
  if (style.edgeStyle !== null) {
    // `\bord` and `\shad` are the two knobs libass has for this. "raised" and
    // "depressed" are drop shadows in opposite directions, which ASS cannot
    // express as a direction — both become a shadow, which is what mpv's own
    // WebVTT converter does with the same CSS values.
    switch (style.edgeStyle) {
      case 'none':
        tags.push('\\bord0', '\\shad0');
        break;
      case 'outline':
        tags.push('\\bord2', '\\shad0');
        break;
      case 'dropShadow':
      case 'raised':
      case 'depressed':
        tags.push('\\bord0', '\\shad2');
        break;
    }
  }
  if (style.bold !== null) tags.push(`\\b${style.bold ? 1 : 0}`);
  if (style.italic !== null) tags.push(`\\i${style.italic ? 1 : 0}`);
  if (style.underline !== null) tags.push(`\\u${style.underline ? 1 : 0}`);

  return tags.length === 0 ? '' : `{${tags.join('')}}`;
}

/** Matches the `Default` style below, so `\fs` can be expressed as a percentage of it. */
const DEFAULT_FONT_SIZE = 48;

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
      '&H80000000,0,0,0,0,100,100,0,0,1,2.5,0,2,60,60,60,1',
    '',
    '[Events]',
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
  ];

  for (const cue of track.cues) {
    lines.push(dialogue(cue));
  }

  return lines.join('\n') + '\n';
}

function dialogue(cue: Cue): string {
  const text = escapeAssText(cueText(cue));
  return (
    `Dialogue: 0,${assTime(cue.startMs)},${assTime(cue.endMs)},Default,,0,0,0,,` +
    `${overrides(cue.style)}${text}`
  );
}
