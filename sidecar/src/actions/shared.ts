/**
 * Helpers shared by every write action (`protocol.md` §3.4) — `playlist.ts`
 * and `interaction.ts` both need the same two checks, and duplicating them
 * verbatim is how the two drift apart the day one gets a fix the other doesn't.
 */

import { RpcError } from '../errors.ts';
import type { Session } from '../innertube/session.ts';
import { get, str } from '../parser/tree.ts';

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
export function requireCookie(session: Session, method: string): void {
  if (session.hasCookie) return;
  throw new RpcError('AUTH_REQUIRED', `${method} needs a signed-in session`);
}

/**
 * Did the edit take?
 *
 * A handful of these write endpoints answer HTTP 200 with `status:
 * "STATUS_FAILED"` when they refuse — a private playlist, a video that cannot
 * be added, a session the server has stopped honouring. Treating 200 as
 * success is the F7 shape again: an operation that reports fine and did
 * nothing. Not every endpoint here is confirmed to carry a `status` field
 * (some may not), so a response with none is treated as success rather than
 * as `BAD_REQUEST` — `str` answers `null` for a missing field, and this only
 * objects when a `status` is present and says otherwise.
 */
export function assertSucceeded(response: unknown, description: string): void {
  const status = str(get(response, 'status'));
  if (status !== null && status !== 'STATUS_SUCCEEDED') {
    throw new RpcError('UPSTREAM_ERROR', `${description}: YouTube answered ${status}`);
  }
}
