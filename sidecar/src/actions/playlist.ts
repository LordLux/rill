/**
 * `action.addToPlaylist` / `action.removeFromPlaylist`, `playlist.forVideo`,
 * `playlist.create` and `playlist.delete` — `protocol.md` §3.4/§3.9. Watch
 * Later is not a special endpoint: it is the playlist whose id is the literal
 * `WL`, edited exactly like any other.
 *
 * These go through `session.execute` like everything else, so `parse: false`
 * still holds (hard invariant 1) — youtubei.js's `PlaylistManager` would build
 * the same requests and then hand the answers to `Parser`, which is the layer
 * this project does not use.
 */

import { RpcError, messageOf } from '../errors.ts';
import { logger } from '../log.ts';
import type { Session } from '../innertube/session.ts';
import type { PlaylistMembership, PlaylistMembershipResult, PlaylistPrivacy } from '../types.ts';
import { deepCollect, get, isObject, str, type JsonObject } from '../parser/tree.ts';
import { text } from '../parser/text.ts';
import { assertSucceeded, requireCookie } from './shared.ts';

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

/**
 * `action.removeFromPlaylist` — the inverse `action.addToPlaylist` never had
 * (`protocol.md`'s gap note under §3.4), and Watch Later's own removal per
 * Task 25 §7: "Watch Later is a playlist with a fixed id," so this is the
 * whole mechanism, not a special case of it.
 *
 * **Removing needs a `setVideoId`, adding does not** — `ACTION_ADD_VIDEO`
 * takes a bare `addedVideoId`, but `ACTION_REMOVE_VIDEO` addresses a specific
 * *entry* in the playlist, because a video can appear in a playlist more than
 * once. youtubei.js's own `PlaylistManager.removeVideos` gets there by
 * browsing the whole playlist and matching video ids to entries — an extra
 * round trip, unbounded on a long playlist, and pagination this task's own
 * "out of scope" list rules out building (`docs/tasks/25-actions.md`, "Playlist
 * reordering").
 *
 * `playlistsForVideo` below sidesteps that: `playlist/get_add_to_playlist`
 * answers, for a playlist that already contains the video, a
 * `removeFromPlaylistServiceEndpoint` whose payload already carries the
 * correct `setVideoId` — YouTube's own "Save to…" dialog removes a checkbox
 * with exactly this token, no playlist browse involved. So `removeToken` is
 * that payload, opaque and round-tripped by the client exactly like a feed
 * `continuation` token: minted by one call, replayed verbatim by another,
 * never constructed or read by anything outside the sidecar.
 *
 * `playlistId` is still required and checked against the token rather than
 * trusted from the token alone — a stale token from a previous video's dialog
 * would otherwise edit whatever playlist it was minted for, silently.
 */
export async function removeFromPlaylist(
  session: Session,
  playlistId: string,
  removeToken: string,
): Promise<Record<string, never>> {
  requireCookie(session, 'action.removeFromPlaylist');

  let payload: unknown;
  try {
    payload = JSON.parse(removeToken);
  } catch {
    throw new RpcError('BAD_REQUEST', 'action.removeFromPlaylist: removeToken is not valid JSON');
  }
  if (!isObject(payload) || str(get(payload, 'playlistId')) !== playlistId) {
    throw new RpcError(
      'BAD_REQUEST',
      'action.removeFromPlaylist: removeToken does not match playlistId — likely stale',
    );
  }

  let response: unknown;
  try {
    response = await session.execute(EDIT_PLAYLIST_ENDPOINT, payload as Record<string, unknown>);
  } catch (error) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `removing a video from ${playlistId}: ${messageOf(error)}`,
    );
  }

  assertSucceeded(response, `removing a video from ${playlistId}`);
  log.info(`removed a video from playlist ${playlistId}`);
  return {};
}

/** `PlaylistPrivacy` (lowercase, client-facing) → the raw value InnerTube sends and expects. */
const PRIVACY_TO_RAW: Readonly<Record<PlaylistPrivacy, string>> = {
  public: 'PUBLIC',
  unlisted: 'UNLISTED',
  private: 'PRIVATE',
};

function privacyFromRaw(value: string | null): PlaylistPrivacy | null {
  if (value === 'PUBLIC') return 'public';
  if (value === 'UNLISTED') return 'unlisted';
  if (value === 'PRIVATE') return 'private';
  return null;
}

/**
 * `playlist.forVideo` — the save-to-playlist dialog's one call, per Task 25
 * §5. It answers both halves the dialog needs at once: **the user's
 * playlists**, and **which of them already contain this video** —
 * deliberately not two calls, because `playlist/get_add_to_playlist` is the
 * single endpoint YouTube's own "Save to…" dialog is backed by, and splitting
 * it into a generic playlist list plus a per-video membership check would
 * invent a round trip that dialog does not pay.
 *
 * **Not paginated, and that is a property of the endpoint rather than
 * something this method chose to drop.** `playlist/get_add_to_playlist`'s
 * request carries no continuation-shaped field (`videoIds`, `playlistId?`,
 * `params?`, `excludeWatchLater`), and neither does the response shape below
 * — there is no observed cursor to page with. **Unverified against a live
 * capture**: this is read from the request/response shapes a maintained
 * community library builds for this exact endpoint
 * (`AddToPlaylistServiceEndpoint`, `PlaylistAddToOption`), not from a fixture
 * in this repo — confirm against a real response, especially for an account
 * with a very large number of playlists.
 *
 * Read structurally (`playlistAddToOptionRenderer`, wherever it sits) rather
 * than by a fixed container path, for the same reason every other parser in
 * this codebase does: the exact wrapping renderer name was not confirmed
 * against a live response either.
 *
 * **One field of it has now been measured, and it was wrong** (2026-09-20,
 * signed in, videos in and out of Watch Later): `containsSelectedVideos` is the
 * string `"ALL"` or `"NONE"`, not a boolean, so the `=== true` this method used
 * to test was false for every row of every video — no playlist ever read as
 * containing the video, and no row ever carried a `removeToken`. The unit test
 * that "covered" it fed the parser `true`, a value YouTube does not send.
 * `parsePlaylistMembership` below is the pure half, so a raw capture can be run
 * through it (`fixtures/viewer-state/`); the rest of the shape is still the
 * community library's.
 */
export async function playlistsForVideo(
  session: Session,
  videoId: string,
): Promise<PlaylistMembershipResult> {
  requireCookie(session, 'playlist.forVideo');

  let raw: unknown;
  try {
    raw = await session.execute('/playlist/get_add_to_playlist', { videoIds: [videoId] });
  } catch (error) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `listing playlists for ${videoId}: ${messageOf(error)}`,
    );
  }

  return parsePlaylistMembership(raw);
}

/**
 * The pure half of {@link playlistsForVideo}: a raw `get_add_to_playlist`
 * response in, the rows out. Exported so a captured response can be parsed
 * without a session.
 */
export function parsePlaylistMembership(raw: unknown): PlaylistMembershipResult {
  const rows = deepCollect(raw, (node) => isObject(node['playlistAddToOptionRenderer'])).map(
    (node) => node['playlistAddToOptionRenderer'] as JsonObject,
  );

  const playlists: PlaylistMembership[] = [];
  for (const row of rows) {
    const id = str(get(row, 'playlistId'));
    // No id, nothing a caller could ever act on — skip rather than ship a
    // row nobody can use (hard invariant 4's "skip, never fail the request").
    if (!id) continue;

    // `"ALL"` / `"NONE"` — a string enum, measured 2026-09-20. `"SOME"` exists
    // for a request naming several videos and cannot occur for the one this is
    // asked about; anything that is not `"ALL"` is "not in it".
    const containsVideo = str(get(row, 'containsSelectedVideos')) === 'ALL';
    const removeEndpoint = get(row, 'removeFromPlaylistServiceEndpoint', 'playlistEditEndpoint');
    playlists.push({
      id,
      title: text(get(row, 'title')) ?? '',
      privacy: privacyFromRaw(str(get(row, 'privacy'))),
      containsVideo,
      removeToken: containsVideo && isObject(removeEndpoint) ? JSON.stringify(removeEndpoint) : null,
    });
  }

  return { playlists };
}

/**
 * `playlist.create` — Task 25 §5's "create a new playlist, with a privacy
 * setting if the API exposes one." `CreatePlaylistServiceRequest` (a
 * community library's type, read as documentation only — hard invariant 1)
 * declares `privacyStatus`, so it does; a caller that omits `privacy` gets
 * whatever YouTube defaults a bare `playlist/create` to, which was not
 * measured here.
 */
export async function createPlaylist(
  session: Session,
  title: string,
  privacy: PlaylistPrivacy | null,
): Promise<{ playlistId: string }> {
  requireCookie(session, 'playlist.create');

  let response: unknown;
  try {
    response = await session.execute('/playlist/create', {
      title,
      ...(privacy ? { privacyStatus: PRIVACY_TO_RAW[privacy] } : {}),
    });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `creating playlist "${title}": ${messageOf(error)}`);
  }

  const playlistId = str(get(response, 'playlistId'));
  if (!playlistId) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `creating playlist "${title}": response carried no playlistId`,
    );
  }

  log.info(`created playlist ${playlistId} ("${title}")`);
  return { playlistId };
}

/**
 * `playlist.delete` — deliberately takes only a `playlistId`. YouTube offers
 * no "are you sure" round trip of its own; the confirmation step is the
 * client's job, same as any other destructive action in this app.
 */
export async function deletePlaylist(
  session: Session,
  playlistId: string,
): Promise<Record<string, never>> {
  requireCookie(session, 'playlist.delete');

  try {
    await session.execute('/playlist/delete', { playlistId });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `deleting playlist ${playlistId}: ${messageOf(error)}`);
  }

  log.info(`deleted playlist ${playlistId}`);
  return {};
}
