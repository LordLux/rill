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

import { logger } from '../src/log.ts';
import { parseMusicTracks } from '../src/parser/music.ts';
import { parseVideoDetail } from '../src/parser/video.ts';

const log = logger('music-test');

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(FIXTURES, `${name}.json`), 'utf8'));
}
function hasFixture(name: string): boolean {
  return existsSync(join(FIXTURES, `${name}.json`));
}
/**
 * Whether this machine's capture of [name] holds the one song card these assertions
 * were written against ("what if?", by Yoko Takahashi).
 *
 * **A mix capture is one moment** (CLAUDE.md, "Fixtures are one moment"): the
 * card was in the capture the assertions were written against and is not in
 * every later one, so asserting on it made the suite red or green by when
 * `bun run capture` last ran. Any song card is not enough, either: a later mix
 * crediting another song would turn the guarded tests red for the wrong reason.
 * The assertions that need that card run only when the fixture has it; the ones
 * below them build the same card by hand and always run.
 */
function hasMusicCard(name: string): boolean {
  return hasFixture(name) && parseMusicTracks(fixture(name)).some((track) => track.title === 'what if?');
}

if (hasFixture('mix') && !hasMusicCard('mix')) {
  // Said out loud, as `corpus.test.ts` does for an absent fixtures directory: a
  // skip nobody sees reads as a pass (`todo.md` 95 — no real card is committed).
  log.warn(
    '[music] fixtures/mix.json does not hold the "what if?" song card — skipping the three tests ' +
      'that read the captured one; the hand-built card below still runs. A capture of that mix ' +
      'brings them back.',
  );
}

/** What every real song card carries, and the synthetic ones below must too: a bare card is not recognised as a song (`parser/music.ts`'s `isSongCard`). */
const SONG = { imageStyle: 'VIDEO_ATTRIBUTE_IMAGE_STYLE_SQUARE' };

describe('music attribution', () => {
  test.skipIf(!hasMusicCard('mix'))('reads the song, artist and album off the card', () => {
    const tracks = parseMusicTracks(fixture('mix'));

    expect(tracks).toHaveLength(1);
    expect(tracks[0]!.title).toBe('what if?');
    // The card's primary artist, deliberately narrower than the credits
    // dialog's "Daft Punk, Julian Casablancas" — see `parser/music.ts`.
    expect(tracks[0]!.artist).toBe('Yoko Takahashi');
    expect(tracks[0]!.album).toBe('鷺巣詩郎 what if? 高橋洋子ver. 通常版');
  });

  test.skipIf(!hasMusicCard('mix'))('sizes the cover, and does not double-size it', () => {
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

  test.skipIf(!hasMusicCard('mix'))('reaches VideoDetail.music through the ordinary parse', () => {
    // The field is wired in, not just parseable in isolation — the gap these
    // two being separate would leave is a parser nothing calls.
    const detail = parseVideoDetail(fixture('mix'));
    expect(detail.music).toHaveLength(1);
    expect(detail.music[0]!.title).toBe('what if?');
  });

  /** A song card as the mix capture of 2026-08 carried it, built by hand so these do not depend on a capture. */
  const WHAT_IF = {
    videoAttributeViewModel: {
      ...SONG,
      title: 'what if?',
      subtitle: 'Yoko Takahashi',
      secondarySubtitle: { content: '鷺巣詩郎 what if? 高橋洋子ver. 通常版' },
      image: { sources: [{ url: 'https://yt3.googleusercontent.com/cover' }] },
    },
  };

  test('reads the song, artist and album off a hand-built card', () => {
    const tracks = parseMusicTracks({ cards: [WHAT_IF] });

    expect(tracks).toHaveLength(1);
    expect(tracks[0]!.title).toBe('what if?');
    expect(tracks[0]!.artist).toBe('Yoko Takahashi');
    expect(tracks[0]!.album).toBe('鷺巣詩郎 what if? 高橋洋子ver. 通常版');
  });

  test('sizes a hand-built card\'s cover once', () => {
    const [track] = parseMusicTracks({ cards: [WHAT_IF] });
    const url = track!.coverUrl;

    expect(url).toBe('https://yt3.googleusercontent.com/cover=s1200');
    expect(url!.match(/=s\d+/g)).toHaveLength(1);
  });

  test.skipIf(!hasFixture('watch'))('reaches VideoDetail.music through the ordinary parse, from a card in a real watch page', () => {
    // A real watch page with no music section (`watch.json`) and one card put
    // where the panel would be: the parse is the ordinary one, only the card is
    // supplied. `parseMusicTracks` collects every card in the body, as the real
    // panel's index moves between responses.
    const body = { ...(fixture('watch') as Record<string, unknown>), injectedPanel: { cards: [WHAT_IF] } };
    const detail = parseVideoDetail(body);

    expect(detail.music).toHaveLength(1);
    expect(detail.music[0]!.title).toBe('what if?');
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
