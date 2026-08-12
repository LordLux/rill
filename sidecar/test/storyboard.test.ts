/**
 * `video.storyboard` — offline. What these cannot establish is that a substituted URL is
 * *fetchable*: one can satisfy every string assertion here and answer 403. That lives in
 * `network.test.ts`.
 */

import { describe, expect, test } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parsePlayer, sheetUrl } from '../src/parser/index.ts';
import { selectSheet, storyboardFrom } from '../src/video/storyboard.ts';
import type { Storyboard } from '../src/types.ts';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(FIXTURES, `${name}.json`), 'utf8'));
}
function hasFixture(name: string): boolean {
  return existsSync(join(FIXTURES, `${name}.json`));
}

/**
 * The spec `aqz-KE-bpKQ` served, verbatim, minus the sqp's length. Inlined because the fixtures
 * are not committed and this shape is what every assertion below is about.
 */
const REAL_SPEC =
  'https://i.ytimg.com/sb/aqz-KE-bpKQ/storyboard3_L$L/$N.jpg?sqp=-oaymwENSDfyq4qpAw==' +
  '|48#27#100#10#10#0#default#rs$AOn4CLC4g9l8goJa' +
  '|80#45#128#10#10#5000#M$M#rs$AOn4CLAze14Ic8Nj' +
  '|160#90#128#5#5#5000#M$M#rs$AOn4CLC9nRwSugHS' +
  '|320#180#128#3#3#5000#M$M#rs$AOn4CLAsookXQ4X4';

function boardsFrom(spec: string, durationSeconds: number | null = 635) {
  const response = parsePlayer({
    videoDetails: { videoId: 'aqz-KE-bpKQ', lengthSeconds: durationSeconds },
    storyboards: { playerStoryboardSpecRenderer: { spec } },
  });
  return response;
}

// ---------------------------------------------------------------------------

describe('template substitution', () => {
  const boards = boardsFrom(REAL_SPEC).storyboards;

  test('$L is the level index and $N is that level’s own name field', () => {
    expect(boards).toHaveLength(4);
    expect(boards[0]!.templateUrl).toContain('/storyboard3_L0/default.jpg');
    expect(boards[1]!.templateUrl).toContain('/storyboard3_L1/M$M.jpg');
    expect(boards[3]!.templateUrl).toContain('/storyboard3_L3/M$M.jpg');
  });

  test('sigh is appended, and sqp survives — dropping either is a 403', () => {
    // Measured 2026-08-11: the full URL is 200; missing either is 403 with an HTML body.
    for (const board of boards) {
      expect(board.templateUrl).toContain('sqp=-oaymwENSDfyq4qpAw==');
      expect(board.templateUrl).toContain('&sigh=rs$AOn4CL');
    }
  });

  test('a signature starting rs$ is not read as a replacement pattern', () => {
    // `$&`, `$'` and `` $` `` are replacement patterns to String.replace, so a naive
    // substitution is one naming change away from silently mangling the URL.
    const hostile = 'https://i.ytimg.com/sb/X/L$L/$N.jpg?sqp=Q|48#27#4#2#2#0#$&#rs$`x';
    const [board] = boardsFrom(hostile).storyboards;
    expect(board!.templateUrl).toBe('https://i.ytimg.com/sb/X/L0/$&.jpg?sqp=Q&sigh=rs$`x');
  });

  test('sheetUrl numbers $M, and is the identity on a level that has none', () => {
    expect(sheetUrl(boards[1]!, 0)).toContain('/storyboard3_L1/M0.jpg');
    expect(sheetUrl(boards[1]!, 7)).toContain('/storyboard3_L1/M7.jpg');
    // Level 0 is one sheet by construction — its name is a literal.
    expect(sheetUrl(boards[0]!, 3)).toBe(boards[0]!.templateUrl);
  });
});

// ---------------------------------------------------------------------------

describe('level selection', () => {
  test('picks the level whose whole frame set is one sheet', () => {
    const spec = selectSheet(boardsFrom(REAL_SPEC).storyboards, 635)!;

    // The only one of the four that fits: level 1 needs 2 sheets, level 2 six, level 3 fifteen.
    expect(spec.level).toBe(0);
    expect(spec.frameCount).toBe(100);
    expect(spec.columns).toBe(10);
    expect(spec.rows).toBe(10);
    expect(spec.frameWidth).toBe(48);
    // `$` alone would be the wrong check — every real `sigh` is literally `rs$AOn4CL…`.
    expect(spec.url).not.toMatch(/\$[LNM]/);
    expect(spec.url).toContain('/storyboard3_L0/default.jpg');
  });

  test('a level-0 interval of 0 is divided out against the duration', () => {
    // 635 s / 100 frames = 6350 ms; level 1 agreeing (128 × 5 s ≈ 635 s) is the cross-check.
    expect(selectSheet(boardsFrom(REAL_SPEC).storyboards, 635)!.intervalMs).toBe(6350);
  });

  test('a bigger level wins when its frames do fit — a short video', () => {
    // Level 1 holds its 100 frames in a 10×10 grid, so it is one sheet and wins on width.
    const short =
      'https://i.ytimg.com/sb/X/storyboard3_L$L/$N.jpg?sqp=Q' +
      '|48#27#100#10#10#0#default#rs$A' +
      '|80#45#100#10#10#1000#M$M#rs$B';
    const spec = selectSheet(boardsFrom(short, 100).storyboards, 100)!;
    expect(spec.level).toBe(1);
    expect(spec.frameWidth).toBe(80);
    expect(spec.intervalMs).toBe(1000);
    expect(spec.url).toContain('/storyboard3_L1/M0.jpg');
  });

  test('when nothing fits, the lowest level is truncated to its first sheet', () => {
    // `frameCount` must then be the cells, not the level's count — trailing cells hold no frame.
    const overflowing =
      'https://i.ytimg.com/sb/X/storyboard3_L$L/$N.jpg?sqp=Q' +
      '|48#27#250#10#10#0#default#rs$A' +
      '|160#90#250#5#5#5000#M$M#rs$B';
    const spec = selectSheet(boardsFrom(overflowing, 500).storyboards, 500)!;
    expect(spec.level).toBe(0);
    expect(spec.frameCount).toBe(100);
    // Truncating what we show does not change what a frame means.
    expect(spec.intervalMs).toBe(2000);
  });

  test('a video with no storyboards answers null, not an error', () => {
    // Measured: `jNQXAC9IVRw` (19 s) carries zero levels on both clients.
    const response = parsePlayer({ videoDetails: { videoId: 'x', lengthSeconds: 19 } });
    expect(storyboardFrom(response).storyboard).toBeNull();
  });

  test('a level with no cadence and no duration declines rather than guessing', () => {
    const spec = selectSheet(boardsFrom(REAL_SPEC, null).storyboards, null);
    expect(spec).toBeNull();
  });

  test('a level missing its grid is skipped, not divided by zero', () => {
    const boards: Storyboard[] = [
      {
        level: 0,
        templateUrl: 'https://i.ytimg.com/sb/X/L0/default.jpg?sqp=Q&sigh=rs$A',
        thumbnailWidth: 48,
        thumbnailHeight: 27,
        thumbnailCount: 100,
        columns: null,
        rows: null,
        intervalMs: 0,
      },
      {
        level: 1,
        templateUrl: 'https://i.ytimg.com/sb/X/L1/M$M.jpg?sqp=Q&sigh=rs$B',
        thumbnailWidth: 80,
        thumbnailHeight: 45,
        thumbnailCount: 9,
        columns: 3,
        rows: 3,
        intervalMs: 2000,
      },
    ];
    const spec = selectSheet(boards, 18)!;
    expect(spec.level).toBe(1);
    expect(Number.isFinite(spec.intervalMs)).toBe(true);
  });
});

// ---------------------------------------------------------------------------

describe.if(hasFixture('player-web') && hasFixture('player-mweb'))('against the captures', () => {
  for (const name of ['player-web', 'player-mweb']) {
    test(`${name} resolves to a single fully-substituted sheet`, () => {
      const spec = storyboardFrom(parsePlayer(fixture(name))).storyboard!;

      expect(spec).not.toBeNull();
      // Catches a half-done substitution: no placeholder survives into a URL about to be fetched.
      expect(spec.url).not.toContain('$L');
      expect(spec.url).not.toContain('$N');
      expect(spec.url).not.toContain('$M');
      expect(spec.url).toStartWith('https://i.ytimg.com/sb/');
      expect(spec.frameCount).toBeLessThanOrEqual(spec.columns * spec.rows);
      expect(spec.frameCount).toBeGreaterThan(0);
      expect(spec.intervalMs).toBeGreaterThan(0);
    });
  }
});
