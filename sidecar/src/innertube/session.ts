/**
 * InnerTube session — creation, raw execution, auth verification.
 *
 * youtubei.js is a session/auth/decipher layer here and nothing more. Every call
 * goes through `execute` with `parse: false` and comes back as raw JSON, because
 * the library's typed accessors silently drop live feed content (F2): a home
 * response containing 24 tiles parsed to `getHomeFeed().videos === []`.
 *
 * No typed accessors. No `Parser` classes. No `.videos`, no `getContinuation()`.
 */

import vm from 'node:vm';
import { ClientType, Innertube, Platform, UniversalCache } from 'youtubei.js';

import { logger } from '../log.ts';
import type { AuthState, AuthVerification } from '../types.ts';

const log = logger('session');

export interface Session {
  readonly innertube: Innertube;
  /** True when a cookie was supplied. Says nothing about server acceptance — see `verifyAuth`. */
  readonly hasCookie: boolean;
  /**
   * Execute an InnerTube endpoint and return the raw response body.
   * Always `parse: false`; there is no opt-out, by design.
   */
  execute(endpoint: string, params?: Record<string, unknown>): Promise<unknown>;
}

// ---------------------------------------------------------------------------
// JS interpreter shim
// ---------------------------------------------------------------------------

let interpreterInstalled = false;

/**
 * youtubei.js ships no interpreter for YouTube's obfuscated player code, so
 * signature and `n` deciphering silently no-op without this. The symptom is not
 * an error — it is ~50 KB/s throughput that looks like a bad connection. Install
 * before session creation, always.
 */
export function installInterpreter(): void {
  if (interpreterInstalled) return;
  Platform.shim.eval = (code: string | { output: string }) => {
    const text = typeof code === 'string' ? code : code.output;
    return vm.runInNewContext(`(function() { ${text} })()`, {});
  };
  interpreterInstalled = true;
  log.debug('node:vm interpreter shim installed');
}

// ---------------------------------------------------------------------------
// Session creation
// ---------------------------------------------------------------------------

export interface SessionOptions {
  /** Cookie header from a logged-in youtube.com session. Omit for anonymous. */
  cookie?: string;
  /** `WEB` for browsing and reporting, `MWEB` for stream resolution (F3/F6). */
  clientType?: 'WEB' | 'MWEB';
  /** Required for decipher. Only turn off for captures that never touch /player. */
  retrievePlayer?: boolean;
  /** A stale cached session survives a cookie rotation and hides F7. Off by default. */
  cache?: boolean;
}

export async function createSession(options: SessionOptions | string = {}): Promise<Session> {
  const opts: SessionOptions = typeof options === 'string' ? { cookie: options } : options;
  const {
    cookie,
    clientType = 'WEB',
    retrievePlayer = true,
    cache = false,
  } = opts;

  installInterpreter();

  const innertube = await Innertube.create({
    ...(cookie ? { cookie } : {}),
    client_type: clientType === 'MWEB' ? ClientType.MWEB : ClientType.WEB,
    device_category: 'desktop',
    retrieve_player: retrievePlayer,
    enable_session_cache: cache,
    ...(cache ? { cache: new UniversalCache(true, './.cache') } : {}),
    generate_session_locally: !cookie,
  });

  log.info(
    `session created client=${clientType} cookie=${cookie ? 'yes' : 'no'} ` +
      `sts=${innertube.session.player?.signature_timestamp ?? 'n/a'}`,
  );

  return {
    innertube,
    hasCookie: Boolean(cookie),
    async execute(endpoint, params = {}) {
      // parse:false is not negotiable — see F2.
      const response = await innertube.actions.execute(endpoint, { ...params, parse: false });
      const body = response as { data?: unknown };
      return body?.data ?? response;
    },
  };
}

// ---------------------------------------------------------------------------
// Player requests
// ---------------------------------------------------------------------------

/**
 * The payload a raw `/player` call needs.
 *
 * `{ videoId }` alone is not enough: YouTube answers
 * `UNPLAYABLE — "The page needs to be reloaded."`, which reads like a broken
 * video rather than a malformed request. The signature timestamp is the piece
 * that matters — it tells the server which player JS the client deciphered
 * against, and without it no streaming data is returned at all.
 *
 * `client` swaps the request context (F3: browse as WEB, resolve as MWEB).
 */
export function playerPayload(
  session: Session,
  videoId: string,
  client?: 'WEB' | 'MWEB',
): Record<string, unknown> {
  return {
    videoId,
    contentCheckOk: true,
    racyCheckOk: true,
    playbackContext: {
      contentPlaybackContext: {
        vis: 0,
        splay: false,
        lactMilliseconds: '-1',
        signatureTimestamp: session.innertube.session.player?.signature_timestamp,
      },
    },
    ...(client ? { client } : {}),
  };
}

// ---------------------------------------------------------------------------
// Auth verification
// ---------------------------------------------------------------------------

/**
 * Count video tiles in a raw response by key, without going through the parser.
 *
 * Deliberately parser-independent: `verifyAuth` is a health check on the
 * *session*, and routing it through the parser would report a parser regression
 * as a login problem — which is the one diagnosis that sends you to re-export
 * cookies for no reason.
 */
export function countTiles(raw: unknown): number {
  const TILE_KEYS = new Set(['lockupViewModel', 'videoRenderer', 'richItemRenderer']);
  let count = 0;
  const seen = new WeakSet<object>();

  const walk = (value: unknown, depth: number): void => {
    if (depth > 60 || value === null || typeof value !== 'object') return;
    if (seen.has(value)) return;
    seen.add(value);

    if (Array.isArray(value)) {
      for (const entry of value) walk(entry, depth + 1);
      return;
    }
    for (const [key, entry] of Object.entries(value)) {
      if (TILE_KEYS.has(key)) count += 1;
      walk(entry, depth + 1);
    }
  };

  walk(raw, 0);
  return count;
}

/**
 * The only trustworthy authentication check.
 *
 * Never trust `logged_in` (hard invariant 5): it reflects cookie presence, not
 * server acceptance. A degraded session returns HTTP 200 with an empty feed and
 * no error (F7), and the app must surface a re-auth prompt rather than an empty
 * homepage. So: fetch home, count tiles, zero with cookies present means
 * degraded.
 */
export async function verifyAuth(session: Session): Promise<AuthVerification> {
  let tileCount = 0;

  try {
    const raw = await session.execute('/browse', { browseId: 'FEwhat_to_watch' });
    tileCount = countTiles(raw);
  } catch (error) {
    log.error(`auth verification request failed: ${(error as Error).message}`);
    return { state: session.hasCookie ? 'degraded' : 'anonymous', tileCount: 0 };
  }

  const state: AuthState = !session.hasCookie
    ? 'anonymous'
    : tileCount > 0
      ? 'authenticated'
      : 'degraded';

  if (state === 'degraded') {
    log.error(
      'session is DEGRADED: cookies present, home feed returned 0 tiles. ' +
        'Cookies were invalidated server-side — re-export from an incognito window ' +
        'parked on youtube.com/robots.txt, and keep main-profile YouTube tabs closed.',
    );
  } else {
    log.info(`auth state=${state} tiles=${tileCount}`);
  }

  return { state, tileCount };
}
