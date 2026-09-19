/**
 * Watch-page methods — `video.info`, `video.related`, the two playlist actions,
 * and `playback.report`. Offline, against stub sessions and the real corpus.
 *
 * The one thing these cannot establish is that a report *lands*. That needs a
 * logged-in session and a look at youtube.com afterwards, and it is the check
 * the task brief calls the only proof. What is testable here is everything
 * around it: that the right client is asked, that a watch is one CPN rather than
 * a string of one-ping views, that the segment a report describes is never
 * negative, and that a malformed report is refused rather than sent into the
 * void — the stats endpoint answers 200 to nonsense.
 */

import { beforeEach, describe, expect, test } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  addToPlaylist,
  addToWatchLater,
  createPlaylist,
  deletePlaylist,
  parsePlaylistMembership,
  playlistsForVideo,
  removeFromPlaylist,
} from '../src/actions/playlist.ts';
import { deleteComment, postComment, replyToComment } from '../src/actions/comments.ts';
import { dislike, like, removeRating, subscribe, unsubscribe } from '../src/actions/interaction.ts';
import { hasCode, isRpcError, type RpcError } from '../src/errors.ts';
import { forgetPlayerResponse } from '../src/innertube/player-response.ts';
import { resetPlayerCache } from '../src/innertube/player.ts';
import type { PlayerClient, Session } from '../src/innertube/session.ts';
import { parseFeed } from '../src/parser/feed.ts';
import { reportPlayback } from '../src/playback/report.ts';
import { openPlayback } from '../src/playback/resolve.ts';
import {
  closePlaybackSession,
  generateCpn,
  getPlaybackSession,
  openPlaybackSession,
  resetPlaybackSessions,
} from '../src/playback/sessions.ts';
import { parseVideoDetail } from '../src/parser/video.ts';
import { getRelated, getVideoInfo } from '../src/video/info.ts';
import type { FeedItem } from '../src/types.ts';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(FIXTURES, `${name}.json`), 'utf8'));
}
function hasFixture(name: string): boolean {
  return existsSync(join(FIXTURES, `${name}.json`));
}

const VIDEO_ID = 'aqz-KE-bpKQ';

// ---------------------------------------------------------------------------
// Stub sessions
// ---------------------------------------------------------------------------

interface StatsCall {
  url: string;
  params: Record<string, unknown>;
}

interface Call {
  endpoint: string;
  params: Record<string, unknown>;
}

interface StubSession extends Session {
  /** Every `execute`, in order — the count that "one /player call" is about. */
  readonly calls: Call[];
  /** Every playback-tracking ping. */
  readonly stats: StatsCall[];
  /** Answers to swap in per endpoint; `/player` is keyed by client. */
  bodies: Record<string, unknown>;
  statsStatus: number;
}

/** The JS player youtubei.js would have fetched, with the transforms stubbed. */
const fakeJsPlayer = {
  player_id: 'testplayer',
  signature_timestamp: 20662,
  decipher(url?: string, cipher?: string): string {
    if (cipher) {
      const args = new URLSearchParams(cipher);
      const out = new URL(args.get('url')!);
      out.searchParams.set(args.get('sp') ?? 'signature', `sig(${args.get('s')})`);
      return out.toString();
    }
    return url!;
  },
};

function stubSession(bodies: Record<string, unknown>, hasCookie = true): StubSession {
  const calls: Call[] = [];
  const stats: StatsCall[] = [];

  const session: StubSession = {
    calls,
    stats,
    bodies,
    statsStatus: 204,
    hasCookie,
    visitorId: 'v'.repeat(558),
    innertube: {
      session: {
        player: fakeJsPlayer,
        context: { client: { visitorData: 'v'.repeat(558), clientName: 'WEB', clientVersion: '2.x' } },
      },
      actions: {
        stats: async (url: string, _client: unknown, params: Record<string, unknown>) => {
          stats.push({ url, params });
          return new Response(null, { status: session.statsStatus });
        },
      },
    } as unknown as Session['innertube'],
    async execute(endpoint, params = {}) {
      calls.push({ endpoint, params });
      const key = endpoint === '/player' ? `/player:${String(params['client'] ?? 'WEB')}` : endpoint;
      const body = session.bodies[key];
      if (body === undefined) throw new Error(`stub session has no response for ${key}`);
      return body;
    },
  };
  return session;
}

/** A `/player` body shaped like the real one, minus everything nothing reads. */
function rawPlayerBody(client: PlayerClient, options: { tracking?: boolean } = {}): unknown {
  return {
    playabilityStatus: { status: 'OK' },
    streamingData: {
      adaptiveFormats: [
        {
          itag: 315,
          mimeType: 'video/webm; codecs="vp9"',
          width: 3840,
          height: 2160,
          fps: 60,
          bitrate: 20_000_000,
          url: `https://r1.googlevideo.com/videoplayback?expire=1&itag=315&c=${client}`,
        },
        {
          itag: 251,
          mimeType: 'audio/webm; codecs="opus"',
          audioQuality: 'AUDIO_QUALITY_MEDIUM',
          audioChannels: 2,
          bitrate: 130_000,
          url: `https://r1.googlevideo.com/videoplayback?expire=1&itag=251&c=${client}`,
        },
      ],
      formats: [],
    },
    videoDetails: { videoId: VIDEO_ID, lengthSeconds: '634' },
    ...(options.tracking === false
      ? {}
      : {
          playbackTracking: {
            videostatsPlaybackUrl: {
              baseUrl: `https://s.youtube.com/api/stats/playback?docid=${VIDEO_ID}&ei=EI1&of=OF1`,
            },
            videostatsWatchtimeUrl: {
              baseUrl: `https://s.youtube.com/api/stats/watchtime?docid=${VIDEO_ID}&ei=EI1&of=OF1`,
            },
          },
        }),
  };
}

/** A `/next` body: enough of the watch page for `parseVideoDetail` to read. */
function rawNextBody(): unknown {
  return {
    contents: {
      twoColumnWatchNextResults: {
        results: {
          results: {
            contents: [
              {
                videoPrimaryInfoRenderer: {
                  title: { runs: [{ text: 'Big Buck Bunny' }] },
                  viewCount: {
                    videoViewCountRenderer: { viewCount: { simpleText: '31,000,000 views' } },
                  },
                  relativeDateText: { simpleText: '16 years ago' },
                },
              },
              {
                videoSecondaryInfoRenderer: {
                  attributedDescription: { content: 'A short film.' },
                  owner: {
                    videoOwnerRenderer: {
                      title: { runs: [{ text: 'Blender' }] },
                      subscriberCountText: { simpleText: '1.2M subscribers' },
                      navigationEndpoint: { browseEndpoint: { browseId: 'UCSMOQeBJ2RAnuFungnQOxLg' } },
                      thumbnail: { thumbnails: [{ url: 'https://yt3.ggpht.com/a.jpg', width: 88 }] },
                    },
                  },
                },
              },
            ],
          },
        },
        secondaryResults: {
          secondaryResults: {
            results: [
              {
                lockupViewModel: {
                  contentId: 'ccccccccccc',
                  contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
                  contentImage: {
                    thumbnailViewModel: {
                      image: { sources: [{ url: 'https://i.ytimg.com/vi/c/hq.jpg', width: 480 }] },
                      overlays: [
                        {
                          thumbnailOverlayBadgeViewModel: {
                            thumbnailBadges: [{ thumbnailBadgeViewModel: { text: '4:20' } }],
                          },
                        },
                      ],
                    },
                  },
                  metadata: {
                    lockupMetadataViewModel: {
                      title: { content: 'A related video' },
                      metadata: {
                        contentMetadataViewModel: {
                          metadataRows: [
                            { metadataParts: [{ text: { content: 'Some Channel' } }] },
                            {
                              metadataParts: [
                                { text: { content: '1.2M views' } },
                                { text: { content: '3 days ago' } },
                              ],
                            },
                          ],
                        },
                      },
                    },
                  },
                },
              },
              {
                continuationItemRenderer: {
                  continuationEndpoint: {
                    continuationCommand: { token: 'RELATED_CONTINUATION_TOKEN_0123456789' },
                  },
                },
              },
            ],
          },
        },
      },
    },
    // `/next` carries no duration — that is the whole reason video.info composes
    // a `/player` response. Deliberately absent, not forgotten.
  };
}

function videoDeps(overrides: { next?: unknown; androidVr?: unknown } = {}) {
  const browse = stubSession({ '/next': overrides.next ?? rawNextBody() });
  const resolve = stubSession(
    { '/player:VISIONOS': overrides.androidVr ?? rawPlayerBody('VISIONOS') },
    false,
  );
  return { browse, resolve };
}

beforeEach(() => {
  resetPlayerCache();
  forgetPlayerResponse();
  resetPlaybackSessions();
});

// ---------------------------------------------------------------------------
// video.info
// ---------------------------------------------------------------------------

describe('video.info', () => {
  test('composes /next with a /player response for the duration /next lacks', async () => {
    const deps = videoDeps();
    const detail = await getVideoInfo(deps, VIDEO_ID);

    expect(detail.id).toBe(VIDEO_ID);
    expect(detail.title).toBe('Big Buck Bunny');
    expect(detail.channelName).toBe('Blender');
    expect(detail.viewCountText).toBe('31,000,000 views');
    expect(detail.description).toBe('A short film.');

    // The composition, in one assertion: `/next` alone answers null here.
    expect(detail.durationSeconds).toBe(634);
  });

  test('and `video.info` + `playback.open` together cost exactly one /player call', async () => {
    const deps = videoDeps();

    // Concurrently, which is how the watch page issues them — the shared
    // response has to survive both the cache and the in-flight coalescing.
    const [detail, source] = await Promise.all([
      getVideoInfo(deps, VIDEO_ID),
      openPlayback({ session: deps.resolve, ytDlpPath: 'yt-dlp-does-not-exist' }, { videoId: VIDEO_ID }),
    ]);

    expect(detail.durationSeconds).toBe(634);
    expect(source.variants[0]!.height).toBe(2160);

    const playerCalls = deps.resolve.calls.filter((c) => c.endpoint === '/player');
    expect(playerCalls).toHaveLength(1);
    expect(playerCalls[0]!.params['client']).toBe('VISIONOS');

    // And the browse session was asked for `/next` and nothing else. A `/player`
    // here would be the second round trip this design exists to avoid.
    expect(deps.browse.calls.map((c) => c.endpoint)).toEqual(['/next']);
  });

  test('a /player that will not answer costs the duration, not the page', async () => {
    // Age-gated, region-locked, or an identity YouTube has stopped believing.
    // `playback.open` has a five-rung ladder and an error contract for that;
    // `video.info` losing one integer must not become a watch page that will
    // not render at all.
    const deps = videoDeps({ androidVr: undefined });
    deps.resolve.bodies = {};

    const detail = await getVideoInfo(deps, VIDEO_ID);
    expect(detail.title).toBe('Big Buck Bunny');
    expect(detail.durationSeconds).toBeNull();
  });

  test('falls back to the requested id when the layout hides it', async () => {
    const deps = videoDeps();
    const detail = await getVideoInfo(deps, VIDEO_ID);
    // The stub `/next` carries no videoDetails at all, so the id can only have
    // come from the parameter — which is what every follow-up call keys on.
    expect(detail.id).toBe(VIDEO_ID);
  });

  test('a live video keeps a null duration rather than borrowing one', async () => {
    const next = rawNextBody() as Record<string, unknown>;
    (next as { videoDetails?: unknown }).videoDetails = { videoId: VIDEO_ID, isLive: true };

    const deps = videoDeps({ next });
    const detail = await getVideoInfo(deps, VIDEO_ID);
    expect(detail.isLive).toBe(true);
    expect(detail.durationSeconds).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// video.related
// ---------------------------------------------------------------------------

describe('video.related', () => {
  test('returns the sidebar as ordinary FeedItems, with a continuation', async () => {
    const deps = videoDeps();
    const result = await getRelated(deps, { videoId: VIDEO_ID });

    expect(result.items).toHaveLength(1);
    expect(result.items[0]!.kind).toBe('video');
    expect(result.continuation).toBe('RELATED_CONTINUATION_TOKEN_0123456789');
    expect(deps.browse.calls[0]).toMatchObject({ endpoint: '/next', params: { videoId: VIDEO_ID } });
  });

  test('a continuation is sent as a continuation, not as a videoId', async () => {
    const deps = videoDeps();
    deps.browse.bodies['/next'] = { continuationContents: {} };

    await getRelated(deps, { videoId: VIDEO_ID, continuation: 'TOKEN_2' });
    expect(deps.browse.calls[0]!.params).toEqual({ continuation: 'TOKEN_2' });
    expect(deps.browse.calls[0]!.params['videoId']).toBeUndefined();
  });

  test.if(hasFixture('watch'))(
    'related tiles from the real corpus are the same DTOs the feed produces',
    async () => {
      const deps = videoDeps({ next: fixture('watch') });
      const related = await getRelated(deps, { videoId: VIDEO_ID });

      expect(related.items.length).toBeGreaterThan(0);

      // The contract, stated as the thing the watch page depends on: every
      // related tile is a kind `MediaTile` already knows how to draw, with the
      // fields it reads present and never `undefined`.
      const feedKinds = new Set(
        parseFeed(fixture('home'), 'home').items.map((item) => item.kind),
      );
      for (const item of related.items) {
        expect(feedKinds.has(item.kind)).toBe(true);
        for (const [key, value] of Object.entries(item as unknown as Record<string, unknown>)) {
          expect(value, `${item.kind}.${key} is undefined`).not.toBeUndefined();
        }
      }

      // Shorts are stripped here exactly as they are in a feed.
      expect(related.items.some((item) => (item as { id?: string }).id === '')).toBe(false);
    },
  );

  test.if(hasFixture('watch'))('and match what video.info returns for the same page', async () => {
    const deps = videoDeps({ next: fixture('watch') });
    const detail = await getVideoInfo(deps, VIDEO_ID);
    const related = await getRelated(videoDeps({ next: fixture('watch') }), { videoId: VIDEO_ID });

    const ids = (items: FeedItem[]) => items.map((item) => (item as { id?: string }).id ?? '');
    expect(ids(related.items)).toEqual(ids(detail.related));
  });
});

// ---------------------------------------------------------------------------
// The owner block
//
// Found by running the thing: a collaboration upload parsed to an empty channel
// name, no avatar, and — the part that matters — a channel id belonging to the
// first *collaborator*, taken out of the dialog behind the byline. Nothing threw
// and no field was empty, so only a live run could have shown it.
//
// The payloads below are trimmed from the real `/next` for G78AnHpIw5w
// (collaboration) and aqz-KE-bpKQ (single owner), captured 2026-08-07.
// ---------------------------------------------------------------------------

const COLLABORATOR_ID = 'UCz7mxur_emoA8fl9kvizgtA';

/** A collaboration owner: attributed byline, avatar stack, dialog endpoint. */
function collaborationOwner(): unknown {
  return {
    contents: {
      twoColumnWatchNextResults: {
        results: {
          results: {
            contents: [
              {
                videoSecondaryInfoRenderer: {
                  owner: {
                    videoOwnerRenderer: {
                      subscriptionButton: { type: 'FREE' },
                      // No `title`, no `thumbnail`, and the endpoint opens a
                      // dialog rather than a channel.
                      attributedTitle: {
                        content: 'jazziiRed and 3 more',
                        commandRuns: [
                          {
                            onTap: {
                              innertubeCommand: {
                                showDialogCommand: {
                                  panelLoadingStrategy: {
                                    inlineContent: {
                                      dialogViewModel: {
                                        customContent: {
                                          listViewModel: {
                                            listItems: [
                                              {
                                                listItemViewModel: {
                                                  title: {
                                                    content: 'jazziiRed',
                                                    commandRuns: [
                                                      {
                                                        onTap: {
                                                          innertubeCommand: {
                                                            browseEndpoint: {
                                                              browseId: COLLABORATOR_ID,
                                                            },
                                                          },
                                                        },
                                                      },
                                                    ],
                                                  },
                                                },
                                              },
                                            ],
                                          },
                                        },
                                      },
                                    },
                                  },
                                },
                              },
                            },
                          },
                        ],
                      },
                      navigationEndpoint: {
                        showDialogCommand: { panelLoadingStrategy: {} },
                      },
                      avatarStack: {
                        avatarStackViewModel: {
                          avatars: [
                            { avatarViewModel: { image: { sources: [{ url: 'https://yt3.ggpht.com/first=s88' }] } } },
                            { avatarViewModel: { image: { sources: [{ url: 'https://yt3.ggpht.com/second=s88' }] } } },
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
}

describe('parseVideoDetail — the owner block', () => {
  test('a collaboration upload reads its byline and its avatar', () => {
    const detail = parseVideoDetail(collaborationOwner(), 'collab');

    // What YouTube itself shows for a collaboration, rather than an empty line.
    expect(detail.channelName).toBe('jazziiRed and 3 more');
    expect(detail.channelAvatarUrl).toBe('https://yt3.ggpht.com/first=s88');
  });

  test('and answers null for the channel rather than naming a collaborator', () => {
    const detail = parseVideoDetail(collaborationOwner(), 'collab');

    // The whole point. A deep scan finds `COLLABORATOR_ID` inside the dialog and
    // returns it as the video's channel — no error, no empty field, just the
    // wrong channel for anything that later acts on it.
    expect(detail.channelId).toBeNull();
    expect(detail.channelId).not.toBe(COLLABORATOR_ID);
  });

  test('a single-owner page is unchanged', () => {
    const detail = parseVideoDetail(rawNextBody(), 'single');
    expect(detail.channelName).toBe('Blender');
    expect(detail.channelId).toBe('UCSMOQeBJ2RAnuFungnQOxLg');
    expect(detail.channelAvatarUrl).toBe('https://yt3.ggpht.com/a.jpg');
    expect(detail.subscriberText).toBe('1.2M subscribers');
  });

  test('an owner with no endpoint at all still falls back to a deep scan', () => {
    // The tolerance that rule 3 keeps: a layout that buries the link somewhere
    // new must not lose the channel just because it is not where it was.
    const detail = parseVideoDetail(
      {
        contents: {
          twoColumnWatchNextResults: {
            results: {
              results: {
                contents: [
                  {
                    videoSecondaryInfoRenderer: {
                      owner: {
                        videoOwnerRenderer: {
                          title: { runs: [{ text: 'Somewhere New' }] },
                          somethingUnseen: {
                            browseEndpoint: { browseId: 'UCSMOQeBJ2RAnuFungnQOxLg' },
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
      },
      'unseen',
    );

    expect(detail.channelName).toBe('Somewhere New');
    expect(detail.channelId).toBe('UCSMOQeBJ2RAnuFungnQOxLg');
  });

  test('a verified channel sets isVerified on the VideoDetail', () => {
    const body = {
      contents: {
        twoColumnWatchNextResults: {
          results: {
            results: {
              contents: [
                {
                  videoSecondaryInfoRenderer: {
                    owner: {
                      videoOwnerRenderer: {
                        title: { runs: [{ text: 'Verified Channel' }] },
                        navigationEndpoint: { browseEndpoint: { browseId: 'UCSMOQeBJ2RAnuFungnQOxLg' } },
                        ownerBadges: [
                          {
                            metadataBadgeRenderer: {
                              style: 'BADGE_STYLE_TYPE_VERIFIED',
                              tooltip: 'Verified',
                            },
                          },
                        ],
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
    const detail = parseVideoDetail(body, 'verified');
    expect(detail.isVerified).toBe(true);
    expect(detail.isArtistChannel).toBe(false);
  });

  test('an official artist channel sets isArtistChannel and not isVerified', () => {
    const body = {
      contents: {
        twoColumnWatchNextResults: {
          results: {
            results: {
              contents: [
                {
                  videoSecondaryInfoRenderer: {
                    owner: {
                      videoOwnerRenderer: {
                        title: { runs: [{ text: 'Artist Channel' }] },
                        navigationEndpoint: { browseEndpoint: { browseId: 'UCSMOQeBJ2RAnuFungnQOxLg' } },
                        ownerBadges: [
                          {
                            metadataBadgeRenderer: {
                              style: 'BADGE_STYLE_TYPE_VERIFIED_ARTIST',
                              tooltip: 'Official Artist Channel',
                            },
                          },
                        ],
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
    const detail = parseVideoDetail(body, 'artist');
    expect(detail.isArtistChannel).toBe(true);
    expect(detail.isVerified).toBe(false);
  });

  test('no ownerBadges yields false for both flags', () => {
    // Mutation guard: a hardcoded false would also pass the positive tests above
    // only if someone added the right badge — this confirms the default path.
    const detail = parseVideoDetail(rawNextBody(), 'no-badge');
    expect(detail.isVerified).toBe(false);
    expect(detail.isArtistChannel).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Playlist actions
// ---------------------------------------------------------------------------

describe('action.addToWatchLater / addToPlaylist', () => {
  test('Watch Later is the playlist WL, edited like any other', async () => {
    const session = stubSession({ '/browse/edit_playlist': { status: 'STATUS_SUCCEEDED' } });
    await addToWatchLater(session, VIDEO_ID);

    expect(session.calls[0]).toEqual({
      endpoint: '/browse/edit_playlist',
      params: {
        playlistId: 'WL',
        actions: [{ action: 'ACTION_ADD_VIDEO', addedVideoId: VIDEO_ID }],
      },
    });
  });

  test('an arbitrary playlist takes the same path', async () => {
    const session = stubSession({ '/browse/edit_playlist': { status: 'STATUS_SUCCEEDED' } });
    await addToPlaylist(session, VIDEO_ID, 'PL_SOMETHING');
    expect(session.calls[0]!.params['playlistId']).toBe('PL_SOMETHING');
  });

  test('no cookie is AUTH_REQUIRED, and never leaves the process', async () => {
    const session = stubSession({ '/browse/edit_playlist': { status: 'STATUS_SUCCEEDED' } }, false);
    const failure = await addToWatchLater(session, VIDEO_ID).catch((e: unknown) => e);

    expect(hasCode(failure, 'AUTH_REQUIRED')).toBe(true);
    expect((failure as RpcError).retry).toBe('no');
    // The point: a write that cannot succeed does not spend a round trip, and
    // does not come back as an `auto` the app would retry four times.
    expect(session.calls).toHaveLength(0);
  });

  test('HTTP 200 with STATUS_FAILED is a failure, not a success', async () => {
    // The F7 shape: an operation that answers fine and did nothing.
    const session = stubSession({ '/browse/edit_playlist': { status: 'STATUS_FAILED' } });
    const failure = await addToWatchLater(session, VIDEO_ID).catch((e: unknown) => e);
    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// action.like / dislike / removeRating, action.subscribe / unsubscribe
// ---------------------------------------------------------------------------

describe('action.like / dislike / removeRating', () => {
  test('like posts to /like/like with target as {videoId}, not a bare string', async () => {
    // A bare-string target answered a real HTTP 400 (2026-09-11) — the
    // library's own declared type for this request is `{ target: { videoId } }`,
    // and this is the regression test for going back to the wrong shape.
    const session = stubSession({ '/like/like': { status: 'STATUS_SUCCEEDED' } });
    await like(session, VIDEO_ID);
    expect(session.calls[0]).toEqual({
      endpoint: '/like/like',
      params: { target: { videoId: VIDEO_ID } },
    });
  });

  test('dislike posts to /like/dislike', async () => {
    const session = stubSession({ '/like/dislike': { status: 'STATUS_SUCCEEDED' } });
    await dislike(session, VIDEO_ID);
    expect(session.calls[0]!.endpoint).toBe('/like/dislike');
  });

  test('removeRating posts to /like/removelike — the un-like/un-dislike path', async () => {
    const session = stubSession({ '/like/removelike': { status: 'STATUS_SUCCEEDED' } });
    await removeRating(session, VIDEO_ID);
    expect(session.calls[0]!.endpoint).toBe('/like/removelike');
  });

  test('none of the three ever touch the TV client override', async () => {
    // The deliberate departure from youtubei.js's InteractionManager
    // (`actions/interaction.ts`'s own doc comment) — every call here goes over
    // whatever session it is handed, unmodified, and the stub session accepts
    // only endpoints it was given a body for, so a `client` override reaching
    // `execute`'s params would show up here.
    const session = stubSession({ '/like/like': { status: 'STATUS_SUCCEEDED' } });
    await like(session, VIDEO_ID);
    expect(session.calls[0]!.params['client']).toBeUndefined();
  });

  test('no cookie is AUTH_REQUIRED for all three, and never leaves the process', async () => {
    for (const [action, endpoint] of [
      [like, '/like/like'],
      [dislike, '/like/dislike'],
      [removeRating, '/like/removelike'],
    ] as const) {
      const session = stubSession({ [endpoint]: { status: 'STATUS_SUCCEEDED' } }, false);
      const failure = await action(session, VIDEO_ID).catch((e: unknown) => e);
      expect(hasCode(failure, 'AUTH_REQUIRED')).toBe(true);
      expect(session.calls).toHaveLength(0);
    }
  });

  test('STATUS_FAILED is a failure, not a success', async () => {
    const session = stubSession({ '/like/like': { status: 'STATUS_FAILED' } });
    const failure = await like(session, VIDEO_ID).catch((e: unknown) => e);
    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
  });
});

const CHANNEL_ID = 'UCSMOQeBJ2RAnuFungnQOxLg';

describe('action.subscribe / unsubscribe', () => {
  test('subscribe posts channelIds to /subscription/subscribe', async () => {
    const session = stubSession({ '/subscription/subscribe': { status: 'STATUS_SUCCEEDED' } });
    await subscribe(session, CHANNEL_ID);
    expect(session.calls[0]).toEqual({
      endpoint: '/subscription/subscribe',
      params: { channelIds: [CHANNEL_ID] },
    });
  });

  test('unsubscribe posts to /subscription/unsubscribe', async () => {
    const session = stubSession({ '/subscription/unsubscribe': { status: 'STATUS_SUCCEEDED' } });
    await unsubscribe(session, CHANNEL_ID);
    expect(session.calls[0]!.endpoint).toBe('/subscription/unsubscribe');
  });

  test('no cookie is AUTH_REQUIRED for both, and never leaves the process', async () => {
    for (const [action, endpoint] of [
      [subscribe, '/subscription/subscribe'],
      [unsubscribe, '/subscription/unsubscribe'],
    ] as const) {
      const session = stubSession({ [endpoint]: { status: 'STATUS_SUCCEEDED' } }, false);
      const failure = await action(session, CHANNEL_ID).catch((e: unknown) => e);
      expect(hasCode(failure, 'AUTH_REQUIRED')).toBe(true);
      expect(session.calls).toHaveLength(0);
    }
  });
});

// ---------------------------------------------------------------------------
// action.postComment / replyToComment / deleteComment
// ---------------------------------------------------------------------------

describe('action.postComment / replyToComment / deleteComment', () => {
  /**
   * A `/comment/create_comment` answer, trimmed to what was measured live on
   * 2026-09-18: `actionResult` at the top level, the new thread under
   * `actions[].createCommentAction`, its entities in `frameworkUpdates`, and —
   * for the author's own comment — a reply token and a Delete menu item on its
   * toolbar surface.
   */
  function createResponse(status = 'STATUS_SUCCEEDED', withThread = true): unknown {
    return {
      actionResult: { status },
      actions: [
        { runAttestationCommand: { ids: [], engagementType: 'ENGAGEMENT_TYPE_COMMENT_POST' } },
        ...(withThread
          ? [
              {
                createCommentAction: {
                  contents: {
                    commentThreadRenderer: {
                      commentViewModel: {
                        commentViewModel: { commentKey: 'new-key', toolbarSurfaceKey: 'new-surface' },
                      },
                    },
                  },
                },
              },
            ]
          : []),
      ],
      frameworkUpdates: {
        entityBatchUpdate: {
          mutations: [
            {
              payload: {
                commentEntityPayload: {
                  key: 'new-key',
                  properties: {
                    commentId: 'UgxNewComment',
                    content: { content: 'hello there' },
                    publishedTime: '0 seconds ago',
                    replyLevel: 0,
                  },
                  author: { displayName: '@me', avatarThumbnailUrl: 'https://example.com/me.jpg', channelId: 'UCme' },
                  toolbar: {},
                },
              },
            },
            {
              payload: {
                engagementToolbarSurfaceEntityPayload: {
                  key: 'new-surface',
                  replyCommand: {
                    innertubeCommand: {
                      createCommentReplyDialogEndpoint: {
                        dialog: {
                          commentReplyDialogRenderer: {
                            replyButton: {
                              buttonRenderer: {
                                serviceEndpoint: { createCommentReplyEndpoint: { createReplyParams: 'NEW_REPLY_TOKEN' } },
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                  menuCommand: {
                    innertubeCommand: {
                      menuEndpoint: {
                        menu: {
                          menuRenderer: {
                            items: [
                              {
                                menuNavigationItemRenderer: {
                                  text: { runs: [{ text: 'Delete' }] },
                                  navigationEndpoint: {
                                    confirmDialogEndpoint: {
                                      content: {
                                        confirmDialogRenderer: {
                                          confirmButton: {
                                            buttonRenderer: {
                                              serviceEndpoint: {
                                                performCommentActionEndpoint: { action: 'NEW_DELETE_TOKEN' },
                                              },
                                            },
                                          },
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
                  },
                },
              },
            },
          ],
        },
      },
    };
  }

  test('postComment sends createCommentParams and commentText to /comment/create_comment', async () => {
    const session = stubSession({ '/comment/create_comment': createResponse() });
    await postComment(session, 'CREATE_TOKEN', 'hello there');
    expect(session.calls).toEqual([
      {
        endpoint: '/comment/create_comment',
        params: { createCommentParams: 'CREATE_TOKEN', commentText: 'hello there' },
      },
    ]);
  });

  test('postComment answers the created comment — real id, and deletable and repliable at once', async () => {
    // The reason it answers a `Comment` rather than `{}`: a client that had to
    // invent a stand-in would have no id and no delete token for it until the
    // list was refetched.
    const session = stubSession({ '/comment/create_comment': createResponse() });
    const { comment } = await postComment(session, 'CREATE_TOKEN', 'hello there');
    expect(comment?.id).toBe('UgxNewComment');
    expect(comment?.text.content).toBe('hello there');
    expect(comment?.authorName).toBe('@me');
    expect(comment?.deleteParams).toBe('NEW_DELETE_TOKEN');
    expect(comment?.replyParams).toBe('NEW_REPLY_TOKEN');
  });

  test('a success that carries no thread is still a success, with no comment to show', async () => {
    const session = stubSession({ '/comment/create_comment': createResponse('STATUS_SUCCEEDED', false) });
    await expect(postComment(session, 'CREATE_TOKEN', 'hi')).resolves.toEqual({ comment: null });
  });

  test('STATUS_FAILED is a failure, not a success', async () => {
    const session = stubSession({ '/comment/create_comment': createResponse('STATUS_FAILED') });
    const failure = await postComment(session, 'CREATE_TOKEN', 'hi').catch((e: unknown) => e);
    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
  });

  test('replyToComment sends createReplyParams and commentText to /comment/create_comment_reply', async () => {
    const session = stubSession({ '/comment/create_comment_reply': { actionResult: { status: 'STATUS_SUCCEEDED' } } });
    await replyToComment(session, 'REPLY_TOKEN', 'a reply');
    expect(session.calls).toEqual([
      {
        endpoint: '/comment/create_comment_reply',
        params: { createReplyParams: 'REPLY_TOKEN', commentText: 'a reply' },
      },
    ]);
  });

  test('replyToComment refuses a STATUS_FAILED', async () => {
    const session = stubSession({ '/comment/create_comment_reply': { actionResult: { status: 'STATUS_FAILED' } } });
    const failure = await replyToComment(session, 'REPLY_TOKEN', 'a reply').catch((e: unknown) => e);
    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
  });

  test('deleteComment sends the action blob to /comment/perform_comment_action', async () => {
    const session = stubSession({
      '/comment/perform_comment_action': {
        actions: [{ removeCommentAction: { commentId: 'x', actionResult: { status: 'STATUS_SUCCEEDED' } } }],
      },
    });
    await deleteComment(session, 'DELETE_TOKEN');
    expect(session.calls).toEqual([
      { endpoint: '/comment/perform_comment_action', params: { action: 'DELETE_TOKEN' } },
    ]);
  });

  test("deleteComment reads its status from where a delete puts it, and refuses a failure", async () => {
    // Not `assertSucceeded`'s top-level `status`, and not `actionResult` at the
    // top level like a create: nested under `removeCommentAction`. A check on
    // either of the other two places would pass this response.
    const session = stubSession({
      '/comment/perform_comment_action': {
        actions: [{ removeCommentAction: { commentId: 'x', actionResult: { status: 'STATUS_FAILED' } } }],
      },
    });
    const failure = await deleteComment(session, 'DELETE_TOKEN').catch((e: unknown) => e);
    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
  });

  test('an upstream rejection is UPSTREAM_ERROR for all three', async () => {
    const session = stubSession({}); // the stub throws for any endpoint it has no answer for
    for (const run of [
      () => postComment(session, 'T', 'x'),
      () => replyToComment(session, 'T', 'x'),
      () => deleteComment(session, 'T'),
    ]) {
      const failure = await run().catch((e: unknown) => e);
      expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
    }
  });

  test('no cookie is AUTH_REQUIRED for all three, and never leaves the process', async () => {
    const session = stubSession({}, false);
    for (const run of [
      () => postComment(session, 'T', 'x'),
      () => replyToComment(session, 'T', 'x'),
      () => deleteComment(session, 'T'),
    ]) {
      const failure = await run().catch((e: unknown) => e);
      expect(hasCode(failure, 'AUTH_REQUIRED')).toBe(true);
    }
    expect(session.calls).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// playlist.forVideo, action.removeFromPlaylist, playlist.create/delete
// ---------------------------------------------------------------------------

const PLAYLIST_ID = 'PLxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';

/**
 * A `/playlist/get_add_to_playlist` body: one row already containing the video, one not.
 *
 * `containsSelectedVideos` is the **string** `"ALL"` / `"NONE"` and the remove
 * action is `ACTION_REMOVE_VIDEO_BY_VIDEO_ID` — both measured 2026-09-20. This
 * builder used to send `true`/`false` and `ACTION_REMOVE_VIDEO` with a
 * `setVideoId`, which are the community library's guesses, and the parser was
 * written to match them: it passed every test and read every real response wrong.
 */
function addToPlaylistBody(): unknown {
  return {
    contents: {
      addToPlaylistRenderer: {
        videoId: VIDEO_ID,
        playlists: [
          {
            playlistAddToOptionRenderer: {
              playlistId: 'WL',
              title: { simpleText: 'Watch later' },
              privacy: 'PRIVATE',
              containsSelectedVideos: 'ALL',
              removeFromPlaylistServiceEndpoint: {
                playlistEditEndpoint: {
                  playlistId: 'WL',
                  actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: VIDEO_ID }],
                },
              },
            },
          },
          {
            playlistAddToOptionRenderer: {
              playlistId: PLAYLIST_ID,
              title: { simpleText: 'My mix tape' },
              privacy: 'PUBLIC',
              containsSelectedVideos: 'NONE',
              addToPlaylistServiceEndpoint: {
                playlistEditEndpoint: {
                  playlistId: PLAYLIST_ID,
                  actions: [{ action: 'ACTION_ADD_VIDEO', addedVideoId: VIDEO_ID }],
                },
              },
            },
          },
        ],
      },
    },
  };
}

describe('playlist.forVideo', () => {
  test('reports membership per playlist, Watch Later included at its fixed id', async () => {
    const session = stubSession({ '/playlist/get_add_to_playlist': addToPlaylistBody() });
    const result = await playlistsForVideo(session, VIDEO_ID);

    expect(result.playlists).toHaveLength(2);
    const wl = result.playlists.find((p) => p.id === 'WL');
    const other = result.playlists.find((p) => p.id === PLAYLIST_ID);

    expect(wl).toMatchObject({ title: 'Watch later', privacy: 'private', containsVideo: true });
    expect(other).toMatchObject({ title: 'My mix tape', privacy: 'public', containsVideo: false });
  });

  test('only a row already containing the video carries a removeToken', () => {
    return playlistsForVideo(stubSession({ '/playlist/get_add_to_playlist': addToPlaylistBody() }), VIDEO_ID).then(
      (result) => {
        const wl = result.playlists.find((p) => p.id === 'WL')!;
        const other = result.playlists.find((p) => p.id === PLAYLIST_ID)!;
        expect(wl.removeToken).not.toBeNull();
        expect(other.removeToken).toBeNull();
        expect(JSON.parse(wl.removeToken!)).toEqual({
          playlistId: 'WL',
          actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: VIDEO_ID }],
        });
      },
    );
  });

  test('containsSelectedVideos is a string enum: ALL is in it, NONE is not, and a boolean means nothing', () => {
    // Measured 2026-09-20 on a signed-in account: `"ALL"` for a video in Watch Later,
    // `"NONE"` for one that is not. `true` is what the parser used to demand and what
    // YouTube has never been seen to send — it must not read as membership.
    const rowsWith = (value: unknown) =>
      parsePlaylistMembership({
        playlistAddToOptionRenderer: {
          playlistId: 'WL',
          title: { simpleText: 'Watch later' },
          containsSelectedVideos: value,
          removeFromPlaylistServiceEndpoint: {
            playlistEditEndpoint: { playlistId: 'WL', actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: VIDEO_ID }] },
          },
        },
      }).playlists[0]!;

    expect(rowsWith('ALL').containsVideo).toBe(true);
    expect(rowsWith('ALL').removeToken).not.toBeNull();
    for (const notMembership of ['NONE', 'SOME', '', true, false, null, undefined]) {
      expect(rowsWith(notMembership).containsVideo).toBe(false);
      expect(rowsWith(notMembership).removeToken).toBeNull();
    }
  });

  test('an unrecognised privacy value is null, never guessed', async () => {
    const body = addToPlaylistBody() as {
      contents: { addToPlaylistRenderer: { playlists: Array<{ playlistAddToOptionRenderer: Record<string, unknown> }> } };
    };
    body.contents.addToPlaylistRenderer.playlists[0]!.playlistAddToOptionRenderer['privacy'] = 'SOMETHING_NEW';
    const result = await playlistsForVideo(stubSession({ '/playlist/get_add_to_playlist': body }), VIDEO_ID);
    expect(result.playlists.find((p) => p.id === 'WL')!.privacy).toBeNull();
  });

  test('no cookie is AUTH_REQUIRED, and never leaves the process', async () => {
    const session = stubSession({ '/playlist/get_add_to_playlist': addToPlaylistBody() }, false);
    const failure = await playlistsForVideo(session, VIDEO_ID).catch((e: unknown) => e);
    expect(hasCode(failure, 'AUTH_REQUIRED')).toBe(true);
    expect(session.calls).toHaveLength(0);
  });
});

describe('action.removeFromPlaylist', () => {
  const TOKEN = JSON.stringify({
    playlistId: 'WL',
    actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: VIDEO_ID }],
  });

  test('replays the token verbatim against /browse/edit_playlist', async () => {
    const session = stubSession({ '/browse/edit_playlist': { status: 'STATUS_SUCCEEDED' } });
    await removeFromPlaylist(session, 'WL', TOKEN);
    expect(session.calls[0]).toEqual({
      endpoint: '/browse/edit_playlist',
      params: { playlistId: 'WL', actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: VIDEO_ID }] },
    });
  });

  test('a token minted for a different playlist is refused, not replayed', async () => {
    const session = stubSession({ '/browse/edit_playlist': { status: 'STATUS_SUCCEEDED' } });
    const failure = await removeFromPlaylist(session, 'PL_OTHER', TOKEN).catch((e: unknown) => e);
    expect(hasCode(failure, 'BAD_REQUEST')).toBe(true);
    expect(session.calls).toHaveLength(0);
  });

  test('malformed JSON is BAD_REQUEST, not a crash', async () => {
    const session = stubSession({ '/browse/edit_playlist': { status: 'STATUS_SUCCEEDED' } });
    const failure = await removeFromPlaylist(session, 'WL', '{not json').catch((e: unknown) => e);
    expect(hasCode(failure, 'BAD_REQUEST')).toBe(true);
    expect(session.calls).toHaveLength(0);
  });

  test('no cookie is AUTH_REQUIRED, and never leaves the process', async () => {
    const session = stubSession({ '/browse/edit_playlist': { status: 'STATUS_SUCCEEDED' } }, false);
    const failure = await removeFromPlaylist(session, 'WL', TOKEN).catch((e: unknown) => e);
    expect(hasCode(failure, 'AUTH_REQUIRED')).toBe(true);
    expect(session.calls).toHaveLength(0);
  });
});

describe('playlist.create / playlist.delete', () => {
  test('create sends title and an uppercased privacy, and reads playlistId back', async () => {
    const session = stubSession({ '/playlist/create': { playlistId: 'PL_NEW' } });
    const result = await createPlaylist(session, 'Road trip', 'unlisted');
    expect(session.calls[0]).toEqual({
      endpoint: '/playlist/create',
      params: { title: 'Road trip', privacyStatus: 'UNLISTED' },
    });
    expect(result).toEqual({ playlistId: 'PL_NEW' });
  });

  test('a null privacy sends no privacyStatus at all', async () => {
    const session = stubSession({ '/playlist/create': { playlistId: 'PL_NEW' } });
    await createPlaylist(session, 'Road trip', null);
    expect(session.calls[0]!.params).not.toHaveProperty('privacyStatus');
  });

  test('a response with no playlistId is UPSTREAM_ERROR, not a silent success', async () => {
    const session = stubSession({ '/playlist/create': {} });
    const failure = await createPlaylist(session, 'Road trip', null).catch((e: unknown) => e);
    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
  });

  test('delete sends the playlistId', async () => {
    const session = stubSession({ '/playlist/delete': {} });
    await deletePlaylist(session, 'PL_NEW');
    expect(session.calls[0]).toEqual({ endpoint: '/playlist/delete', params: { playlistId: 'PL_NEW' } });
  });

  test('no cookie is AUTH_REQUIRED for both, and never leaves the process', async () => {
    const createSession = stubSession({ '/playlist/create': { playlistId: 'PL_NEW' } }, false);
    const createFailure = await createPlaylist(createSession, 'x', null).catch((e: unknown) => e);
    expect(hasCode(createFailure, 'AUTH_REQUIRED')).toBe(true);
    expect(createSession.calls).toHaveLength(0);

    const deleteSession = stubSession({ '/playlist/delete': {} }, false);
    const deleteFailure = await deletePlaylist(deleteSession, 'PL_NEW').catch((e: unknown) => e);
    expect(hasCode(deleteFailure, 'AUTH_REQUIRED')).toBe(true);
    expect(deleteSession.calls).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// VideoDetail.myRating
// ---------------------------------------------------------------------------

describe('parseVideoDetail — myRating', () => {
  function withClassicLikeButton(likeStatus: string): unknown {
    return {
      contents: {
        twoColumnWatchNextResults: {
          results: {
            results: {
              contents: [
                {
                  videoPrimaryInfoRenderer: {
                    videoActions: {
                      menuRenderer: {
                        topLevelButtons: [
                          {
                            likeButtonRenderer: {
                              target: { videoId: VIDEO_ID },
                              likeStatus,
                            },
                          },
                        ],
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

  test('a classic LIKE status maps to "like"', () => {
    expect(parseVideoDetail(withClassicLikeButton('LIKE'), 'rate').myRating).toBe('like');
  });

  test('a classic DISLIKE status maps to "dislike"', () => {
    expect(parseVideoDetail(withClassicLikeButton('DISLIKE'), 'rate').myRating).toBe('dislike');
  });

  test('a classic INDIFFERENT status maps to "none" — the not-liked case', () => {
    // Mutation guard: a parser that always answers "like" would pass the LIKE
    // test above and only fail here.
    expect(parseVideoDetail(withClassicLikeButton('INDIFFERENT'), 'rate').myRating).toBe('none');
  });

  test('no like button at all is also "none"', () => {
    expect(parseVideoDetail(rawNextBody(), 'rate').myRating).toBe('none');
  });

  function withViewBasedLikeButton(likeStatus: string): unknown {
    return {
      contents: {
        twoColumnWatchNextResults: {
          results: {
            results: {
              contents: [
                {
                  videoPrimaryInfoRenderer: {
                    videoActions: {
                      buttonViewModel: {
                        segmentedLikeDislikeButtonViewModel: {
                          likeButtonViewModel: {
                            likeButtonViewModel: {
                              toggleButtonViewModel: {},
                              likeStatusEntityKey: 'key1',
                              likeStatusEntity: { key: 'key1', likeStatus },
                            },
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
  }

  test('a view-based LIKE status maps to "like"', () => {
    expect(parseVideoDetail(withViewBasedLikeButton('LIKE'), 'rate').myRating).toBe('like');
  });

  test('a view-based DISLIKE status maps to "dislike"', () => {
    expect(parseVideoDetail(withViewBasedLikeButton('DISLIKE'), 'rate').myRating).toBe('dislike');
  });

  test('a view-based INDIFFERENT status maps to "none"', () => {
    expect(parseVideoDetail(withViewBasedLikeButton('INDIFFERENT'), 'rate').myRating).toBe('none');
  });

  test.if(hasFixture('watch'))('reads the captured watch page without throwing', () => {
    const detail = parseVideoDetail(fixture('watch'), 'rate');
    expect(['like', 'dislike', 'none']).toContain(detail.myRating);
  });
});

// ---------------------------------------------------------------------------
// VideoDetail.publishedDateText
// ---------------------------------------------------------------------------

describe('parseVideoDetail — publishedDateText', () => {
  function withDates(relative?: string, exact?: string): unknown {
    return {
      contents: {
        twoColumnWatchNextResults: {
          results: {
            results: {
              contents: [
                {
                  videoPrimaryInfoRenderer: {
                    ...(relative ? { relativeDateText: { simpleText: relative } } : {}),
                    ...(exact ? { dateText: { simpleText: exact } } : {}),
                  },
                },
              ],
            },
          },
        },
      },
    };
  }

  test('both siblings are kept independently, not folded into one another', () => {
    const detail = parseVideoDetail(withDates('14 years ago', 'Dec 6, 2009'), 'dates');
    expect(detail.publishedText).toBe('14 years ago');
    expect(detail.publishedDateText).toBe('Dec 6, 2009');
  });

  test('publishedText still falls back to dateText when relativeDateText is missing', () => {
    // The pre-existing `??` — a layout that only ships the exact date must
    // not lose the headline just because this task added a second field.
    const detail = parseVideoDetail(withDates(undefined, 'Dec 6, 2009'), 'dates');
    expect(detail.publishedText).toBe('Dec 6, 2009');
    expect(detail.publishedDateText).toBe('Dec 6, 2009');
  });

  test('no exact date at all is null, not the relative text guessed twice', () => {
    // Mutation guard: a `publishedDateText` that just mirrored `publishedText`
    // would pass the first test above and only fail here.
    const detail = parseVideoDetail(withDates('14 years ago', undefined), 'dates');
    expect(detail.publishedText).toBe('14 years ago');
    expect(detail.publishedDateText).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Playback sessions
// ---------------------------------------------------------------------------

describe('playback sessions', () => {
  test('a real open registers a reportable session; a preload does not', async () => {
    const resolve = stubSession({ '/player:VISIONOS': rawPlayerBody('VISIONOS') }, false);
    const deps = { session: resolve, ytDlpPath: 'yt-dlp-does-not-exist' };

    const preloaded = await openPlayback(deps, { videoId: VIDEO_ID, preload: true });
    expect(getPlaybackSession(preloaded.sessionId)).toBeNull();

    const opened = await openPlayback(deps, { videoId: VIDEO_ID });
    expect(getPlaybackSession(opened.sessionId)?.videoId).toBe(VIDEO_ID);
  });

  test('closing releases it, and closing twice is not an error', () => {
    openPlaybackSession('s1', VIDEO_ID);
    expect(closePlaybackSession('s1')).toBe(true);
    expect(closePlaybackSession('s1')).toBe(false);
    expect(getPlaybackSession('s1')).toBeNull();
  });

  test('a CPN is 16 characters of YouTube alphabet and not reused', () => {
    const cpns = new Set(Array.from({ length: 64 }, generateCpn));
    expect(cpns.size).toBe(64);
    for (const cpn of cpns) expect(cpn).toMatch(/^[A-Za-z0-9_-]{16}$/);
  });
});

// ---------------------------------------------------------------------------
// playback.report
// ---------------------------------------------------------------------------

describe('playback.report', () => {
  function reportDeps() {
    const browse = stubSession({ '/player:WEB': rawPlayerBody('WEB') });
    return { browse };
  }

  test('the first report registers the view, then reports watchtime', async () => {
    const deps = reportDeps();
    const session = openPlaybackSession('s1', VIDEO_ID);

    await reportPlayback(deps, { sessionId: 's1', positionMs: 0, state: 'playing' });

    expect(deps.browse.stats.map((s) => new URL(s.url).pathname)).toEqual([
      '/api/stats/playback',
      '/api/stats/watchtime',
    ]);
    // Authenticated host, not the `s.` one YouTube publishes: a ping to `s.`
    // succeeds and is attributed to nobody.
    expect(deps.browse.stats[0]!.url).toStartWith('https://www.youtube.com/');
    expect(deps.browse.stats[0]!.params['cpn']).toBe(session.cpn);
  });

  test('registers the view once, no matter how many reports follow', async () => {
    const deps = reportDeps();
    openPlaybackSession('s1', VIDEO_ID);

    for (const positionMs of [0, 15_000, 30_000, 45_000]) {
      await reportPlayback(deps, { sessionId: 's1', positionMs, state: 'playing' });
    }

    const playbacks = deps.browse.stats.filter((s) => s.url.includes('/stats/playback'));
    const watchtimes = deps.browse.stats.filter((s) => s.url.includes('/stats/watchtime'));

    // Four reports, four watchtime pings — the cadence §3.5 asks for — and one
    // view. A second playback ping would read as a second view of the video.
    expect(playbacks).toHaveLength(1);
    expect(watchtimes).toHaveLength(4);
  });

  test('one CPN for the whole watch', async () => {
    const deps = reportDeps();
    openPlaybackSession('s1', VIDEO_ID);

    await reportPlayback(deps, { sessionId: 's1', positionMs: 0, state: 'playing' });
    await reportPlayback(deps, { sessionId: 's1', positionMs: 20_000, state: 'playing' });

    // A CPN per ping is a string of one-ping views rather than one watch, and
    // nothing about the response would say so.
    const cpns = new Set(deps.browse.stats.map((s) => s.params['cpn']));
    expect(cpns.size).toBe(1);
  });

  test('each report describes the segment since the last one', async () => {
    const deps = reportDeps();
    openPlaybackSession('s1', VIDEO_ID);

    await reportPlayback(deps, { sessionId: 's1', positionMs: 0, state: 'playing' });
    await reportPlayback(deps, { sessionId: 's1', positionMs: 30_000, state: 'playing' });

    const last = deps.browse.stats.at(-1)!;
    expect(last.params['st']).toBe('0.000');
    expect(last.params['et']).toBe('30.000');
    expect(last.params['cmt']).toBe('30.000');
  });

  test('a backward seek never describes a negative segment', async () => {
    const deps = reportDeps();
    openPlaybackSession('s1', VIDEO_ID);

    await reportPlayback(deps, { sessionId: 's1', positionMs: 120_000, state: 'playing' });
    await reportPlayback(deps, { sessionId: 's1', positionMs: 10_000, state: 'playing' });

    const last = deps.browse.stats.at(-1)!;
    // st ≤ et, or the endpoint answers 200 to an interval that counts nothing.
    expect(Number(last.params['st'])).toBeLessThanOrEqual(Number(last.params['et']));
    expect(last.params['et']).toBe('10.000');
  });

  test('only the ended report is final', async () => {
    const deps = reportDeps();
    openPlaybackSession('s1', VIDEO_ID);

    await reportPlayback(deps, { sessionId: 's1', positionMs: 10_000, state: 'playing' });
    await reportPlayback(deps, { sessionId: 's1', positionMs: 20_000, state: 'paused' });
    await reportPlayback(deps, { sessionId: 's1', positionMs: 634_000, state: 'ended' });

    const finals = deps.browse.stats.map((s) => s.params['final']);
    expect(finals.filter((f) => f === '1')).toHaveLength(1);
    expect(deps.browse.stats.at(-1)!.params['final']).toBe('1');
  });

  test('reporting is a WEB call — never the client the stream resolved through', async () => {
    const deps = reportDeps();
    openPlaybackSession('s1', VIDEO_ID);
    await reportPlayback(deps, { sessionId: 's1', positionMs: 0, state: 'playing' });

    // A5: two independent calls, no CPN bridged. The stub would throw for any
    // other client, so this asserts the client *and* that the tracking URLs came
    // from the response that will send them.
    expect(deps.browse.calls.map((c) => c.params['client'])).toEqual(['WEB']);
  });

  test('the WEB /player is fetched once for a whole watch', async () => {
    const deps = reportDeps();
    openPlaybackSession('s1', VIDEO_ID);

    for (let i = 0; i < 10; i++) {
      await reportPlayback(deps, { sessionId: 's1', positionMs: i * 15_000, state: 'playing' });
    }
    expect(deps.browse.calls.filter((c) => c.endpoint === '/player')).toHaveLength(1);
  });

  test('an unknown session is BAD_REQUEST, and pings nothing', async () => {
    const deps = reportDeps();
    const failure = await reportPlayback(deps, {
      sessionId: 'never-opened',
      positionMs: 0,
      state: 'playing',
    }).catch((e: unknown) => e);

    expect(isRpcError(failure)).toBe(true);
    expect(hasCode(failure, 'BAD_REQUEST')).toBe(true);
    expect((failure as RpcError).retry).toBe('no');
    expect(deps.browse.stats).toHaveLength(0);
  });

  test('a response with no tracking URLs fails loudly rather than quietly', async () => {
    // Load-bearing means the failure has to be visible. A silent return here is
    // a client that reports forever into nothing and a homepage that drifts.
    const deps = { browse: stubSession({ '/player:WEB': rawPlayerBody('WEB', { tracking: false }) }) };
    openPlaybackSession('s1', VIDEO_ID);

    const failure = await reportPlayback(deps, {
      sessionId: 's1',
      positionMs: 0,
      state: 'playing',
    }).catch((e: unknown) => e);

    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
    expect((failure as RpcError).message).toContain('watch history cannot land');
  });

  test('a rejected ping is an error, not a success', async () => {
    const deps = reportDeps();
    deps.browse.statsStatus = 403;
    openPlaybackSession('s1', VIDEO_ID);

    const failure = await reportPlayback(deps, {
      sessionId: 's1',
      positionMs: 0,
      state: 'playing',
    }).catch((e: unknown) => e);

    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
    expect((failure as RpcError).message).toContain('403');
  });
});
