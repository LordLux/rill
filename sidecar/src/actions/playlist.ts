/**
 * `action.addToWatchLater` and `action.addToPlaylist` — `protocol.md` §3.4.
 *
 * Both are one InnerTube call against the authenticated `WEB` session. Watch
 * Later is not a special endpoint: it is the playlist whose id is the literal
 * `WL`, edited exactly like any other.
 *
 * These go through `session.execute` like everything else, so `parse: false`
 * still holds (hard invariant 1) — youtubei.js's `PlaylistManager.addVideos`
 * would build the same request and then hand the answer to `Parser`, which is
 * the layer this project does not use.
 */

import { RpcError, messageOf } from '../errors.ts';
import { logger } from '../log.ts';
import type { Session } from '../innertube/session.ts';
import { get, str } from '../parser/tree.ts';

const log = logger('action');

/** The playlist id Watch Later has had since playlists existed. */
export const WATCH_LATER_PLAYLIST_ID = 'WL';

/**
 * The endpoint `playlistEditEndpoint` resolves to.
 *
 * Named here rather than reached through youtubei.js's `NavigationEndpoint`, so
 * the request shape is visible in this file instead of assembled three modules
 * away by a class whose parsed return value we discard.
 */
const EDIT_PLAYLIST_ENDPOINT = '/browse/edit_playlist';

/**
 * A write needs a cookie, and says so before spending a round trip.
 *
 * `AUTH_REQUIRED` is `retry: "no"` (§4): the same request will fail the same way
 * until someone logs in. Letting it go upstream instead would come back as an
 * `UPSTREAM_ERROR` — which is `auto`, so the app would back off and retry a
 * write that cannot succeed, four times, behind a spinner.
 *
 * Note what this does *not* claim. A cookie present is not a session accepted
 * (hard invariant 5); a degraded session still fails upstream, and that is
 * `auth.verify`'s job to name, not this one's.
 */
function requireCookie(session: Session, method: string): void {
  if (session.hasCookie) return;
  throw new RpcError('AUTH_REQUIRED', `${method} needs a signed-in session`);
}

/**
 * Did the edit take?
 *
 * `edit_playlist` answers HTTP 200 with `status: "STATUS_FAILED"` when it
 * refuses — a private playlist, a video that cannot be added, a session the
 * server has stopped honouring. Treating 200 as success is the F7 shape again:
 * an operation that reports fine and did nothing.
 */
function assertSucceeded(response: unknown, description: string): void {
  const status = str(get(response, 'status'));
  if (status !== null && status !== 'STATUS_SUCCEEDED') {
    throw new RpcError('UPSTREAM_ERROR', `${description}: YouTube answered ${status}`);
  }
}

export async function addToPlaylist(
  session: Session,
  videoId: string,
  playlistId: string,
): Promise<Record<string, never>> {
  requireCookie(session, 'action.addToPlaylist');

  let response: unknown;
  try {
    response = await session.execute(EDIT_PLAYLIST_ENDPOINT, {
      playlistId,
      actions: [{ action: 'ACTION_ADD_VIDEO', addedVideoId: videoId }],
    });
  } catch (error) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `could not add ${videoId} to ${playlistId}: ${messageOf(error)}`,
    );
  }

  assertSucceeded(response, `adding ${videoId} to ${playlistId}`);
  log.info(`added ${videoId} to playlist ${playlistId}`);
  return {};
}

export function addToWatchLater(
  session: Session,
  videoId: string,
): Promise<Record<string, never>> {
  return addToPlaylist(session, videoId, WATCH_LATER_PLAYLIST_ID);
}
