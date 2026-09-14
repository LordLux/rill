/**
 * `exactCountFromText` — the view-count parser, and mostly what it refuses.
 *
 * A view count is the one metadata string YouTube routinely ships *already
 * rounded*, so the interesting behaviour is not "parses a number" but "knows
 * when it cannot". A wrong answer here is worse than none: it gets shortened
 * and displayed as fact, and `"1.8M views"` read naively is **18**.
 *
 * The locale cases are not hypothetical padding. The sidecar does not pin a
 * language, and the abbreviation styles below are the ones that break a
 * strip-the-non-digits parser in different ways: a Latin suffix, a CJK
 * myriad character, and a European decimal comma.
 */

import { describe, expect, test } from 'bun:test';

import { exactCountFromText } from '../src/parser/text.ts';

describe('exact counts, parsed', () => {
  // The live shapes, measured 2026-09-13.
  test.each([
    ['1,815,347,797 views', 1815347797],
    ['57,253,345 views', 57253345],
    ['4,642,098 views', 4642098],
    ['313,095 views', 313095],
    ['10,625 watching', 10625],
    ['347 watching', 347],
    ['1 view', 1],
    ['0 views', 0],
  ])('%s -> %p', (input, expected) => {
    expect(exactCountFromText(input)).toBe(expected);
  });

  test('accepts a plain runs/simpleText node, like everything else here', () => {
    expect(exactCountFromText({ simpleText: '4,642,098 views' })).toBe(4642098);
    expect(exactCountFromText({ runs: [{ text: '4,642,098' }, { text: ' views' }] })).toBe(4642098);
  });

  test('other separators are thousands separators too', () => {
    // German/Italian dots, French narrow no-break space, Swiss apostrophe.
    expect(exactCountFromText('4.642.098 Aufrufe')).toBe(4642098);
    expect(exactCountFromText('4 642 098 vues')).toBe(4642098);
    expect(exactCountFromText("4'642'098")).toBe(4642098);
  });
});

describe('rounded counts, refused', () => {
  // Each of these has an exact number that is NOT recoverable from the string.
  // Answering anything here would be answering wrongly.
  test.each([
    ['1.8M views'],
    ['57M views'],
    ['88K views'],
    ['2.3K views'],
    ['4.1K watching'],
    ['1.8B'],
    ['10K watching'],
  ])('%s -> null', (input) => {
    expect(exactCountFromText(input)).toBeNull();
  });

  test('a Latin magnitude suffix is refused, not stripped', () => {
    // The failure this exists to prevent: 1.8M read as 18.
    expect(exactCountFromText('1.8M views')).not.toBe(18);
    expect(exactCountFromText('1.8M views')).toBeNull();
  });

  test('a CJK myriad marker is refused', () => {
    // 182万 is 1,820,000. Stripping non-digits answers 182 — off by four
    // orders of magnitude, and it would render as "182 views".
    expect(exactCountFromText('182万回視聴')).toBeNull();
    expect(exactCountFromText('1.8億回視聴')).toBeNull();
  });

  test('a European decimal comma is refused', () => {
    // "1,8 Mio. Aufrufe" — the digits group as 1 then 8, not in threes, and
    // the space before the unit means a letter check alone would miss it.
    expect(exactCountFromText('1,8 Mio. Aufrufe')).toBeNull();
    expect(exactCountFromText('1,8 Mio.')).toBeNull();
  });
});

describe('nothing to parse', () => {
  test.each([
    ['No views'],
    ['views'],
    [''],
    ['—'],
  ])('%p -> null', (input) => {
    expect(exactCountFromText(input)).toBeNull();
  });

  test('null and non-text nodes', () => {
    expect(exactCountFromText(null)).toBeNull();
    expect(exactCountFromText(undefined)).toBeNull();
    expect(exactCountFromText({})).toBeNull();
    expect(exactCountFromText([])).toBeNull();
  });
});

describe('it is not countFromText', () => {
  test('the two disagree on a rounded string, deliberately', async () => {
    // `countFromText` strips every non-digit, which is right for
    // "1,234 videos" and wrong for a view count. If someone ever collapses
    // the two, this fails.
    const { countFromText } = await import('../src/parser/text.ts');
    expect(countFromText('1.8M views')).toBe(18);
    expect(exactCountFromText('1.8M views')).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// parseVideoDetail — where the number is actually chosen
// ---------------------------------------------------------------------------

import { parseVideoDetail } from '../src/parser/video.ts';

/** A `/next` body carrying just the view-count renderer under test. */
function watchPage(viewCount: string | null, originalViewCount?: string): unknown {
  return {
    contents: {
      twoColumnWatchNextResults: {
        results: {
          results: {
            contents: [
              {
                videoPrimaryInfoRenderer: {
                  title: { runs: [{ text: 'A video' }] },
                  viewCount: {
                    videoViewCountRenderer: {
                      ...(viewCount === null ? {} : { viewCount: { simpleText: viewCount } }),
                      ...(originalViewCount === undefined ? {} : { originalViewCount }),
                    },
                  },
                },
              },
            ],
          },
        },
      },
    },
  };
}

describe('parseVideoDetail — viewCount', () => {
  test('"0" in originalViewCount is "not filled in", not zero', () => {
    // Reported from the app: "0 views" on screen, "67,573 views" in the
    // tooltip. Measured: 18 of 24 real watch pages carry exactly this shape.
    const detail = parseVideoDetail(watchPage('67,573 views', '0'));
    expect(detail.viewCount).toBe(67573);
    expect(detail.viewCount).not.toBe(0);
  });

  test('the number shown matches the text the tooltip shows', () => {
    // Derived from the same string, so the two cannot disagree.
    const detail = parseVideoDetail(watchPage('1,897,747 views', '1897747'));
    expect(detail.viewCount).toBe(1897747);
    expect(detail.viewCountText).toBe('1,897,747 views');
  });

  test('a populated originalViewCount rescues an unparseable text', () => {
    const detail = parseVideoDetail(watchPage('1.8M views', '1815380369'));
    expect(detail.viewCount).toBe(1815380369);
  });

  test('a genuinely unwatched video is still 0, from its text', () => {
    const detail = parseVideoDetail(watchPage('0 views', '0'));
    expect(detail.viewCount).toBe(0);
  });

  test('rounded text and a "0" sentinel is not recoverable', () => {
    const detail = parseVideoDetail(watchPage('1.8M views', '0'));
    expect(detail.viewCount).toBeNull();
  });
});
