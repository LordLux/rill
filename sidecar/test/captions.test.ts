/**
 * Captions — track list, json3 parsing, ASR grouping, ASS output.
 *
 * **Inline payloads, not corpus files, and for two reasons.** The first is the
 * one `premiere.test.ts` gives: `fixtures/` is captured and gitignored, `corpus/`
 * is derived from it, and hand-writing a file into either turns a captured
 * corpus into a mixture of captured and invented data that every later reader
 * has to sort out. The second is specific to captions — a real caption track is
 * the transcript of a copyrighted work, and committing one to make a timing
 * assertion is not a trade worth making.
 *
 * So the payloads below are **real shapes with substituted words**. Every
 * structural feature is verbatim from `dQw4w9WgXcQ`'s tracks, fetched
 * 2026-08-18: the window-definition event, the `aAppend` roll markers, the
 * per-word `tOffsetMs`, the leading spaces that are the only word separator, and
 * — the part that matters most — the real overlapping durations, where an event
 * starting at 18800 ms declares 7160 ms while the next starts at 21800 ms.
 * The words are filler; the timings are the measurement.
 */

import { beforeEach, describe, expect, test } from 'bun:test';
import { parseCaptionTracks } from '../src/parser/captions.ts';
import { fontSizePercentFrom, parseJson3 } from '../src/captions/json3.ts';
import { cueText, groupAsrCues, normalizeCues, type Cue } from '../src/captions/cues.ts';
import {
  assColor,
  assTime,
  escapeAssText,
  renderAss,
} from '../src/captions/ass.ts';
import { NO_CAPTION_STYLE } from '../src/captions/style.ts';
import {
  captionsNegativeCacheSize,
  convert,
  classifyDocument,
  forgetCaptions,
  listCaptionTracks,
} from '../src/captions/service.ts';
import { forgetPlayerResponse } from '../src/innertube/player-response.ts';
import type { Session } from '../src/innertube/session.ts';

// ---------------------------------------------------------------------------
// Payloads
// ---------------------------------------------------------------------------

/** `VISIONOS`'s shape: absolute `baseUrl`, no `translationLanguages`. */
const VISIONOS_RESPONSE = {
  captions: {
    playerCaptionsTracklistRenderer: {
      captionTracks: [
        {
          baseUrl: 'https://www.youtube.com/api/timedtext?v=VIDEO&lang=en&signature=SIG&key=yt8',
          name: { simpleText: 'English' },
          vssId: '.en',
          languageCode: 'en',
          isTranslatable: true,
        },
        {
          baseUrl: 'https://www.youtube.com/api/timedtext?v=VIDEO&lang=en&kind=asr&signature=SIG',
          name: { runs: [{ text: 'English (auto-generated)' }] },
          vssId: 'a.en',
          languageCode: 'en',
          kind: 'asr',
          isTranslatable: true,
        },
      ],
      translationLanguages: [],
    },
  },
};

/** `WEB`/`MWEB`'s shape: relative `baseUrl`, and ~156 translation languages. */
const WEB_RESPONSE = {
  captions: {
    playerCaptionsTracklistRenderer: {
      captionTracks: [
        {
          baseUrl: '/api/timedtext?v=VIDEO&lang=de-DE&signature=SIG&key=yt8',
          name: { simpleText: 'German (Germany)' },
          vssId: '.de-DE',
          languageCode: 'de-DE',
          isTranslatable: true,
        },
      ],
      translationLanguages: Array.from({ length: 156 }, (_, i) => ({
        languageCode: `x${i}`,
        languageName: { simpleText: `Language ${i}` },
      })),
    },
  },
};

/**
 * Ten consecutive ASR events, with the structure and the timings of a real
 * rolling window.
 *
 * Event 0 is the window definition — no `segs`, and a `dDurationMs` covering the
 * whole track. Events with `aAppend: 1` are roll markers carrying a lone
 * newline. The rest are lines, and every one of them overlaps the next.
 */
const ASR_EVENTS = {
  wireMagic: 'pb3',
  pens: [{}],
  wsWinStyles: [{}, { mhModeHint: 2, juJustifCode: 0, sdScrollDir: 3 }],
  wpWinPositions: [{}, { apPoint: 6, ahHorPos: 20, avVerPos: 100, rcRows: 2, ccCols: 40 }],
  events: [
    { tStartMs: 0, dDurationMs: 211879, id: 1, wpWinPosId: 1, wsWinStyleId: 1 },
    { tStartMs: 320, dDurationMs: 14260, wWinId: 1, segs: [{ utf8: '[Music]' }] },
    { tStartMs: 18790, dDurationMs: 4170, wWinId: 1, aAppend: 1, segs: [{ utf8: '\n' }] },
    {
      tStartMs: 18800,
      dDurationMs: 7160,
      wWinId: 1,
      segs: [
        { utf8: 'alpha', acAsrConf: 0 },
        { utf8: ' bravo', tOffsetMs: 239, acAsrConf: 0 },
        { utf8: ' charlie', tOffsetMs: 559, acAsrConf: 0 },
        { utf8: ' delta', tOffsetMs: 1040, acAsrConf: 0 },
      ],
    },
    { tStartMs: 21790, dDurationMs: 4170, wWinId: 1, aAppend: 1, segs: [{ utf8: '\n' }] },
    {
      tStartMs: 21800,
      dDurationMs: 7319,
      wWinId: 1,
      segs: [
        { utf8: 'echo.', acAsrConf: 0 },
        { utf8: ' foxtrot', tOffsetMs: 1000, acAsrConf: 0 },
        { utf8: ' golf', tOffsetMs: 1239, acAsrConf: 0 },
      ],
    },
    { tStartMs: 25950, dDurationMs: 3169, wWinId: 1, aAppend: 1, segs: [{ utf8: '\n' }] },
    {
      tStartMs: 25960,
      dDurationMs: 4319,
      wWinId: 1,
      segs: [
        { utf8: 'hotel', acAsrConf: 0 },
        { utf8: ' india', tOffsetMs: 1079, acAsrConf: 0 },
      ],
    },
    // Deliberately 480 ms of clear space before the next line starts: this is
    // the short cue the merge rule exists for.
    { tStartMs: 29119, dDurationMs: 5241, wWinId: 1, segs: [{ utf8: 'juliett' }] },
    { tStartMs: 29599, dDurationMs: 4761, wWinId: 1, segs: [{ utf8: 'kilo lima mike' }] },
  ],
};

/**
 * A styled track, with the structure of `L-BgxLtMxh0` — the caption-styling demo
 * whose cues label their own styling, and the document every mapping in
 * `json3.ts` was measured against on 2026-08-19.
 *
 * The shapes are verbatim; the words are substituted, except where the original
 * text *is* the measurement (a cue reading "Red font." next to `0xFF0000` is the
 * evidence, and paraphrasing it would throw the evidence away).
 *
 * Pens come in pairs on purpose. `pens[1]` and `pens[2]` are one caption:
 * `foForeAlpha: 0` makes the first invisible so it contributes only its
 * `etEdgeType: 4` drop shadow, and the second draws the glyphs with an
 * `etEdgeType: 3` outline. That pair, repeated, is 240 of the real document's
 * 257 cue groups, and rendering it as two events is the stacked-duplicates bug.
 */
const STYLED_EVENTS = {
  wireMagic: 'pb3',
  pens: [
    {},
    // The layered pair: shadow-only over glyphs-with-outline.
    { bAttr: 1, szPenSize: 100, etEdgeType: 4, fcForeColor: 16711422, foForeAlpha: 0, boBackAlpha: 0, ecEdgeColor: 0 },
    { bAttr: 1, szPenSize: 100, etEdgeType: 3, fcForeColor: 16711422, bcBackColor: 0, boBackAlpha: 0, ecEdgeColor: 0 },
    // "Red font." — the cue that fixes the channel order as 0xRRGGBB.
    { szPenSize: 100, etEdgeType: 3, fcForeColor: 16711680, bcBackColor: 0, boBackAlpha: 0, ecEdgeColor: 0 },
    // "72px font size." — 600 on YouTube's damped scale, which is 1.5×.
    { szPenSize: 600, etEdgeType: 3, fcForeColor: 16711422, boBackAlpha: 0, ecEdgeColor: 0 },
    // "Times New Roman." — CEA-708 font tag 2, plus italic and underline.
    { iAttr: 1, uAttr: 1, szPenSize: 100, fsFontStyle: 2, fcForeColor: 16711422, boBackAlpha: 0 },
    // "Custom text background and colour." — an opaque box, and the one cue in
    // the real document that arrives *unpaired*, because two layers cannot
    // composite through an opaque background.
    { szPenSize: 100, etEdgeType: 4, fcForeColor: 2001236, bcBackColor: 16777215, boBackAlpha: 254, ecEdgeColor: 15263976 },
    // "Chromatic aberration." — two *visible* pens at one position, half alpha,
    // different hues. The case a merge cannot express.
    { szPenSize: 100, fcForeColor: 16711680, foForeAlpha: 127, boBackAlpha: 0 },
    { szPenSize: 100, fcForeColor: 65280, foForeAlpha: 127, boBackAlpha: 0 },
    // Ids no table entry answers, and a sub/superscript ASS has no tag for.
    { szPenSize: 100, etEdgeType: 97, fsFontStyle: 98, ofOffset: 0, fcForeColor: 16711422 },
  ],
  wsWinStyles: [{}, { juJustifCode: 2, pdPrintDir: 0, sdScrollDir: 0 }],
  wpWinPositions: [
    {},
    { apPoint: 7, ahHorPos: 50, avVerPos: 100 },
    { apPoint: 0, ahHorPos: 0, avVerPos: 0 },
  ],
  events: [
    { tStartMs: 4946, dDurationMs: 1034, segs: [{ utf8: 'Bold text.' }], wpWinPosId: 1, wsWinStyleId: 1, pPenId: 1 },
    { tStartMs: 4946, dDurationMs: 1034, segs: [{ utf8: 'Bold text.' }], wpWinPosId: 1, wsWinStyleId: 1, pPenId: 2 },
    { tStartMs: 11986, dDurationMs: 2002, segs: [{ utf8: 'Red font.' }], wpWinPosId: 1, wsWinStyleId: 1, pPenId: 3 },
    { tStartMs: 8983, dDurationMs: 1001, segs: [{ utf8: '72px font size.' }], wpWinPosId: 1, wsWinStyleId: 1, pPenId: 4 },
    { tStartMs: 7982, dDurationMs: 1001, segs: [{ utf8: 'Times New Roman.' }], wpWinPosId: 2, wsWinStyleId: 1, pPenId: 5 },
    { tStartMs: 35977, dDurationMs: 2002, segs: [{ utf8: 'Custom text background and colour.' }], wpWinPosId: 1, wsWinStyleId: 1, pPenId: 6 },
    { tStartMs: 26000, dDurationMs: 267, segs: [{ utf8: 'Chromatic aberration.' }], wpWinPosId: 1, wsWinStyleId: 1, pPenId: 7 },
    { tStartMs: 26000, dDurationMs: 267, segs: [{ utf8: 'Chromatic aberration.' }], wpWinPosId: 1, wsWinStyleId: 1, pPenId: 8 },
    { tStartMs: 40000, dDurationMs: 1000, segs: [{ utf8: 'Out of range.' }], wpWinPosId: 99, wsWinStyleId: 99, pPenId: 9 },
  ],
};

/**
 * The `Default` events of a document — the ones carrying the words.
 *
 * Task 19 gives a caption up to three events: a window, a per-line box and the
 * text. The first two are backdrops drawn from the same string with invisible
 * glyphs, so a naive `startsWith('Dialogue:')` filter now finds each caption
 * two or three times, and an assertion about "the line" silently measures a
 * backdrop. Anything about words, colours, positions or runs wants this.
 */
function textEvents(ass: string): string[] {
  return dialogues(ass).filter((line) => /^Dialogue: \d+,[^,]+,[^,]+,Default,/.test(line));
}

/** Every `Dialogue` line, backdrops included. */
function dialogues(ass: string): string[] {
  return ass.split('\n').filter((line) => line.startsWith('Dialogue:'));
}

/** Every `CueStyle` field unset — the base for a test that varies exactly one. */
const NO_STYLE = {
  alignment: null,
  positionX: null,
  positionY: null,
  textColor: null,
  backgroundColor: null,
  edgeColor: null,
  edgeStyles: null,
  fontFamily: null,
  fontSizePercent: null,
  bold: null,
  italic: null,
  underline: null,
} as const;

/** A manual track: already cue-level, one line per event, no overlap. */
const MANUAL_EVENTS = {
  wireMagic: 'pb3',
  events: [
    { tStartMs: 1360, dDurationMs: 1680, segs: [{ utf8: '[intro]' }] },
    { tStartMs: 18640, dDurationMs: 3240, segs: [{ utf8: 'alpha bravo charlie' }] },
    { tStartMs: 22640, dDurationMs: 4320, segs: [{ utf8: 'delta echo\nfoxtrot golf' }] },
  ],
};

const MANUAL_SOURCE = {
  baseUrl: 'https://www.youtube.com/api/timedtext?v=VIDEO',
  track: {
    id: '.en',
    languageCode: 'en',
    label: 'English',
    isAutoGenerated: false,
    trackName: '',
    styled: null,
    positional: null,
    isTranslatable: true,
  },
};

const ASR_SOURCE = {
  ...MANUAL_SOURCE,
  track: { ...MANUAL_SOURCE.track, id: 'a.en', isAutoGenerated: true },
};

// ---------------------------------------------------------------------------
// Track list
// ---------------------------------------------------------------------------

describe('parseCaptionTracks', () => {
  test('reads the VISIONOS shape, absolute baseUrl', () => {
    const sources = parseCaptionTracks(VISIONOS_RESPONSE);
    expect(sources.map((s) => s.track)).toEqual([
      { id: '.en', languageCode: 'en', label: 'English', isAutoGenerated: false, trackName: '', styled: null, positional: null, isTranslatable: true },
      {
        id: 'a.en',
        languageCode: 'en',
        label: 'English (auto-generated)',
        isAutoGenerated: true,
        trackName: '',
        styled: null,
        positional: null,
        isTranslatable: true,
      },
    ]);
    expect(sources[0]!.baseUrl).toStartWith('https://www.youtube.com/api/timedtext');
  });

  test('resolves the WEB/MWEB relative baseUrl to an absolute one', () => {
    const sources = parseCaptionTracks(WEB_RESPONSE);
    expect(sources).toHaveLength(1);
    expect(sources[0]!.baseUrl).toBe(
      'https://www.youtube.com/api/timedtext?v=VIDEO&lang=de-DE&signature=SIG&key=yt8',
    );
  });

  test('156 translationLanguages are not tracks', () => {
    // The whole point of the note in `parser/captions.ts`: a one-entry track list
    // beside 156 translation languages is correct, not a parser that lost 156
    // tracks. If this ever returns 157 someone has "fixed" it.
    expect(parseCaptionTracks(WEB_RESPONSE)).toHaveLength(1);
  });

  test('a video with no captions yields an empty list, not an error', () => {
    expect(parseCaptionTracks({ videoDetails: { videoId: 'VIDEO' } })).toEqual([]);
    expect(parseCaptionTracks({})).toEqual([]);
    expect(parseCaptionTracks(null)).toEqual([]);
  });

  test('skips a malformed track and ships the rest (hard invariant 4)', () => {
    const sources = parseCaptionTracks({
      captions: {
        playerCaptionsTracklistRenderer: {
          captionTracks: [
            { name: { simpleText: 'No URL' }, languageCode: 'en' },
            { baseUrl: 'https://x/y', languageCode: 'fr', name: { simpleText: 'French' } },
            'not an object',
          ],
        },
      },
    });
    expect(sources.map((s) => s.track.languageCode)).toEqual(['fr']);
  });

  test('synthesises a vssId when YouTube omits one', () => {
    const sources = parseCaptionTracks({
      captions: {
        playerCaptionsTracklistRenderer: {
          captionTracks: [{ baseUrl: 'https://x/y', languageCode: 'nl', kind: 'asr' }],
        },
      },
    });
    // Falls back to the language code for the label too — an unlabelled track is
    // still selectable, and "nl" beats nothing.
    expect(sources[0]!.track).toMatchObject({ id: 'a.nl', label: 'nl', isAutoGenerated: true });
  });
});

// ---------------------------------------------------------------------------
// json3
// ---------------------------------------------------------------------------

describe('parseJson3', () => {
  test('parses cues with the timings the document declares', () => {
    const cues = parseJson3(MANUAL_EVENTS);
    expect(cues).toHaveLength(3);
    expect(cues[0]).toMatchObject({ startMs: 1360, endMs: 3040 });
    expect(cues[1]).toMatchObject({ startMs: 18640, endMs: 21880 });
    expect(cueText(cues[2]!)).toBe('delta echo\nfoxtrot golf');
  });

  test('drops the window definition and the roll markers', () => {
    const cues = parseJson3(ASR_EVENTS);
    // 10 events in: 1 window definition, 3 roll markers, 6 lines.
    expect(ASR_EVENTS.events).toHaveLength(10);
    expect(cues).toHaveLength(6);
    // The window definition declares 211879 ms. If it ever survives, one caption
    // covers the entire video and this is the assertion that says so.
    expect(cues.some((cue) => cue.endMs - cue.startMs > 200_000)).toBe(false);
    expect(cues.every((cue) => cueText(cue).trim() !== '')).toBe(true);
  });

  test('keeps the leading space that separates ASR words', () => {
    // `parser/tree.ts`'s `str()` trims, which is correct for renderer text and
    // silently destroys an ASR track: the space is *inside* the segment. This is
    // the regression test for reading the field raw instead.
    const cues = parseJson3(ASR_EVENTS);
    expect(cueText(cues[1]!)).toBe('alpha bravo charlie delta');
    expect(cueText(cues[1]!)).not.toBe('alphabravocharliedelta');
  });

  test('keeps per-word offsets for a future karaoke renderer', () => {
    const cues = parseJson3(ASR_EVENTS);
    expect(cues[1]!.segments.map((s) => s.offsetMs)).toEqual([null, 239, 559, 1040]);
  });

  test('never throws on a malformed document', () => {
    expect(parseJson3(null)).toEqual([]);
    expect(parseJson3({})).toEqual([]);
    expect(parseJson3({ events: 'nonsense' })).toEqual([]);
    expect(parseJson3({ events: [null, 7, { segs: [{ utf8: 'x' }] }] })).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// ASR grouping
// ---------------------------------------------------------------------------

describe('ASR grouping', () => {
  const raw = normalizeCues(parseJson3(ASR_EVENTS));
  const grouped = groupAsrCues(raw);

  test('the ungrouped track really does overlap — otherwise this suite proves nothing', () => {
    // The control for every assertion below. If the source stops overlapping,
    // grouping becomes a no-op and every test here passes against deleted code.
    const overlaps = raw.filter((cue, i) => {
      const next = raw[i + 1];
      return next !== undefined && cue.endMs > next.startMs;
    });
    expect(overlaps.length).toBeGreaterThanOrEqual(3);
  });

  test('produces non-overlapping lines', () => {
    for (let i = 0; i < grouped.length - 1; i++) {
      expect(grouped[i]!.endMs).toBeLessThanOrEqual(grouped[i + 1]!.startMs);
    }
  });

  test('the words survive the grouping, in order', () => {
    // Nothing is dropped and nothing is duplicated. The clamp changes times; it
    // must not change text.
    expect(grouped.map(cueText).join(' ')).toBe(
      '[Music] alpha bravo charlie delta echo. foxtrot golf hotel india juliett kilo lima mike',
    );
  });

  test('merges a sub-second cue forward instead of flashing it', () => {
    // "juliett" is clamped to 29119→29599, 480 ms — below the 1200 ms floor — so
    // it joins the line after it rather than appearing on its own.
    const juliett = grouped.find((cue) => cueText(cue).startsWith('juliett'));
    expect(cueText(juliett!)).toBe('juliett kilo lima mike');
    expect(juliett!.startMs).toBe(29119);
    expect(juliett!.endMs).toBe(34360);
  });

  test('rebases word offsets onto the merged cue', () => {
    const merged = grouped.find((cue) => cueText(cue).startsWith('juliett'))!;
    // Every offset stays within the cue it now belongs to. A merge that forgot to
    // shift would leave an offset pointing before the cue's own start.
    for (const segment of merged.segments) {
      if (segment.offsetMs === null) continue;
      expect(segment.offsetMs).toBeGreaterThanOrEqual(0);
      expect(merged.startMs + segment.offsetMs).toBeLessThanOrEqual(merged.endMs);
    }
  });

  test('MUTATION: grouping is not a no-op on this fixture', () => {
    // The check the brief asks for. Six raw cues, five grouped lines, and — the
    // part that actually matters — the *timings* differ. A test asserting only
    // the count would pass against a `groupAsrCues` that returned its input if
    // the input happened to have no mergeable pair.
    expect(raw).toHaveLength(6);
    expect(grouped).toHaveLength(5);
    expect(raw.map((c) => c.endMs)).not.toEqual(grouped.slice(0, 6).map((c) => c.endMs));
    // Specifically: the first line's declared end is 7160 ms long and the
    // grouped one is 3000 ms, because the next line starts there.
    expect(raw[1]!.endMs).toBe(25960);
    expect(grouped[1]!.endMs).toBe(21800);
  });

  test('a manual track is not re-grouped', () => {
    const manual = normalizeCues(parseJson3(MANUAL_EVENTS));
    const content = convert(JSON.stringify(MANUAL_EVENTS), MANUAL_SOURCE);
    // Every declared time survives to the ASS document unchanged.
    for (const cue of manual) {
      expect(content.content).toContain(`${assTime(cue.startMs)},${assTime(cue.endMs)}`);
    }
    expect(content.cueCount).toBe(3);
  });

  test('MUTATION: a manual track with overlaps keeps them', () => {
    // The distinguishing case. A well-formed manual track does not overlap, so
    // "manual is not re-grouped" passes trivially against a `convert` that
    // grouped everything. This one overlaps on purpose: if the ASR branch ever
    // starts applying to manual tracks, the second cue's end moves 5000 → 3000.
    const overlapping = {
      events: [
        { tStartMs: 0, dDurationMs: 5000, segs: [{ utf8: 'one' }] },
        { tStartMs: 3000, dDurationMs: 5000, segs: [{ utf8: 'two' }] },
      ],
    };
    const manual = convert(JSON.stringify(overlapping), MANUAL_SOURCE);
    expect(manual.content).toContain('0:00:00.00,0:00:05.00');

    const asr = convert(JSON.stringify(overlapping), ASR_SOURCE);
    expect(asr.content).toContain('0:00:00.00,0:00:03.00');
    expect(asr.content).not.toContain('0:00:00.00,0:00:05.00');
  });
});

// ---------------------------------------------------------------------------
// normalizeCues
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// YTT styling
// ---------------------------------------------------------------------------

/** The cue whose text starts with `prefix`, or a failure that names what it looked for. */
function cueStarting(cues: Cue[], prefix: string): Cue {
  const cue = cues.find((candidate) => cueText(candidate).startsWith(prefix));
  if (cue === undefined) {
    throw new Error(`no cue starting "${prefix}" in: ${cues.map(cueText).join(' | ')}`);
  }
  return cue;
}

describe('YTT styling', () => {
  test('the three style tables resolve onto the cues that reference them', () => {
    const cues = parseJson3(STYLED_EVENTS);

    // Position: `apPoint: 7` is bottom-centre, which is ASS `\an2`, at 50%/100%.
    const bold = cueStarting(cues, 'Bold');
    expect(bold.style).toMatchObject({ alignment: 2, positionX: 0.5, positionY: 1, bold: true });

    // Colour, and the channel order the "Red font." cue exists to fix.
    expect(cueStarting(cues, 'Red font.').style?.textColor).toEqual({ r: 255, g: 0, b: 0, a: 1 });

    // Font, and the two attribute flags that are not bold.
    expect(cueStarting(cues, 'Times New Roman.').style).toMatchObject({
      fontFamily: 'Times New Roman',
      italic: true,
      underline: true,
    });
  });

  test('apPoint is not \\an — the two 3x3 grids are numbered differently', () => {
    const cues = parseJson3(STYLED_EVENTS);
    // `apPoint: 0` is top-*left*. Read as an `\an` it would be 0, which is not a
    // valid alignment; read as the same number it would be bottom-left. Only the
    // row-major-to-numpad flip gives 7, and getting it wrong is silent.
    expect(cueStarting(cues, 'Times New Roman.').style?.alignment).toBe(7);
    expect(cueStarting(cues, 'Bold').style?.alignment).toBe(2);
  });

  test('MUTATION: the identity anchor mapping puts captions in the wrong corner', () => {
    // The check the brief asks for. If `ANCHOR_TO_ASS` were `[0..8]` — the
    // reflex, and the thing that reports nothing when wrong — the bottom-centre
    // default window would come out as `\an7`, the top-left corner. Asserting
    // the *pair* is what makes an off-by-one visible: any single point can be
    // matched by a wrong table, two adjacent ones cannot.
    const cues = parseJson3(STYLED_EVENTS);
    const bottomCentre = cueStarting(cues, 'Bold').style?.alignment;
    const topLeft = cueStarting(cues, 'Times New Roman.').style?.alignment;
    expect([bottomCentre, topLeft]).toEqual([2, 7]);
    expect(bottomCentre).not.toBe(7);
  });

  test('szPenSize runs on a damped scale, not a plain percentage', () => {
    // The demo labels this cue "72px font size" and carries `szPenSize: 600`.
    // Read as a plain percentage it is six times the default; the measured curve
    // — a quarter of the nominal — makes it 1.5×, which is what 72 against 48 is.
    expect(fontSizePercentFrom(600)).toBe(225);
    expect(fontSizePercentFrom(300)).toBe(150);
    // The property that makes the curve credible: an unstyled pen is unchanged.
    expect(fontSizePercentFrom(100)).toBe(100);
    expect(cueStarting(parseJson3(STYLED_EVENTS), '72px').style?.fontSizePercent).toBe(225);
  });

  test('a pen size of exactly 100 emits nothing rather than a redundant \\fs', () => {
    expect(cueStarting(parseJson3(STYLED_EVENTS), 'Bold').style?.fontSizePercent).toBeNull();
  });

  test('an unknown or out-of-range id degrades to the default, and still ships the cue', () => {
    // Hard invariant 4's reasoning, applied to the style tables: ids 99 and 97/98
    // answer nothing. The cue must survive with the fields that did resolve.
    const cue = cueStarting(parseJson3(STYLED_EVENTS), 'Out of range.');
    expect(cueText(cue)).toBe('Out of range.');
    expect(cue.style?.alignment).toBeNull();
    expect(cue.style?.edgeStyles).toBeNull();
    expect(cue.style?.fontFamily).toBeNull();
    // Something did resolve, so the style is not null: the colour on that pen.
    expect(cue.style?.textColor).toEqual({ r: 254, g: 254, b: 254, a: 1 });
  });

  test('the ASR window is reached through wWinId, not wpWinPosId', () => {
    // An ASR line carries `wWinId: 1` and names no position of its own; the
    // window definition holds it. A parser reading only `wpWinPosId` finds
    // nothing here and looks exactly like a track that declares no window.
    const cues = normalizeCues(parseJson3(ASR_EVENTS));
    expect(cues.length).toBeGreaterThan(0);
    for (const cue of cues) {
      expect(cue.style).toMatchObject({ alignment: 1, positionX: 0.2, positionY: 1 });
    }
  });
});

describe('the duplication rule', () => {
  test('two layers of one caption merge into a single line carrying both edges', () => {
    // The visible bug: `Bold text.` arrives as two events, identical in text and
    // timing, differing only in pen. One is a drop shadow around invisible
    // glyphs; the other is the glyphs with an outline. That is one caption.
    const cues = parseJson3(STYLED_EVENTS).filter((cue) => cueText(cue).startsWith('Bold'));
    expect(cues).toHaveLength(1);
    // Both effects survive the merge — dropping either loses a real one.
    expect(cues[0]!.style?.edgeStyles).toEqual(['dropShadow', 'outline']);
    // And the glyphs come from the layer that has any: the invisible pen must
    // not be the one that supplies the colour.
    expect(cues[0]!.style?.textColor?.a).toBe(1);
  });

  test('the merged cue renders as one Dialogue with \\bord and \\shad together', () => {
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: normalizeCues(parseJson3(STYLED_EVENTS)),
    });
    const bold = ass.split('\n').filter((line) => line.includes('Bold text.'));
    expect(bold).toHaveLength(1);
    expect(bold[0]).toContain('\\bord2.5');
    expect(bold[0]).toContain('\\shad2');
  });

  test('MUTATION: without the merge the same caption is two stacked Dialogues', () => {
    // The check the brief asks for, and the only one that pins the *visible*
    // symptom. Feeding the layers through unmerged is what the old parser did;
    // libass then stacks them, because two events at one position with one text
    // are two events.
    const unmerged = STYLED_EVENTS.events.filter((e) => e.segs[0]?.utf8 === 'Bold text.');
    expect(unmerged).toHaveLength(2);
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: normalizeCues(parseJson3({ ...STYLED_EVENTS, events: unmerged })),
    });
    expect(ass.split('\n').filter((line) => line.includes('Bold text.'))).toHaveLength(1);
  });

  test('two *visible* layers conflict and are both emitted, positioned', () => {
    // "Chromatic aberration." is red and green at half alpha in one place. ASS
    // cannot put two fills on one line, so these pass through — sound because
    // `\pos` suppresses libass's collision avoidance, measured against the
    // bundled libmpv: positioned duplicates superimpose, unpositioned ones stack.
    const cues = parseJson3(STYLED_EVENTS).filter((cue) =>
      cueText(cue).startsWith('Chromatic'),
    );
    expect(cues).toHaveLength(2);
    expect(cues.map((cue) => cue.style?.textColor)).toEqual([
      { r: 255, g: 0, b: 0, a: 127 / 255 },
      { r: 0, g: 255, b: 0, a: 127 / 255 },
    ]);
    const ass = renderAss({ languageCode: 'en', isAutoGenerated: false, cues });
    for (const line of ass.split('\n').filter((l) => l.includes('Chromatic'))) {
      expect(line).toContain('\\pos(');
    }
  });

  test('captions that differ in time, text or window are never merged', () => {
    const cues = parseJson3(STYLED_EVENTS);
    expect(cueText(cueStarting(cues, 'Red font.'))).toBe('Red font.');
    // Nine events in; one pair merged, one conflicting pair kept.
    expect(cues).toHaveLength(8);
  });
});

/**
 * Karaoke, with `L-BgxLtMxh0`'s real structure.
 *
 * Three layers, none of which carries an event pen: the styling is entirely on
 * the `seg`s. Two layers are fully transparent — one is the drop shadow, one
 * draws nothing — and the third has the glyphs. The split between the two pens
 * moves one event to the next, and that is the whole animation.
 */
const KARAOKE_EVENTS = {
  wireMagic: 'pb3',
  pens: [
    {},
    { szPenSize: 100, etEdgeType: 4, fcForeColor: 16774656, foForeAlpha: 0 }, // shadow, sung
    { szPenSize: 100, etEdgeType: 4, fcForeColor: 0, foForeAlpha: 0 }, // shadow, unsung
    { szPenSize: 100, etEdgeType: 3, fcForeColor: 16774656 }, // visible, sung
    { szPenSize: 100, etEdgeType: 3, fcForeColor: 0 }, // visible, unsung
  ],
  wsWinStyles: [{}, { juJustifCode: 2 }],
  wpWinPositions: [{}, { apPoint: 7, ahHorPos: 50, avVerPos: 100 }],
  events: [
    {
      tStartMs: 16991,
      dDurationMs: 200,
      wpWinPosId: 1,
      wsWinStyleId: 1,
      segs: [{ utf8: 'Ba', pPenId: 1 }, { utf8: 'sic karaoke timing.', pPenId: 2 }],
    },
    {
      tStartMs: 16991,
      dDurationMs: 200,
      wpWinPosId: 1,
      wsWinStyleId: 1,
      segs: [{ utf8: 'Ba', pPenId: 3 }, { utf8: 'sic karaoke timing.', pPenId: 4 }],
    },
    {
      tStartMs: 17191,
      dDurationMs: 360,
      wpWinPosId: 1,
      wsWinStyleId: 1,
      segs: [{ utf8: 'Basic ', pPenId: 3 }, { utf8: 'karaoke timing.', pPenId: 4 }],
    },
    // A third step, because one increase is not a sweep — a line can be re-split
    // once for reasons that are not karaoke, and `isKaraokeOnly` wants two.
    {
      tStartMs: 17551,
      dDurationMs: 400,
      wpWinPosId: 1,
      wsWinStyleId: 1,
      segs: [{ utf8: 'Basic ka', pPenId: 3 }, { utf8: 'raoke timing.', pPenId: 4 }],
    },
  ],
};

describe('karaoke', () => {
  test('a pen on a seg styles that run alone', () => {
    const cue = parseJson3(KARAOKE_EVENTS)[0]!;
    expect(cue.segments.map((segment) => segment.text)).toEqual(['Ba', 'sic karaoke timing.']);
    // Sung is 0xFFF600; unsung is a different colour. Which colours are *right*
    // is the document's business, not this test's — what is asserted is that the
    // two runs are styled *separately*, which is the mechanism.
    expect(cue.segments[0]!.style?.textColor).toEqual({ r: 255, g: 246, b: 0, a: 1 });
    expect(cue.segments[1]!.style?.textColor).not.toEqual(cue.segments[0]!.style?.textColor);
  });

  test('the highlight steps because the split moves, not because of \\k', () => {
    const cues = parseJson3(KARAOKE_EVENTS);
    expect(cues.map((cue) => cue.segments[0]!.text)).toEqual(['Ba', 'Basic ', 'Basic ka']);
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: normalizeCues(cues),
    });
    expect(ass).not.toContain('\\k');
  });

  test('MUTATION: read at the event level, all three layers look visible', () => {
    // The layer that draws the glyphs is opaque and the other two are not — but
    // *no event carries a pen*, so an event-level alpha reads 1 for all three,
    // the merge calls them a conflict and emits the line once per layer. That is
    // the stacked-duplicates bug returning through the karaoke path.
    const cues = parseJson3(KARAOKE_EVENTS).filter((cue) => cue.startMs === 16991);
    expect(cues).toHaveLength(1);
    // And the layer that survived is the one with glyphs, not a shadow.
    expect(cues[0]!.segments[0]!.style?.textColor?.a).toBe(1);
  });

  test('the run overrides land inside one Dialogue, after the line overrides', () => {
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: normalizeCues(parseJson3(KARAOKE_EVENTS)),
    });
    const line = textEvents(ass).find((l) => l.includes('sic karaoke'))!;
    // Position and edge once for the line; colour twice, once per run.
    expect(line.match(/\\pos\(/g)).toHaveLength(1);
    expect(line.match(/\\bord/g)).toHaveLength(1);
    expect(line.match(/\\c&H/g)).toHaveLength(2);
    // The edge belongs to the line: a run that restated it could cancel the
    // shadow the layer union established.
    expect(line.indexOf('\\bord')).toBeLessThan(line.indexOf('Ba'));
  });

  test('a track with no segment pens emits no run overrides at all', () => {
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: normalizeCues(parseJson3(MANUAL_EVENTS)),
    });
    // The *text* events, not the document: task 19's background is an event of
    // its own and it is nothing but overrides.
    for (const line of textEvents(ass)) expect(line).not.toContain('{');
  });
});

describe('the styled flag', () => {
  test('styling is pens, not "any of the three arrays"', () => {
    // The measurement that decides it: every auto-generated track populates
    // `wsWinStyles` and `wpWinPositions` for its rolling window, so the loose
    // predicate answers "styled" for the plainest tracks in the app. Measured on
    // `dQw4w9WgXcQ` — all six tracks had `pens: []`, and only the ASR one had a
    // populated window.
    expect(classifyDocument(ASR_EVENTS, true)).toEqual({ styled: 'plain', positional: false });
    expect(classifyDocument(STYLED_EVENTS, false)).toEqual({ styled: 'styled', positional: true });
  });

  test('karaoke is the moving split, and only when nothing wider is true', () => {
    // Karaoke is a *subset* of styled, so the narrow badge is earned by a track
    // that does nothing else. `KARAOKE_EVENTS` is exactly that.
    expect(classifyDocument(KARAOKE_EVENTS, false)).toEqual({ styled: 'karaoke', positional: false });
    // Add one feature karaoke does not need and the wider badge takes over.
    const withAFont = {
      ...KARAOKE_EVENTS,
      pens: [...KARAOKE_EVENTS.pens, { fsFontStyle: 5, fcForeColor: 16711422 }],
    };
    expect(classifyDocument(withAFont, false)).toEqual({ styled: 'styled', positional: false });
  });

  test('MUTATION: a per-segment pen is not on its own karaoke', () => {
    // The rule this replaced answered `karaoke` for any `pPenId` on a `seg`, and
    // badged all three real test documents — per-segment pens are also how a
    // track colours one word or sweeps a gradient. Same text, repeated, with the
    // split standing still: styled, not karaoke.
    const notKaraoke = {
      pens: [{}, { fcForeColor: 16711680 }, { fcForeColor: 255 }],
      wpWinPositions: [{}, { apPoint: 7, ahHorPos: 50, avVerPos: 100 }],
      events: [0, 1, 2, 3].map(() => ({
        segs: [{ utf8: 'same ', pPenId: 1 }, { utf8: 'split', pPenId: 2 }],
      })),
    };
    expect(notKaraoke.events.every((e) => e.segs.some((s) => s.pPenId !== undefined))).toBe(true);
    expect(classifyDocument(notKaraoke, false)).toEqual({ styled: 'styled', positional: false });
  });

  test('the zero-width spaces between segments do not hide the sweep', () => {
    // They sit *at the split*, so the same line concatenates differently on
    // every step. Grouping on raw text finds no repeats and reports no karaoke
    // at all — which is what a first attempt did, on the one document that
    // visibly has it.
    const zwsp = '​';
    const swept = {
      pens: [{}, { fcForeColor: 16774656 }, { fcForeColor: 16711422 }],
      wpWinPositions: [{}, { apPoint: 7, ahHorPos: 50, avVerPos: 100 }],
      events: [1, 2, 3, 4].map((n) => ({
        segs: [
          { utf8: `${'ab cd ef gh'.slice(0, n)}${zwsp}`, pPenId: 1 },
          { utf8: `${zwsp}${'ab cd ef gh'.slice(n)}${zwsp}`, pPenId: 2 },
        ],
      })),
    };
    expect(classifyDocument(swept, false)).toEqual({ styled: 'karaoke', positional: false });
  });

  test('an absent or empty pens array is plain', () => {
    expect(classifyDocument(MANUAL_EVENTS, false)).toEqual({ styled: 'plain', positional: false });
    expect(classifyDocument({ pens: [{}, {}] }, false)).toEqual({ styled: 'plain', positional: false });
    expect(classifyDocument({}, false)).toEqual({ styled: 'plain', positional: false });
    expect(classifyDocument(null, false)).toEqual({ styled: 'plain', positional: false });
  });

  test('the track list leaves it null rather than guessing', () => {
    // It cannot be answered from a `/player` response, and `captions.list` is on
    // the video-open path — so "not known" is the honest default and the caption
    // menu is what opts into paying for the answer.
    for (const source of parseCaptionTracks(VISIONOS_RESPONSE)) {
      expect(source.track.styled).toBeNull();
    }
  });

  test('trackName rides along, and is empty rather than absent', () => {
    // YouTube sends `""` on every track measured so far; it is how a channel
    // labels two tracks in one language, and dropping it would leave the picker
    // showing identical rows.
    for (const source of parseCaptionTracks(VISIONOS_RESPONSE)) {
      expect(source.track.trackName).toBe('');
    }
  });
});

describe('an unstyled document', () => {
  test('produces style: null on every cue', () => {
    // The guarantee every existing video depends on. `pens: [{}]` with no ids on
    // the events has to resolve to nothing at all, not to a style whose fields
    // happen to be null — the second would emit `{}` override blocks.
    const emptyArrays = { ...MANUAL_EVENTS, pens: [{}], wsWinStyles: [{}], wpWinPositions: [{}] };
    for (const cue of parseJson3(emptyArrays)) expect(cue.style).toBeNull();
  });

  test('MUTATION: renders byte-identical ASS to a document with no style tables', () => {
    // The check the brief asks for, and the one that protects a plain track from
    // a styling regression. The same events with the three arrays present but
    // empty — which is what a plain track actually transmits — must produce the
    // same document, byte for byte, as one with no arrays at all.
    const withTables = convert(
      JSON.stringify({ ...MANUAL_EVENTS, pens: [{}], wsWinStyles: [{}], wpWinPositions: [{}] }),
      MANUAL_SOURCE,
    );
    const without = convert(JSON.stringify(MANUAL_EVENTS), MANUAL_SOURCE);
    expect(withTables.content).toBe(without.content);
    for (const line of textEvents(without.content)) expect(line).not.toContain('{');
  });

  test('is byte-identical to what Task 17 rendered', () => {
    // Verified 2026-08-19 against Task 17's own `ass.ts` / `cues.ts` / `json3.ts`
    // read out of `HEAD`, on this document and on the same one carrying empty
    // style tables: both byte-identical. Pinned as a literal because the
    // comparison it came from cannot live in the suite — the point is that
    // *nothing* in the header moves, including the things no assertion names,
    // and the one that nearly did was the extra `Style` line the background box
    // needed.
    //
    // **Task 19 needed a caveat here and phase 5 removed it.** For one release
    // the background was drawn by the document, so this ran with the background
    // explicitly turned off and the claim was "task 17's document, plus a
    // backdrop". `LibassLayer` paints backdrops itself now, the box and window
    // events are gone, and a plain track is unconditionally byte-identical
    // again — no options, no opt-out. `[assLayout]`'s constants, the margins,
    // the wrap style and the timings are all still pinned here.
    expect(convert(JSON.stringify(MANUAL_EVENTS), MANUAL_SOURCE).content).toBe(
      '[Script Info]\n' +
        '; Generated by Rill from YouTube timed text. Do not edit.\n' +
        '; source: manual en\n' +
        'ScriptType: v4.00+\n' +
        'WrapStyle: 0\n' +
        'ScaledBorderAndShadow: yes\n' +
        'YCbCr Matrix: None\n' +
        'PlayResX: 1920\n' +
        'PlayResY: 1080\n' +
        '\n' +
        '[V4+ Styles]\n' +
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, ' +
        'BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, ' +
        'BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n' +
        'Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,' +
        '&H80000000,0,0,0,0,100,100,0,0,1,2.5,0,2,60,60,60,1\n' +
        '\n' +
        '[Events]\n' +
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n' +
        'Dialogue: 0,0:00:01.36,0:00:03.04,Default,,0,0,0,,[intro]\n' +
        'Dialogue: 0,0:00:18.64,0:00:21.88,Default,,0,0,0,,alpha bravo charlie\n' +
        'Dialogue: 0,0:00:22.64,0:00:26.96,Default,,0,0,0,,delta echo\\Nfoxtrot golf\n',
    );
  });

  test('a style that only turns the background off changes nothing', () => {
    // The other half of the claim above, and the reason it no longer needs an
    // opt-out: background is not something this renderer expresses at all, so
    // asking for none produces the same bytes as asking for nothing.
    expect(
      convert(JSON.stringify(MANUAL_EVENTS), MANUAL_SOURCE, {
        style: { ...NO_CAPTION_STYLE, background: { r: 0, g: 0, b: 0, a: 0 } },
      }).content,
    ).toBe(convert(JSON.stringify(MANUAL_EVENTS), MANUAL_SOURCE).content);
  });
});

describe('normalizeCues', () => {
  const cue = (startMs: number, endMs: number, text: string): Cue => ({
    startMs,
    endMs,
    segments: [{ text, offsetMs: null, style: null }],
    style: null,
  });

  test('sorts by start, so the clamp reads the right neighbour', () => {
    const sorted = normalizeCues([cue(300, 400, 'c'), cue(100, 200, 'a'), cue(200, 300, 'b')]);
    expect(sorted.map(cueText)).toEqual(['a', 'b', 'c']);
  });

  test('gives a cue with no declared end a default one', () => {
    expect(normalizeCues([cue(1000, 0, 'x')])[0]!.endMs).toBe(4000);
  });

  test('drops a cue with no visible text', () => {
    expect(normalizeCues([cue(0, 100, '   '), cue(100, 200, 'x')]).map(cueText)).toEqual(['x']);
  });
});

// ---------------------------------------------------------------------------
// ASS
// ---------------------------------------------------------------------------

/**
 * What `ASR_EVENTS`'s window resolves to, and the reason every ASR Dialogue
 * carries an override block now where it carried none before Task 18.
 *
 * `apPoint: 6` is bottom-left, which is ASS `\an1`; `ahHorPos: 20` /
 * `avVerPos: 100` map into the caption area, not the raw frame — 60 + 0.2×1800
 * and 60 + 1.0×960. Spelled out rather than computed so that a change to either
 * mapping has to be typed here deliberately.
 */
const ASR_WINDOW_OVERRIDE = '{\\an1\\pos(420,1020)}';

describe('ASS output', () => {
  test('times are H:MM:SS.cc — centiseconds, one hour digit', () => {
    expect(assTime(0)).toBe('0:00:00.00');
    expect(assTime(1360)).toBe('0:00:01.36');
    expect(assTime(3_661_234)).toBe('1:01:01.23');
    // Truncates rather than rounds up past the second, so a cue never starts
    // after the one before it ends by a rounding hair.
    expect(assTime(1999)).toBe('0:00:01.99');
    expect(assTime(-5)).toBe('0:00:00.00');
  });

  test('colours are &HAABBGGRR with alpha inverted into transparency', () => {
    expect(assColor({ r: 255, g: 255, b: 255, a: 1 })).toBe('&H00FFFFFF');
    expect(assColor({ r: 255, g: 0, b: 0, a: 1 })).toBe('&H000000FF');
    expect(assColor({ r: 0, g: 0, b: 255, a: 1 })).toBe('&H00FF0000');
    expect(assColor({ r: 0, g: 0, b: 0, a: 0 })).toBe('&HFF000000');
  });

  test('escapes the four things that break a Dialogue line', () => {
    expect(escapeAssText('a\nb')).toBe('a\\Nb');
    expect(escapeAssText('{drop}')).not.toContain('{');
    expect(escapeAssText('C:\\temp')).not.toContain('\\t');
    expect(escapeAssText(' lead')).toBe('\\hlead');
  });

  test('is well-formed, and its timings match the cues', () => {
    const cues = groupAsrCues(normalizeCues(parseJson3(ASR_EVENTS)));
    const ass = renderAss({ cues, isAutoGenerated: true, languageCode: 'en' });

    expect(ass).toStartWith('[Script Info]');
    expect(ass).toContain('ScriptType: v4.00+');
    expect(ass).toContain('[V4+ Styles]');
    expect(ass).toContain('[Events]');
    // A `Format:` line for each section, and a Style the Dialogues reference.
    expect(ass.match(/^Format: /gm)).toHaveLength(2);
    expect(ass).toContain('Style: Default,');

    const lines = textEvents(ass);
    expect(lines).toHaveLength(cues.length);
    lines.forEach((line, i) => {
      const cue = cues[i]!;
      expect(line).toBe(
        `Dialogue: 0,${assTime(cue.startMs)},${assTime(cue.endMs)},Default,,0,0,0,,` +
          `${ASR_WINDOW_OVERRIDE}${cueText(cue)}`,
      );
    });
    // Every Dialogue has the 9 commas its format line promises before the text.
    for (const line of dialogues(ass)) {
      expect(line.slice('Dialogue: '.length).split(',').length).toBeGreaterThanOrEqual(10);
    }
  });

  test('emits positioning and inline overrides when a style carries them', () => {
    // Nothing populates a style today. This pins the path a YTT parser will use,
    // so "the renderer can express YTT" is a tested claim rather than a plan.
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: [
        {
          startMs: 0,
          endMs: 1000,
          segments: [{ text: 'styled', offsetMs: null, style: null }],
          style: {
            alignment: 7,
            positionX: 0.25,
            positionY: 0.5,
            textColor: { r: 255, g: 255, b: 0, a: 1 },
            backgroundColor: null,
            edgeColor: { r: 0, g: 0, b: 0, a: 1 },
            edgeStyles: ['dropShadow'],
            fontFamily: 'Roboto',
            fontSizePercent: 150,
            bold: true,
            italic: null,
            underline: null,
          },
        },
      ],
    });
    expect(ass).toContain('\\an7');
    // Inside the caption area: 60 + 0.25×1800, 60 + 0.5×960.
    expect(ass).toContain('\\pos(510,540)');
    expect(ass).toContain('\\fnRoboto');
    expect(ass).toContain('\\fs72');
    // Six digits, not eight: an inline `\c` has no alpha byte.
    expect(ass).toContain('\\c&H00FFFF');
    expect(ass).not.toContain('\\c&H0000FFFF');
    expect(ass).toContain('\\shad2');
    expect(ass).toContain('\\bord0');
    expect(ass).toContain('\\b1');
    // A null field emits nothing rather than a default that overrides the Style.
    expect(ass).not.toContain('\\i0');
  });

  test('an opaque colour emits no alpha tag; a translucent one emits \\1a', () => {
    const render = (a: number) =>
      renderAss({
        languageCode: 'en',
        isAutoGenerated: false,
        cues: [
          {
            startMs: 0,
            endMs: 1000,
            segments: [{ text: 'faded', offsetMs: null, style: null }],
            style: { ...NO_STYLE, textColor: { r: 255, g: 0, b: 0, a } },
          },
        ],
      });
    const text = (a: number) => textEvents(render(a))[0]!;
    expect(text(1)).not.toContain('\\1a');
    // Half alpha is transparency 0x80. Putting it in `\c` instead would render
    // opaque and the wrong hue — measured against the bundled libmpv.
    expect(text(0.5)).toContain('\\1a&H80&');
    expect(text(0)).toContain('\\1a&HFF&');
  });

  test('a cue that authors a background still emits no background event', () => {
    // **The document draws no backdrops at all**, and this is the case that
    // would have drawn one: a cue with an opaque authored `backgroundColor`.
    //
    // Task 19 rendered it as a second, lower `Dialogue` with invisible glyphs
    // and `BorderStyle: 3`, because ASS has no background *tag* — it is a Style
    // property, and `BorderStyle: 3` replaces the outline rather than sitting
    // behind it, so a box on the text event would have killed every edge style.
    // Phase 5 hands backgrounds to `LibassLayer`, which paints them from the
    // real rendered boxes; emitting them here too is the double-draw bug. What
    // has to survive is the edge styling the split existed to protect.
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: [
        {
          startMs: 0,
          endMs: 1000,
          segments: [{ text: 'boxed', offsetMs: null, style: null }],
          style: {
            ...NO_STYLE,
            textColor: { r: 30, g: 137, b: 84, a: 1 },
            backgroundColor: { r: 255, g: 255, b: 255, a: 254 / 255 },
            edgeColor: { r: 0, g: 0, b: 0, a: 1 },
            edgeStyles: ['dropShadow'],
          },
        },
      ],
    });
    // No extra `Style` line, no second event, one `Dialogue` for the cue.
    expect(ass).not.toContain('Style: Box,');
    expect(ass).not.toContain(',Box,,');
    expect(dialogues(ass)).toHaveLength(1);

    // And the edge style survives, on the one event there is. `BorderStyle: 1`
    // on `Default` is what makes that possible — the property the layer split
    // was protecting, now had for free.
    const text = textEvents(ass)[0]!;
    expect(text).toContain('\\shad2');
    expect(text).toContain('\\bord0');
    expect(text).toContain('boxed');
  });

  test('an authored outline renders on the same single event', () => {
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: [
        {
          startMs: 0,
          endMs: 1000,
          segments: [{ text: 'plain', offsetMs: null, style: null }],
          style: {
            ...NO_STYLE,
            backgroundColor: { r: 0, g: 0, b: 0, a: 0 },
            edgeStyles: ['outline'],
          },
        },
      ],
    });
    expect(dialogues(ass)).toHaveLength(1);
    expect(ass).toContain('\\bord2.5');
  });
  test('two overlapping cues from a styled document emit distinct pos values', () => {
    const ass = renderAss({
      languageCode: 'en',
      isAutoGenerated: false,
      cues: [
        {
          startMs: 0,
          endMs: 1000,
          segments: [{ text: 'duplicate', offsetMs: null, style: null }],
          style: {
            alignment: 7,
            positionX: 0.25,
            positionY: 0.5,
            textColor: null, backgroundColor: null, edgeColor: null, edgeStyles: null, fontFamily: null, fontSizePercent: null, bold: null, italic: null, underline: null,
          },
        },
        {
          startMs: 0,
          endMs: 1000,
          segments: [{ text: 'duplicate', offsetMs: null, style: null }],
          style: {
            alignment: 7,
            positionX: 0.75,
            positionY: 0.5,
            textColor: null, backgroundColor: null, edgeColor: null, edgeStyles: null, fontFamily: null, fontSizePercent: null, bold: null, italic: null, underline: null,
          },
        },
      ],
    });
    
    expect(ass).toContain('\\pos(510,540)');
    expect(ass).toContain('\\pos(1410,540)');

    // They are distinctly present, separating the identical text onto different paths
    const lines = textEvents(ass);
    expect(lines).toHaveLength(2);
    expect(lines[0]).not.toEqual(lines[1]);
  });
});

// ---------------------------------------------------------------------------
// convert — the whole pipeline
// ---------------------------------------------------------------------------

describe('convert', () => {
  test('ASR: 10 events in, readable lines out', () => {
    const content = convert(JSON.stringify(ASR_EVENTS), ASR_SOURCE);
    expect(content.format).toBe('ass');
    expect(content.trackId).toBe('a.en');
    expect(content.cueCount).toBe(5);
    expect(content.content).toContain('; source: asr en');
    // No word appears on a line of its own — the stutter this exists to stop.
    // The text is everything past the 9th comma; splitting on `,,` instead lands
    // inside the event's own empty fields (`Default,,`).
    const lines = textEvents(content.content)
      // Past the 9th comma, then past the override block the ASR window now puts
      // on every line (`ASR_WINDOW_OVERRIDE`).
      .map((l) => l.split(',').slice(9).join(',').replace(/^\{[^}]*\}/, ''));
    expect(lines.filter((l) => l.trim().split(/\s+/).length === 1)).toEqual(['[Music]']);
  });

  test('an empty track converts to a valid, empty ASS document', () => {
    const content = convert(JSON.stringify({ events: [] }), MANUAL_SOURCE);
    expect(content.cueCount).toBe(0);
    expect(content.content).toContain('[Events]');
    expect(content.content).not.toContain('Dialogue:');
  });
});

// ---------------------------------------------------------------------------
// The VISIONOS fallback and its negative cache
// ---------------------------------------------------------------------------

/** Counts `/player` calls per client, so "did it fall back" is observable. */
function stubResolveSession(bodies: Record<string, unknown>) {
  const calls: string[] = [];
  const session = {
    hasCookie: false,
    visitorId: 'v'.repeat(558),
    innertube: {
      session: { player: { signature_timestamp: 20662 }, context: { client: {} } },
    },
    async execute(endpoint: string, params: Record<string, unknown> = {}) {
      const client = String(params['client'] ?? 'WEB');
      calls.push(`${endpoint}:${client}`);
      const body = bodies[client];
      if (body === undefined) throw new Error(`no stub body for ${client}`);
      return body;
    },
  } as unknown as Session;
  return { session, calls };
}

const NO_TRACKS = { videoDetails: { videoId: 'VIDEO' }, playabilityStatus: { status: 'OK' } };

describe('the VISIONOS fallback', () => {
  beforeEach(() => {
    forgetCaptions();
    forgetPlayerResponse();
  });

  test('does not fire when VISIONOS has tracks', async () => {
    const { session, calls } = stubResolveSession({
      VISIONOS: VISIONOS_RESPONSE,
      MWEB: WEB_RESPONSE,
    });
    const result = await listCaptionTracks(session, 'has-captions');
    expect(result.sources).toHaveLength(2);
    expect(result.usedFallback).toBe(false);
    expect(calls).toEqual(['/player:VISIONOS']);
  });

  test('fires on an empty list and recovers the tracks', async () => {
    const { session, calls } = stubResolveSession({ VISIONOS: NO_TRACKS, MWEB: WEB_RESPONSE });
    const result = await listCaptionTracks(session, 'vr-gap');
    expect(result.sources.map((s) => s.track.languageCode)).toEqual(['de-DE']);
    expect(result.usedFallback).toBe(true);
    expect(calls).toEqual(['/player:VISIONOS', '/player:MWEB']);
  });

  test('asks MWEB, not WEB — a WEB caption URL answers 200 with no body', async () => {
    // Measured 2026-08-18: a `WEB` `/player` signs its timedtext URLs with
    // `exp=xpe`, and every one of them returns an empty 200. Falling back to WEB
    // would fill the language picker with tracks that render nothing.
    const { session, calls } = stubResolveSession({ VISIONOS: NO_TRACKS, MWEB: WEB_RESPONSE });
    await listCaptionTracks(session, 'vr-gap');
    expect(calls).not.toContain('/player:WEB');
  });

  test('caches the negative and does not fire twice inside the TTL', async () => {
    const { session, calls } = stubResolveSession({ VISIONOS: NO_TRACKS, MWEB: NO_TRACKS });

    expect((await listCaptionTracks(session, 'captionless')).sources).toEqual([]);
    expect(calls).toEqual(['/player:VISIONOS', '/player:MWEB']);
    expect(captionsNegativeCacheSize()).toBe(1);

    // The `/player` cache is dropped between the two, so anything that fires
    // again shows up as a real call rather than being hidden by a cache hit.
    forgetPlayerResponse();
    expect((await listCaptionTracks(session, 'captionless')).sources).toEqual([]);
    expect(calls.filter((c) => c === '/player:MWEB')).toHaveLength(1);
  });

  test('MUTATION: without the negative cache the fallback fires again', async () => {
    // The check the brief asks for. Clearing the cache is what deleting it would
    // look like from outside, and the test above must fail under it — so this
    // asserts the *other* outcome explicitly rather than trusting that a passing
    // test was testing anything.
    const { session, calls } = stubResolveSession({ VISIONOS: NO_TRACKS, MWEB: NO_TRACKS });
    await listCaptionTracks(session, 'captionless');
    forgetCaptions();
    forgetPlayerResponse();
    await listCaptionTracks(session, 'captionless');
    expect(calls.filter((c) => c === '/player:MWEB')).toHaveLength(2);
  });

  test('the negative is per video, not global', async () => {
    const { session, calls } = stubResolveSession({
      VISIONOS: NO_TRACKS,
      MWEB: NO_TRACKS,
    });
    await listCaptionTracks(session, 'video-a');
    forgetPlayerResponse();
    await listCaptionTracks(session, 'video-b');
    // Both fell back; caching "a" as captionless must not silence "b".
    expect(calls.filter((c) => c === '/player:MWEB')).toHaveLength(2);
    expect(captionsNegativeCacheSize()).toBe(2);
  });

  test('a video with no tracks anywhere yields an empty list, not an error', async () => {
    const { session } = stubResolveSession({ VISIONOS: NO_TRACKS, MWEB: NO_TRACKS });
    await expect(listCaptionTracks(session, 'captionless')).resolves.toMatchObject({
      sources: [],
    });
  });
});

// ---------------------------------------------------------------------------
// Task 19 — the drag, the clamp and the style menu
// ---------------------------------------------------------------------------

/** A one-cue track, for the tests that vary exactly one thing about rendering. */
function oneCue(text: string, style: Cue['style'] = null): Parameters<typeof renderAss>[0] {
  return {
    languageCode: 'en',
    isAutoGenerated: false,
    cues: [{ startMs: 0, endMs: 1000, segments: [{ text, offsetMs: null, style: null }], style }],
  };
}

/** `\pos(x,y)` off the text event of a single-cue document. */
function posOf(ass: string): { x: number; y: number } | null {
  const match = /\\pos\((-?\d+),(-?\d+)\)/.exec(textEvents(ass)[0] ?? '');
  return match === null ? null : { x: Number(match[1]), y: Number(match[2]) };
}

describe('the drag offset', () => {
  test('a zero offset changes nothing at all', () => {
    // The property the whole delta model rests on: turning the feature on must
    // not move a caption that nobody dragged, on any kind of track.
    expect(renderAss(oneCue('hello'), { offset: { dx: 0, dy: 0 } })).toBe(
      renderAss(oneCue('hello')),
    );
    expect(posOf(renderAss(oneCue('hello')))).toBeNull();
  });

  test('it is added to wherever the cue already was', () => {
    // One rule for every kind of track — that is the point of a delta. An
    // unpositioned cue starts at the default anchor and a positioned one at its
    // own, and both move by the same fraction of the frame.
    const plain = posOf(renderAss(oneCue('hi'), { offset: { dx: -0.1, dy: -0.2 } }))!;
    expect(plain).toEqual({ x: 960 - 192, y: 1020 - 216 });

    const positioned = { ...NO_STYLE, positionX: 0.25, positionY: 0.5, alignment: 7 as const };
    const styled = posOf(renderAss(oneCue('hi', positioned), { offset: { dx: -0.1, dy: -0.2 } }))!;
    expect(styled).toEqual({ x: 510 - 192, y: 540 - 216 });
  });

  test('the position is the anchor plus the delta, with no clamp of its own', () => {
    // **The document no longer estimates a width or pulls a drag back in.** It
    // used to, because libass will not clamp a positioned line and the mpv
    // pipeline could not see where the line landed — so both sides approximated
    // a box neither could reach. `LibassLayer` reads the boxes out of
    // `ass_render_frame` and clamps against those every frame, so the honest
    // answer here is the arithmetic and nothing else.
    //
    // Stated as *text-independence*, which is the property that actually
    // changed: two cues dragged by the same delta land on the same pixel however
    // long they are. Under the old clamp the longer one came back in.
    const drag = { offset: { dx: 0.5, dy: 0.5 } };
    const short = posOf(renderAss(oneCue('Hello!'), drag))!;
    const long = posOf(renderAss(oneCue('hey there! how are you doing my friend?'), drag))!;
    expect(long).toEqual(short);
    expect(short).toEqual({ x: 960 + 960, y: 1020 + 540 });
  });

  test('an anchored cue is not nudged either', () => {
    // `\an7` used to change the clamp's arithmetic, since that anchor sits at
    // the top-left of the box rather than its centre. With no clamp the
    // alignment has nothing to do with the position at all — it reaches the
    // `\an` tag and stops there, and libass and the client both read it from
    // the same place.
    const topLeft = { ...NO_STYLE, positionX: 0.99, positionY: 0.99, alignment: 7 as const };
    const ass = renderAss(oneCue('a reasonably long caption', topLeft), {
      offset: { dx: 0.4, dy: 0.4 },
    });
    expect(posOf(ass)).toEqual({
      x: Math.round(60 + 0.99 * 1800) + 0.4 * 1920,
      y: Math.round(60 + 0.99 * 960) + 0.4 * 1080,
    });
    expect(ass).toContain('\\an7');
  });

  test('a drag emits one event, not a text event and a backdrop', () => {
    const ass = renderAss(oneCue('hello'), { offset: { dx: 0.1, dy: -0.1 } });
    expect(dialogues(ass)).toHaveLength(1);
    expect(dialogues(ass)[0]).toStartWith('Dialogue: 0,');
  });
});

describe('the style menu', () => {
  const authored = {
    ...NO_STYLE,
    textColor: { r: 255, g: 255, b: 0, a: 1 },
    fontFamily: 'Comic Sans MS',
    fontSizePercent: 150,
  };

  test('a user override suppresses the authored tag rather than racing it', () => {
    // Emitting both and relying on order would put the answer in libass's
    // precedence rules instead of in `ass.ts`.
    const ass = renderAss(oneCue('styled', authored), {
      style: { ...NO_CAPTION_STYLE, fontFamily: 'Georgia', fontSizePercent: 200 },
    });
    expect(ass).toContain('Style: Default,Georgia,96,');
    expect(textEvents(ass)[0]).not.toContain('\\fnComic Sans MS');
    expect(textEvents(ass)[0]).not.toContain('\\fs');
  });

  test('the font colour replaces the line colour and leaves karaoke alone', () => {
    // **The rule the whole karaoke path turns on.** A user colour replaces the
    // line's *base* colour and nothing else; a run that differs from the base is
    // the highlight, and is left exactly as authored. Flattening both would make
    // karaoke look broken while the setting looked like it worked, which is the
    // silent class of failure this project keeps finding.
    const sung = { ...NO_STYLE, textColor: { r: 255, g: 255, b: 0, a: 1 } };
    const base = { ...NO_STYLE, textColor: { r: 255, g: 255, b: 255, a: 1 } };
    const ass = renderAss(
      {
        languageCode: 'en',
        isAutoGenerated: false,
        cues: [
          {
            startMs: 0,
            endMs: 1000,
            segments: [
              { text: 'Ba', offsetMs: null, style: sung },
              { text: 'sic karaoke', offsetMs: null, style: base },
            ],
            style: base,
          },
        ],
      },
      { style: { ...NO_CAPTION_STYLE, textColor: { r: 255, g: 0, b: 0, a: 1 } } },
    );
    const line = textEvents(ass)[0]!;
    // The highlight survives …
    expect(line).toContain('\\c&H00FFFF}Ba');
    // … and the base run follows the user, stated explicitly rather than left to
    // inherit — an ASS override persists to the end of its event, so a silent
    // base run would have come out in the highlight's colour.
    expect(line).toContain('\\c&H0000FF}sic karaoke');
  });

  test('an edge style reaches every track, because it is not on the box', () => {
    const ass = renderAss(oneCue('words', { ...NO_STYLE, edgeStyles: ['none'] }), {
      style: { ...NO_CAPTION_STYLE, edgeStyle: 'outline' },
    });
    expect(textEvents(ass)[0]).toContain('\\bord2.5');
  });

  test('a window the user turned on still reaches no event here', () => {
    // The window used to be a third `Dialogue`, lower than the box, using
    // `BorderStyle: 4` to draw one rectangle behind a whole multi-line cue. Like
    // the per-line box it belongs to `LibassLayer` now, which has the block's
    // real extent and does not need an invisible-glyph copy of the text to size
    // it. So an opaque window is a client-side instruction that leaves the
    // document alone — and the whole style menu is still exactly two `Style`
    // lines' worth of document: one.
    const ass = renderAss(oneCue('two\nlines'), {
      style: { ...NO_CAPTION_STYLE, window: { r: 255, g: 0, b: 0, a: 0.6 } },
    });
    expect(ass).not.toContain('Style: Window,');
    expect(ass).not.toContain(',Window,,');
    expect(ass.match(/^Style: /gm)).toHaveLength(1);
    expect(dialogues(ass).map((line) => line.split(',')[0])).toEqual(['Dialogue: 0']);
    // And it is the same document as if no window had been asked for.
    expect(ass).toBe(renderAss(oneCue('two\nlines')));
  });

  test('an untouched menu is a document nobody has to opt out of', () => {
    // `NO_CAPTION_STYLE` is every field null — "the track decides" — and it has
    // to render exactly what passing no style at all renders.
    expect(renderAss(oneCue('hello'), { style: NO_CAPTION_STYLE })).toBe(
      renderAss(oneCue('hello')),
    );
  });
});
