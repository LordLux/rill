/**
 * Parser tests — offline, against real captured fixtures.
 *
 * No network. Every assertion runs against `fixtures/`, which holds raw
 * `parse: false` responses from a live session. Pinning the live feed is
 * impossible, so this corpus is the only place tolerant parsing can be tested
 * honestly.
 */

import { beforeEach, describe, expect, test } from 'bun:test';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseFeed, parsePlayer, parseVideoDetail } from '../src/parser/index.ts';
import { logger, resetUnknownRenderers, unknownRendererCounts } from '../src/log.ts';
import { countTiles } from '../src/innertube/session.ts';
import { isPublishedText, isViewCountText } from '../src/parser/text.ts';
import { walk, type JsonObject } from '../src/parser/tree.ts';
import { firstChannelOrderViolation } from '../src/parser/channel-order.ts';
import type { FeedItem } from '../src/types.ts';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(FIXTURES, `${name}.json`), 'utf8'));
}
function hasFixture(name: string): boolean {
  return existsSync(join(FIXTURES, `${name}.json`));
}

/**
 * Captures are gitignored, so a fresh clone has none and nothing here can run.
 * Reading them at module scope throws before any test is collected, which bun
 * reports as an unhandled error and a red suite on every clean checkout — a
 * missing capture is a missing precondition, not a failure.
 */
const HAS_CAPTURES = hasFixture('home') && hasFixture('history');

/** stderr, like everything else — hard invariant 3 applies to the suite too. */
const log = logger('parser-test');

if (!HAS_CAPTURES) {
  log.warn(
    '[parser] sidecar/fixtures/ is absent — skipping every parser test. ' +
      'These are the only tests that prove tolerant parsing against real renderer ' +
      'trees; with them skipped, a parser regression is a green suite. ' +
      'Run `bun run capture` (needs YT_COOKIE) to restore them.',
  );
}

const home = HAS_CAPTURES ? fixture('home') : null;
const history = HAS_CAPTURES ? fixture('history') : null;

/** Every feed-shaped fixture this capture produced, for corpus-wide invariants. */
const CORPUS: Record<string, unknown> = Object.fromEntries(
  ['home', 'home-continuation', 'subscriptions', 'channels', 'history', 'watch-later', 'search', 'search-artist', 'search-playlists', 'mix', 'playlist']
    .filter(hasFixture)
    .map((name) => [name, fixture(name)]),
);

// ---------------------------------------------------------------------------
// DTO shape validation
//
// The DTO is a contract with the Flutter side. `undefined` is the failure that
// matters: it survives JSON.stringify by vanishing, so a field that should be
// null arrives at Flutter as a missing key and blows up freezed's fromJson.
// ---------------------------------------------------------------------------

const SHAPES = {
  video: {
    id: 'string',
    title: 'string',
    channelName: 'string',
    channelId: 'string?',
    channelAvatarUrl: 'string?',
    thumbnailUrl: 'string',
    durationSeconds: 'number?',
    isLive: 'boolean',
    isStation: 'boolean',
    viewCountText: 'string?',
    publishedText: 'string?',
    descriptionSnippet: 'string?',
    badges: 'string[]',
    isShort: 'boolean',
    isMusic: 'boolean',
    isMembersOnly: 'boolean',
    isVerified: 'boolean',
    isArtistChannel: 'boolean',
    premiereAtMs: 'number?',
    canWatchLater: 'boolean',
    canAddToQueue: 'boolean',
  },
  mix: {
    id: 'string',
    title: 'string',
    subtitle: 'string?',
    thumbnailUrl: 'string',
    videoCount: 'number?',
    seedVideoId: 'string?',
    startParams: 'string?',
  },
  playlist: {
    id: 'string',
    title: 'string',
    thumbnailUrl: 'string',
    videoCount: 'number?',
    channelName: 'string?',
  },
  channel: {
    id: 'string',
    name: 'string',
    avatarUrl: 'string',
    subscriberText: 'string?',
    descriptionSnippet: 'string?',
    isVerified: 'boolean',
    isArtistChannel: 'boolean',
  },
} as const;

function validateItem(item: FeedItem): string[] {
  const problems: string[] = [];
  const shape = SHAPES[item.kind];
  if (!shape) return [`unknown kind '${(item as { kind: string }).kind}'`];

  const record = item as unknown as Record<string, unknown>;
  const expected = new Set(['kind', ...Object.keys(shape)]);

  for (const key of Object.keys(record)) {
    if (!expected.has(key)) problems.push(`${item.kind}.${key}: not in the DTO`);
  }

  for (const [key, spec] of Object.entries(shape)) {
    const value = record[key];
    if (value === undefined) {
      problems.push(`${item.kind}.${key}: undefined (must be a value or null)`);
      continue;
    }
    const optional = spec.endsWith('?');
    const base = optional ? spec.slice(0, -1) : spec;
    if (value === null) {
      if (!optional) problems.push(`${item.kind}.${key}: null but not nullable`);
      continue;
    }
    if (base === 'string[]') {
      if (!Array.isArray(value) || value.some((entry) => typeof entry !== 'string')) {
        problems.push(`${item.kind}.${key}: expected string[]`);
      }
      continue;
    }
    if (typeof value !== base) {
      problems.push(`${item.kind}.${key}: expected ${base}, got ${typeof value}`);
    }
  }
  return problems;
}

/**
 * Every fixture holding at least one node of `rendererKey`, as an isolated feed.
 *
 * Which generation lands in which feed is YouTube's choice on the day: this
 * capture served the home feed entirely as `lockupViewModel`, put `videoRenderer`
 * in search, and `playlistVideoRenderer` in watch-later. A test that assumes a
 * particular renderer lives in a particular fixture is testing the weather.
 */
function corpusIsolate(rendererKey: string): Array<{ name: string; feed: unknown }> {
  return Object.entries(CORPUS)
    .filter(([, raw]) => countKey(raw, rendererKey) > 0)
    .map(([name, raw]) => ({ name, feed: isolate(raw, rendererKey) }));
}

/** Collect every `{ key: … }` wrapper of one renderer type into a standalone feed. */
function isolate(raw: unknown, rendererKey: string): unknown {
  const nodes: unknown[] = [];
  walk(raw, (node: JsonObject) => {
    if (Object.hasOwn(node, rendererKey)) nodes.push({ [rendererKey]: node[rendererKey] });
    return true;
  });
  return { contents: nodes };
}

/** How many times a renderer key appears anywhere in the raw tree. */
function countKey(raw: unknown, rendererKey: string): number {
  let count = 0;
  walk(raw, (node: JsonObject) => {
    if (Object.hasOwn(node, rendererKey)) count += 1;
    return true;
  });
  return count;
}

/**
 * An ad tile wearing a real renderer's name.
 *
 * An in-feed ad nests a genuine `lockupViewModel` inside `adSlotRenderer`, and
 * the parser prunes that whole subtree — so in a real feed the mapper never sees
 * one. `isolate` lifts every lockup out of its wrapper, ad shells included, and
 * those carry `feedAdMetadataViewModel` where a real tile carries
 * `lockupMetadataViewModel`: no title, correctly dropped.
 *
 * Counting them as expected output would assert that ads must ship. This
 * capture is the first to put in-feed ads in the home fixture; the previous one
 * had none, which is why the distinction had not come up.
 */
function isAdShell(payload: unknown): boolean {
  if (!payload || typeof payload !== 'object') return false;
  const metadata = (payload as JsonObject)['metadata'];
  return Boolean(metadata && typeof metadata === 'object' && 'feedAdMetadataViewModel' in metadata);
}

/** Nodes of `rendererKey` the parser is expected to emit an item for. */
function countMappable(raw: unknown, rendererKey: string): number {
  let count = 0;
  walk(raw, (node: JsonObject) => {
    if (Object.hasOwn(node, rendererKey) && !isAdShell(node[rendererKey])) count += 1;
    return true;
  });
  return count;
}

function idsOf(raw: unknown, rendererKey: string, idKey: string): Set<string> {
  const ids = new Set<string>();
  walk(raw, (node: JsonObject) => {
    const payload = node[rendererKey];
    if (payload && typeof payload === 'object') {
      const value = (payload as Record<string, unknown>)[idKey];
      if (typeof value === 'string') ids.add(value);
    }
    return true;
  });
  return ids;
}

beforeEach(() => {
  resetUnknownRenderers();
});

// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('parseFeed — home', () => {
  test('yields items and chips', () => {
    const result = parseFeed(home, 'home');
    expect(result.items.length).toBeGreaterThan(0);
    expect(result.chips.length).toBeGreaterThan(0);
  });

  test('extracts a continuation token from continuationItemRenderer', () => {
    const { continuation } = parseFeed(home, 'home');
    expect(continuation).toBeString();
    expect(continuation!.length).toBeGreaterThan(20);
  });

  test('chips carry a label, a replay handle and a selection state', () => {
    const { chips } = parseFeed(home, 'home');
    const selected = chips.filter((chip) => chip.selected);

    expect(selected).toHaveLength(1);
    // "All" is the default feed and carries no token — that is not a failure.
    expect(selected[0]!.label).toBeString();
    for (const chip of chips) {
      expect(chip.label.length).toBeGreaterThan(0);
      expect(chip.token).toBeString();
      expect(['feed', 'shelf']).toContain(chip.scope);
    }
    expect(chips.filter((chip) => chip.token.length > 20).length).toBeGreaterThan(0);
  });

  test('every emitted item validates against the DTO shape', () => {
    const { items } = parseFeed(home, 'home');
    const problems = items.flatMap(validateItem);
    expect(problems).toEqual([]);
  });

  test('no item survives JSON round-tripping with a lost field', () => {
    // The `undefined` failure mode is invisible until it crosses the wire.
    const { items } = parseFeed(home, 'home');
    for (const item of items) {
      expect(JSON.parse(JSON.stringify(item))).toEqual(item);
    }
  });

  test('the whole result is JSON-serialisable — no renderer fragments leak', () => {
    const result = parseFeed(home, 'home');
    const serialised = JSON.stringify(result);
    expect(serialised).not.toContain('Renderer');
    expect(serialised).not.toContain('ViewModel');
    expect(serialised).not.toContain('trackingParams');
  });
});

describe.if(HAS_CAPTURES)('parseFeed — history', () => {
  test('yields one item per watch entry, repeats included', () => {
    const { items } = parseFeed(history, 'history');

    expect(items.length).toBeGreaterThan(100);
    // A rewatched video is a real repeat entry; de-duplicating would lose it.
    expect(items.length).toBeGreaterThan(new Set(items.map((item) => item.id)).size);
    // Every entry comes from a tile, and no tile is emitted twice.
    expect(items.length).toBeLessThanOrEqual(
      countKey(history, 'lockupViewModel') + countKey(history, 'videoRenderer')
    );
  });

  test('shelf-scoped chips are collected with their browse params', () => {
    const { chips } = parseFeed(history, 'history');
    expect(chips.length).toBeGreaterThan(0);
    expect(chips.every((chip) => chip.scope === 'shelf')).toBe(true);
    expect(chips.filter((chip) => chip.token.length > 0).length).toBeGreaterThan(0);
  });

  test('every emitted item validates against the DTO shape', () => {
    const { items } = parseFeed(history, 'history');
    expect(items.flatMap(validateItem)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Both generations
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('renderer generations', () => {
  test('videoRenderer and lockupViewModel produce identical VideoItem shapes', () => {
    const classicSources = corpusIsolate('videoRenderer');
    const viewSources = corpusIsolate('lockupViewModel');

    // Both generations must be present somewhere in the corpus, or this test is
    // not testing what it claims to.
    expect(classicSources.length).toBeGreaterThan(0);
    expect(viewSources.length).toBeGreaterThan(0);

    const classic = parseFeed(classicSources[0]!.feed, 'classic').items;
    const viewBased = parseFeed(viewSources[0]!.feed, 'view-based').items;

    const classicVideo = classic.find((item) => item.kind === 'video');
    const viewVideo = viewBased.find((item) => item.kind === 'video');
    expect(classicVideo).toBeDefined();
    expect(viewVideo).toBeDefined();

    // Same keys, same order-independent shape — Flutter switches on `kind` alone.
    expect(Object.keys(classicVideo!).sort()).toEqual(Object.keys(viewVideo!).sort());
    expect(classic.flatMap(validateItem)).toEqual([]);
    expect(viewBased.flatMap(validateItem)).toEqual([]);
  });

  test('no tile of either generation is silently dropped', () => {
    for (const key of ['videoRenderer', 'playlistVideoRenderer', 'lockupViewModel'] as const) {
      for (const { name, feed } of corpusIsolate(key)) {
        const nodes = countMappable(feed, key);
        const { items } = parseFeed(feed, key);

        // Every node becomes an item. Fewer means tiles are going missing, which
        // is the failure this parser exists to prevent; more means double-walking.
        expect({ source: `${name}/${key}`, items: items.length }).toEqual({
          source: `${name}/${key}`,
          items: nodes,
        });
        expect(items.flatMap(validateItem)).toEqual([]);
      }
    }
  });

  test('both generations fill the fields that drive the tile', () => {
    // A fixture can legitimately hold only non-video tiles — this capture's
    // search results put videos in `videoRenderer` and left `lockupViewModel`
    // holding nothing but playlists and mixes. So the requirement is corpus-wide
    // per generation, not per fixture.
    for (const key of ['videoRenderer', 'playlistVideoRenderer', 'lockupViewModel'] as const) {
      const items = corpusIsolate(key).flatMap(({ feed }) => parseFeed(feed, key).items);
      const videos = items.filter((item) => item.kind === 'video');

      expect({ generation: key, hasVideos: videos.length > 0 }).toEqual({
        generation: key,
        hasVideos: true,
      });

      for (const item of videos) {
        expect(item.id.length).toBeGreaterThan(5);
        expect(item.title.length).toBeGreaterThan(0);
        expect(item.thumbnailUrl).toStartWith('http');
      }
      // Per-video fields vary, but a generation returning none of them across
      // the whole corpus means the badge or metadata path broke.
      expect({
        generation: key,
        duration: videos.some((item) => item.durationSeconds !== null),
        channel: videos.some((item) => item.channelName.length > 0),
      }).toEqual({ generation: key, duration: true, channel: true });
    }
  });

  test('non-video tiles map to their own kinds, not to videos', () => {
    // Search's lockups are playlists and mixes; getting these wrong would show
    // up in the UI as playlists that play a single video.
    const all = Object.entries(CORPUS).flatMap(([name, raw]) => parseFeed(raw, name).items);
    const kinds = new Set(all.map((item) => item.kind));

    expect(kinds.has('video')).toBe(true);
    expect(kinds.has('mix')).toBe(true);
    expect(kinds.has('playlist')).toBe(true);

    for (const item of all) {
      if (item.kind === 'mix') expect(item.id).toStartWith('RD');
      if (item.kind === 'playlist') expect(item.id).not.toStartWith('RD');
    }
  });

  test('a LIVE badge produces isLive with a null duration', () => {
    // Synthetic, because whether the corpus contains a live stream depends on
    // what was on the homepage the day it was captured.
    const raw = {
      contents: [
        {
          lockupViewModel: {
            contentId: 'liveliveliv',
            contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
            contentImage: {
              thumbnailViewModel: {
                image: { sources: [{ url: 'https://i.ytimg.com/vi/x/hq.jpg', width: 360 }] },
                overlays: [
                  {
                    thumbnailOverlayBadgeViewModel: {
                      thumbnailBadges: [
                        {
                          thumbnailBadgeViewModel: {
                            text: 'LIVE',
                            badgeStyle: 'THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE',
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            },
            metadata: {
              lockupMetadataViewModel: {
                title: { content: 'A live stream' },
                metadata: {
                  contentMetadataViewModel: {
                    metadataRows: [
                      { metadataParts: [{ text: { content: 'Some Channel' } }] },
                      { metadataParts: [{ text: { content: '1.2K watching' } }] },
                    ],
                  },
                },
              },
            },
          },
        },
      ],
    };

    const item = parseFeed(raw, 'synthetic').items[0]!;
    expect(item.kind).toBe('video');
    expect(item.kind === 'video' && item.isLive).toBe(true);
    expect(item.kind === 'video' && item.durationSeconds).toBeNull();
    // LIVE drives the flag; it is not also repeated as a display badge.
    expect(item.kind === 'video' && item.badges).toEqual([]);
    // An ordinary LIVE tile is not a station — isStation does not just mirror isLive.
    expect(item.kind === 'video' && item.isStation).toBe(false);
  });

  test('a STATION badge is treated as live too, and flagged distinctly (F22, 2026-09-11)', () => {
    // Same shape as the LIVE test above, with the label YouTube ships for a
    // 24/7 radio/music station instead. "78 watching" deliberately omits
    // "now" — the lockup mapper's own view-count fallback only fires on the
    // literal "watching now", so this isolates the label match rather than
    // riding along on that fallback.
    //
    // `badgeStyle` is deliberately `..._LIVE`, not a made-up "default" style —
    // that is the real shape, confirmed live 2026-09-11 against a search
    // result for `h4hy2Gn-FVE`. The first version of this test used an
    // invented style and passed against a real ordering bug: `consider`
    // checked the generic style-based LIVE match before the STATION label,
    // so every real station's `LIVE`-style badge was classified as ordinary
    // live and never reached the label — `isStation` silently stayed false in
    // production while this test, built on the wrong assumption, kept passing.
    const raw = {
      contents: [
        {
          lockupViewModel: {
            contentId: 'stationstat',
            contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
            contentImage: {
              thumbnailViewModel: {
                image: { sources: [{ url: 'https://i.ytimg.com/vi/x/hq.jpg', width: 360 }] },
                overlays: [
                  {
                    thumbnailOverlayBadgeViewModel: {
                      thumbnailBadges: [
                        {
                          thumbnailBadgeViewModel: {
                            text: 'STATION',
                            badgeStyle: 'THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE',
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            },
            metadata: {
              lockupMetadataViewModel: {
                title: { content: 'MV STATION' },
                metadata: {
                  contentMetadataViewModel: {
                    metadataRows: [
                      { metadataParts: [{ text: { content: 'DECO*27' } }] },
                      { metadataParts: [{ text: { content: '78 watching' } }] },
                    ],
                  },
                },
              },
            },
          },
        },
      ],
    };

    const item = parseFeed(raw, 'synthetic').items[0]!;
    expect(item.kind).toBe('video');
    // A station is live too — the duration/sort behaviour still applies.
    expect(item.kind === 'video' && item.isLive).toBe(true);
    expect(item.kind === 'video' && item.durationSeconds).toBeNull();
    // …but it is also flagged distinctly, so the UI can draw its own pill.
    expect(item.kind === 'video' && item.isStation).toBe(true);
    // STATION drives the flag; it is not also repeated as a display badge —
    // the same convention as LIVE and Shorts.
    expect(item.kind === 'video' && item.badges).toEqual([]);
  });

  test('any live tile in the corpus has a null duration', () => {
    // Whether one exists is up to the capture; the invariant holds either way.
    for (const [name, raw] of Object.entries(CORPUS)) {
      for (const item of parseFeed(raw, name).items) {
        if (item.kind === 'video' && item.isLive) expect(item.durationSeconds).toBeNull();
      }
    }
  });

  describe('subscriptions.channels ordering', () => {
    // The app's A–Z scrubber has no ordering of its own: it trusts the order
    // `FEchannels` arrives in. That is an undocumented dependency on a server
    // default with no request parameter behind it, so it gets asserted rather
    // than assumed.

    test('the rule itself catches a list that goes backwards', () => {
      const named = (...names: string[]): FeedItem[] =>
        names.map((name) => ({
          kind: 'channel',
          id: `UC${name}`,
          name,
          avatarUrl: '',
          subscriberText: null,
          descriptionSnippet: null,
          isVerified: false,
          isArtistChannel: false,
        }));

      expect(firstChannelOrderViolation(named('3Blue1Brown', 'Acme', 'Ada', 'Zed'))).toBeNull();
      expect(firstChannelOrderViolation(named('Acme', 'Zed', 'Beta'))).toEqual({
        index: 2,
        previousBucket: 'Z',
        bucket: 'B',
      });
      // Digits and symbols bucket to `#` and sort first, matching
      // `letterBucketOf` in the Flutter index.
      expect(firstChannelOrderViolation(named('Acme', '3Blue1Brown'))).toEqual({
        index: 1,
        previousBucket: 'A',
        bucket: '#',
      });
    });

    test('the captured first page really is non-decreasing by first character', () => {
      // Against the capture, not the corpus: `export-contract-corpus` replaces
      // every channel name with "Sanitised Channel <n>", which is ordered by
      // construction and would assert nothing at all.
      if (!hasFixture('channels')) return;
      const items = parseFeed(fixture('channels'), 'channels').items;
      expect(items.length).toBeGreaterThan(0);
      expect(firstChannelOrderViolation(items)).toBeNull();
    });
  });

  test('no flagged fact is also shipped as a badge label', () => {
    // The convention `BadgeScan` states: a fact with a DTO field of its own
    // does not also travel in `badges[]`. It used to be enforced by each
    // mapper filtering `"LIVE"` back out of the labels it had just been
    // handed, which is redundant and leaves a hole the size of the next
    // mapper someone writes. Asserting it here instead means the hole closes
    // for mappers that do not exist yet.
    const flagged = /^(live|live now|shorts)$/i;
    for (const [name, raw] of Object.entries(CORPUS)) {
      for (const item of parseFeed(raw, name).items) {
        if (item.kind !== 'video') continue;
        for (const badge of item.badges) {
          expect(`${name}:${badge}`).not.toMatch(flagged);
        }
      }
    }
  });

  test('continuation is read from ContinuationItem as well as continuationItemRenderer', () => {
    // The view-based/typed spelling, which a parsed tree would use.
    const token = 'x'.repeat(64);
    const parsedShape = {
      contents: [
        { type: 'ContinuationItem', continuationEndpoint: { continuationCommand: { token } } },
      ],
    };
    expect(parseFeed(parsedShape, 'synthetic').continuation).toBe(token);

    // And the raw spelling, on the same payload shape.
    const rawShape = {
      contents: [
        { continuationItemRenderer: { continuationEndpoint: { continuationCommand: { token } } } },
      ],
    };
    expect(parseFeed(rawShape, 'synthetic').continuation).toBe(token);
  });

  test('a continuation response envelope parses like a first page', () => {
    // Page 2 arrives under onResponseReceivedActions, not contents. Same tiles,
    // different wrapper — infinite scroll breaks silently if this path is missed.
    const tiles = (
      (home as JsonObject).contents as JsonObject
    );
    const page2 = {
      onResponseReceivedActions: [
        {
          appendContinuationItemsAction: {
            targetId: 'browse-feedFEwhat_to_watch',
            continuationItems: [tiles],
          },
        },
      ],
    };
    const result = parseFeed(page2, 'home-continuation');
    expect(result.items.length).toBeGreaterThan(0);
    expect(result.items.flatMap(validateItem)).toEqual([]);
    expect(result.continuation).toBeString();
  });

  test('a chip token is never mistaken for the feed continuation', () => {
    const { chips, continuation } = parseFeed(home, 'home');
    const chipTokens = new Set(chips.map((chip) => chip.token));
    expect(chipTokens.has(continuation!)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Mixes
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('mixes', () => {
  test('Mix tiles parse as kind:mix with an RD* id', () => {
    const mixes = parseFeed(home, 'home').items.filter((item) => item.kind === 'mix');
    expect(mixes.length).toBeGreaterThan(0);
    for (const mix of mixes) {
      expect(mix.id).toStartWith('RD');
      expect(mix.title.length).toBeGreaterThan(0);
      expect(mix.thumbnailUrl).toStartWith('http');
    }
  });

  test('a Mix is not emitted as a playlist', () => {
    const items = parseFeed(home, 'home').items;
    const playlists = items.filter((item) => item.kind === 'playlist');
    expect(playlists.some((item) => item.id.startsWith('RD'))).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Shorts
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('shorts', () => {
  test('are stripped from every feed', () => {
    // Across the whole corpus, not just `home`: which fixture carries a
    // Shorts shelf on a given capture is YouTube's choice on the day
    // (`corpusIsolate`'s own doc comment above), and this capture happened to
    // put it in `mix`/`search`/`search-artist`/`subscriptions` instead.
    let checked = 0;
    for (const [name, raw] of Object.entries(CORPUS)) {
      const shortsIds = idsOf(raw, 'shortsLockupViewModel', 'entityId');
      if (shortsIds.size === 0) continue;
      checked += shortsIds.size;

      const emitted = new Set(parseFeed(raw, name).items.map((item) => item.id));
      for (const entityId of shortsIds) {
        // entityId is `shorts-shelf-item-<videoId>`.
        const videoId = entityId.replace(/^shorts-shelf-item-/, '');
        expect(emitted.has(videoId)).toBe(false);
      }
    }
    expect(checked).toBeGreaterThan(0);
  });

  test('a Shorts shelf does not become an empty item', () => {
    const shelf = isolate(home, 'reelShelfRenderer');
    expect(parseFeed(shelf, 'shorts').items).toEqual([]);
  });

  // Task 21 §1: the *other* Shorts shape — an ordinary videoRenderer carrying
  // a SHORTS-styled duration overlay — is classified, not stripped. By id,
  // per the task's own mutation-check instruction: a hardcoded `false` would
  // pass a test that only checked "the field exists".
  // The fixture moves with the capture, because the Short does: in the Task 21
  // capture it was `search-artist.json`'s `T0oRfI3PYCU`; re-captured
  // 2026-09-14 that same video arrives inside a `gridShelfViewModel` of
  // `shortsLockupViewModel`s (stripped whole, correctly), and the corpus's only
  // SHORTS-styled `videoRenderer` is this watch-history entry. Checked against
  // the raw overlay (`"style":"SHORTS"`), not against this parser's output.
  test('a SHORTS-badged video is flagged isShort, and the badge is not duplicated', () => {
    const items = parseFeed(history, 'history').items;
    const short = items.find((item) => item.kind === 'video' && item.id === 'i7Cinf_GUto');
    expect(short?.kind).toBe('video');
    if (short?.kind !== 'video') return;
    expect(short.isShort).toBe(true);
    expect(short.badges).not.toContain('SHORTS');
  });

  test.skipIf(!hasFixture('search-artist'))('an ordinary video is not flagged isShort', () => {
    const raw = fixture('search-artist');
    const items = parseFeed(raw, 'search-artist').items;
    const ordinary = items.find((item) => item.kind === 'video' && item.id === 'MhViuFoLkbs');
    expect(ordinary?.kind).toBe('video');
    if (ordinary?.kind !== 'video') return;
    expect(ordinary.isShort).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Task 21 — music note, verified / artist channel badges
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('music note (per video)', () => {
  test('a video with a MUSIC-badged thumbnail is flagged isMusic, by id', () => {
    const items = parseFeed(history, 'history').items;
    const musicVideo = items.find((item) => item.kind === 'video' && item.id === '7i_nc5GGIsI');
    expect(musicVideo?.kind).toBe('video');
    if (musicVideo?.kind !== 'video') return;
    expect(musicVideo.isMusic).toBe(true);
  });

  // A classic tile carrying no badge of any kind in the raw response — see
  // the "flagged neither" test for why it is not a lockup.
  test('an ordinary video is not flagged isMusic', () => {
    const items = parseFeed(fixture('search'), 'search').items;
    const ordinary = items.find((item) => item.kind === 'video' && item.id === 'zW5wpJY1rgQ');
    expect(ordinary?.kind).toBe('video');
    if (ordinary?.kind !== 'video') return;
    expect(ordinary.isMusic).toBe(false);
  });
});

describe.if(HAS_CAPTURES)('verified / artist-channel badges', () => {
  // Search stopped carrying channel tiles at all in the 2026-09-14 capture (0
  // `channelRenderer`s in either search fixture), so this reads the
  // subscriptions list. Its raw badge is `BADGE_STYLE_TYPE_VERIFIED_ARTIST`
  // with no plain `BADGE_STYLE_TYPE_VERIFIED` beside it.
  test.skipIf(!hasFixture('channels'))('an official artist channel is flagged isArtistChannel, not isVerified', () => {
    const items = parseFeed(fixture('channels'), 'channels').items;
    const artist = items.find((item) => item.kind === 'channel' && item.id === 'UCUnHZYgNkPRP2lBIStjdrmA');
    expect(artist?.kind).toBe('channel');
    if (artist?.kind !== 'channel') return;
    expect(artist.isArtistChannel).toBe(true);
    expect(artist.isVerified).toBe(false);
  });

  test('a video from an official artist channel is flagged isArtistChannel', () => {
    const search = fixture('search');
    const items = parseFeed(search, 'search').items;
    const artistVideo = items.find((item) => item.kind === 'video' && item.id === 'rFZHOHl-L8A');
    expect(artistVideo?.kind).toBe('video');
    if (artistVideo?.kind !== 'video') return;
    expect(artistVideo.isArtistChannel).toBe(true);
    expect(artistVideo.isVerified).toBe(false);
  });

  test('a video from a plain verified channel is flagged isVerified, not isArtistChannel', () => {
    const search = fixture('search');
    const items = parseFeed(search, 'search').items;
    const verifiedVideo = items.find((item) => item.kind === 'video' && item.id === 'mG1aeD7odqk');
    expect(verifiedVideo?.kind).toBe('video');
    if (verifiedVideo?.kind !== 'video') return;
    expect(verifiedVideo.isVerified).toBe(true);
    expect(verifiedVideo.isArtistChannel).toBe(false);
  });

  // Deliberately a *classic* tile. A lockup would pass this for the wrong
  // reason: `scanOwnerBadges` reads only `metadataBadgeRenderer`, and a
  // lockup carries its tick as an `attachmentRuns` image on the channel name,
  // so no lockup is ever flagged verified (open defect, CLAUDE.md).
  test('an unbadged channel/video is flagged neither', () => {
    const items = parseFeed(fixture('search'), 'search').items;
    const ordinary = items.find((item) => item.kind === 'video' && item.id === 'zW5wpJY1rgQ');
    expect(ordinary?.kind).toBe('video');
    if (ordinary?.kind !== 'video') return;
    expect(ordinary.isVerified).toBe(false);
    expect(ordinary.isArtistChannel).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Task 21 §3 — the artist search panel
// ---------------------------------------------------------------------------

describe.if(hasFixture('search-artist'))('artist panel (officialCardViewModel)', () => {
  test('an artist-name search carries the panel, populated', () => {
    const raw = fixture('search-artist');
    const result = parseFeed(raw, 'search-artist');
    const panel = result.artistPanel;
    expect(panel).not.toBeNull();
    if (!panel) return;
    expect(panel.channelId).toMatch(/^UC[\w-]{20,}$/);
    expect(panel.name.length).toBeGreaterThan(0);
    expect(panel.avatarUrl).toMatch(/^https:\/\//);
    expect(typeof panel.isSubscribed).toBe('boolean');
  });

  test('an ordinary search carries no panel', () => {
    const search = fixture('search');
    expect(parseFeed(search, 'search').artistPanel).toBeNull();
  });

  // Task 23 — the panel's palette and its embedded shelf.

  test('the panel carries the colours YouTube ships, both themes, as ARGB ints', () => {
    const panel = parseFeed(fixture('search-artist'), 'search-artist').artistPanel;
    expect(panel).not.toBeNull();
    if (!panel) return;

    for (const themed of [panel.backgroundColor, panel.baseBackgroundColor]) {
      expect(themed).not.toBeNull();
      if (!themed) continue;
      // Opaque ARGB, both halves. A partial pair is rejected outright by
      // `themedColor`, so a non-null value here is always a complete one.
      for (const value of [themed.light, themed.dark]) {
        expect(Number.isInteger(value)).toBe(true);
        expect(value).toBeGreaterThan(0);
        expect(value >>> 24).toBe(0xff);
      }
    }

    // The card fill is the lighter of the two on dark — `baseBackgroundColor`
    // is the page wash behind it, and swapping them would tint the hero
    // almost black. Asserted as an ordering rather than as literals, which
    // would be asserting the weather (an artist can restyle their channel).
    const luminance = (argb: number) => {
      const r = (argb >> 16) & 0xff;
      const g = (argb >> 8) & 0xff;
      const b = argb & 0xff;
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    };
    expect(luminance(panel.backgroundColor!.dark)).toBeGreaterThan(
      luminance(panel.baseBackgroundColor!.dark),
    );
  });

  test('the backdrop is its own image, not the avatar', () => {
    // The header carries a `cinematicContainerViewModel` whose background is a
    // wide banner (measured 600x176) — a different picture from the square
    // avatar. Blurring the avatar instead, which is what the panel did before
    // this was extracted, renders artwork the artist never chose.
    const panel = parseFeed(fixture('search-artist'), 'search-artist').artistPanel;
    expect(panel).not.toBeNull();
    if (!panel) return;

    expect(panel.backdropUrl).toMatch(/^https:\/\//);
    expect(panel.backdropUrl).not.toBe(panel.avatarUrl);
  });

  test('the embedded shelf maps to flat DTOs, mix first', () => {
    const panel = parseFeed(fixture('search-artist'), 'search-artist').artistPanel;
    expect(panel).not.toBeNull();
    if (!panel) return;

    expect(panel.shelfItems.length).toBeGreaterThan(1);
    expect(panel.shelfItems.flatMap(validateItem)).toEqual([]);
    // The panel leads with the artist's radio mix, then their videos — the
    // order YouTube ships, preserved rather than re-sorted.
    expect(panel.shelfItems[0]!.kind).toBe('mix');
    expect(panel.shelfItems.slice(1).every((item) => item.kind === 'video')).toBe(true);
  });

  test('the shelf does not leak into the surrounding search results', () => {
    // The walker must map the panel whole and never descend into it: these
    // tiles are the panel's, and splicing them into `items[]` would show the
    // artist's top videos twice on one screen.
    const result = parseFeed(fixture('search-artist'), 'search-artist');
    const panel = result.artistPanel;
    expect(panel).not.toBeNull();
    if (!panel) return;

    const shelfMixIds = new Set(
      panel.shelfItems.filter((item) => item.kind === 'mix').map((item) => item.id),
    );
    // Videos legitimately recur — YouTube ranks the artist's own uploads into
    // the results below as well — but the shelf's *mix* exists only on the
    // panel, so it is the one id whose presence in `items[]` could only mean
    // the walker descended.
    expect(result.items.filter((item) => shelfMixIds.has(item.id))).toEqual([]);
  });

  test('a one-row lockup still yields its view count and date', () => {
    // Regression: the shelf packs channel/views/date into a single metadata
    // row where an ordinary lockup uses two. Scanning `rows.slice(1)` found
    // nothing there and dropped both fields silently — no throw, no log,
    // just every shelf tile missing its metadata line.
    const panel = parseFeed(fixture('search-artist'), 'search-artist').artistPanel;
    expect(panel).not.toBeNull();
    if (!panel) return;

    const videos = panel.shelfItems.filter((item) => item.kind === 'video');
    expect(videos.length).toBeGreaterThan(0);
    expect(videos.every((video) => video.viewCountText !== null)).toBe(true);
    expect(videos.every((video) => video.publishedText !== null)).toBe(true);
    expect(videos.every((video) => video.channelName.length > 0)).toBe(true);
    // The channel must not have been taken from a detail part - the exact
    // failure the old channelRow[0] would produce on a tile whose row 0
    // starts with the view count.
    expect(videos.every((video) => !isViewCountText(video.channelName))).toBe(true);
    expect(videos.every((video) => !isPublishedText(video.channelName))).toBe(true);
  });

  test('shelf videos inherit the panel avatar, and only the artist own ones', () => {
    // The shelf's lockups carry no avatar anywhere in their subtree (measured
    // — no `image` key, no avatar host in the whole node), so every tile drew
    // the placeholder person glyph. These are the artist's uploads on the
    // artist's own panel, so the panel avatar is the missing value.
    const panel = parseFeed(fixture('search-artist'), 'search-artist').artistPanel;
    expect(panel).not.toBeNull();
    if (!panel) return;
    expect(panel.avatarUrl).toMatch(/^https:\/\//);

    const videos = panel.shelfItems.filter((item) => item.kind === 'video');
    expect(videos.length).toBeGreaterThan(0);

    for (const video of videos) {
      if (video.channelId === panel.channelId) {
        expect(video.channelAvatarUrl).toBe(panel.avatarUrl);
      } else {
        // Never stamped onto someone else's upload — a guest video, or one
        // whose channel could not be extracted, keeps its honest null rather
        // than wearing the wrong face.
        expect(video.channelAvatarUrl).not.toBe(panel.avatarUrl);
      }
    }

    // The mix is not a video and has no such field to fill.
    expect(panel.shelfItems.filter((item) => item.kind === 'mix').length).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// Ads
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('ads', () => {
  test('in-feed ads are stripped, including the real lockup nested inside them', () => {
    const ads = isolate(home, 'adSlotRenderer');
    const result = parseFeed(ads, 'ads');
    expect(result.items).toEqual([]);
    // Stripping is deliberate, so it must not register as an unknown renderer.
    expect(unknownRendererCounts()).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Tolerance — the test that matters most
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('unknown renderers', () => {
  /** Splice a node into the middle of the home feed's item list. */
  function injectIntoItemList(raw: unknown, node: unknown): unknown {
    const clone = structuredClone(raw) as JsonObject;
    let injected = false;
    walk(clone, (candidate: JsonObject) => {
      if (injected) return false;
      const grid = candidate['richGridRenderer'];
      if (grid && typeof grid === 'object') {
        const contents = (grid as JsonObject)['contents'];
        if (Array.isArray(contents)) {
          contents.splice(Math.floor(contents.length / 2), 0, node);
          injected = true;
          return false;
        }
      }
      return true;
    });
    if (!injected) throw new Error('could not find richGridRenderer.contents to inject into');
    return clone;
  }

  test('an injected unknown renderer does not throw and does not drop siblings', () => {
    const baseline = parseFeed(home, 'home');
    resetUnknownRenderers();

    const withUnknown = injectIntoItemList(home, {
      quantumTileRenderer: {
        contentId: 'zzzzzzzzzzz',
        title: { content: 'A tile type that does not exist yet' },
        someFutureField: [1, 2, 3],
      },
    });

    const result = parseFeed(withUnknown, 'home');

    // Every surrounding item still ships, in the same order.
    expect(result.items).toEqual(baseline.items);
    expect(result.chips).toEqual(baseline.chips);
    expect(result.continuation).toBe(baseline.continuation);

    // And the surprise is reported, once, with a count. Asserted by type rather
    // than by total, so a fresh capture that happens to contain an unclassified
    // renderer does not fail this — that belongs in its own test.
    const injected = unknownRendererCounts().find(
      (entry) => entry.type === 'home:quantumTileRenderer',
    );
    expect(injected).toBeDefined();
    expect(injected!.count).toBe(1);
  });

  test('a repeated unknown renderer is counted, not re-announced', () => {
    let raw: unknown = home;
    for (let i = 0; i < 3; i += 1) {
      raw = injectIntoItemList(raw, { quantumTileRenderer: { contentId: `id${i}` } });
    }
    resetUnknownRenderers();

    parseFeed(raw, 'home');
    const injected = unknownRendererCounts().find(
      (entry) => entry.type === 'home:quantumTileRenderer',
    );
    expect(injected).toBeDefined();
    expect(injected!.count).toBe(3);
  });

  test('the checked-in corpus is fully classified', () => {
    // A tripwire, not a formality. The corpus only changes when someone runs
    // `bun run capture`, so this fails exactly when YouTube has shipped a
    // renderer we do not handle — which is the moment to look, not weeks later
    // when a screen is quietly missing tiles.
    //
    // To fix: classify the type in src/parser/vocabulary.ts. If it holds tiles
    // it is a `container`; if it is chrome it is `ignore`; if it is a new tile
    // shape it needs a mapper.
    for (const [name, raw] of Object.entries(CORPUS)) {
      resetUnknownRenderers();
      parseFeed(raw, name);
      expect(unknownRendererCounts()).toEqual([]);
    }
  });

  test('malformed nodes do not throw', () => {
    const hostile: unknown[] = [
      null,
      undefined,
      42,
      'a string',
      [],
      {},
      { contents: null },
      { contents: [null, undefined, 0, '', []] },
      { contents: [{ videoRenderer: null }, { lockupViewModel: 'not an object' }] },
      { contents: [{ lockupViewModel: { contentId: 'abc' } }] }, // id but no title
      { contents: [{ videoRenderer: { title: { runs: [] } } }] }, // title but no id
    ];
    for (const input of hostile) {
      expect(() => parseFeed(input, 'hostile')).not.toThrow();
      expect(parseFeed(input, 'hostile').items.flatMap(validateItem)).toEqual([]);
    }
  });

  test('a deeply nested unknown renderer does not stop the walk above it', () => {
    const raw = {
      contents: [
        { lockupViewModel: { contentId: 'aaaaaaaaaaa', contentType: 'LOCKUP_CONTENT_TYPE_VIDEO', metadata: { lockupMetadataViewModel: { title: { content: 'first' } } } } },
        { neverSeenBeforeRenderer: { nested: { alsoUnknownRenderer: {} } } },
        { lockupViewModel: { contentId: 'bbbbbbbbbbb', contentType: 'LOCKUP_CONTENT_TYPE_VIDEO', metadata: { lockupMetadataViewModel: { title: { content: 'second' } } } } },
      ],
    };
    const { items } = parseFeed(raw, 'nested');
    expect(items.map((item) => item.id)).toEqual(['aaaaaaaaaaa', 'bbbbbbbbbbb']);
    // The inner unknown is never reached — its parent was already skipped.
    expect(unknownRendererCounts().map((entry) => entry.type)).toEqual([
      'nested:neverSeenBeforeRenderer',
    ]);
  });
});

// ---------------------------------------------------------------------------
// Auth verification — hard invariant 5
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('countTiles', () => {
  test('counts tiles in a real home response', () => {
    expect(countTiles(home)).toBeGreaterThan(0);
  });

  test('a degraded session — HTTP 200, empty shell — counts zero', () => {
    const degraded = {
      responseContext: { visitorData: 'abc' },
      contents: {
        twoColumnBrowseResultsRenderer: {
          tabs: [{ tabRenderer: { content: { richGridRenderer: { contents: [] } } } }],
        },
      },
    };
    expect(countTiles(degraded)).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('parsePlayer', () => {
  test('maps adaptive formats without ever producing a signed URL', () => {
    const raw = {
      videoDetails: { videoId: 'aqz-KE-bpKQ', lengthSeconds: '634', isLive: false },
      playabilityStatus: { status: 'OK' },
      streamingData: {
        adaptiveFormats: [
          {
            itag: 315,
            url: 'https://r1.googlevideo.com/videoplayback?n=RAW',
            mimeType: 'video/webm; codecs="vp9"',
            bitrate: 1234,
            width: 3840,
            height: 2160,
            fps: 60,
            contentLength: '999',
          },
          {
            itag: 251,
            signatureCipher: 's=abc&sp=sig&url=https%3A%2F%2Fr1.googlevideo.com%2F',
            mimeType: 'audio/webm; codecs="opus"',
            audioQuality: 'AUDIO_QUALITY_MEDIUM',
            audioSampleRate: '48000',
          },
        ],
        formats: [{ itag: 18, url: 'https://r1.googlevideo.com/x', mimeType: 'video/mp4' }],
      },
      storyboards: {
        playerStoryboardSpecRenderer: {
          spec: 'https://i.ytimg.com/sb/ID/storyboard3_L$L/$N.jpg?sqp=X|48#27#100#10#10#0#default#rs$AA|80#45#100#5#5#1000#M$M#rs$BB',
        },
      },
    };

    const result = parsePlayer(raw);

    expect(result.videoId).toBe('aqz-KE-bpKQ');
    expect(result.durationSeconds).toBe(634);
    expect(result.sabrOnly).toBe(false);
    expect(result.formats).toHaveLength(3);

    const video = result.formats.find((format) => format.itag === 315)!;
    expect(video.height).toBe(2160);
    expect(video.codecs).toBe('vp9');
    expect(video.hasVideo).toBe(true);
    expect(video.isAdaptive).toBe(true);
    // The parser reports the raw URL and nothing more. A URL fit for mpv can
    // only come from the decipher path (hard invariant 2).
    expect(video.rawUrl).toContain('n=RAW');
    expect(Object.keys(video)).not.toContain('url');

    const audio = result.formats.find((format) => format.itag === 251)!;
    expect(audio.rawUrl).toBeNull();
    expect(audio.signatureCipher).toBeString();
    expect(audio.hasAudio).toBe(true);

    expect(result.storyboards).toHaveLength(2);
    expect(result.storyboards[0]!.templateUrl).toContain('storyboard3_L0');
    expect(result.storyboards[0]!.columns).toBe(10);
    expect(result.storyboards[1]!.intervalMs).toBe(1000);
  });

  test('detects the SABR-only case rather than emitting empty URLs', () => {
    const raw = {
      streamingData: {
        serverAbrStreamingUrl: 'https://r1.googlevideo.com/videoplayback/sabr',
        adaptiveFormats: [
          { itag: 315, mimeType: 'video/webm; codecs="vp9"', width: 3840, height: 2160 },
          { itag: 251, mimeType: 'audio/webm; codecs="opus"' },
        ],
      },
    };
    const result = parsePlayer(raw);
    expect(result.sabrOnly).toBe(true);
    expect(result.serverAbrStreamingUrl).toBeString();
    expect(result.formats.every((format) => format.rawUrl === null)).toBe(true);
  });

  test('an empty response yields an empty result rather than throwing', () => {
    for (const input of [null, {}, { streamingData: {} }, 'nonsense']) {
      expect(() => parsePlayer(input)).not.toThrow();
      expect(parsePlayer(input).formats).toEqual([]);
      expect(parsePlayer(input).sabrOnly).toBe(false);
    }
  });

  test.if(hasFixture('player-mweb'))('reads the captured MWEB player response', () => {
    const result = parsePlayer(fixture('player-mweb'));
    expect(result.playabilityStatus).toBeString();

    if (result.playabilityStatus !== 'OK') {
      // A `/player` payload missing `signatureTimestamp` comes back UNPLAYABLE
      // ("The page needs to be reloaded"), which reads like a broken video
      // rather than a broken request. Nothing to assert about formats, but the
      // parser must still surface the status rather than an empty shell.
      expect(result.formats).toEqual([]);
      return;
    }

    // F3/F4: MWEB still hands out plain adaptive URLs, up to 2160p.
    expect(result.formats.length).toBeGreaterThan(0);
    expect(result.sabrOnly).toBe(false);
    expect(result.formats.some((format) => (format.height ?? 0) >= 1080)).toBe(true);
    expect(result.storyboards.length).toBeGreaterThan(0);
    // Whatever else happens, the parser never emits a URL fit to play.
    for (const format of result.formats) {
      expect(Object.keys(format)).not.toContain('url');
    }
  });

  test.if(hasFixture('player-web'))('WEB player response is SABR-only (F3)', () => {
    const result = parsePlayer(fixture('player-web'));
    if (result.playabilityStatus !== 'OK') return;

    // F3: WEB no longer serves usable adaptive URLs. If this ever stops holding,
    // the Phase 2 trigger has moved and architecture.md needs re-checking.
    expect(result.sabrOnly).toBe(true);
    expect(result.serverAbrStreamingUrl).toBeString();

    const adaptive = result.formats.filter((format) => format.isAdaptive);
    expect(adaptive.length).toBeGreaterThan(0);
    expect(adaptive.every((f) => f.rawUrl === null && f.signatureCipher === null)).toBe(true);

    // …but itag 18 still carries a plain URL. That is ladder tier 5, the
    // always-works 360p fallback — and the reason `sabrOnly` is defined over
    // adaptive formats rather than over all of them.
    const progressive = result.formats.filter(
      (format) => !format.isAdaptive && format.rawUrl !== null,
    );
    expect(progressive.length).toBeGreaterThan(0);
    expect(progressive.some((format) => format.itag === 18)).toBe(true);
  });

  test('isLiveContent alone does not mean live — a finished broadcast keeps its duration', () => {
    // MUTATION: OR `isLiveContent === true` back into `isLive` and this fails.
    // Confirmed live 2026-09-11 on `0QnMv0bRyk0` (NTO — a "Live Session" that
    // ended June 2024): every client's `videoDetails.isLiveContent` is still
    // `true` a year and a half later — it is a permanent "this is/was live-form
    // content" tag, not a current-status flag — while `videoDetails.isLive` is
    // correctly absent and `liveBroadcastDetails.isLiveNow` is explicitly
    // `false`. Treating `isLiveContent` as sufficient nulled `durationSeconds`
    // for an ordinary 2442-second VOD, and downstream that null `durationMs`
    // plus the still-present `startTimestamp` (a real historical fact — the
    // broadcast really did start in June 2024) is exactly what the Flutter
    // live-scrubber gates on: a finished video computed a "live edge" from a
    // year-and-a-half-old start time and refused to seek backward.
    const raw = {
      videoDetails: {
        videoId: 'aqz-KE-bpKQ',
        lengthSeconds: '2442',
        isLiveContent: true,
        // isLive deliberately absent — that is the real shape.
      },
      playabilityStatus: { status: 'OK' },
      microformat: {
        playerMicroformatRenderer: {
          liveBroadcastDetails: {
            isLiveNow: false,
            startTimestamp: '2024-06-13T21:55:36+00:00',
            endTimestamp: '2024-06-13T22:44:48+00:00',
          },
        },
      },
      streamingData: { adaptiveFormats: [], formats: [] },
    };

    const result = parsePlayer(raw);
    expect(result.isLive).toBe(false);
    expect(result.durationSeconds).toBe(2442);
    // The start time is a historical fact and still ships — it is `isLive`
    // being wrong, not `startTimestamp` being present, that broke playback.
    expect(result.startTimestamp).toBe('2024-06-13T21:55:36+00:00');
  });

  test('liveBroadcastDetails.isLiveNow: true is still recognised as live', () => {
    const raw = {
      videoDetails: { videoId: 'aqz-KE-bpKQ', lengthSeconds: '0', isLiveContent: true },
      playabilityStatus: { status: 'OK' },
      microformat: {
        playerMicroformatRenderer: {
          liveBroadcastDetails: {
            isLiveNow: true,
            startTimestamp: '2026-09-11T12:00:00+00:00',
          },
        },
      },
      streamingData: { adaptiveFormats: [], formats: [] },
    };

    const result = parsePlayer(raw);
    expect(result.isLive).toBe(true);
    expect(result.durationSeconds).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Video detail
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('parseVideoDetail', () => {
  test('never throws on an unusable response', () => {
    for (const input of [null, {}, 'nonsense', { contents: {} }]) {
      expect(() => parseVideoDetail(input)).not.toThrow();
      expect(parseVideoDetail(input).related).toEqual([]);
    }
  });

  test('reads a watch response and flattens related tiles to the same DTOs', () => {
    const raw = {
      videoDetails: {
        videoId: 'aqz-KE-bpKQ',
        title: 'Big Buck Bunny',
        author: 'Blender',
        channelId: 'UCSMOQeBJ2RAnuFungnQOxLg',
        lengthSeconds: '634',
        shortDescription: 'A short film.',
        isLive: false,
      },
      contents: {
        twoColumnWatchNextResults: {
          secondaryResults: {
            secondaryResults: {
              results: [
                {
                  lockupViewModel: {
                    contentId: 'ccccccccccc',
                    contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
                    metadata: {
                      lockupMetadataViewModel: {
                        title: { content: 'Up next' },
                        metadata: {
                          contentMetadataViewModel: {
                            metadataRows: [
                              { metadataParts: [{ text: { content: 'Some Channel' } }] },
                              { metadataParts: [{ text: { content: '1.2M views' } }] },
                            ],
                          },
                        },
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

    const detail = parseVideoDetail(raw);
    expect(detail.id).toBe('aqz-KE-bpKQ');
    expect(detail.title).toBe('Big Buck Bunny');
    expect(detail.channelName).toBe('Blender');
    expect(detail.durationSeconds).toBe(634);
    expect(detail.related).toHaveLength(1);
    expect(detail.related[0]!.kind).toBe('video');
    expect(detail.related.flatMap(validateItem)).toEqual([]);
  });

  test.if(hasFixture('watch'))('parses the captured watch page', () => {
    const detail = parseVideoDetail(fixture('watch'));

    expect(detail.id).toMatch(/^[\w-]{11}$/);
    expect(detail.title.length).toBeGreaterThan(0);
    expect(detail.channelName.length).toBeGreaterThan(0);
    expect(detail.channelId).toMatch(/^UC/);
    expect(detail.channelAvatarUrl).toStartWith('http');
    expect(detail.subscriberText).toContain('subscriber');
    expect(detail.viewCountText).toContain('view');
    expect(detail.publishedText).toBeString();
    expect(detail.likeText).toBeString();
    expect(detail.description).toBeString();
    expect(typeof detail.isSubscribed).toBe('boolean');

    // A /next response carries no duration; it comes from /player. Null here is
    // the contract, not a parse failure.
    expect(detail.durationSeconds).toBeNull();

    expect(detail.related.length).toBeGreaterThan(0);
    expect(detail.related.flatMap(validateItem)).toEqual([]);
    expect(detail.relatedContinuation).toBeString();
  });

  test.if(hasFixture('mix'))('a Mix watch page reads like any other watch page', () => {
    const detail = parseVideoDetail(fixture('mix'));
    expect(detail.id).toMatch(/^[\w-]{11}$/);
    expect(detail.title.length).toBeGreaterThan(0);
    expect(detail.related.flatMap(validateItem)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Any other fixture the capture run produced
// ---------------------------------------------------------------------------

describe.if(HAS_CAPTURES)('captured corpus', () => {
  const optional = [
    'home-continuation',
    'subscriptions',
    'watch-later',
    'search',
    'playlist',
    'mix',
  ];

  for (const name of optional) {
    test.if(hasFixture(name))(`${name}: parses into valid DTOs`, () => {
      const result = parseFeed(fixture(name), name);
      expect(result.items.flatMap(validateItem)).toEqual([]);
      expect(result.items.length).toBeGreaterThan(0);
    });
  }

  test.if(hasFixture('mix'))('mix fixture yields an RD* playlist', () => {
    const result = parseFeed(fixture('mix'), 'mix');
    expect(result.items.length).toBeGreaterThan(0);
  });
});
