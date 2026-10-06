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
import { getPlaylist, parsePlaylistHeader } from '../src/parser/playlist.ts';
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
      ? { alerts: [{ alertRenderer: { type: options.alert[0], text: { runs: [{ text: options.alert[1] }] } } }] }
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
    expect((failure as RpcError).code).toBe('UPSTREAM_ERROR');
    expect((failure as RpcError).message).toBe('The playlist does not exist.');
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
