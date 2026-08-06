/**
 * What a decipher handle does when the player code returns something that is not
 * a URL.
 *
 * `JsPlayer.decipher` runs obfuscated JavaScript that YouTube rewrites whenever
 * it likes, so "the output is not a URL" is a thing it can genuinely produce.
 * Before this, `new URL(out)` threw a bare `TypeError: Invalid URL` — which is
 * not an `RpcError`, so it escaped the resolution ladder instead of declining a
 * rung, and took the whole `playback.open` down with it. The ladder is built on
 * tiers saying "not my case, keep going"; a tier that throws something the
 * ladder does not recognise defeats that.
 */

import { describe, it, expect } from 'bun:test';
import type { Player as JsPlayer } from 'youtubei.js';
import { buildHandle } from '../src/innertube/player.ts';
import { isRpcError, hasCode } from '../src/errors.ts';

/** The two fields `buildHandle` reads, plus a `decipher` under the test's control. */
function fakeSource(decipher: (url?: string, cipher?: string) => Promise<string>): JsPlayer {
  return {
    player_id: 'deadbeef',
    signature_timestamp: 20668,
    decipher,
  } as unknown as JsPlayer;
}

describe('decipher handle, non-URL output', () => {
  it('decipherN declines with STREAM_UNAVAILABLE rather than a raw TypeError', async () => {
    const handle = buildHandle(fakeSource(async () => 'not a url at all'));

    const error = await handle.decipherN('abc').then(
      () => null,
      (e: unknown) => e,
    );

    expect(isRpcError(error)).toBe(true);
    expect(hasCode(error, 'STREAM_UNAVAILABLE')).toBe(true);
    expect((error as Error).message).toContain('deadbeef');
  });

  it('decipherSignature declines the same way', async () => {
    const handle = buildHandle(fakeSource(async () => '<html>nope</html>'));

    const error = await handle.decipherSignature('sig', 'sp').then(
      () => null,
      (e: unknown) => e,
    );

    expect(isRpcError(error)).toBe(true);
    expect(hasCode(error, 'STREAM_UNAVAILABLE')).toBe(true);
  });

  it('a URL that simply lacks the parameter still declines, not crashes', async () => {
    // The pre-existing branch, still reachable: parseable, but no `n` on it.
    const handle = buildHandle(fakeSource(async () => 'https://example.com/videoplayback?x=1'));

    const error = await handle.decipherN('abc').then(
      () => null,
      (e: unknown) => e,
    );

    expect(hasCode(error, 'STREAM_UNAVAILABLE')).toBe(true);
  });

  it('a well-formed output still works', async () => {
    const handle = buildHandle(
      fakeSource(async () => 'https://example.com/videoplayback?n=deciphered'),
    );
    expect(await handle.decipherN('abc')).toBe('deciphered');
  });
});
