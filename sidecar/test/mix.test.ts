/**
 * `mix.start` and `mix.extend` — Task 26. Offline, against stub sessions and
 * the real corpus where one is present.
 *
 * The properties worth pinning here are all about the **anchor-and-diff**,
 * because that is the thing the RPC boundary exists to keep out of Dart:
 *
 *   - only the tail after the anchor ships, never the history before it
 *   - the two ways a mix ends are distinguishable, not both "empty items"
 *   - `isInfinite: true` — which every real mix claims, including the ones
 *     that demonstrably run out — never suppresses exhaustion
 *   - the panel is scoped, so the related rail cannot leak into the queue
 *
 * `parser/mix.ts`'s own reason for existing (the panel is a bare object the
 * renderer walker cannot see) is covered by the scoping test: a response whose
 * related rail holds tiles must still yield only the panel's.
 */

import { describe, expect, test } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { extendMix, startMix } from '../src/mix/service.ts';
import { parseMixPanel } from '../src/parser/mix.ts';
import { hasCode } from '../src/errors.ts';
import type { Session } from '../src/innertube/session.ts';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');

// ---------------------------------------------------------------------------
// Builders — the real shapes, measured 2026-09-12
// ---------------------------------------------------------------------------

function panelVideo(id: string, title = `Video ${id}`): Record<string, unknown> {
  return {
    playlistPanelVideoRenderer: {
      videoId: id,
      title: { simpleText: title },
      lengthText: { simpleText: '3:33' },
      longBylineText: { runs: [{ text: 'A Channel' }] },
      thumbnail: { thumbnails: [{ url: `https://i.ytimg.com/vi/${id}/hq.jpg`, width: 336 }] },
    },
  };
}

/**
 * A `/next` body with a mix panel.
 *
 * Note the shape: the panel is a **bare object** under `playlist.playlist`,
 * with no renderer wrapper — that is the whole reason `parser/mix.ts` reaches
 * it by path. A test that wrapped it in `playlistPanelRenderer` would be
 * testing a response YouTube no longer sends.
 */
function nextBody(options: {
  playlistId?: string | null;
  title?: string;
  ids: string[];
  currentIndex?: number;
  isInfinite?: boolean;
  /** Tiles in the related rail, which must never reach the queue. */
  relatedIds?: string[];
}): unknown {
  const { playlistId = 'RDseed0000001', title = 'My Mix', ids, currentIndex = 0 } = options;
  return {
    contents: {
      twoColumnWatchNextResults: {
        results: { results: { contents: [] } },
        secondaryResults: {
          secondaryResults: {
            results: (options.relatedIds ?? []).map((id) => ({
              compactVideoRenderer: {
                videoId: id,
                title: { simpleText: `Related ${id}` },
                longBylineText: { runs: [{ text: 'Someone Else' }] },
                thumbnail: { thumbnails: [{ url: `https://i.ytimg.com/vi/${id}/hq.jpg` }] },
              },
            })),
          },
        },
        playlist: {
          playlist: {
            ...(playlistId === null ? {} : { playlistId }),
            title,
            titleText: { simpleText: title },
            currentIndex,
            localCurrentIndex: currentIndex,
            // Every real mix claims this, including curated lists that run out
            // after ~51 items. Nothing may branch on it.
            isInfinite: options.isInfinite ?? true,
            ownerName: { simpleText: 'YouTube' },
            contents: ids.map((id) => panelVideo(id)),
          },
        },
      },
    },
  };
}

function stubBrowse(body: unknown): { deps: { browse: Session }; calls: Record<string, unknown>[] } {
  const calls: Record<string, unknown>[] = [];
  const browse = {
    hasCookie: true,
    visitorId: 'v'.repeat(558),
    innertube: {} as Session['innertube'],
    async execute(_endpoint: string, params: Record<string, unknown> = {}) {
      calls.push(params);
      return typeof body === 'function' ? (body as (p: unknown) => unknown)(params) : body;
    },
  } as unknown as Session;
  return { deps: { browse }, calls };
}

const ids = (n: number, offset = 0): string[] =>
  Array.from({ length: n }, (_, i) => `vid${String(i + offset).padStart(8, '0')}`);

// ---------------------------------------------------------------------------
// parseMixPanel
// ---------------------------------------------------------------------------

describe('parseMixPanel', () => {
  test('reads the bare panel object, not a renderer', () => {
    const panel = parseMixPanel(nextBody({ ids: ids(3), title: 'Mix - Something' }));
    expect(panel).not.toBeNull();
    expect(panel!.playlistId).toBe('RDseed0000001');
    expect(panel!.title).toBe('Mix - Something');
    expect(panel!.items).toHaveLength(3);
    expect(panel!.items[0]!.kind).toBe('video');
  });

  test('a watch page with no playlist context is null, not an error', () => {
    expect(parseMixPanel({ contents: { twoColumnWatchNextResults: { results: {} } } })).toBeNull();
  });

  test('a panel with no playlistId is ignored rather than shipped unusable', () => {
    expect(parseMixPanel(nextBody({ ids: ids(3), playlistId: null }))).toBeNull();
  });

  test('rows become the same flat DTOs the feed ships', () => {
    const panel = parseMixPanel(nextBody({ ids: ['abcdefghijk'] }))!;
    const item = panel.items[0]!;
    expect(item).toMatchObject({
      kind: 'video',
      id: 'abcdefghijk',
      channelName: 'A Channel',
      durationSeconds: 213,
      isLive: false,
    });
  });
});

// ---------------------------------------------------------------------------
// mix.start
// ---------------------------------------------------------------------------

describe('mix.start', () => {
  test('opens a mix and returns its window', async () => {
    const { deps, calls } = stubBrowse(nextBody({ ids: ids(25), title: 'My Mix' }));
    const result = await startMix(deps, { playlistId: 'RDseed0000001', videoId: 'vid00000000' });

    expect(result.playlistId).toBe('RDseed0000001');
    expect(result.title).toBe('My Mix');
    expect(result.items).toHaveLength(25);
    expect(calls[0]).toMatchObject({ playlistId: 'RDseed0000001', videoId: 'vid00000000' });
  });

  test('the seed videoId is optional and simply omitted when absent', async () => {
    const { deps, calls } = stubBrowse(nextBody({ ids: ids(24) }));
    await startMix(deps, { playlistId: 'RDseed0000001' });
    expect(calls[0]).toEqual({ playlistId: 'RDseed0000001' });
    expect(calls[0]).not.toHaveProperty('videoId');
  });

  test('never sends an `index` — the server ignores it and resolves from videoId', async () => {
    const { deps, calls } = stubBrowse(nextBody({ ids: ids(25) }));
    await startMix(deps, { playlistId: 'RDseed0000001', videoId: 'vid00000000' });
    expect(calls[0]).not.toHaveProperty('index');
    expect(calls[0]).not.toHaveProperty('playlistIndex');
  });

  test('a playlist id that opens no panel is BAD_REQUEST, not an empty mix', async () => {
    const { deps } = stubBrowse({ contents: { twoColumnWatchNextResults: {} } });
    const error = await startMix(deps, { playlistId: 'RDnope' }).catch((e: unknown) => e);
    expect(hasCode(error, 'BAD_REQUEST')).toBe(true);
  });

  test('the related rail never reaches the queue', async () => {
    // The panel is invisible to the renderer walker, so a whole-body parse
    // would return both. This is the regression guard for that.
    const { deps } = stubBrowse(
      nextBody({ ids: ids(3), relatedIds: ['rel00000001', 'rel00000002', 'rel00000003'] }),
    );
    const result = await startMix(deps, { playlistId: 'RDseed0000001' });
    expect(result.items).toHaveLength(3);
    expect(result.items.map((i) => i.id).some((id) => id.startsWith('rel'))).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// mix.extend — the anchor-and-diff
// ---------------------------------------------------------------------------

describe('mix.extend', () => {
  test('returns only the tail after the anchor', async () => {
    // A 50-item window with the anchor at 25 — the real steady state.
    const window = ids(50);
    const { deps } = stubBrowse(nextBody({ ids: window, currentIndex: 25 }));
    const result = await extendMix(deps, {
      playlistId: 'RDseed0000001',
      afterVideoId: window[25]!,
    });

    expect(result.exhausted).toBe(false);
    expect(result.items).toHaveLength(24);
    expect(result.items.map((i) => i.id)).toEqual(window.slice(26));
  });

  test('never returns the anchor itself, nor anything before it', async () => {
    // The mutation check that matters: a diff done on the wrong side of the
    // boundary, or an off-by-one in the slice, shows up here and nowhere else.
    // Returning the history would duplicate the client's whole queue.
    const window = ids(50);
    const anchor = window[25]!;
    const { deps } = stubBrowse(nextBody({ ids: window, currentIndex: 25 }));
    const result = await extendMix(deps, { playlistId: 'RDseed0000001', afterVideoId: anchor });

    const returned = result.items.map((i) => i.id);
    expect(returned).not.toContain(anchor);
    for (const earlier of window.slice(0, 26)) expect(returned).not.toContain(earlier);
  });

  test('anchors on the videoId, and sends no index', async () => {
    const window = ids(50);
    const { deps, calls } = stubBrowse(nextBody({ ids: window, currentIndex: 25 }));
    await extendMix(deps, { playlistId: 'RDseed0000001', afterVideoId: window[25]! });
    expect(calls[0]).toEqual({ playlistId: 'RDseed0000001', videoId: window[25] });
  });

  test('exhausted when the anchor is the last item — the empty tail', async () => {
    const window = ids(26);
    const { deps } = stubBrowse(nextBody({ ids: window, currentIndex: 25 }));
    const result = await extendMix(deps, {
      playlistId: 'RDseed0000001',
      afterVideoId: window[25]!,
    });
    expect(result).toEqual({ items: [], exhausted: true });
  });

  test('exhausted when the server re-seeds and drops the anchor', async () => {
    // Measured on a real auto radio after ~169 items: the response comes back
    // a perfectly healthy window that simply does not contain the anchor.
    // Distinct upstream behaviour from the empty tail, same answer to the client.
    const { deps } = stubBrowse(nextBody({ ids: ids(25, 900), currentIndex: 0 }));
    const result = await extendMix(deps, {
      playlistId: 'RDseed0000001',
      afterVideoId: 'gone00000001',
    });
    expect(result).toEqual({ items: [], exhausted: true });
  });

  test('`isInfinite: true` does not suppress exhaustion', async () => {
    // Every real mix claims this, curated ones that run out after 51 items
    // included. If anything ever branches on it, this fails.
    const window = ids(26);
    const { deps } = stubBrowse(
      nextBody({ ids: window, currentIndex: 25, isInfinite: true }),
    );
    const result = await extendMix(deps, {
      playlistId: 'RDseed0000001',
      afterVideoId: window[25]!,
    });
    expect(result.exhausted).toBe(true);
  });

  test('a response with no panel is exhausted, not a thrown error', async () => {
    // §4: a failed extension leaves the queue playable.
    const { deps } = stubBrowse({ contents: { twoColumnWatchNextResults: {} } });
    const result = await extendMix(deps, {
      playlistId: 'RDseed0000001',
      afterVideoId: 'anything123',
    });
    expect(result).toEqual({ items: [], exhausted: true });
  });

  test('a tapering tail still ships what it has', async () => {
    // The curated case: lookahead 24 → 2 → 0. The middle step must not be
    // mistaken for the end.
    const window = ids(28);
    const { deps } = stubBrowse(nextBody({ ids: window, currentIndex: 25 }));
    const result = await extendMix(deps, {
      playlistId: 'RDseed0000001',
      afterVideoId: window[25]!,
    });
    expect(result.items).toHaveLength(2);
    expect(result.exhausted).toBe(false);
  });

  test('an upstream failure is UPSTREAM_ERROR, not a silent empty extension', async () => {
    const browse = {
      hasCookie: true,
      visitorId: 'v',
      innertube: {} as Session['innertube'],
      execute: () => Promise.reject(new Error('socket hang up')),
    } as unknown as Session;
    const error = await extendMix(
      { browse },
      { playlistId: 'RDseed0000001', afterVideoId: 'anything123' },
    ).catch((e: unknown) => e);
    expect(hasCode(error, 'UPSTREAM_ERROR')).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Against the real corpus
// ---------------------------------------------------------------------------

describe('captured corpus', () => {
  const path = join(FIXTURES, 'mix.json');
  const present = existsSync(path);

  test.skipIf(!present)('the mix fixture parses into a panel of flat DTOs', () => {
    const panel = parseMixPanel(JSON.parse(readFileSync(path, 'utf8')));
    expect(panel).not.toBeNull();
    expect(panel!.playlistId).toMatch(/^RD/);
    expect(panel!.items.length).toBeGreaterThan(0);
    for (const item of panel!.items) {
      expect(item.id).toBeTruthy();
      expect(item.kind).toBe('video');
    }
  });
});
