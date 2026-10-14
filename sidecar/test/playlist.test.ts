/**
 * `playlist.get` and the playlist tile's count — Task 34.
 *
 * The synthetic trees are the shapes measured 2026-10-06 (`architecture.md`
 * F54): a `/browse VL<id>` page of `playlistVideoRenderer` rows ending in a
 * continuation item, and a search `lockupViewModel` whose count is its
 * thumbnail badge.
 */

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, test } from 'bun:test';

import { RpcError } from '../src/errors.ts';
import type { Session } from '../src/innertube/session.ts';
import { parseFeed } from '../src/parser/feed.ts';
import { getPlaylist, parsePlaylistHeader, parsePlaylistPage } from '../src/parser/playlist.ts';
import type { Json } from '../src/parser/tree.ts';

const FIXTURES = join(import.meta.dir, '..', 'fixtures');
const hasFixture = (name: string): boolean => existsSync(join(FIXTURES, `${name}.json`));
const fixture = (name: string): Json => JSON.parse(readFileSync(join(FIXTURES, `${name}.json`), 'utf8')) as Json;

function row(id: string, title = `Video ${id}`, extra: Record<string, unknown> = {}) {
  return {
    playlistVideoRenderer: {
      videoId: id,
      title: { runs: [{ text: title }] },
      shortBylineText: { runs: [{ text: 'Owner' }] },
      lengthSeconds: '200',
      ...extra,
    },
  };
}

function page(rows: unknown[], options: { token?: string; title?: string; count?: string; alert?: [string, string] } = {}) {
  return {
    ...(options.alert
      ? {
          alerts: [
            // The two shapes seen: an ERROR as `alertRenderer` with runs, the
            // "hidden" notice as `alertWithButtonRenderer` with simpleText.
            options.alert[0] === 'ERROR'
              ? { alertRenderer: { type: options.alert[0], text: { runs: [{ text: options.alert[1] }] } } }
              : { alertWithButtonRenderer: { type: options.alert[0], text: { simpleText: options.alert[1] } } },
          ],
        }
      : {}),
    ...(options.title ? { metadata: { playlistMetadataRenderer: { title: options.title } } } : {}),
    ...(options.count
      ? {
          sidebar: {
            playlistSidebarRenderer: {
              items: [{ playlistSidebarPrimaryInfoRenderer: { stats: [{ runs: [{ text: options.count }, { text: ' videos' }] }] } }],
            },
          },
        }
      : {}),
    contents: [
      ...rows,
      ...(options.token
        ? [
            {
              continuationItemViewModel: {
                trigger: 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN',
                continuationCommand: { innertubeCommand: { continuationCommand: { token: options.token } } },
              },
            },
          ]
        : []),
    ],
  };
}

/** A session answering `/browse` from a script, and recording what it was asked. */
function sessionOf(responses: unknown[]): { session: Session; calls: Record<string, unknown>[] } {
  const calls: Record<string, unknown>[] = [];
  const session = {
    execute: async (_endpoint: string, params: Record<string, unknown> = {}) => {
      calls.push(params);
      return responses.shift();
    },
  } as unknown as Session;
  return { session, calls };
}

function playlistLockup(options: { id: string; badge: string | null; rows: string[][] }) {
  return {
    contents: [
      {
        lockupViewModel: {
          contentId: options.id,
          contentType: 'LOCKUP_CONTENT_TYPE_PLAYLIST',
          contentImage: {
            collectionThumbnailViewModel: {
              primaryThumbnail: {
                thumbnailViewModel: {
                  image: { sources: [{ url: 'https://i.ytimg.com/vi/thumbVideo1/hq.jpg', width: 480 }] },
                  overlays: options.badge
                    ? [{ thumbnailOverlayBadgeViewModel: { thumbnailBadges: [{ thumbnailBadgeViewModel: { text: options.badge } }] } }]
                    : [],
                },
              },
            },
          },
          metadata: {
            lockupMetadataViewModel: {
              title: { content: 'Ado playlist' },
              metadata: {
                contentMetadataViewModel: {
                  metadataRows: options.rows.map((parts) => ({
                    metadataParts: parts.map((content) => ({ text: { content } })),
                  })),
                },
              },
            },
          },
        },
      },
    ],
  };
}

describe('playlist.get', () => {
  test('the first page asks for VL<id> and carries the header', async () => {
    const token = 'next-page-token-longer-than-twenty-characters';
    const { session, calls } = sessionOf([page([row('a'), row('b')], { token, title: 'Ado playlist', count: '135' })]);
    const result = await getPlaylist(session, { playlistId: 'PLabc', continuation: null });

    expect(calls).toEqual([{ browseId: 'VLPLabc' }]);
    expect(result.items.map((item) => item.id)).toEqual(['a', 'b']);
    expect(result.continuation).toBe(token);
    expect(result.title).toBe('Ado playlist');
    expect(result.videoCount).toBe(135);
  });

  test('a continuation is sent as one, and the last page ends with null', async () => {
    const { session, calls } = sessionOf([page([row('c')])]);
    const result = await getPlaylist(session, { playlistId: 'PLabc', continuation: 'next-page' });

    expect(calls).toEqual([{ continuation: 'next-page' }]);
    expect(result.continuation).toBeNull();
    expect(result.title).toBeNull();
    expect(result.videoCount).toBeNull();
  });

  // A continuation page repeats enough of the metadata to build a header from,
  // and whatever it lacks (the tint, the cover) would replace the first page's.
  test('the header is the first page\'s: a continuation has none, even with a title to build one from', async () => {
    const first = sessionOf([page([row('a')], { token: 'next-page-token-longer-than-twenty-characters', title: 'Ado playlist', count: '135' })]);
    expect((await getPlaylist(first.session, { playlistId: 'PLabc', continuation: null })).header).not.toBeNull();

    const next = sessionOf([page([row('b')], { title: 'Ado playlist', count: '135' })]);
    const result = await getPlaylist(next.session, { playlistId: 'PLabc', continuation: 'next-page' });
    expect(result.header).toBeNull();
    // Still passed on: the queue names and sizes the playlist from these.
    expect(result.title).toBe('Ado playlist');
    expect(result.videoCount).toBe(135);
    expect(result.items.map((item) => item.id)).toEqual(['b']);
  });

  test('unavailable entries are skipped, and the rest of the page ships', async () => {
    const { session } = sessionOf([
      page([row('a'), row('gone1', '[Deleted video]'), row('gone2', '[Private video]'), row('gone3', 'Blocked', { isPlayable: false }), row('b')]),
    ]);
    const result = await getPlaylist(session, { playlistId: 'PLabc', continuation: null });
    expect(result.items.map((item) => item.id)).toEqual(['a', 'b']);
  });

  test('an ERROR alert is the answer', async () => {
    const { session } = sessionOf([page([], { alert: ['ERROR', 'The playlist does not exist.'] })]);
    const failure = await getPlaylist(session, { playlistId: 'PLabc', continuation: null }).catch((e: unknown) => e);
    expect(failure).toBeInstanceOf(RpcError);
    // YouTube answered, and the answer is no: not a failure to get an answer
    // (`UPSTREAM_ERROR`, which the app retries by itself), and nothing a retry
    // changes.
    expect((failure as RpcError).code).toBe('NOT_FOUND');
    expect((failure as RpcError).retry).toBe('no');
    expect((failure as RpcError).toEnvelope()).toEqual({
      code: 'NOT_FOUND',
      message: 'The playlist does not exist.',
      retry: 'no',
    });
  });

  // Ownership and visibility are the viewer's, and were wrong with an all-green
  // suite: the privacy dropdown was read one level short of its entries, so an
  // owned playlist was nobody's and a private one was public. A fixture in each
  // known state is the only thing that says otherwise (CLAUDE.md, viewer state).
  for (const [name, visibility, owned] of [
    ['playlist-private-owned', 'private', true],
    ['playlist-unlisted-owned', 'unlisted', true],
    ['playlist-public-owned', 'public', true],
    ['playlist-wl', 'private', true],
    ['playlist-public-anon', 'public', false],
    ['playlist', 'public', false],
  ] as const) {
    test.if(hasFixture(name))(`the captured ${name} is ${visibility}, and ${owned ? 'the viewer\'s' : 'not the viewer\'s'}`, () => {
      const { header } = parsePlaylistPage(fixture(name), false);
      expect(header?.visibility).toBe(visibility);
      expect(header?.isOwnedByViewer).toBe(owned);
    });
  }

  test('the privacy dropdown\'s selected entry is the visibility, and having one is owning it', () => {
    const withDropdown = (selected: number) => ({
      metadata: { playlistMetadataRenderer: { title: 'Mine' } },
      sidebar: {
        playlistSidebarRenderer: {
          items: [
            {
              playlistSidebarPrimaryInfoRenderer: {
                privacyForm: {
                  dropdownFormFieldRenderer: {
                    dropdown: {
                      dropdownRenderer: {
                        entries: [0, 1, 2].map((value) => ({
                          privacyDropdownItemRenderer: { int32Value: value, isSelected: value === selected },
                        })),
                      },
                    },
                  },
                },
              },
            },
          ],
        },
      },
    });
    for (const [value, visibility] of [[0, 'private'], [1, 'public'], [2, 'unlisted']] as const) {
      const { header } = parsePlaylistHeader(withDropdown(value) as Json);
      expect(header?.visibility).toBe(visibility);
      expect(header?.isOwnedByViewer).toBe(true);
    }
    const { header } = parsePlaylistHeader({ metadata: { playlistMetadataRenderer: { title: 'Theirs' } } });
    expect(header?.isOwnedByViewer).toBe(false);
    expect(header?.visibility).toBe('public');
  });

  test('any other alert leaves the list alone', async () => {
    const { session } = sessionOf([page([row('a')], { alert: ['INFO', 'Unavailable videos are hidden'] })]);
    const result = await getPlaylist(session, { playlistId: 'PLabc', continuation: null });
    expect(result.items.map((item) => item.id)).toEqual(['a']);
  });

  test.if(hasFixture('playlist'))('the captured page has a title, a count and videos', () => {
    const raw = fixture('playlist');
    const header = parsePlaylistHeader(raw);
    expect(header.title).toBeTruthy();
    expect(header.videoCount).toBeGreaterThan(0);

    const videos = parseFeed(raw, 'playlist').items.filter((item) => item.kind === 'video');
    expect(videos.length).toBeGreaterThan(0);
    // A page never holds more than the playlist does — and when it holds
    // fewer, it has to say where the rest is. This fixture is what caught the
    // token being read from the wrong path: 100 of 250, and no continuation.
    expect(videos.length).toBeLessThanOrEqual(header.videoCount!);
    if (header.videoCount! > 100) {
      expect(parseFeed(raw, 'playlist').continuation).toBeTruthy();
    }
  });

  // The tint was read from a path no response has, so every header was grey
  // with an all-green suite: nothing asserted that a captured page has one.
  for (const name of ['playlist', 'playlist-public-anon', 'playlist-wl']) {
    test.if(hasFixture(name))(`the captured ${name} header has its tint, opaque`, () => {
      const tint = parsePlaylistHeader(fixture(name)).header?.backgroundColor;
      expect(tint).toBeTruthy();
      for (const argb of [tint!.light, tint!.dark]) {
        expect(argb >>> 24).toBe(0xff);
      }
    });
  }

  // A playlist row ships "622K" beside a play icon and keeps the unit in its
  // accessibility label, so its tiles read "56M • 4y ago" until it is put back.
  for (const name of ['playlist', 'playlist-public-anon', 'playlist-wl', 'playlist-public-owned', 'playlist-private-owned']) {
    test.if(hasFixture(name))(`every captured ${name} row's view count says what it counts`, () => {
      const videos = parseFeed(fixture(name), 'playlist').items.filter((item) => item.kind === 'video');
      const counted = videos.filter((video) => video.viewCountText !== null);
      expect(counted.length).toBeGreaterThan(0);
      for (const video of counted) {
        expect(video.viewCountText).toMatch(/^\S+ views?$/);
      }
    });
  }

  test('a bare count takes its unit from the accessibility label, singular included', () => {
    const lockup = (id: string, parts: unknown[]) => ({
      lockupViewModel: {
        contentId: id,
        contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
        metadata: {
          lockupMetadataViewModel: {
            title: { content: `Video ${id}` },
            metadata: {
              contentMetadataViewModel: {
                metadataRows: [{ metadataParts: [{ text: { content: 'Owner' } }] }, { metadataParts: parts }],
              },
            },
          },
        },
      },
    });
    const part = (content: string, accessibilityLabel?: string) => ({ text: { content }, accessibilityLabel });
    const views = (parts: unknown[]) => {
      const [item] = parseFeed(lockup('a', parts) as Json, 'playlist').items;
      return item?.kind === 'video' ? item.viewCountText : undefined;
    };

    expect(views([part('622K', '622 thousand views'), part('5y ago', '5 years ago')])).toBe('622K views');
    // Too small for a magnitude: only the label says this number is a count.
    expect(views([part('532', '532 views'), part('5y ago', '5 years ago')])).toBe('532 views');
    expect(views([part('1', '1 view')])).toBe('1 view');
    // Already worded, as on every other surface: left alone, not doubled.
    expect(views([part('22K views', '22 thousand views')])).toBe('22K views');
    expect(views([part('5y ago', '5 years ago')])).toBeNull();
  });

  // The classic row an owned playlist and Watch Later ship: one `videoInfo`
  // line, no label. Unread, those tiles had no view count and no date.
  test('a classic row reads its count and date from videoInfo', async () => {
    const info = (...texts: string[]) => ({ videoInfo: { runs: texts.map((text) => ({ text })) } });
    const { session } = sessionOf([
      page([
        row('a', 'A', info('84K', ' • ', '3d ago')),
        row('b', 'B', info('1', ' • ', '2y ago')),
        row('c', 'C', info('532', ' • ', '1mo ago')),
        row('d', 'D'),
      ]),
    ]);
    const { items } = await getPlaylist(session, { playlistId: 'PLabc', continuation: null });
    expect(items.map((item) => [item.viewCountText, item.publishedText])).toEqual([
      ['84K views', '3d ago'],
      ['1 view', '2y ago'],
      ['532 views', '1mo ago'],
      [null, null],
    ]);
  });

  test('a header with no cinematic container has no tint, and is still a header', () => {
    const { header } = parsePlaylistHeader({ metadata: { playlistMetadataRenderer: { title: 'Plain' } } });
    expect(header).not.toBeNull();
    expect(header!.backgroundColor).toBeNull();
  });
});

describe('a playlist tile counts its videos from the thumbnail badge', () => {
  const countOf = (raw: unknown): number | null => {
    const item = parseFeed(raw, 'search').items[0];
    if (item?.kind !== 'playlist') throw new Error(`expected a playlist, got ${item?.kind}`);
    return item.videoCount;
  };

  test('digits in the owner name and the previewed titles are not the count', () => {
    const raw = playlistLockup({
      id: 'PL9GRDHnLR6e0rRAR1PCuuALd2Uun7O_rj',
      badge: '134 videos',
      rows: [['8Click', 'Playlist'], ['Usseewa · 3:27'], ['ＡＵＴＵＭＮ - [1 HOUR] · 1:00:02']],
    });
    expect(countOf(raw)).toBe(134);
  });

  test('no badge is no count, never a guess from the rows', () => {
    const raw = playlistLockup({ id: 'PL9GRDHnLR6e0rRAR1PCuuALd2Uun7O_rj', badge: null, rows: [['the bootleg boy 2']] });
    expect(countOf(raw)).toBeNull();
  });

  test.if(hasFixture('search-playlists'))('every captured playlist tile has a plausible count', () => {
    const playlists = parseFeed(fixture('search-playlists'), 'search').items.filter((item) => item.kind === 'playlist');
    expect(playlists.length).toBeGreaterThan(0);
    for (const playlist of playlists) {
      expect(playlist.videoCount).not.toBeNull();
      // YouTube caps a playlist at 5,000 videos.
      expect(playlist.videoCount!).toBeLessThanOrEqual(5000);
    }
  });
});
