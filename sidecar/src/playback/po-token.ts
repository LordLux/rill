/**
 * Proof-of-origin tokens — the seam, not the implementation.
 *
 * A PO token is a BotGuard attestation proving the request came from a real
 * client. Anonymous `MWEB` does not currently require one, which is the only
 * reason Phase 1 can resolve streams with no browser in the process at all.
 *
 * That is a policy, and policies move. When it moves, the fix should be writing
 * one class that implements this interface and passing it to `openPlayback` —
 * not threading a new parameter through the resolution ladder under time
 * pressure, which is what building it later without the seam would mean.
 *
 * Deliberately unimplemented. A speculative BotGuard runner is a large, fragile
 * dependency to carry for a requirement that does not exist yet.
 */

export interface PoTokenProvider {
  /**
   * A token for this video, or `null` when none is needed or none can be
   * obtained. Returning `null` must always be safe: the caller treats it as
   * "carry on without one".
   */
  mint(videoId: string): Promise<string | null>;
}

/** The Phase 1 provider. Mints nothing, never fails. */
export const nullPoTokenProvider: PoTokenProvider = {
  mint: async () => null,
};
