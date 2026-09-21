/**
 * No cookie reaches the resolution path — asserted over the source, offline.
 *
 * Task 22 §8: *"The sidecar's two-client model is untouched — browse is `WEB`
 * with cookies, stream resolution stays anonymous `VISIONOS` (F11). **Do not
 * send cookies on the resolution path.**"*
 *
 * That is a requirement with no runtime test that could catch it. A cookie sent
 * on `/player` does not fail — it resolves a stream perfectly well, and the
 * damage is that the anonymous resolve identity stops being anonymous and
 * starts being the user's. Nothing in the app would look different, and A5's
 * "two independent calls, no CPN bridged" would have quietly become one.
 *
 * So the check is on the code rather than on behaviour, in the same style as
 * `contract-docs.test.ts`: scan `src/` for every `createSession` call, and
 * require that the ones passing a cookie are exactly the two that are supposed
 * to. It is a whitelist of *call sites*, which is small, changes rarely, and
 * fails loudly the first time someone adds a third.
 *
 * Task 22 made this worth automating: before it, the browse session's cookie
 * came straight off `process.env` at one call site and there was nothing to
 * plumb anywhere. Now there is a `BrowseAuth` object holding a live cookie, and
 * "just pass `browseAuth.session()`" is a one-line change that would look like
 * a simplification.
 */

import { describe, expect, test } from 'bun:test';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC = join(dirname(fileURLToPath(import.meta.url)), '..', 'src');

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory()
      ? sourceFiles(join(dir, entry.name))
      : entry.name.endsWith('.ts')
        ? [join(dir, entry.name)]
        : [],
  );
}

/**
 * The three places a cookie may be attached to a session, and why each is allowed.
 *
 * Anything else is a bug this test exists to name.
 */
const COOKIE_ALLOWED = new Map<string, string>([
  [
    'innertube/auth.ts',
    'the authenticated WEB browse session — the only session that may hold one',
  ],
  [
    'capture.ts',
    'the offline fixture-capture tool; not a request path, and it needs the ' +
      'personalised feed it is capturing',
  ],
  [
    'capture-viewer-state.ts',
    'the other offline capture tool, for the same reason: never on a request path, ' +
      'and it needs the signed-in viewer whose state it is capturing',
  ],
]);

/** Every `createSession({...})` call in `src/`, with the file it is in. */
function createSessionCalls(): Array<{ file: string; args: string }> {
  const out: Array<{ file: string; args: string }> = [];
  for (const path of sourceFiles(SRC)) {
    const source = readFileSync(path, 'utf8');
    // The definition itself lives in `session.ts` and is not a call.
    for (const match of source.matchAll(/\bcreateSession\((\{[^)]*?\})\)/gs)) {
      out.push({
        file: relative(SRC, path).replaceAll('\\', '/'),
        args: match[1]!,
      });
    }
  }
  return out;
}

describe('the resolution path is anonymous', () => {
  const calls = createSessionCalls();

  test('the scan found the call sites at all', () => {
    // Guards against this whole file passing because a regex stopped matching —
    // which is how a source-level check fails open.
    expect(calls.length).toBeGreaterThanOrEqual(4);
    expect(calls.map((c) => c.file)).toContain('innertube/auth.ts');
    expect(calls.map((c) => c.file)).toContain('rpc/server.ts');
  });

  test('only the browse session and the capture tools pass a cookie', () => {
    const withCookie = calls.filter((c) => /\bcookie\b/.test(c.args)).map((c) => c.file);
    const unexpected = withCookie.filter((file) => !COOKIE_ALLOWED.has(file));
    expect(
      unexpected,
      `these call sites pass a cookie to createSession and must not: ${unexpected.join(', ')}. ` +
        'Stream resolution is anonymous (F11, protocol.md §3.5, architecture.md A5).',
    ).toEqual([]);
  });

  test('the session `rpc/server.ts` resolves streams through carries none', () => {
    // Named specifically rather than left to the rule above, because this is
    // the one the ladder actually uses and the one a refactor would touch.
    const serverCalls = calls.filter((c) => c.file === 'rpc/server.ts');
    expect(serverCalls.length).toBe(1);
    expect(serverCalls[0]!.args).toContain("clientType: 'MWEB'");
    expect(serverCalls[0]!.args).not.toContain('cookie');
  });

  test('the browse session is the one holding the cookie', () => {
    // The positive half. Without it, deleting the cookie everywhere would pass
    // every assertion above while signing the user out of browsing entirely.
    const authCalls = calls.filter((c) => c.file === 'innertube/auth.ts');
    expect(authCalls.length).toBe(1);
    expect(authCalls[0]!.args).toContain("clientType: 'WEB'");
    expect(authCalls[0]!.args).toContain('cookie');
  });

  test('nothing hands the browse session to a resolution call', () => {
    // The other shape this could take: not a cookie on `createSession`, but
    // `browseAuth.session()` passed where the resolve session belongs. Every
    // resolution entry point in `rpc/server.ts` takes `getResolveSession()`.
    const server = readFileSync(join(SRC, 'rpc', 'server.ts'), 'utf8');
    for (const method of ['playback.open', 'video.storyboard', 'captions.list', 'captions.get']) {
      const handler = server.slice(
        server.indexOf(`method === '${method}'`),
        server.indexOf(`method === '${method}'`) + 1400,
      );
      expect(handler.length, `handler for ${method} not found`).toBeGreaterThan(0);
      expect(
        handler,
        `${method} must resolve through getResolveSession(), never the browse session`,
      ).not.toContain('getBrowseSession');
      expect(handler).not.toContain('browseAuth');
    }
  });
});
