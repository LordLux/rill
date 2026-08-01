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

export type ErrorCode =
  | 'AUTH_DEGRADED'
  | 'AUTH_REQUIRED'
  | 'STREAM_UNAVAILABLE'
  | 'STREAM_REQUIRES_SABR'
  | 'RATE_LIMITED'
  | 'PARSE_FAILED'
  | 'UPSTREAM_ERROR';

export class RpcError extends Error {
  readonly code: ErrorCode;
  readonly retryable: boolean;

  constructor(code: ErrorCode, message: string, retryable = false) {
    super(message);
    this.name = 'RpcError';
    this.code = code;
    this.retryable = retryable;
  }

  /** The `error` member of a JSON-RPC failure envelope. */
  toEnvelope(): { code: ErrorCode; message: string; retryable: boolean } {
    return { code: this.code, message: this.message, retryable: this.retryable };
  }
}

export function isRpcError(error: unknown): error is RpcError {
  return error instanceof RpcError;
}

/** True when `error` is an `RpcError` carrying `code`. */
export function hasCode(error: unknown, code: ErrorCode): boolean {
  return isRpcError(error) && error.code === code;
}
