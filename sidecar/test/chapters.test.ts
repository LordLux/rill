/**
 * Chapters, and the two rules that make them usable as "which song is this".
 *
 * `test/data/` holds real `/next` engagement panels trimmed to what these read
 * (captured 2026-09-25): an 80s mix with 23 chapters and 10 song cards, and a
 * Portal 2 gameplay video whose only attribute card is the **game**. They are
 * committed — unlike `fixtures/` — so these run on a clean checkout instead of
 * skipping silently.
 */
import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { chaptersFromDescription, parseChapters } from '../src/parser/chapters.ts';
import { parseMusicTracks } from '../src/parser/music.ts';
import { parseVideoDetail } from '../src/parser/video.ts';

const DATA = join(dirname(fileURLToPath(import.meta.url)), 'data');
const load = (name: string): unknown => JSON.parse(readFileSync(join(DATA, `${name}.json`), 'utf8'));

describe('YouTube chapters', () => {
  const mix = load('watch-music-mix');

  test('reads every chapter once, with its start time', () => {
    const chapters = parseChapters(mix, null);

    // The list is on the page twice (the chapters panel and the structured
    // description's card list); one panel is read, so it is not 46.
    expect(chapters).toHaveLength(23);
    expect(chapters[0]).toMatchObject({ title: 'a-ha – Take On Me', startSeconds: 0 });
    expect(chapters[1]).toMatchObject({ title: 'Michael Jackson – Billie Jean', startSeconds: 222 });
    expect(chapters[22]!.startSeconds).toBe(5931);
  });

  test('is ascending and every chapter carries a thumbnail', () => {
    const chapters = parseChapters(mix, null);
    for (let i = 1; i < chapters.length; i++) {
      expect(chapters[i]!.startSeconds).toBeGreaterThan(chapters[i - 1]!.startSeconds);
    }
    for (const chapter of chapters) {
      expect(chapter.thumbnailUrl).toMatch(/^https:\/\/i\.ytimg\.com\//);
    }
  });

  test('YouTube\'s chapters win over the description', () => {
    const description = '0:00 Not this\n1:00 Nor this\n2:00 Or this';
    expect(parseChapters(mix, description)[0]!.title).toBe('a-ha – Take On Me');
  });

  test('a video with no chapters panel yields an empty list', () => {
    expect(parseChapters(load('watch-game-card'), null)).toEqual([]);
    expect(parseChapters({}, null)).toEqual([]);
  });

  test('reaches VideoDetail.chapters through the ordinary parse', () => {
    const detail = parseVideoDetail(mix);
    expect(detail.chapters).toHaveLength(23);
    // Wired next to the credits, not instead of them.
    expect(detail.music).toHaveLength(10);
  });
});

describe('song cards are told from other attributes by structure', () => {
  test('a game card is not a song', () => {
    // dHPQNc9oa_E: title "Portal 2", subtitle "2011", PORTRAIT art, an `onTap`
    // browse to the game's channel. It used to come back as the song.
    expect(parseMusicTracks(load('watch-game-card'))).toEqual([]);
    expect(parseVideoDetail(load('watch-game-card')).music).toEqual([]);
  });

  test('every card on a compilation is still a song', () => {
    const tracks = parseMusicTracks(load('watch-music-mix'));
    expect(tracks).toHaveLength(10);
    expect(tracks[0]).toMatchObject({ title: 'Take on Me (2016 Remaster)', artist: 'a-ha' });
  });

  test('an unfamiliar card with no style is a song only if it opens the credits', () => {
    const card = (extra: object) => ({
      engagementPanels: [{ videoAttributeViewModel: { title: 'X', subtitle: 'Y', ...extra } }],
    });
    expect(parseMusicTracks(card({ overflowMenuOnTap: { innertubeCommand: {} } }))).toHaveLength(1);
    expect(parseMusicTracks(card({ onTap: { innertubeCommand: {} } }))).toHaveLength(0);
    expect(parseMusicTracks(card({ imageStyle: 'VIDEO_ATTRIBUTE_IMAGE_STYLE_PORTRAIT' }))).toHaveLength(0);
  });
});

describe('timestamps in a description, as the last resort', () => {
  test('reads the common leading form', () => {
    const chapters = chaptersFromDescription(
      ['Tracklist', '', '0:00 Artist – One', '3:42 Artist – Two', '1:02:03 Artist – Three'].join('\n'),
    );
    expect(chapters.map((c) => [c.title, c.startSeconds])).toEqual([
      ['Artist – One', 0],
      ['Artist – Two', 222],
      ['Artist – Three', 3723],
    ]);
    // The description carries no image.
    expect(chapters.every((c) => c.thumbnailUrl === null)).toBe(true);
  });

  test('tolerates numbering, brackets and separators', () => {
    const chapters = chaptersFromDescription(
      ['01. [00:00] - One', '02) (03:42) | Two', '3. 07:10 — Three'].join('\r\n'),
    );
    expect(chapters.map((c) => [c.title, c.startSeconds])).toEqual([
      ['One', 0],
      ['Two', 222],
      ['Three', 430],
    ]);
  });

  test('reads a trailing timestamp when there are no leading ones', () => {
    const chapters = chaptersFromDescription(['One - 0:00', 'Two - 3:42', 'Three (7:10)'].join('\n'));
    expect(chapters.map((c) => [c.title, c.startSeconds])).toEqual([
      ['One', 0],
      ['Two', 222],
      ['Three', 430],
    ]);
  });

  test('a stray out-of-order timestamp in prose is skipped, not believed', () => {
    const chapters = chaptersFromDescription(
      ['0:00 One', '3:00 Two', 'recorded at 1:30 in the studio', '6:00 Three'].join('\n'),
    );
    expect(chapters.map((c) => c.title)).toEqual(['One', 'Two', 'Three']);
  });

  test('fewer than three is not a tracklist', () => {
    expect(chaptersFromDescription('0:00 One\n3:00 Two')).toEqual([]);
  });

  test('a list that does not start near zero is not a segmentation', () => {
    expect(chaptersFromDescription('4:00 One\n8:00 Two\n12:00 Three')).toEqual([]);
  });

  test('a line that is only symbols after the timestamp is dropped', () => {
    const chapters = chaptersFromDescription(['0:00 One', '2:00 ---', '3:00 Two', '6:00 Three'].join('\n'));
    expect(chapters.map((c) => c.title)).toEqual(['One', 'Two', 'Three']);
  });

  test('no description, or an ordinary one, is empty', () => {
    expect(chaptersFromDescription(null)).toEqual([]);
    expect(chaptersFromDescription('Subscribe for more! New video every week.')).toEqual([]);
  });

  test('reaches parseChapters when there is no panel', () => {
    const chapters = parseChapters({}, '0:00 One\n2:00 Two\n4:00 Three');
    expect(chapters).toHaveLength(3);
  });
});
