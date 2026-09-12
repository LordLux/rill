/**
 * `action.like` / `action.dislike` / `action.removeRating` and
 * `action.subscribe` / `action.unsubscribe` — `protocol.md` §3.4.
 *
 * Task 25: `protocol.md` listed `action.like`/`dislike`/`subscribe` before this
 * task, but none of the four existed in `rpc/server.ts` — the dispatch table
 * had no `action.like`, `action.dislike` or `action.subscribe` case at all.
 * `ArtistPanelCard` in the Flutter app already calls `action.subscribe`
 * (`docs/tasks/25-actions.md` §2's "written and never exercised" describes
 * `action.addToWatchLater`; this is the sharper version of the same problem —
 * a call to a method that does not exist yet). `action.removeRating` is new:
 * the protocol table had no way to *undo* a like or dislike, and "un-like a
 * video" is explicitly one of this task's done-criteria.
 *
 * **All four go over the authenticated `WEB` session**, no client override.
 * The first version of this file sent `target` as a bare video-id string,
 * matching what youtubei.js's `InteractionManager.like`/`dislike` build — and
 * that same method also forces `client: 'TV'`, which is why a live HTTP 400
 * against `WEB` first read as possible evidence for the client-override stop
 * condition. It probably was not: this library's own declared type for the
 * request is `LikeRequest { target?: LikeTarget }` with
 * `LikeTarget = { videoId: string }` — an *object*, not a bare string — and
 * the `buildRequest()` method that actually sends the bare string never
 * matches its own type, which is a strong sign it was written against
 * whatever `client: 'TV'` happens to accept rather than against the documented
 * shape. Sending `{ videoId }` instead is the fix under test now (2026-09-11);
 * if a 400 still occurs with this shape, `client` becomes the more likely
 * explanation after all and the stop condition should be raised for real.
 */

import { RpcError, messageOf } from '../errors.ts';
import { logger } from '../log.ts';
import type { Session } from '../innertube/session.ts';
import { assertSucceeded, requireCookie } from './shared.ts';

const log = logger('action');

type RatingTarget = 'LIKE' | 'DISLIKE' | 'INDIFFERENT';

/**
 * The three raw InnerTube paths a rating change can land on — named here
 * rather than reached through youtubei.js's `LikeEndpoint`, so the request
 * shape is visible in this file instead of assembled by a class whose parsed
 * return value we discard (hard invariant 1).
 */
const RATING_ENDPOINT: Readonly<Record<RatingTarget, string>> = {
  LIKE: '/like/like',
  DISLIKE: '/like/dislike',
  INDIFFERENT: '/like/removelike',
};

async function setRating(
  session: Session,
  videoId: string,
  target: RatingTarget,
  method: string,
): Promise<Record<string, never>> {
  requireCookie(session, method);

  let response: unknown;
  try {
    // `target` is an object, `{ videoId }` — not the bare video-id string a
    // first version of this sent (see the file doc comment for why that
    // looked plausible and was not).
    response = await session.execute(RATING_ENDPOINT[target], { target: { videoId } });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `${method} on ${videoId}: ${messageOf(error)}`);
  }

  assertSucceeded(response, `${method} on ${videoId}`);
  log.info(`${method} ${videoId} -> ${target}`);
  return {};
}

export function like(session: Session, videoId: string): Promise<Record<string, never>> {
  return setRating(session, videoId, 'LIKE', 'action.like');
}

export function dislike(session: Session, videoId: string): Promise<Record<string, never>> {
  return setRating(session, videoId, 'DISLIKE', 'action.dislike');
}

/** Un-likes or un-dislikes — pressing an already-active Like/Dislike again. */
export function removeRating(session: Session, videoId: string): Promise<Record<string, never>> {
  return setRating(session, videoId, 'INDIFFERENT', 'action.removeRating');
}

export async function subscribe(
  session: Session,
  channelId: string,
): Promise<Record<string, never>> {
  requireCookie(session, 'action.subscribe');

  let response: unknown;
  try {
    // No `params` sent. youtubei.js's own `InteractionManager.subscribe` always
    // sends a literal opaque params blob (`'EgIIAhgA'`) alongside `channelIds`;
    // `SubscribeRequest`'s own type makes it optional, and guessing a wrong
    // opaque value seemed worse than a bare request that either works or fails
    // cleanly. If live testing shows subscribing fails where it should not,
    // that blob is the first thing to try adding back.
    response = await session.execute('/subscription/subscribe', { channelIds: [channelId] });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `action.subscribe to ${channelId}: ${messageOf(error)}`);
  }

  assertSucceeded(response, `subscribing to ${channelId}`);
  log.info(`subscribed to ${channelId}`);
  return {};
}

export async function unsubscribe(
  session: Session,
  channelId: string,
): Promise<Record<string, never>> {
  requireCookie(session, 'action.unsubscribe');

  let response: unknown;
  try {
    response = await session.execute('/subscription/unsubscribe', { channelIds: [channelId] });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `action.unsubscribe from ${channelId}: ${messageOf(error)}`);
  }

  assertSucceeded(response, `unsubscribing from ${channelId}`);
  log.info(`unsubscribed from ${channelId}`);
  return {};
}
