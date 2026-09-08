/**
 * The Phase 2 trigger.
 *
 * Phase 1 exists because `MWEB` still hands out plain adaptive URLs while `WEB`
 * has gone SABR-only (F3). That is a dated observation about YouTube's policy,
 * not a property of the protocol — the day `MWEB` follows `WEB`, tier 2 of the
 * resolution ladder stops working and the SABR → DASH bridge stops being
 * deferrable. Tier 1 resolves as `VISIONOS` and is a separate bet with a
 * separate expiry date; this one is about `MWEB`.
 *
 * This function is how we find that out from a failing test rather than from a
 * user reporting that everything is 360p.
 *
 * ## Defined over adaptive formats only
 *
 * This is the whole subtlety, and getting it wrong is silent (F9). A SABR-only
 * `WEB` response carries 40 adaptive formats with neither a URL nor a cipher —
 * *and* a working itag 18 progressive stream at 360p. Define "SABR-only" over
 * every format and that one 360p URL makes the answer `false`: the ladder skips
 * its SABR branch, a plain tier finds a playable format, and the client serves 360p
 * forever while every check reports healthy.
 */

import type { PlayerFormat, PlayerResult } from '../types.ts';

/**
 * The primitive, over an already-filtered adaptive list.
 *
 * Exported so `parsePlayer` can populate `PlayerResult.sabrOnly` from the same
 * definition rather than a second copy of it — two implementations of this rule
 * would eventually disagree, and the disagreement would be invisible.
 */
export function isSabrOnlyAdaptive(adaptive: readonly PlayerFormat[]): boolean {
  return (
    adaptive.length > 0 && adaptive.every((f) => f.rawUrl === null && f.signatureCipher === null)
  );
}

/**
 * True when the response's adaptive ladder is reachable only over SABR.
 *
 * Takes the parsed response rather than the raw JSON: `parsePlayer` is total and
 * already the one place that knows the field names, and this way there is no
 * second tolerant reader of `streamingData` to keep in step.
 */
export function isSabrOnly(playerResponse: PlayerResult): boolean {
  return isSabrOnlyAdaptive(playerResponse.formats.filter((format) => format.isAdaptive));
}
