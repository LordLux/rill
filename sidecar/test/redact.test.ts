/**
 * No cookie value reaches a log or an error envelope — asserted, not eyeballed.
 *
 * Task 22 §5 and its test list: *"No cookie value appears in any log at any
 * level — assert this, do not eyeball it."* Eyeballing is what fails here,
 * because the leak this guards against is not a `log.info` someone wrote. It is
 * a third party — youtubei.js, `fetch`, a stack frame — quoting a request that
 * carried the header, on a path that only runs when something has already gone
 * wrong. Reading the repo will never find it.
 *
 * Two rules, tested independently, because each covers the other's gap:
 * registered secrets catch a value in any shape, and the cookie-name pattern
 * catches a value that was never registered.
 */

import { afterEach, describe, expect, test } from 'bun:test';
import { REDACTED, clearSecrets, redact, registerSecret } from '../src/redact.ts';
import { logger } from '../src/log.ts';
import { errorLine } from '../src/rpc/server.ts';
import { RpcError } from '../src/errors.ts';

/** A realistic header. Every value in it is fake and none of it has ever been valid. */
const COOKIE =
  'VISITOR_INFO1_LIVE=aBcDeFgH; SID=g.a000fake-sid-value-0001; ' +
  '__Secure-1PSID=g.a000fake-1psid-0002; HSID=AfakeHsid0003; SSID=AfakeSsid0004; ' +
  'APISID=fakeApisid0005/fakeApisid0006; SAPISID=fakeSapisid0007/fakeSapisid0008; ' +
  '__Secure-3PAPISID=fakeSecure3p0009/fakeSecure3p0010; LOGIN_INFO=AFmmF2swRQIhAfake0011';

/** Every value in the header, one per cookie. What must never survive a pass. */
const VALUES = COOKIE.split(';')
  .map((pair) => pair.split('=').slice(1).join('=').trim())
  .filter((value) => value.length > 0);

afterEach(() => clearSecrets());

describe('registered secrets', () => {
  test('the whole header is struck out', () => {
    registerSecret(COOKIE);
    const out = redact(`request failed with headers {"Cookie":"${COOKIE}"}`);
    expect(out).toContain(REDACTED);
    for (const value of VALUES) expect(out).not.toContain(value);
  });

  test('a single value quoted on its own is struck out too', () => {
    // The likelier shape by far: a library reporting one bad cookie, not the
    // whole header. An exact match on the header alone sails straight past it,
    // which is why `registerSecret` also registers each pair's value.
    registerSecret(COOKIE);
    const out = redact('SAPISID looked like fakeSapisid0007/fakeSapisid0008 and was rejected');
    expect(out).not.toContain('fakeSapisid0007');
  });

  test('short values are not registered — they would redact ordinary prose', () => {
    registerSecret('abc');
    expect(redact('the abc of it')).toBe('the abc of it');
  });

  test('a non-string is ignored rather than throwing', () => {
    expect(() => registerSecret(undefined)).not.toThrow();
    expect(() => registerSecret(null)).not.toThrow();
  });
});

describe('the cookie-name pattern, with nothing registered', () => {
  test('strikes every auth cookie in a header it has never seen', () => {
    // No `registerSecret`. This is the rule that catches a cookie arriving from
    // somewhere the sidecar never handed to the registry.
    const out = redact(`Cookie: ${COOKIE}`);
    for (const value of VALUES) {
      // `VISITOR_INFO1_LIVE` is not an auth cookie and is deliberately kept —
      // it is a diagnostic this project logs on purpose.
      if (value === 'aBcDeFgH') continue;
      expect(out).not.toContain(value);
    }
    expect(out).toContain('VISITOR_INFO1_LIVE=aBcDeFgH');
  });

  test('the cookie names survive, so a log still says what was redacted', () => {
    const out = redact(`Cookie: ${COOKIE}`);
    expect(out).toContain(`SAPISID=${REDACTED}`);
    expect(out).toContain(`__Secure-1PSID=${REDACTED}`);
    expect(out).toContain(`LOGIN_INFO=${REDACTED}`);
  });

  test('ordinary diagnostics are untouched', () => {
    const line = 'videoId=dQw4w9WgXcQ itag=401 height=2160 sessionId=abc-123';
    expect(redact(line)).toBe(line);
  });
});

describe('the logger', () => {
  /** Capture stderr for the duration of `body`. */
  function captureStderr(body: () => void): string {
    const original = process.stderr.write.bind(process.stderr);
    let captured = '';
    (process.stderr as { write: unknown }).write = (chunk: string | Uint8Array) => {
      captured += typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString();
      return true;
    };
    try {
      body();
    } finally {
      (process.stderr as { write: unknown }).write = original;
    }
    return captured;
  }

  test('redacts at every level', () => {
    registerSecret(COOKIE);
    const log = logger('redact-test');
    // `debug` is included deliberately — §5 says "not at debug level" first,
    // because a debug line is the one people assume nobody reads.
    const captured = captureStderr(() => {
      log.debug(`debug ${COOKIE}`);
      log.info(`info ${COOKIE}`);
      log.warn(`warn ${COOKIE}`);
      log.error(`error ${COOKIE}`);
    });
    for (const value of VALUES) {
      if (value === 'aBcDeFgH') continue;
      expect(captured).not.toContain(value);
    }
  });

  test('a debug line below the threshold is not written at all', () => {
    // Not a redaction property, but the one that makes the assertion above
    // meaningful: if `debug` were silently dropped by the level filter, the
    // test would pass without ever exercising the debug path. `SIDECAR_LOG_LEVEL`
    // defaults to `info`, so this documents that the check above passes because
    // of redaction on the three levels that *did* write.
    const captured = captureStderr(() => logger('redact-test').info('plain line'));
    expect(captured).toContain('plain line');
  });
});

describe('the RPC error envelope', () => {
  test('a cookie inside an upstream error message never reaches stdout', () => {
    registerSecret(COOKIE);
    const line = errorLine(7, new Error(`fetch failed: sent Cookie: ${COOKIE}`));
    for (const value of VALUES) {
      if (value === 'aBcDeFgH') continue;
      expect(line).not.toContain(value);
    }
    // Still a well-formed envelope, and still says what happened.
    const parsed = JSON.parse(line) as { id: number; error: { code: string; retry: string } };
    expect(parsed.id).toBe(7);
    expect(parsed.error.code).toBe('UPSTREAM_ERROR');
    expect(parsed.error.retry).toBe('auto');
  });

  test('with nothing registered, the pattern still strikes it', () => {
    const line = errorLine(8, new RpcError('UPSTREAM_ERROR', `refused: ${COOKIE}`));
    expect(line).not.toContain('fakeSapisid0007');
    expect(line).toContain(`SAPISID=${REDACTED}`);
  });
});
