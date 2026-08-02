/**
 * The shared `/player` response.
 *
 * Two consumers need this call for different reasons and would otherwise each
 * make it:
 *
 *   - `video.info` needs the duration. A `/next` response does not carry one —
 *     it is only in `videoDetails.lengthSeconds`.
 *   - `playback.open` needs the formats.
 *
 * Opening a video does both, so without a cache every video open is two
 * `/player` round trips against an endpoint that is neither cheap nor
 * unmetered. One call, one entry, both consumers.
 *
 * The TTL is short on purpose. Stream URLs carry their own `expire` (typically
 * ~6 h), but playability is not fixed — a video can be pulled, age-gated, or
 * region-blocked between one open and the next, and a long-lived cache would
 * keep serving the old answer.
 */

import { logger } from '../log.ts';
import { parsePlayer } from '../parser/player.ts';
import type { PlayerResult } from '../types.ts';
import { PLAYER_CLIENTS, playerPayload, type PlayerClient, type Session } from './session.ts';

const log = logger('player-response');

const TTL_MS = Number(process.env['SIDECAR_PLAYER_RESPONSE_TTL_MS'] ?? 5 * 60_000);
/** Roughly a queue's worth of preloads plus what the user has open. */
const MAX_ENTRIES = 64;

export type { PlayerClient };

interface Entry {
  result: PlayerResult;
  raw: unknown;
  fetchedAt: number;
}

const cache = new Map<string, Entry>();
const inFlight = new Map<string, Promise<Entry>>();

function keyFor(videoId: string, client: PlayerClient): string {
  return `${client}:${videoId}`;
}

/** Insertion-ordered eviction — oldest key first, which is close enough to LRU here. */
function evictIfFull(): void {
  while (cache.size > MAX_ENTRIES) {
    const oldest = cache.keys().next();
    if (oldest.done) return;
    cache.delete(oldest.value);
  }
}

async function fetchPlayer(
  session: Session,
  videoId: string,
  client: PlayerClient,
): Promise<Entry> {
  // `playerPayload` carries the signatureTimestamp. Hard invariant 7: without it
  // YouTube answers UNPLAYABLE — "The page needs to be reloaded." — which reads
  // like a dead or region-locked video and is neither.
  const raw = await session.execute('/player', playerPayload(session, videoId, client));
  const result = parsePlayer(raw);

  log.debug(
    `${client} ${videoId}: status=${result.playabilityStatus ?? '?'} ` +
      `formats=${result.formats.length} sabrOnly=${result.sabrOnly}`,
  );

  return { result, raw, fetchedAt: Date.now() };
}

export interface PlayerRequestOptions {
  /**
   * Ignore any cached or in-flight answer and ask YouTube again.
   *
   * For ladder tier 1's `LOGIN_REQUIRED` retry: the point of the retry is that
   * the session now carries a different visitor id, and both the cached refusal
   * and a request already on the wire were made under the old one.
   */
  refresh?: boolean;
}

/**
 * The parsed `/player` response for this video and client, from cache when
 * fresh.
 *
 * Concurrent callers for the same key share one request — `video.info` and
 * `playback.open` racing on the same video open is the common case, not the
 * edge case.
 */
export async function getPlayerResponse(
  session: Session,
  videoId: string,
  client: PlayerClient,
  options: PlayerRequestOptions = {},
): Promise<PlayerResult> {
  return (await getPlayerEntry(session, videoId, client, options)).result;
}

/** As `getPlayerResponse`, but also exposes the raw body for fixture capture. */
export async function getPlayerEntry(
  session: Session,
  videoId: string,
  client: PlayerClient,
  options: PlayerRequestOptions = {},
): Promise<{ result: PlayerResult; raw: unknown }> {
  const key = keyFor(videoId, client);

  if (options.refresh) {
    cache.delete(key);
  } else {
    const cached = cache.get(key);
    if (cached && Date.now() - cached.fetchedAt < TTL_MS) return cached;

    const pending = inFlight.get(key);
    if (pending) return pending;
  }

  const request = fetchPlayer(session, videoId, client)
    .then((entry) => {
      cache.set(key, entry);
      evictIfFull();
      return entry;
    })
    .finally(() => {
      // Only if it is still ours. A `refresh` call replaces the entry for a key
      // that may already have a request on the wire, and the older one settling
      // must not clear the newer one's slot — that would leave the next caller
      // starting a third request instead of joining the second.
      if (inFlight.get(key) === request) inFlight.delete(key);
    });

  inFlight.set(key, request);
  return request;
}

/** Test seam, and the hook `playback.close` will use to release a video's entry. */
export function forgetPlayerResponse(videoId?: string): void {
  if (videoId === undefined) {
    cache.clear();
    return;
  }
  for (const client of PLAYER_CLIENTS) cache.delete(keyFor(videoId, client));
}
