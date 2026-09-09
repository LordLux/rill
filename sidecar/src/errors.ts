/**
 * The error codes from `protocol.md` §4, as a throwable.
 *
 * Two of these are load-bearing rather than cosmetic:
 *
 *   - `STREAM_REQUIRES_SABR` is internal. It is how a resolution tier tells the
 *     ladder "not my case, keep going"; it must never reach Flutter.
 *   - `STREAM_UNAVAILABLE` is what the ladder throws once every tier has
 *     declined. It is the only stream error the UI is meant to render.
 */

/**
 * Codes that can reach Flutter in a failure envelope. Each one has a `retry`.
 */
export type EnvelopeErrorCode =
  | 'AUTH_DEGRADED'
  | 'AUTH_REQUIRED'
  /** Unknown method, or params that failed validation. The caller is at fault. */
  | 'BAD_REQUEST'
  | 'STREAM_UNAVAILABLE'
  /**
   * The video exists and is fine; it has not premiered yet.
   *
   * Distinct from `STREAM_UNAVAILABLE` because it is not a failure to resolve —
   * there is nothing to resolve until the scheduled time, and no rung of the
   * ladder will ever produce one. Collapsing the two put a premiere behind
   * "This video would not open" with a *Try again* button that could only fail
   * for the next nine days.
   */
  | 'VIDEO_UPCOMING'
  /**
   * The video exists and is fine; it is behind the channel's membership.
   *
   * The same shape as `VIDEO_UPCOMING` and for the same reason: no rung of the
   * ladder can resolve it, so declining down all four spends four `/player`
   * calls to reach a worse-worded version of the answer tier 1 already gave.
   * `no` because retrying cannot buy a membership.
   *
   * Kept separate from `AUTH_REQUIRED`, which means "sign in" — signing in does
   * not help here, and on a members-only video the user is *already* signed in
   * more often than not.
   */
  | 'VIDEO_MEMBERS_ONLY'
  | 'RATE_LIMITED'
  | 'UPSTREAM_ERROR';

/**
 * Codes that are control flow inside the sidecar and never cross the wire.
 *
 * They are deliberately *not* given a `retry` value. Marking them `no` would put
 * them in the same column as `AUTH_DEGRADED` and quietly claim something about
 * what the app should do with an error the app never receives — and a value that
 * is inert today is exactly the kind that gets read as meaningful later, by
 * whoever builds the RPC layer and sees three codes marked alike.
 */
export type InternalSignalCode =
  /** A tier telling the ladder "not my case, keep going". Never surfaced. */
  | 'STREAM_REQUIRES_SABR'
  /** One unrecognised renderer, skipped. Never fails a whole response. */
  | 'PARSE_FAILED';

export type ErrorCode = EnvelopeErrorCode | InternalSignalCode;

/**
 * Who, if anyone, should try again.
 *
 * Three values rather than a boolean, because `retryable: true` answered two
 * different questions with one bit — *should the sidecar retry* and *should the
 * user be offered a retry* — and the UI contract turns on the difference.
 */
export type RetryMode =
  /**
   * The app retries with backoff and shows loading, not an error.
   *
   * The app, not the sidecar (`protocol.md` §4). A sidecar-side retry cannot be
   * superseded: a filter switch mid-retry leaves it working on a request nobody
   * wants, with `$cancel` arriving while it sleeps between attempts.
   */
  | 'auto'
  /** Show the error with a retry affordance. Never loop silently. */
  | 'user'
  /** Retrying changes nothing until a login, a cookie or a policy changes. */
  | 'no';

/**
 * Retry behaviour is a property of the code, not of the throw site.
 *
 * Deriving it here rather than passing a flag per `throw` means two
 * `STREAM_UNAVAILABLE`s cannot disagree about whether the user may retry — which
 * is the sort of drift nobody notices until the UI behaves differently depending
 * on which line threw.
 */
const RETRY_BY_CODE: Readonly<Record<EnvelopeErrorCode, RetryMode>> = Object.freeze({
  AUTH_DEGRADED: 'no',
  AUTH_REQUIRED: 'no',
  // The only `no` that is a certainty rather than a judgement: the same bytes
  // will fail the same way forever. Retrying a client bug just hides it behind a
  // spinner, which is what `UPSTREAM_ERROR` (`auto`) used to do to it.
  BAD_REQUEST: 'no',
  // The ladder's floor is a very good bet, not a promise (F9, `protocol.md`
  // §3.5): every rung can decline for a video that is fine. So the user gets an
  // affordance — but not a silent loop, which on a genuinely deleted video would
  // spend requests to keep showing a spinner instead of the honest answer.
  STREAM_UNAVAILABLE: 'user',
  // `no`, and for once that is a statement about the clock rather than about
  // policy: retrying before the scheduled time cannot succeed, and the UI has
  // something better than a retry button to offer — the date and a reminder.
  VIDEO_UPCOMING: 'no',
  VIDEO_MEMBERS_ONLY: 'no',
  RATE_LIMITED: 'auto',
  UPSTREAM_ERROR: 'auto',
});

/** The two codes that never reach an envelope. Kept next to the table above. */
const INTERNAL_SIGNALS: ReadonlySet<string> = new Set<InternalSignalCode>([
  'STREAM_REQUIRES_SABR',
  'PARSE_FAILED',
]);

export function isInternalSignal(code: ErrorCode): code is InternalSignalCode {
  return INTERNAL_SIGNALS.has(code);
}

export class RpcError extends Error {
  readonly code: ErrorCode;
  /**
   * What the app should do — or `null` for an internal signal, which the app
   * never sees and therefore has no instruction about.
   */
  readonly retry: RetryMode | null;

  constructor(code: ErrorCode, message: string) {
    super(message);
    this.name = 'RpcError';
    this.code = code;
    this.retry = isInternalSignal(code) ? null : RETRY_BY_CODE[code];
  }

  /**
   * The `error` member of a JSON-RPC failure envelope.
   *
   * Throws on an internal signal rather than inventing a `retry` for it. That is
   * not defensive noise: `protocol.md` §4 says `STREAM_REQUIRES_SABR` reaching
   * Flutter is a bug, and this is the one place that can still notice. A thrown
   * error costs one request; a `STREAM_REQUIRES_SABR` envelope would have the UI
   * rendering an error code that means "keep going" and nobody able to explain
   * where it came from.
   */
  toEnvelope(): { code: EnvelopeErrorCode; message: string; retry: RetryMode } {
    if (isInternalSignal(this.code)) {
      throw new Error(
        `${this.code} is an internal signal and must never cross the RPC boundary ` +
          `(protocol.md §4). Message was: ${this.message}`,
      );
    }
    return { code: this.code, message: this.message, retry: RETRY_BY_CODE[this.code] };
  }
}

export function isRpcError(error: unknown): error is RpcError {
  return error instanceof RpcError;
}

/** True when `error` is an `RpcError` carrying `code`. */
export function hasCode(error: unknown, code: ErrorCode): boolean {
  return isRpcError(error) && error.code === code;
}

/** The retry mode for an envelope code, for anything that needs it without an instance. */
export function retryModeFor(code: EnvelopeErrorCode): RetryMode {
  return RETRY_BY_CODE[code];
}

/**
 * A message out of an unknown thrown value.
 *
 * `catch (e)` is `unknown` under `strict`, and it really can be anything —
 * `throw 'string'` is legal, and a rejected fetch can hand back a `DOMException`.
 * Typing the catch as `any` to reach `.message` trades a compile error for a
 * runtime `undefined` in a log line written precisely when something has already
 * gone wrong.
 */
export function messageOf(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'string') return error;
  return String(error);
}

/** The `name` of an unknown thrown value, for `AbortError` and friends. */
export function nameOf(error: unknown): string | null {
  return error instanceof Error ? error.name : null;
}
