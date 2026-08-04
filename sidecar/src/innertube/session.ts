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

import { RpcError } from '../errors.ts';
import { logger } from '../log.ts';
import type { AuthState, AuthVerification } from '../types.ts';

const log = logger('session');

export interface Session {
  readonly innertube: Innertube;
  /** True when a cookie was supplied. Says nothing about server acceptance — see `verifyAuth`. */
  readonly hasCookie: boolean;
  /**
   * The visitor id this session currently presents, as `X-Goog-Visitor-Id` and
   * in `context.client.visitorData`. Reads live, so it reflects a
   * `refreshVisitorId` call rather than the value the session was born with.
   */
  readonly visitorId: string | null;
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
  /**
   * The session's base context: `WEB` for browsing and reporting (F3/F6).
   *
   * Stream resolution passes `MWEB` here, but the client that matters is the one
   * named per `/player` call — tier 1 asks as `ANDROID_VR` through this same
   * session, and youtubei.js rewrites `context.client` before sending.
   */
  clientType?: 'WEB' | 'MWEB';
  /** Required for decipher. Only turn off for captures that never touch /player. */
  retrievePlayer?: boolean;
  /** A stale cached session survives a cookie rotation and hides F7. Off by default. */
  cache?: boolean;
  /**
   * Fetch the visitor id from YouTube instead of fabricating one locally.
   *
   * On by default, and the reason is F5: `ANDROID_VR` — ladder tier 1 — answers
   * `LOGIN_REQUIRED / "Sign in to confirm you're not a bot"` to a fabricated id
   * on about 93% of attempts, and `OK` to a server-issued one 13/13. A cookie
   * session already fetched one (youtubei.js used `generate_session_locally:
   * !cookie`), so this changes anonymous sessions only — which are exactly the
   * sessions streams resolve through.
   *
   * The cost is one `/sw.js_data` round trip at creation. Turn it off only to
   * reproduce the fabricated-id failure deliberately.
   */
  serverVisitorId?: boolean;
}

/**
 * Above this, the id came from YouTube; below it, youtubei.js made it up.
 *
 * F5 measured the two: `generate_session_locally: true` produces a 32-character
 * fabricated id, and a server-issued one is ~558 characters. There is no flag on
 * the session saying which you got — youtubei.js falls back to fabricating one
 * when `/sw.js_data` fails and does not raise — so length is the only signal
 * available, and it is not a close call.
 */
const SERVER_VISITOR_ID_MIN_LENGTH = 64;

function readVisitorId(innertube: Innertube): string | null {
  return innertube.session.context.client.visitorData ?? null;
}

export async function createSession(options: SessionOptions | string = {}): Promise<Session> {
  const opts: SessionOptions = typeof options === 'string' ? { cookie: options } : options;
  const {
    cookie,
    clientType = 'WEB',
    retrievePlayer = true,
    cache = false,
    serverVisitorId = true,
  } = opts;

  installInterpreter();

  const innertube = await Innertube.create({
    ...(cookie ? { cookie } : {}),
    client_type: clientType === 'MWEB' ? ClientType.MWEB : ClientType.WEB,
    device_category: 'desktop',
    retrieve_player: retrievePlayer,
    enable_session_cache: cache,
    ...(cache ? { cache: new UniversalCache(true, './.cache') } : {}),
    generate_session_locally: !serverVisitorId,
  });

  const visitorId = readVisitorId(innertube);

  log.info(
    `session created client=${clientType} cookie=${cookie ? 'yes' : 'no'} ` +
      `sts=${innertube.session.player?.signature_timestamp ?? 'n/a'} ` +
      `visitor=${visitorId?.length ?? 0}ch`,
  );

  if (serverVisitorId && !isServerIssued(visitorId)) {
    // youtubei.js swallows a `/sw.js_data` failure and fabricates an id instead,
    // so this is the only place the fallback becomes visible. Not fatal: tier 1
    // retries with a fresh id when YouTube refuses (F5's 2/28 says a fabricated
    // id is a bad bet, not a certain refusal).
    log.warn(
      `visitor id looks locally generated (${visitorId?.length ?? 0} chars); ` +
        'YouTube refuses those on ~93% of ANDROID_VR resolutions (F5)',
    );
  }

  return {
    innertube,
    hasCookie: Boolean(cookie),
    get visitorId() {
      return readVisitorId(innertube);
    },
    async execute(endpoint, params = {}) {
      // parse:false is not negotiable — see F2.
      const response = await innertube.actions.execute(endpoint, { ...params, parse: false });
      const body = response as { data?: unknown };
      return body?.data ?? response;
    },
  };
}

// ---------------------------------------------------------------------------
// Visitor ids
// ---------------------------------------------------------------------------

function isServerIssued(visitorId: string | null): boolean {
  return visitorId !== null && visitorId.length >= SERVER_VISITOR_ID_MIN_LENGTH;
}

/**
 * A fresh server-issued visitor id.
 *
 * Bootstraps a throwaway session with everything expensive turned off — no
 * player, no InnerTube config — so what is left is the one `/sw.js_data` fetch
 * that returns the id. `fail_fast` matters: without it youtubei.js answers a
 * failed fetch with a fabricated id and no error, which is the failure this
 * function exists to avoid handing back.
 */
export async function mintVisitorId(): Promise<string> {
  const innertube = await Innertube.create({
    client_type: ClientType.WEB,
    device_category: 'desktop',
    retrieve_player: false,
    retrieve_innertube_config: false,
    enable_session_cache: false,
    generate_session_locally: false,
    fail_fast: true,
  });

  const visitorId = readVisitorId(innertube);
  if (!isServerIssued(visitorId)) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `minted a visitor id of ${visitorId?.length ?? 0} chars — that is a locally ` +
        'fabricated one, not the server-issued id ANDROID_VR needs (F5)',
    );
  }
  return visitorId!;
}

/**
 * Mint a fresh visitor id and install it on `session`.
 *
 * youtubei.js reads `context.client.visitorData` per request — for the
 * `X-Goog-Visitor-Id` header and for the body context it deep-copies — so
 * assigning it re-identifies every subsequent call on this session. Nothing else
 * about the session changes.
 *
 * Used by ladder tier 1 when YouTube answers `LOGIN_REQUIRED`. F5 puts a
 * fabricated id at 2/28 rather than 0/28, so the refusal is a probabilistic bot
 * score and not a rule — which makes exactly one retry with a new identity worth
 * the round trip, and a second one superstition.
 */
export async function refreshVisitorId(session: Session): Promise<string> {
  const previous = session.visitorId;
  const visitorId = await mintVisitorId();
  session.innertube.session.context.client.visitorData = visitorId;
  log.info(`visitor id refreshed (${previous?.length ?? 0}ch → ${visitorId.length}ch)`);
  return visitorId;
}

// ---------------------------------------------------------------------------
// Player requests
// ---------------------------------------------------------------------------

/**
 * The clients the sidecar issues `/player` calls as.
 *
 * `ANDROID_VR` is ladder tier 1 (F5, F11): plain URLs with no `n`, ranges and
 * bare GETs accepted, and it seeks on the libmpv media_kit ships. `MWEB` is
 * tier 2 and the only client with a proven decipher path. `WEB` is here because
 * `video.info` reads durations from it, not because anything streams from it —
 * F3 has it SABR-only.
 */
export type PlayerClient = 'WEB' | 'MWEB' | 'ANDROID_VR';

/** Every value of `PlayerClient`, for anything that has to sweep them all. */
export const PLAYER_CLIENTS: readonly PlayerClient[] = ['WEB', 'MWEB', 'ANDROID_VR'];

/**
 * The payload a raw `/player` call needs.
 *
 * `{ videoId }` alone is not enough: YouTube answers
 * `UNPLAYABLE — "The page needs to be reloaded."`, which reads like a broken
 * video rather than a malformed request. The signature timestamp is the piece
 * that matters — it tells the server which player JS the client deciphered
 * against, and without it no streaming data is returned at all.
 *
 * `client` swaps the request context: youtubei.js rewrites `context.client` to
 * that client's identity before sending (F3: browse as `WEB`, resolve as
 * `ANDROID_VR`). `signatureTimestamp` is sent for every client, including the
 * ones whose formats need no deciphering — it describes the player script, not
 * the caller, and spike 03 measured `ANDROID_VR` passing with it.
 */
export function playerPayload(
  session: Session,
  videoId: string,
  client?: PlayerClient,
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
 *
 * `fetchHome` exists so a caller that is about to fetch the same home feed can
 * hand over a shared (briefly cached) fetch instead of paying for a second
 * identical /browse. It must stay inside the try: a fetch failure is a session
 * health signal, not an RPC error.
 */
export async function verifyAuth(
  session: Session,
  fetchHome: (session: Session) => Promise<unknown> = (s) =>
    s.execute('/browse', { browseId: 'FEwhat_to_watch' }),
): Promise<AuthVerification> {
  let tileCount = 0;

  try {
    const raw = await fetchHome(session);
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
