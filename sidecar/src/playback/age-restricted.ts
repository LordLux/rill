/**
 * The age-restricted path — a cookie, in memory, on one throwaway call.
 *
 * Task 22 §8 / A5: the sidecar's two-client model keeps browsing (`WEB`, the
 * account's cookie) and stream resolution (anonymous) on independent calls,
 * and nothing else in this codebase crosses that line. This file is the one
 * deliberate, narrow exception — `architecture.md` A12 — and it exists
 * because F48 measured what actually blocks an age-restricted video: every
 * anonymous client answers `LOGIN_REQUIRED — "Sign in to confirm your age"`
 * regardless of PO token, and the missing ingredient is the account's own
 * cookie. yt-dlp can supply one, but only from a file — `--cookies` has no
 * other form — and Task 22 §5 forbids writing a cookie to disk outside the
 * credential store. That path was built and reverted once already
 * (`todo.md` 54, `architecture.md` F46).
 *
 * So this builds a fresh, one-off session instead of a file: `WEB_CREATOR`,
 * the browse cookie, and a PO token, passed to `Innertube.create` as ordinary
 * in-memory strings and never touching disk. **Verified directly, not
 * assumed from yt-dlp's success** — a raw `/player` call built exactly this
 * way answered `OK` with 7 formats on the same video yt-dlp needed the
 * identical cookie+token pair to clear (F48). `WEB_CREATOR` specifically,
 * because the token yt-dlp accepted was bound to that client
 * (`po_token=web_creator.gvs+...`); a token minted for one client context is
 * not shown to transfer to another, and only this one has been tested.
 *
 * **Only ever called after the anonymous ladder already declined with
 * `AGE_VERIFICATION_REQUIRED`, and only when a cookie exists.** This is not a
 * ladder tier — `resolve.ts`'s `descendLadder` and `PlaybackDeps` stay exactly
 * as anonymous as they have always been, and `resolve-anonymous.test.ts`
 * keeps asserting that. `rpc/server.ts`'s `playback.open` handler is the only
 * caller, and the only thing it reads off `browseAuth` is the cookie
 * *string* — never `browseAuth.session()`, which would hand resolution the
 * browse `Innertube` object itself (its CPN, its cache, its revision) and
 * actually bridge the two clients the way A5 forbids. A string crossing this
 * process's own memory once, to build one call, is not that.
 */

import { hasCode } from '../errors.ts';
import { logger } from '../log.ts';
import { createSession } from '../innertube/session.ts';
import { getPlayerEntry } from '../innertube/player-response.ts';
import type { PlaybackDeps } from './resolve.ts';
import { tierPlainAdaptive } from './resolve.ts';
import { openPlaybackSession } from './sessions.ts';
import type { PlaybackSource } from '../types.ts';
import type { PoTokenProvider } from './po-token.ts';

const log = logger('age-restricted');

export interface AgeRestrictedParams {
  videoId: string;
  cookie: string;
  poTokens: PoTokenProvider;
  /** Mirrors `OpenParams.preload` — a preload registers no reportable session. */
  preload?: boolean;
  playlistId?: string | null;
}

/**
 * Try the age-restricted path. Returns `null` on any failure — a missing
 * cookie, a mint failure, a `/player` call that still declines — so the
 * caller can fall back to the original `AGE_VERIFICATION_REQUIRED` rather
 * than replacing one opaque failure with another.
 */
export async function resolveAgeRestricted(params: AgeRestrictedParams): Promise<PlaybackSource | null> {
  const { videoId, cookie, poTokens, preload = false, playlistId = null } = params;
  try {
    // The same content-bound token tier 1 already tried to mint for this
    // video — re-minting is not wasted work once the shared minter is warm
    // (F48: ~1ms once built), and it keeps this file from having to thread a
    // token out of `openPlayback`'s return value for a path that runs on a
    // small fraction of opens.
    const poToken = await poTokens.mint(videoId);
    if (poToken === null) {
      log.info(`${videoId}: no PO token available; declining the age-restricted retry`);
      return null;
    }

    const session = await createSession({ cookie, clientType: 'WEB_CREATOR', poToken });
    const entry = await getPlayerEntry(session, videoId, 'WEB_CREATOR');
    const deps: PlaybackDeps = { session };
    const source = await tierPlainAdaptive(deps, videoId, 'WEB_CREATOR', poToken, entry);
    log.info(`${videoId}: age-restricted retry succeeded (WEB_CREATOR, cookie + PO token)`);
    // Same rule `openPlayback` follows: a preload resolves and caches without
    // registering a reportable session (`OpenParams.preload`, `protocol.md` §3.6).
    if (!preload) {
      openPlaybackSession(source.sessionId, videoId, playlistId);
    }
    return source;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (hasCode(error, 'AGE_VERIFICATION_REQUIRED')) {
      log.info(`${videoId}: age-restricted retry still declined — ${message}`);
    } else {
      log.warn(`${videoId}: age-restricted retry failed — ${message}`);
    }
    return null;
  }
}
