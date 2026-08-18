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
import { parseJson3 } from '../src/captions/json3.ts';
import { cueText, groupAsrCues, normalizeCues, type Cue } from '../src/captions/cues.ts';
import { assColor, assTime, escapeAssText, renderAss } from '../src/captions/ass.ts';
import {
  captionsNegativeCacheSize,
  convert,
  forgetCaptions,
  listCaptionTracks,
} from '../src/captions/service.ts';
import { forgetPlayerResponse } from '../src/innertube/player-response.ts';
import type { Session } from '../src/innertube/session.ts';

// ---------------------------------------------------------------------------
// Payloads
// ---------------------------------------------------------------------------

/** `ANDROID_VR`'s shape: absolute `baseUrl`, no `translationLanguages`. */
const ANDROID_VR_RESPONSE = {
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
  test('reads the ANDROID_VR shape, absolute baseUrl', () => {
    const sources = parseCaptionTracks(ANDROID_VR_RESPONSE);
    expect(sources.map((s) => s.track)).toEqual([
      { id: '.en', languageCode: 'en', label: 'English', isAutoGenerated: false, isTranslatable: true },
      {
        id: 'a.en',
        languageCode: 'en',
        label: 'English (auto-generated)',
        isAutoGenerated: true,
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

describe('normalizeCues', () => {
  const cue = (startMs: number, endMs: number, text: string): Cue => ({
    startMs,
    endMs,
    segments: [{ text, offsetMs: null }],
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

    const dialogues = ass.split('\n').filter((line) => line.startsWith('Dialogue:'));
    expect(dialogues).toHaveLength(cues.length);
    dialogues.forEach((line, i) => {
      const cue = cues[i]!;
      expect(line).toBe(
        `Dialogue: 0,${assTime(cue.startMs)},${assTime(cue.endMs)},Default,,0,0,0,,${cueText(cue)}`,
      );
    });
    // Every Dialogue has the 9 commas its format line promises before the text.
    for (const line of dialogues) {
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
          segments: [{ text: 'styled', offsetMs: null }],
          style: {
            alignment: 7,
            positionX: 0.25,
            positionY: 0.5,
            textColor: { r: 255, g: 255, b: 0, a: 1 },
            backgroundColor: null,
            edgeColor: { r: 0, g: 0, b: 0, a: 1 },
            edgeStyle: 'dropShadow',
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
    expect(ass).toContain('\\pos(480,540)');
    expect(ass).toContain('\\fnRoboto');
    expect(ass).toContain('\\fs72');
    expect(ass).toContain('\\c&H0000FFFF');
    expect(ass).toContain('\\shad2');
    expect(ass).toContain('\\b1');
    // A null field emits nothing rather than a default that overrides the Style.
    expect(ass).not.toContain('\\i0');
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
    const lines = content.content
      .split('\n')
      .filter((l) => l.startsWith('Dialogue:'))
      .map((l) => l.split(',').slice(9).join(','));
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
// The ANDROID_VR fallback and its negative cache
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

describe('the ANDROID_VR fallback', () => {
  beforeEach(() => {
    forgetCaptions();
    forgetPlayerResponse();
  });

  test('does not fire when ANDROID_VR has tracks', async () => {
    const { session, calls } = stubResolveSession({
      ANDROID_VR: ANDROID_VR_RESPONSE,
      MWEB: WEB_RESPONSE,
    });
    const result = await listCaptionTracks(session, 'has-captions');
    expect(result.sources).toHaveLength(2);
    expect(result.usedFallback).toBe(false);
    expect(calls).toEqual(['/player:ANDROID_VR']);
  });

  test('fires on an empty list and recovers the tracks', async () => {
    const { session, calls } = stubResolveSession({ ANDROID_VR: NO_TRACKS, MWEB: WEB_RESPONSE });
    const result = await listCaptionTracks(session, 'vr-gap');
    expect(result.sources.map((s) => s.track.languageCode)).toEqual(['de-DE']);
    expect(result.usedFallback).toBe(true);
    expect(calls).toEqual(['/player:ANDROID_VR', '/player:MWEB']);
  });

  test('asks MWEB, not WEB — a WEB caption URL answers 200 with no body', async () => {
    // Measured 2026-08-18: a `WEB` `/player` signs its timedtext URLs with
    // `exp=xpe`, and every one of them returns an empty 200. Falling back to WEB
    // would fill the language picker with tracks that render nothing.
    const { session, calls } = stubResolveSession({ ANDROID_VR: NO_TRACKS, MWEB: WEB_RESPONSE });
    await listCaptionTracks(session, 'vr-gap');
    expect(calls).not.toContain('/player:WEB');
  });

  test('caches the negative and does not fire twice inside the TTL', async () => {
    const { session, calls } = stubResolveSession({ ANDROID_VR: NO_TRACKS, MWEB: NO_TRACKS });

    expect((await listCaptionTracks(session, 'captionless')).sources).toEqual([]);
    expect(calls).toEqual(['/player:ANDROID_VR', '/player:MWEB']);
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
    const { session, calls } = stubResolveSession({ ANDROID_VR: NO_TRACKS, MWEB: NO_TRACKS });
    await listCaptionTracks(session, 'captionless');
    forgetCaptions();
    forgetPlayerResponse();
    await listCaptionTracks(session, 'captionless');
    expect(calls.filter((c) => c === '/player:MWEB')).toHaveLength(2);
  });

  test('the negative is per video, not global', async () => {
    const { session, calls } = stubResolveSession({
      ANDROID_VR: NO_TRACKS,
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
    const { session } = stubResolveSession({ ANDROID_VR: NO_TRACKS, MWEB: NO_TRACKS });
    await expect(listCaptionTracks(session, 'captionless')).resolves.toMatchObject({
      sources: [],
    });
  });
});
