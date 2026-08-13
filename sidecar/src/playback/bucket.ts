/**
 * Re-mint the resolve session when YouTube hands back a poisoned one.
 *
 * **The problem, measured (F20).** About 27% of resolve sessions are minted into
 * a YouTube experiment bucket whose stream URLs refuse ffmpeg's open-ended
 * `Range: bytes=0-` with `403` — on every rung of the ladder and on the audio
 * track too, for the life of the session. mpv cannot play such a URL at all, so
 * roughly one launch in four showed no video. The bucket is stamped into the
 * URL as an `fexp` flag, which is the whole reason this is fixable: the sidecar
 * already holds the URL, so detection costs nothing and no extra request.
 *
 * **Why re-minting works.** Measured over 90 sessions: replacing a flagged
 * session clears it 18/24 = 75% of the time, against 73.3% predicted if each
 * mint were an independent draw at the 26.7% base rate. Within that sample the
 * replacement carries no memory of the session it replaced — so this is a
 * retry with real odds, not a loop.
 */

import { logger } from '../log.ts';
import { messageOf } from '../errors.ts';
import { forgetPlayerResponse } from '../innertube/player-response.ts';
import type { Session } from '../innertube/session.ts';
import type { OpenParams, PlaybackDeps } from './resolve.ts';
import { openPlayback } from './resolve.ts';
import type { PlaybackSource } from '../types.ts';

const log = logger('playback');

/**
 * The `fexp` experiment flags whose mints refuse ffmpeg's request shape.
 *
 * **A list, and expected to change.** YouTube can retire `51946838` or ship a
 * sibling under a new number at any time, and neither event announces itself.
 * **The symptom of this list going stale is the 26.7% failure rate returning
 * silently** — launches that resolve fine and never show a picture, with no
 * error anywhere, exactly as before this existed. If that is ever reported
 * again, re-run `sidecar/exe-bucket-probe.ts`: it samples the rate in about two
 * seconds per session without launching Flutter, and diffing the `fexp` of a
 * failing mint against a healthy one is how `51946838` was found in the first
 * place.
 */
export const POISONED_FEXP_FLAGS: readonly string[] = ['51946838'];

/**
 * How many times to re-mint before giving up and resolving anyway.
 *
 * Each attempt is an independent draw at the 26.7% base rate, so the residual
 * failure rate is `0.267 ^ (attempts)`:
 *
 * | re-mints | residual failure | added cost when it is needed |
 * |---------:|-----------------:|-----------------------------:|
 * |        0 |            26.7% |                            — |
 * |        1 |             7.1% |                       ~170 ms |
 * |    **2** |         **1.9%** |                   **~340 ms** |
 * |        3 |             0.5% |                       ~510 ms |
 *
 * Two, deliberately: the third attempt buys 1.4 percentage points for another
 * ~170 ms and a branch nobody will ever see fire. The cost is only paid by the
 * ~27% of opens that need it; a healthy mint takes this path in zero extra time.
 * Change this number and you are trading that table — which is why it is here
 * rather than inline.
 */
export const MAX_REMINTS = 2;

/**
 * Is this failure YouTube telling us to slow down rather than a flagged mint?
 *
 * **The distinction is load-bearing, and it was learned the expensive way.** A
 * measurement run of ~180 anonymous resolutions inside an hour tripped YouTube's
 * anti-bot throttle, and every tier of the ladder then declined with
 * `LOGIN_REQUIRED — Sign in to confirm you're not a bot`. That is not a bucket
 * problem and a re-mint cannot fix it: each one spends a fresh visitor-id fetch
 * plus another `/player` against the very limit that is already refusing, which
 * makes the throttle worse and the recovery slower.
 *
 * So a throttle **stops** the retry rather than driving it. `LOGIN_REQUIRED` is
 * also what F5 records for a fabricated visitor id, and tier 1 already mints a
 * fresh one and re-asks once on any non-`OK` response (§2.3) — so by the time
 * this sees it, one retry has already been spent.
 */
export function isThrottleSignal(error: unknown): boolean {
  return /LOGIN_REQUIRED|not a bot/i.test(messageOf(error));
}

/** The `fexp` flags a resolved URL was minted under. */
function fexpOf(url: string): string[] {
  try {
    return (new URL(url).searchParams.get('fexp') ?? '').split(',').filter(Boolean);
  } catch {
    // A URL that will not parse is not a bucketing problem, and guessing that it
    // is would spend two re-mints on something they cannot fix.
    return [];
  }
}

/**
 * Was this source minted into a poisoned bucket?
 *
 * Read from the top variant: the flag is a property of the whole `/player`
 * response, and F20 measured every rung of a flagged mint refusing alike — so
 * one URL answers for all of them, and checking more would be theatre.
 */
export function isPoisonedMint(source: PlaybackSource): boolean {
  const url = source.variants[0]?.videoUrl;
  if (!url) return false;
  const flags = fexpOf(url);
  return POISONED_FEXP_FLAGS.some((flag) => flags.includes(flag));
}

export interface RemintDeps extends PlaybackDeps {
  /**
   * Drop the current **resolve** session and mint a replacement.
   *
   * Resolve only. The browse session is `WEB` with cookies and has nothing to do
   * with this bucket; re-minting it would drop the user's authentication on a
   * quarter of launches, which is a worse failure than the one being fixed and
   * a much quieter one — a degraded session answers HTTP 200 with an empty feed
   * (F7, hard invariant 5).
   */
  remintResolveSession: () => Promise<Session>;
}

/**
 * `openPlayback`, retrying past a poisoned mint.
 *
 * The `/player` cache is dropped for this video between attempts — without that
 * the retry is served the same poisoned response from memory and the new session
 * never reaches YouTube, which is the shape of the first recovery attempt F20
 * recorded as useless.
 *
 * On exhausting the cap it returns the poisoned source rather than throwing:
 * `MediaKitEngine`'s fast-fail surfaces the refusal in under two seconds, which
 * is the honest floor and better than inventing an error code for a video that
 * might yet play.
 */
export async function openPlaybackPastBucket(
  deps: RemintDeps,
  params: OpenParams,
  /**
   * The resolve itself, injectable so the retry can be tested without a network.
   * A test that had to reach YouTube to prove the cap is respected would be a
   * test of YouTube.
   */
  resolve: (deps: PlaybackDeps, params: OpenParams) => Promise<PlaybackSource> = openPlayback,
): Promise<PlaybackSource> {
  let session = deps.session;
  let source = await resolve({ ...deps, session }, params);

  for (let attempt = 1; attempt <= MAX_REMINTS; attempt++) {
    if (!isPoisonedMint(source)) return source;

    log.info(
      `${params.videoId}: mint is in a poisoned bucket ` +
        `(fexp ${POISONED_FEXP_FLAGS.join('/')}) — re-minting the resolve session, ` +
        `attempt ${attempt} of ${MAX_REMINTS}`,
    );

    session = await deps.remintResolveSession();
    forgetPlayerResponse(params.videoId);
    try {
      source = await resolve({ ...deps, session }, params);
    } catch (error) {
      // **Re-mint only on a detected flagged mint, never on a failure.** A
      // throw here means the ladder declined outright, and the loop must not
      // spend its remaining attempts on it — a throttled resolve answers the
      // same way however many sessions it is asked from.
      if (isThrottleSignal(error)) {
        log.warn(
          `${params.videoId}: resolve refused with a throttle signal after re-mint ` +
            `${attempt} — not re-minting again`,
        );
      }
      throw error;
    }
  }

  if (isPoisonedMint(source)) {
    // Deliberately not an error. The stream may still play — the refusal is of
    // ffmpeg's request shape, and nothing here has proven mpv will be refused
    // this time. Fast-fail will say so in ~2 s if it is.
    log.warn(
      `${params.videoId}: still in a poisoned bucket after ${MAX_REMINTS} re-mints — ` +
        'resolving anyway; playback will fail fast if the URL is refused',
    );
  }

  return source;
}
