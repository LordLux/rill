/**
 * `video.info` and `video.related` — `protocol.md` §3.3.
 *
 * The watch page needs two things `/next` alone cannot give it:
 *
 *   - **A duration.** A `/next` response does not carry one. `lengthSeconds`
 *     lives on `/player`'s `videoDetails`, and `videoPrimaryInfoRenderer` has no
 *     length text, so `parseVideoDetail` returns `null` for it by construction.
 *   - **Related tiles**, which `parseVideoDetail` already flattens to the same
 *     `FeedItem` DTOs the feed uses.
 *
 * So `video.info` composes `/next` with a `/player` response — **the same one
 * `playback.open` resolves from**, not a second call. That is the whole reason
 * `innertube/player-response.ts` exists, and it only works if both consumers ask
 * as the same client: the cache is keyed `client:videoId`. Ladder tier 1 asks as
 * `VISIONOS`, so this does too, over the same anonymous resolve session.
 *
 * **That is a deliberate reading of §2.3.** The table there assigns `WEB` to
 * "browse" and `VISIONOS` to "stream resolution"; a `/player` call for a
 * duration is resolution-shaped, not browse-shaped, and asking as `WEB` here
 * would buy a SABR-only response (F3) nothing reads, on a second round trip, for
 * a number both responses carry identically. `/next` stays on the authenticated
 * `WEB` session, because subscription state, the like count and a personalised
 * sidebar are exactly what cookies are for.
 *
 * Nothing is bridged between the two: no CPN crosses, and the anonymous response
 * contributes one integer. A5 rejects bridging a *CPN* across clients, which is
 * a different thing from reading a length from the response you already have.
 */

import { messageOf } from '../errors.ts';
import { logger } from '../log.ts';
import { getPlayerResponse } from '../innertube/player-response.ts';
import type { Session } from '../innertube/session.ts';
import { parseFeed } from '../parser/feed.ts';
import { get } from '../parser/tree.ts';
import { parseVideoDetail } from '../parser/video.ts';
import type { ItemListResult, VideoDetail } from '../types.ts';

const log = logger('video');

export interface VideoDeps {
  /** Authenticated `WEB`. Serves `/next`: sidebar, subscription state, likes. */
  browse: Session;
  /** Anonymous, server-issued visitor id. Serves the shared `/player`. */
  resolve: Session;
}

/**
 * The `/player` duration, or `null` if this video will not give us one.
 *
 * Never throws. A refused or unplayable `/player` is `playback.open`'s problem
 * to report — it has a five-rung ladder and an error contract for exactly that —
 * and failing `video.info` over it would replace a watch page missing one number
 * with no watch page at all.
 */
async function fromPlayer(
  deps: VideoDeps,
  videoId: string,
): Promise<{ durationSeconds: number | null; premiereAtMs: number | null }> {
  try {
    const response = await getPlayerResponse(deps.resolve, videoId, 'VISIONOS');
    return {
      durationSeconds: response.durationSeconds,
      // The premiere's start time, from the response that actually knows it.
      // `/next` carries the prose ("Premieres Aug 22, 2026") and not always a
      // timestamp; `/player` carries the timestamp. Read out of a response this
      // call already makes, so a premiere costs no extra round trip.
      premiereAtMs: response.scheduledStartMs,
    };
  } catch (error) {
    log.warn(`${videoId}: /player gave no duration (${messageOf(error)})`);
    return { durationSeconds: null, premiereAtMs: null };
  }
}

/**
 * `video.info` — the watch page's payload.
 *
 * Both halves are issued together. They are independent requests to different
 * sessions, and awaiting them in sequence would put the `/player` round trip
 * behind the `/next` one for no reason.
 *
 * **Captions are not here, and that is a decision rather than an omission.** The
 * track list is on the `/player` response this already has, so reading it would
 * be free — but a list is only useful once the `VISIONOS` → `MWEB` fallback has
 * run (`captions/service.ts`), and that fallback is a second `/player` call. On
 * the ~29% of videos with no captions it would fire on every open, for a
 * measured rescue rate of zero, and §3.3's one-`/player`-call property would be
 * gone. `captions.list` owns it; the watch page calls both at once.
 */
export async function getVideoInfo(deps: VideoDeps, videoId: string): Promise<VideoDetail> {
  const [raw, player] = await Promise.all([
    deps.browse.execute('/next', { videoId }),
    fromPlayer(deps, videoId),
  ]);

  const detail = parseVideoDetail(raw, 'video.info');

  return {
    ...detail,
    // `/next` wins when it has one — a live stream's `null` is a statement, not
    // a gap, and `parseVideoDetail` already nulls the duration when `isLive`.
    durationSeconds: detail.isLive ? null : (detail.durationSeconds ?? player.durationSeconds),
    // `/next` first, `/player` behind it — same precedence as the duration, for
    // the same reason: the watch page's own payload is the one describing the
    // page the user is looking at.
    premiereAtMs: detail.premiereAtMs ?? player.premiereAtMs,
    // An id is what every follow-up call keys on. A layout that hides it in a
    // place the parser does not know about would otherwise produce a detail
    // nothing can act on, silently.
    id: detail.id || videoId,
  };
}

/**
 * `video.related` — the sidebar, first page or continuation.
 *
 * The same tiles `video.info` already returns in `related`, reachable on their
 * own so paging does not have to re-fetch a whole watch page. Both go through
 * `parseFeed`, so a related tile and a home tile are the same DTO — which is the
 * point of the contract and what lets the watch page reuse `MediaTile`.
 */
export async function getRelated(
  deps: VideoDeps,
  params: { videoId: string; continuation?: string | null },
): Promise<ItemListResult> {
  const { videoId, continuation } = params;
  const raw = continuation
    ? await deps.browse.execute('/next', { continuation })
    : await deps.browse.execute('/next', { videoId });

  // A continuation response is a bare list; a first page buries the sidebar
  // under `secondaryResults`, and walking the whole body instead would pull in
  // the primary column — the description's own chapter and product tiles.
  //
  // Falls back to the whole response when that path is absent rather than
  // returning nothing: the sidebar has moved before, and an empty related list
  // is indistinguishable from a video that genuinely has none.
  const root = continuation
    ? raw
    : (get(raw, 'contents', 'twoColumnWatchNextResults', 'secondaryResults') ?? raw);

  const result = parseFeed(root, 'video.related');
  return { items: result.items, continuation: result.continuation };
}
