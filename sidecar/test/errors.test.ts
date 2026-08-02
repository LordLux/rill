/**
 * The error envelope — `protocol.md` §2 and §4.
 *
 * This is a wire contract: Flutter switches on `code` and decides what to show
 * the user from `retry`. Nothing else in the suite touched it, which is how
 * `retryable: boolean` survived long enough to be wrong — it answered two
 * questions with one bit, *should the sidecar retry* and *may the user retry*,
 * and the UI obligation turns on the difference.
 */

import { describe, expect, test } from 'bun:test';

import {
  isInternalSignal,
  RpcError,
  retryModeFor,
  type EnvelopeErrorCode,
  type InternalSignalCode,
  type RetryMode,
} from '../src/errors.ts';

/** `protocol.md` §4, first table — the codes an envelope can carry. */
const ENVELOPE_CODES: EnvelopeErrorCode[] = [
  'AUTH_DEGRADED',
  'AUTH_REQUIRED',
  'STREAM_UNAVAILABLE',
  'RATE_LIMITED',
  'UPSTREAM_ERROR',
];

/** `protocol.md` §4, second table — control flow that never crosses the wire. */
const INTERNAL_CODES: InternalSignalCode[] = ['STREAM_REQUIRES_SABR', 'PARSE_FAILED'];

const MODES: RetryMode[] = ['auto', 'user', 'no'];

describe('the error envelope', () => {
  test('carries code, message and retry — and nothing else', () => {
    const envelope = new RpcError('UPSTREAM_ERROR', 'upstream fell over').toEnvelope();

    expect(Object.keys(envelope).sort()).toEqual(['code', 'message', 'retry']);
    expect(envelope).toEqual({
      code: 'UPSTREAM_ERROR',
      message: 'upstream fell over',
      retry: 'auto',
    });

    // The field it replaced must be gone, not shadowed. A leftover `retryable`
    // would let both halves of the app be right about different things.
    expect('retryable' in envelope).toBe(false);
  });

  test('survives JSON round-tripping with no field lost', () => {
    // `undefined` is the failure that matters: it vanishes through stringify and
    // arrives at Flutter as a missing key.
    const envelope = new RpcError('AUTH_DEGRADED', 'cookies went stale').toEnvelope();
    expect(JSON.parse(JSON.stringify(envelope))).toEqual(envelope);
  });
});

describe('retry modes', () => {
  test('every envelope code has one, and it is one of the three', () => {
    for (const code of ENVELOPE_CODES) {
      expect({ code, mode: retryModeFor(code) }).toEqual({
        code,
        mode: expect.stringMatching(/^(auto|user|no)$/) as unknown as RetryMode,
      });
      expect(MODES).toContain(new RpcError(code, 'x').retry as RetryMode);
    }
  });

  test('the table matches protocol.md §4', () => {
    // Written out rather than looped, so a change to the mapping has to be made
    // here too — this table is the contract, and a drifting one is worse than
    // none.
    expect(ENVELOPE_CODES.map((code) => [code, retryModeFor(code)])).toEqual([
      ['AUTH_DEGRADED', 'no'],
      ['AUTH_REQUIRED', 'no'],
      ['STREAM_UNAVAILABLE', 'user'],
      ['RATE_LIMITED', 'auto'],
      ['UPSTREAM_ERROR', 'auto'],
    ]);
  });

  test('STREAM_UNAVAILABLE is user-retryable, not auto and not terminal', () => {
    // The decision this three-valued field exists for. The ladder's floor is a
    // very good bet and not a promise (F9): every rung can decline for a video
    // that is fine, so "Unavailable" has to be a state the user can retry out of
    // rather than a verdict on the video. `auto` would be wrong in the other
    // direction — a silent loop on a genuinely deleted video spends requests to
    // keep showing a spinner instead of the honest answer.
    expect(retryModeFor('STREAM_UNAVAILABLE')).toBe('user');
  });

  test('an internal signal has no retry mode at all', () => {
    // Not `no`. `no` is an instruction to the app — "retrying changes nothing
    // until something external does" — and these never reach the app, so any
    // value here would be a claim about a situation that cannot arise. Marking
    // them `no` would also file them alongside AUTH_DEGRADED, which is how an
    // inert value gets read as meaningful by whoever writes the RPC layer.
    for (const code of INTERNAL_CODES) {
      expect({ code, retry: new RpcError(code, 'x').retry }).toEqual({ code, retry: null });
      expect(isInternalSignal(code)).toBe(true);
    }

    for (const code of ENVELOPE_CODES) {
      expect(isInternalSignal(code)).toBe(false);
    }
  });

  test('building an envelope from an internal signal throws', () => {
    // §4 says `STREAM_REQUIRES_SABR` reaching Flutter is a bug. `descendLadder`
    // converts a full set of declines into STREAM_UNAVAILABLE, so this is the
    // backstop for the day some other path forgets — loud, rather than a UI
    // rendering an error code that means "keep going".
    for (const code of INTERNAL_CODES) {
      expect(() => new RpcError(code, 'internal').toEnvelope()).toThrow(
        /must never cross the RPC boundary/,
      );
    }

    // …and the envelope codes still build, or the guard would be catching
    // everything.
    for (const code of ENVELOPE_CODES) {
      expect(new RpcError(code, 'x').toEnvelope().code).toBe(code);
    }
  });

  test('the mode comes from the code, not from the throw site', () => {
    // Two STREAM_UNAVAILABLEs thrown from different places cannot disagree about
    // whether the user may retry. That is the drift nobody notices until the UI
    // behaves differently depending on which line threw.
    const fromLadder = new RpcError('STREAM_UNAVAILABLE', 'every tier declined');
    const fromSigning = new RpcError('STREAM_UNAVAILABLE', 'itag 18 carries no address');
    expect(fromLadder.retry).toBe(fromSigning.retry);
  });
});
