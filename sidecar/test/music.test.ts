/**
 * "Music in this video", off the watch page's `engagementPanels`.
 *
 * **One fixture carries this.** `mix.json` is the only capture in the corpus
 * with a `videoAttributeViewModel`, and it has exactly one card, so these
 * assertions pin a shape observed once. `watch.json` is the control: a watch
 * page with a `structuredDescriptionContentRenderer` and no music section,
 * which must come back empty rather than throwing or guessing.
 */
import { describe, expect, test } from 'bun:test';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseMusicTracks } from '../src/parser/music.ts';
import { parseVideoDetail } from '../src/parser/video.ts';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(FIXTURES, `${name}.json`), 'utf8'));
}
function hasFixture(name: string): boolean {
  return existsSync(join(FIXTURES, `${name}.json`));
}

/** What every real song card carries, and the synthetic ones below must too: a bare card is not recognised as a song (`parser/music.ts`'s `isSongCard`). */
const SONG = { imageStyle: 'VIDEO_ATTRIBUTE_IMAGE_STYLE_SQUARE' };

describe('music attribution', () => {
  test.skipIf(!hasFixture('mix'))('reads the song, artist and album off the card', () => {
    const tracks = parseMusicTracks(fixture('mix'));

    expect(tracks).toHaveLength(1);
    expect(tracks[0]!.title).toBe('Instant Crush (feat. Julian Casablancas)');
    // The card's primary artist, deliberately narrower than the credits
    // dialog's "Daft Punk, Julian Casablancas" — see `parser/music.ts`.
    expect(tracks[0]!.artist).toBe('Daft Punk');
    expect(tracks[0]!.album).toBe('Random Access Memories');
  });

  test.skipIf(!hasFixture('mix'))('sizes the cover, and does not double-size it', () => {
    const [track] = parseMusicTracks(fixture('mix'));
    const url = track!.coverUrl;

    expect(url).not.toBeNull();
    expect(url).toContain('googleusercontent.com');
    // `=s1200` is the measured cap: `=s1800` returns the same 1200x1200.
    expect(url!.endsWith('=s1200')).toBe(true);
    expect(url!.match(/=s\d+/g)).toHaveLength(1);
  });

  test.skipIf(!hasFixture('watch'))('a video with no music section yields an empty list', () => {
    // Not null, not a throw: empty is the ordinary answer and the client must
    // be able to treat it as one.
    expect(parseMusicTracks(fixture('watch'))).toEqual([]);
  });

  test.skipIf(!hasFixture('mix'))('reaches VideoDetail.music through the ordinary parse', () => {
    // The field is wired in, not just parseable in isolation — the gap these
    // two being separate would leave is a parser nothing calls.
    const detail = parseVideoDetail(fixture('mix'));
    expect(detail.music).toHaveLength(1);
    expect(detail.music[0]!.title).toBe('Instant Crush (feat. Julian Casablancas)');
  });

  test('a card with no title is dropped rather than shipped blank', () => {
    const tracks = parseMusicTracks({
      cards: [
        { videoAttributeViewModel: { ...SONG, subtitle: 'Nobody', secondarySubtitle: { content: 'Nothing' } } },
        { videoAttributeViewModel: { ...SONG, title: 'Real Song', subtitle: 'Real Artist' } },
      ],
    });

    expect(tracks).toHaveLength(1);
    expect(tracks[0]!.title).toBe('Real Song');
    expect(tracks[0]!.album).toBeNull();
    expect(tracks[0]!.coverUrl).toBeNull();
  });

  test("YouTube's stock no-art cover ships as null, and the track still ships", () => {
    // The URL verbatim as measured 2026-09-24 — six cards, one URL.
    const tracks = parseMusicTracks({
      cards: [
        {
          videoAttributeViewModel: {
            ...SONG,
            title: 'M11 re-arrange and re-mix',
            subtitle: 'Shiro SAGISU',
            image: { sources: [{ url: 'https://www.gstatic.com/youtube/img/watch/yt_music_channel.jpeg' }] },
          },
        },
        {
          videoAttributeViewModel: {
            ...SONG,
            title: 'Real Song',
            image: { sources: [{ url: 'https://yt3.googleusercontent.com/abc' }] },
          },
        },
      ],
    });

    expect(tracks).toHaveLength(2);
    expect(tracks[0]!.title).toBe('M11 re-arrange and re-mix');
    expect(tracks[0]!.coverUrl).toBeNull();
    expect(tracks[1]!.coverUrl).toBe('https://yt3.googleusercontent.com/abc=s1200');
  });

  test('an unrecognised card does not take the rest down (hard invariant 4)', () => {
    const tracks = parseMusicTracks({
      a: { videoAttributeViewModel: 'not an object' },
      b: { videoAttributeViewModel: { ...SONG, title: 'Survivor' } },
    });

    expect(tracks).toHaveLength(1);
    expect(tracks[0]!.title).toBe('Survivor');
  });
});
