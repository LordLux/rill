/**
 * The raw half of the viewer-state contract: the captures taken with the account
 * put in a *known* state (`src/capture-viewer-state.ts`), run through the real
 * parsers.
 *
 * Why this file exists is in that script's header. In short: every other fixture
 * was captured with the account in whatever state it happened to be in, so a
 * parser that reported the wrong state — or the same state always — passed. These
 * fixtures cannot be passed by a parser that gets the state wrong, because the
 * capture script proves the state from the raw response before it writes them.
 *
 * `fixtures/` is gitignored, so on a clean checkout these skip; the committed,
 * sanitised copies are asserted in `corpus.test.ts`, which always runs. What this
 * file adds over that one is the *raw* parse — real ids, the real remove token —
 * and a cross-check against the manifest the capture wrote.
 */
import { describe, expect, test } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parsePlaylistMembership } from '../src/actions/playlist.ts';
import { parseComments } from '../src/parser/comments.ts';
import { parseVideoDetail } from '../src/parser/video.ts';

const DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures', 'viewer-state');
const has = (name: string) => existsSync(join(DIR, name));
const load = (name: string): unknown => JSON.parse(readFileSync(join(DIR, name), 'utf8'));

interface Manifest {
  video: string;
  channelId: string;
  commentId: string | null;
  phases: Record<string, { facts: Record<string, unknown> }>;
}
const manifest = (): Manifest => load('manifest.json') as Manifest;

describe('viewer state — the watch page', () => {
  test.if(has('watch-before.json'))('before: unrated, channel not subscribed', () => {
    const detail = parseVideoDetail(load('watch-before.json'), 'viewer-state');
    expect(detail.id).toBe(manifest().video);
    expect(detail.myRating).toBe('none');
    expect(detail.isSubscribed).toBe(false);
  });

  test.if(has('watch-after.json'))('after: liked, channel subscribed', () => {
    const detail = parseVideoDetail(load('watch-after.json'), 'viewer-state');
    expect(detail.id).toBe(manifest().video);
    expect(detail.myRating).toBe('like');
    expect(detail.isSubscribed).toBe(true);
    expect(detail.channelId).toBe(manifest().channelId);
  });

  test.if(has('watch-disliked.json'))('a disliked video reads as dislike', () => {
    expect(parseVideoDetail(load('watch-disliked.json'), 'viewer-state').myRating).toBe('dislike');
  });

  test.if(has('watch-before.json') && has('watch-after.json'))('the pair differs in the states and in nothing that identifies the video', () => {
    const before = parseVideoDetail(load('watch-before.json'), 'viewer-state');
    const after = parseVideoDetail(load('watch-after.json'), 'viewer-state');
    expect([before.id, before.channelId, before.title]).toEqual([after.id, after.channelId, after.title]);
    expect([before.myRating, before.isSubscribed]).not.toEqual([after.myRating, after.isSubscribed]);
  });
});

describe('viewer state — the save dialog', () => {
  test.if(has('membership-before.json'))('before: no playlist holds the video, and no row carries a removeToken', () => {
    const { playlists } = parsePlaylistMembership(load('membership-before.json'));
    expect(playlists.length).toBeGreaterThan(1);
    expect(playlists.filter((p) => p.containsVideo)).toEqual([]);
    expect(playlists.filter((p) => p.removeToken !== null)).toEqual([]);
    expect(playlists.some((p) => p.id === 'WL')).toBe(true);
  });

  test.if(has('membership-after.json'))('after: Watch Later holds it, and its removeToken removes exactly this video from it', () => {
    const { playlists } = parsePlaylistMembership(load('membership-after.json'));
    const holding = playlists.filter((p) => p.containsVideo);
    expect(holding.map((p) => p.id)).toEqual(['WL']);
    // The token is replayed verbatim by `action.removeFromPlaylist`, and this exact
    // shape was replayed against the real service on 2026-09-20 and removed the video.
    expect(JSON.parse(holding[0]!.removeToken!)).toEqual({
      playlistId: 'WL',
      actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: manifest().video }],
    });
    expect(playlists.filter((p) => !p.containsVideo).every((p) => p.removeToken === null)).toBe(true);
  });
});

describe("viewer state — a comment's like and heart", () => {
  const ownComment = (name: string) => {
    const id = manifest().commentId;
    return parseComments(load(name), 'viewer-state').items.find((c) => c.id === id);
  };

  test.if(has('comments-before.json') && has('manifest.json'))('before: the own comment is neither liked nor hearted', () => {
    const own = ownComment('comments-before.json');
    expect(own).toBeDefined();
    expect([own!.isLiked, own!.creatorHearted]).toEqual([false, false]);
    expect(own!.deleteParams).not.toBeNull();
  });

  test.if(has('comments-after.json') && has('manifest.json'))('after: the creator sees it liked and hearted', () => {
    const own = ownComment('comments-after.json');
    expect([own!.isLiked, own!.creatorHearted]).toEqual([true, true]);
  });

  test.if(has('comments-after-anonymous.json') && has('manifest.json'))(
    "after, anyone else: hearted (the heart is public), not liked (the like is the viewer's), and not deletable",
    () => {
      const own = ownComment('comments-after-anonymous.json');
      expect([own!.isLiked, own!.creatorHearted]).toEqual([false, true]);
      expect(own!.deleteParams).toBeNull();
    },
  );

  test.if(has('manifest.json'))('the manifest records the raw facts each phase was verified against', () => {
    // The capture refuses to write unless these hold, so this is a check that the
    // manifest is the one the fixtures came from, not a second opinion.
    const { phases } = manifest();
    expect(phases['before']?.facts).toMatchObject({ likeStatus: 'INDIFFERENT', subscribed: false, watchLater: 'NONE' });
    expect(phases['after']?.facts).toMatchObject({ likeStatus: 'LIKE', subscribed: true, watchLater: 'ALL' });
  });
});
