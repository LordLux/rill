/**
 * `mix.start` and `mix.extend` — `protocol.md` §3.3, Task 26.
 *
 * ---
 *
 * **A mix does not paginate, and the shape `protocol.md` used to specify for
 * it was fiction.** §3.3 said `mix.start {videoId}` → `{playlistId, items[],
 * continuation?}`. Measured live 2026-09-12, all three halves of that are
 * wrong:
 *
 *  - **The parameter is the playlist id.** One video has at least three valid
 *    mixes — `RD<id>`, `RDMM<id>`, `RDAMVM<id>` — returning different
 *    contents, so a video id cannot name one. A mix tile already carries the
 *    `RD…` id; nothing had to be derived from a thumbnail (which is what
 *    `mixSeedVideoId` in the Flutter app was doing, and why it is gone).
 *  - **There is no continuation token.** Not a missing one: zero occurrences
 *    of `"continuation"` anywhere in the response.
 *  - **`index` is ignored.** The server resolves position from `videoId` and
 *    corrects you — asking for the seed at `index: 24` comes back
 *    `currentIndex: 0`.
 *
 * What `/next` actually returns is a **sliding window centred on whatever
 * video you anchor on**: at most 25 items of history, and exactly 24 of
 * lookahead. Anchor at index 0 and you get 25 items; at index 10, 35; at index
 * 24, 49; from index 25 on it caps at 50 as the history end slides forward.
 *
 * **So extension is re-anchoring, and this module is where that lives.** The
 * client holds a queue and says "I have up to `afterVideoId`"; the sidecar
 * anchors there, finds it in the window, slices what follows and returns only
 * that. The alternative — hand the client a window and let it diff — would put
 * InnerTube's sliding-window semantics into Dart, which is hard invariant 6
 * exactly: the messy nested reality stays in V8 and Flutter gets flat DTOs.
 *
 * ---
 *
 * **Two different ends, and `items: []` conflates them.** Measured, a mix stops
 * yielding in two distinguishable ways, and `exhausted` exists so the client
 * does not have to guess which it hit:
 *
 *  - **Empty tail.** The anchor is the last item the server has. This is how a
 *    curated list finishes — `RDCLAK…`'s lookahead tapered 24 → 2 → 0 and the
 *    whole list came to 51 items.
 *  - **Anchor absent.** The server no longer places that video in this
 *    sequence at all and has answered with a re-seeded window (`indexOf === -1`,
 *    `currentIndex: 0`). An auto radio did this after ~169 items.
 *
 * Both mean "stop asking", so both set `exhausted`. They are logged apart
 * because they are different upstream behaviours and a change in which one
 * fires is worth being able to see. **Nothing branches on `isInfinite`** — it
 * was `true` on every mix sampled, including the curated ones that ran out.
 *
 * ---
 *
 * **Nothing here caches** (`docs/tasks/26-mixes.md` §4). Mixes are personalised
 * and change: the same list id opened anonymously and signed-in at the same
 * moment shared 2 items out of 25 (1 of 25 for `RDMM`). A cached mix is a stale
 * mix, and a cache keyed by list id would serve one session's radio to another.
 */

import { RpcError, messageOf } from '../errors.ts';
import { logger } from '../log.ts';
import type { Session } from '../innertube/session.ts';
import { mixItemIds, parseMixPanel, type MixPanel } from '../parser/mix.ts';
import { parseVideoDetail } from '../parser/video.ts';
import type { FeedItem, MixExtendResult, MixStartResult, VideoDetail, VideoItem } from '../types.ts';

const log = logger('mix');

export interface MixDeps {
  /** Authenticated `WEB`. A mix is personalised, and cookies are what personalise it. */
  browse: Session;
}

async function fetchNext(
  deps: MixDeps,
  params: Record<string, unknown>,
  description: string,
): Promise<unknown> {
  try {
    return await deps.browse.execute('/next', params);
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `${description}: ${messageOf(error)}`);
  }
}

async function fetchPanel(
  deps: MixDeps,
  params: Record<string, unknown>,
  description: string,
): Promise<MixPanel | null> {
  return parseMixPanel(await fetchNext(deps, params, description), description);
}

/**
 * The seed at the front of the list, or `null` if it is not in the list at all.
 *
 * Moving it rather than rebuilding around it: everything after the seed is the
 * radio's own order and stays that way, and the *tail* — which is what
 * `mix.extend` anchors on — is untouched by anything done to the head.
 */
function seedFirst(items: FeedItem[], seed: string): FeedItem[] | null {
  const at = items.findIndex((item) => item.id === seed);
  if (at < 0) return null;
  if (at === 0) return items;
  return [items[at]!, ...items.slice(0, at), ...items.slice(at + 1)];
}

/**
 * A queue entry for the seed, built from the watch page the same `/next`
 * already returned — so a seed missing from the panel costs no extra round
 * trip when the page is for the seed.
 *
 * `null` unless that page really is the seed's: when YouTube swaps the opener
 * it can swap the page with it, and prepending the wrong video under the
 * seed's name is worse than not prepending.
 *
 * `durationSeconds` is whatever `/next` carries, usually `null` — `/player`
 * has the real one and `playback.open` fetches it anyway. The thumbnail is
 * YouTube's standard still for the id, the same URL shape the panel's own
 * rows use.
 */
function seedItemFrom(detail: VideoDetail, seed: string): VideoItem | null {
  if (detail.id !== seed || !detail.title) return null;
  return {
    kind: 'video',
    id: seed,
    title: detail.title,
    channelName: detail.channelName,
    channelId: detail.channelId,
    channelAvatarUrl: detail.channelAvatarUrl,
    thumbnailUrl: `https://i.ytimg.com/vi/${seed}/hqdefault.jpg`,
    durationSeconds: detail.isLive ? null : detail.durationSeconds,
    isLive: detail.isLive,
    isStation: false,
    viewCountText: detail.viewCountText,
    publishedText: detail.publishedText,
    descriptionSnippet: null,
    badges: [],
    isShort: false,
    isMusic: false,
    isMembersOnly: detail.isMembersOnly,
    isVerified: detail.isVerified,
    isArtistChannel: detail.isArtistChannel,
    premiereAtMs: detail.premiereAtMs,
    canWatchLater: true,
    canAddToQueue: true,
  };
}

/**
 * `mix.start` — open a mix and hand back the window YouTube leads with.
 *
 * `videoId` is optional and is the *seed*, not the identity: passing the video
 * the user clicked starts the radio there, and omitting it lets YouTube pick
 * (measured: 24 items at `currentIndex: 0` rather than 25 — the panel simply
 * starts one earlier). Both work for every `RD` sub-type sampled.
 */
export async function startMix(
  deps: MixDeps,
  params: { playlistId: string; videoId?: string | null; params?: string | null },
): Promise<MixStartResult> {
  const { playlistId, videoId } = params;
  const description = `mix.start ${playlistId}`;
  const request = {
    playlistId,
    ...(videoId ? { videoId } : {}),
    // The tile's own click-target `params`. Signed in, it is what makes the
    // server honour `videoId` as the opener (114/114 with, 86/90 without).
    ...(params.params ? { params: params.params } : {}),
  };

  const raw = await fetchNext(deps, request, description);
  let panel = parseMixPanel(raw, description);

  if (!panel) {
    // A playlist id YouTube will not open as a watch context: a deleted or
    // private list, or a malformed `RD…`. `retry: "no"` territory — the same
    // bytes fail the same way.
    throw new RpcError(
      'BAD_REQUEST',
      `mix.start: ${playlistId} returned no playlist panel — not a playable mix`,
    );
  }

  let items = panel.items;

  // **The advertised video plays first, whatever the response says.** A mix
  // tile is titled and thumbnailed after one song, and opening it on another
  // is a user clicking one thing and getting something else — so this is
  // enforced here rather than trusted to the seed and `params` alone, which
  // are very reliable but were measured, not guaranteed.
  if (videoId) {
    const ordered = seedFirst(items, videoId);
    if (ordered) {
      if (ordered !== items) log.info(`${description}: seed ${videoId} was not first — moved to the front`);
      items = ordered;
    } else {
      const fromPage = seedItemFrom(parseVideoDetail(raw, description), videoId);
      if (fromPage) {
        log.info(`${description}: seed ${videoId} absent from the panel — prepended from its own watch page`);
        items = [fromPage, ...items];
      } else {
        log.warn(`${description}: seed ${videoId} absent and the page is another video's — retrying once`);
        const retryRaw = await fetchNext(deps, request, `${description} (retry)`);
        const retry = parseMixPanel(retryRaw, description);
        const retried = retry ? seedFirst(retry.items, videoId) : null;
        const retriedPage = retried ? null : seedItemFrom(parseVideoDetail(retryRaw, description), videoId);
        if (retry && retried) {
          panel = retry;
          items = retried;
        } else if (retry && retriedPage) {
          panel = retry;
          items = [retriedPage, ...retry.items];
        } else {
          // Nothing left to build the seed's entry from. Plays what YouTube
          // gave — the retry's answer, being the more recent — and says so.
          // This is the one case the guarantee cannot keep.
          if (retry) {
            panel = retry;
            items = retry.items;
          }
          log.warn(`${description}: seed ${videoId} still absent after a retry — opening on YouTube's choice`);
        }
      }
    }
  }

  log.info(
    `${description}: ${items.length} items ` +
      `(currentIndex ${panel.currentIndex}, infinite=${panel.isInfinite})`,
  );

  return {
    playlistId: panel.playlistId,
    title: panel.title,
    items,
  };
}

/**
 * `mix.extend` — everything the radio has after `afterVideoId`.
 *
 * The client passes the last item it holds. Anything before the anchor in the
 * returned window is history the client already has by construction, so only
 * the tail ships — which is what keeps the window arithmetic on this side of
 * the RPC boundary.
 */
export async function extendMix(
  deps: MixDeps,
  params: { playlistId: string; afterVideoId: string },
): Promise<MixExtendResult> {
  const { playlistId, afterVideoId } = params;

  const panel = await fetchPanel(
    deps,
    { playlistId, videoId: afterVideoId },
    `mix.extend ${playlistId}`,
  );

  if (!panel) {
    // The list opened once and will not open now. Treated as exhausted rather
    // than as an error: the client has a playable queue either way, and §4
    // says a failed extension must not be fatal.
    log.warn(`mix.extend ${playlistId}: no panel for anchor ${afterVideoId} — treating as exhausted`);
    return { items: [], exhausted: true };
  }

  const ids = mixItemIds(panel);
  const at = ids.indexOf(afterVideoId);

  if (at < 0) {
    log.info(
      `mix.extend ${playlistId}: exhausted — anchor ${afterVideoId} absent from a ` +
        `${ids.length}-item window (currentIndex ${panel.currentIndex}); the server re-seeded`,
    );
    return { items: [], exhausted: true };
  }

  const items = panel.items.slice(at + 1);
  if (items.length === 0) {
    log.info(
      `mix.extend ${playlistId}: exhausted — empty tail after ${afterVideoId} ` +
        `at ${at}/${ids.length}; the list has run out`,
    );
    return { items: [], exhausted: true };
  }

  log.info(`mix.extend ${playlistId}: +${items.length} after ${afterVideoId} (at ${at}/${ids.length})`);
  return { items, exhausted: false };
}
