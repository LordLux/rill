/**
 * Player JS retrieval and deciphering.
 *
 * YouTube's player script obfuscates two things: the `s` signature parameter and
 * the `n` throttling parameter. `n` is the one that matters — an undeciphered
 * `n` is not rejected, it is *served slowly*, at roughly 50 KB/s, which reaches
 * the user as constant buffering and reaches us as a bug report about their
 * internet. Nothing in the pipeline errors.
 *
 * Two rules follow from that, and both are implemented here:
 *
 *   1. **The interpreter shim must be installed.** youtubei.js ships no JS
 *      evaluator (`jsruntime/default.js` throws), so `Platform.shim.eval` has to
 *      be provided by us. `session.ts` installs it; we call it again here
 *      because a decipher without it fails loudly, and a decipher with a *stale*
 *      one fails silently.
 *
 *   2. **The cache is keyed by `playerId` and expires.** YouTube ships new
 *      player revisions on its own schedule. Deciphering a fresh `n` with an old
 *      script produces a plausible-looking string that throttles exactly like no
 *      decipher at all — so a cache with no expiry does not degrade, it breaks,
 *      invisibly. Past the TTL we re-check which player YouTube is currently
 *      serving and rebuild if it moved.
 *
 * When the refreshed player differs from the one the session was created with,
 * we install it on the session too. `signatureTimestamp` in a `/player` payload
 * has to describe the same script we decipher against; letting those two drift
 * is how you get `UNPLAYABLE` on a video that plays fine in a browser.
 */

import { Player as JsPlayer } from 'youtubei.js';

import { logger } from '../log.ts';
import { RpcError } from '../errors.ts';
import { installInterpreter, type Session } from './session.ts';

const log = logger('player');

/**
 * How long a built player is trusted before we re-check YouTube's current
 * revision. Short enough that a rollout costs one throttled session at worst,
 * long enough that it is not a per-video round trip.
 */
const PLAYER_TTL_MS = Number(process.env['SIDECAR_PLAYER_TTL_MS'] ?? 30 * 60_000);

/** Deciphered `n` values, memoised per player. Bounded; see `remember`. */
const NSIG_CACHE_LIMIT = 512;

/**
 * The signature and `n` transforms of one specific player revision.
 *
 * Both are async because the underlying evaluation goes through
 * `Platform.shim.eval`, which youtubei.js declares as possibly-promise-returning
 * and awaits internally. Nothing here can be made synchronous without forking
 * the library's decipher path.
 */
export interface Player {
  /** The 8-hex-digit revision id, e.g. `3bb1f723`. The cache key. */
  readonly playerId: string;
  /**
   * The `sts` value this script deciphers against. Mandatory on every raw
   * `/player` call — see `playerPayload` in `session.ts`.
   */
  readonly signatureTimestamp: number;
  /** `s` → the value to place in the `sp`-named query parameter. */
  decipherSignature(s: string, sp: string): Promise<string>;
  /** `n` → the deciphered `n`. Returning the input unchanged is a failure. */
  decipherN(n: string): Promise<string>;
}

interface CacheEntry {
  player: Player;
  source: JsPlayer;
  /** When this entry was last confirmed to be YouTube's current revision. */
  checkedAt: number;
}

const cache = new Map<string, CacheEntry>();
/** In-flight refreshes, so N concurrent opens cost one player download. */
let refreshing: Promise<CacheEntry> | null = null;

// ---------------------------------------------------------------------------
// Building a handle
// ---------------------------------------------------------------------------

/**
 * A URL that exists only to be handed back to us.
 *
 * `JsPlayer.decipher` works on URLs, not on bare values, so both primitives put
 * their input into a throwaway URL and read the transformed value back out. The
 * host is never contacted.
 */
const MOCK_URL = 'https://ytjs.googlevideo.com/videoplayback?expire=1234567890';

function remember(memo: Map<string, string>, key: string, value: string): void {
  if (memo.size >= NSIG_CACHE_LIMIT) memo.clear();
  memo.set(key, value);
}

function buildHandle(source: JsPlayer): Player {
  // youtubei.js writes deciphered `n` values into this map and reads them back,
  // so passing the same one to every call memoises across formats. Adaptive
  // responses repeat `n` across the whole format list, so this is most of the
  // per-video decipher cost.
  const nsigMemo = new Map<string, string>();

  return {
    playerId: source.player_id,
    signatureTimestamp: source.signature_timestamp,

    async decipherSignature(s, sp) {
      const cipher = new URLSearchParams({ s, sp, url: MOCK_URL }).toString();
      const out = await source.decipher(undefined, cipher);
      const value = new URL(out).searchParams.get(sp || 'signature');
      if (!value) {
        throw new RpcError(
          'STREAM_UNAVAILABLE',
          `player ${source.player_id} returned no signature for s=${s.slice(0, 12)}…`,
        );
      }
      return value;
    },

    async decipherN(n) {
      const cached = nsigMemo.get(n);
      if (cached) return cached;

      const out = await source.decipher(`${MOCK_URL}&n=${encodeURIComponent(n)}`);
      const value = new URL(out).searchParams.get('n');
      if (!value) {
        throw new RpcError(
          'STREAM_UNAVAILABLE',
          `player ${source.player_id} returned no n for n=${n}`,
        );
      }
      remember(nsigMemo, n, value);
      return value;
    },
  };
}

// ---------------------------------------------------------------------------
// Revision checking
// ---------------------------------------------------------------------------

/**
 * The player revision YouTube is serving right now.
 *
 * `/iframe_api` is a few kilobytes and names the current player in an escaped
 * path (`player\/3bb1f723\/`). Reading it is far cheaper than downloading and
 * re-analysing the ~2 MB `base.js`, which is the whole point: most TTL expiries
 * find the same revision and cost one small GET.
 */
async function currentPlayerId(): Promise<string | null> {
  try {
    const response = await fetch('https://www.youtube.com/iframe_api');
    if (!response.ok) {
      log.warn(`could not read /iframe_api: HTTP ${response.status}`);
      return null;
    }
    const body = await response.text();
    return /player\\\/([\w-]+)\\\//.exec(body)?.[1] ?? null;
  } catch (error) {
    log.warn(`could not read /iframe_api: ${(error as Error).message}`);
    return null;
  }
}

/**
 * Download and analyse a player revision from scratch.
 *
 * This is the rollout branch: on a normal run `getPlayer` adopts the player the
 * session already retrieved, and this only fires once YouTube has shipped a new
 * revision — which means, left untested, its first ever execution would be on a
 * user's machine on the day the throttle would otherwise return. It is exported
 * so the suite can exercise it deliberately.
 */
export async function rebuildPlayer(session: Session, playerId?: string): Promise<Player> {
  return (await build(session, playerId)).player;
}

async function build(session: Session, playerId?: string): Promise<CacheEntry> {
  // No cache argument: a refresh that reads from disk is not a refresh.
  const source = await JsPlayer.create(undefined, undefined, undefined, playerId);
  const entry: CacheEntry = {
    player: buildHandle(source),
    source,
    checkedAt: Date.now(),
  };

  const sessionPlayer = session.innertube.session.player;
  if (sessionPlayer && sessionPlayer.player_id !== source.player_id) {
    // The session was created against an older revision. Its `sts` would now
    // describe a different script than the one we decipher with, and YouTube
    // answers that mismatch with UNPLAYABLE ("The page needs to be reloaded"),
    // which reads like a dead video.
    log.info(
      `player revision changed ${sessionPlayer.player_id} → ${source.player_id} ` +
        `(sts ${sessionPlayer.signature_timestamp} → ${source.signature_timestamp}); ` +
        'installing on the session',
    );
    session.innertube.session.player = source;
  }

  cache.set(source.player_id, entry);
  for (const [id, cached] of cache) {
    if (id !== source.player_id && Date.now() - cached.checkedAt > PLAYER_TTL_MS) {
      cache.delete(id);
    }
  }

  log.debug(`player ${source.player_id} ready (sts=${source.signature_timestamp})`);
  return entry;
}

async function refresh(session: Session, stale: CacheEntry): Promise<CacheEntry> {
  const live = await currentPlayerId();

  if (live === stale.player.playerId) {
    // Same revision, still good. Re-stamp rather than rebuild.
    stale.checkedAt = Date.now();
    return stale;
  }

  if (live === null) {
    // We could not find out. Keeping the old script risks the throttle;
    // discarding it guarantees no playback at all. Keep it, say so loudly, and
    // re-check on the next expiry.
    log.warn(
      `could not confirm the current player revision; continuing with ${stale.player.playerId}. ` +
        'If throughput drops to ~50 KB/s this is the first thing to suspect.',
    );
    stale.checkedAt = Date.now();
    return stale;
  }

  log.info(`player revision moved ${stale.player.playerId} → ${live}; rebuilding`);
  return build(session, live);
}

// ---------------------------------------------------------------------------

/**
 * The deciphering player for this session, built at most once per revision.
 *
 * The session already retrieved a player at creation (`retrieve_player: true`),
 * which is what we start from; past the TTL we ask YouTube which revision is
 * current and rebuild only if it moved.
 */
export async function getPlayer(session: Session): Promise<Player> {
  installInterpreter();

  const sessionPlayer = session.innertube.session.player;
  if (!sessionPlayer) {
    throw new RpcError(
      'STREAM_UNAVAILABLE',
      'this session has no JS player — it was created with retrievePlayer: false, ' +
        'so nothing can be deciphered through it',
    );
  }

  const existing = cache.get(sessionPlayer.player_id);

  if (!existing) {
    // First call for this revision. The session downloaded and analysed this
    // player when it was created, so it is current as of session creation —
    // adopting it costs nothing, where rebuilding would re-download ~2 MB of
    // `base.js` to arrive at the same script. The TTL runs from here.
    const adopted: CacheEntry = {
      player: buildHandle(sessionPlayer),
      source: sessionPlayer,
      checkedAt: Date.now(),
    };
    cache.set(sessionPlayer.player_id, adopted);
    log.debug(`adopted the session player ${sessionPlayer.player_id}`);
    return adopted.player;
  }

  if (Date.now() - existing.checkedAt < PLAYER_TTL_MS) {
    return existing.player;
  }

  // Collapse concurrent refreshes: a queue of video opens must not each go and
  // check the revision.
  refreshing ??= refresh(session, existing)
    .catch((error: unknown) => {
      log.warn(
        `player refresh failed (${(error as Error).message}); ` +
          `continuing with ${existing.player.playerId}`,
      );
      existing.checkedAt = Date.now();
      return existing;
    })
    .finally(() => {
      refreshing = null;
    });

  const entry = await refreshing;
  return entry.player;
}

/** Test seam — drops every cached player revision. */
export function resetPlayerCache(): void {
  cache.clear();
  refreshing = null;
}
