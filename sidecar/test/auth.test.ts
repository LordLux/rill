/**
 * `auth.*` — offline, over a fake session.
 *
 * Every assertion here is about the *state machine*, not about YouTube: the
 * session factory is injected, so a "degraded session" is a session whose home
 * response has no tiles, which is exactly what F7 describes and exactly what
 * cannot be produced on demand against the live API.
 *
 * Task 22's tests section asks for the degraded path and the sign-out clear to
 * be **mutation-checked** — "a test asserting sign-out sets state to anonymous
 * passes while leaving cookies on disk". So the sign-out tests below assert on
 * what the *next session is built with*, and the degraded tests assert the
 * measured state rather than an input flag. Each one is annotated with the
 * mutation it would catch.
 */

import { describe, expect, test } from 'bun:test';
import { BrowseAuth } from '../src/innertube/auth.ts';
import { isRpcError } from '../src/errors.ts';
import type { Session } from '../src/innertube/session.ts';

// ---------------------------------------------------------------------------
// A fake session
// ---------------------------------------------------------------------------

/** One `lockupViewModel`, which `countTiles` counts as one tile. */
const ONE_TILE = { contents: [{ lockupViewModel: { contentId: 'abc' } }] };

/** HTTP 200, no error, nothing in it. F7's shape exactly. */
const EMPTY_FEED = { contents: [] };

const ACCOUNT_MENU = {
  actions: [
    {
      openPopupAction: {
        popup: {
          multiPageMenuRenderer: {
            sections: [
              {
                accountSectionListRenderer: {
                  contents: [
                    {
                      accountItemSectionRenderer: {
                        contents: [
                          {
                            accountItem: {
                              isSelected: true,
                              accountName: { simpleText: 'Ada Lovelace' },
                              channelHandle: { simpleText: '@ada' },
                              accountPhoto: {
                                thumbnails: [
                                  { url: '//yt3.ggpht.com/small', width: 48 },
                                  { url: '//yt3.ggpht.com/big', width: 176 },
                                ],
                              },
                            },
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      },
    },
  ],
};

interface Recorder {
  /** The cookie each session was built with, in creation order. */
  cookies: (string | undefined)[];
  /** Every endpoint executed, across every session. */
  calls: string[];
}

/**
 * A factory whose sessions answer `/browse` from `homeByCookie`.
 *
 * Keyed by cookie so a test can say "this cookie is good and that one is
 * degraded" without any other machinery — which is the whole point, since the
 * difference between the two is invisible at the HTTP layer.
 */
function fakeFactory(
  homeByCookie: (cookie: string | undefined) => unknown,
  options: { accountMenu?: unknown; accountThrows?: boolean } = {},
): { factory: (cookie: string | undefined) => Promise<Session>; recorder: Recorder } {
  const recorder: Recorder = { cookies: [], calls: [] };
  const factory = async (cookie: string | undefined): Promise<Session> => {
    recorder.cookies.push(cookie);
    return {
      innertube: null as never,
      hasCookie: cookie !== undefined,
      visitorId: 'visitor',
      async execute(endpoint: string) {
        recorder.calls.push(endpoint);
        if (endpoint === '/account/account_menu') {
          if (options.accountThrows) throw new Error('account menu exploded');
          return options.accountMenu ?? ACCOUNT_MENU;
        }
        return homeByCookie(cookie);
      },
    };
  };
  return { factory, recorder };
}

/** Home has tiles for anyone holding a cookie. The ordinary happy case. */
const goodCookie = (cookie: string | undefined) => (cookie ? ONE_TILE : EMPTY_FEED);

// ---------------------------------------------------------------------------
// verify — the three states
// ---------------------------------------------------------------------------

describe('auth.verify', () => {
  test('no cookie is anonymous, not degraded', async () => {
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, undefined);
    expect(await auth.verify()).toEqual({ state: 'anonymous', tileCount: 0 });
  });

  test('a working cookie is authenticated, with tiles > 0', async () => {
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-cookie-value; SID=env');
    const result = await auth.verify();
    expect(result.state).toBe('authenticated');
    expect(result.tileCount).toBeGreaterThan(0);
  });

  test('a cookie with an empty feed is degraded — not anonymous, not an error', async () => {
    // F7. The mutation this catches: deriving the state from `hasCookie` alone
    // (`cookie ? 'authenticated' : 'anonymous'`) passes every other test in
    // this file and answers `authenticated` here, which is the exact bug hard
    // invariant 5 exists to prevent. Deriving it from tiles alone answers
    // `anonymous`, which sends the user to a login page instead of telling
    // them their session expired.
    const { factory } = fakeFactory(() => EMPTY_FEED);
    const auth = new BrowseAuth(factory, 'SAPISID=stale; SID=stale');
    const result = await auth.verify();
    expect(result.state).toBe('degraded');
    expect(result.tileCount).toBe(0);
  });

  test('an upstream failure with a cookie is degraded, not a thrown error', async () => {
    const auth = new BrowseAuth(
      async () => ({
        innertube: null as never,
        hasCookie: true,
        visitorId: null,
        execute: () => Promise.reject(new Error('network down')),
      }),
      'SAPISID=whatever; SID=x',
    );
    expect((await auth.verify()).state).toBe('degraded');
  });
});

// ---------------------------------------------------------------------------
// setCookie
// ---------------------------------------------------------------------------

describe('auth.setCookie', () => {
  test('replaces the session and reports a measured state', async () => {
    const { factory, recorder } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, undefined);
    expect((await auth.verify()).state).toBe('anonymous');

    const result = await auth.setCookie('SAPISID=fresh-value; SID=fresh');
    expect(result.state).toBe('authenticated');
    // Two sessions: the anonymous one, then the one built from the new cookie.
    expect(recorder.cookies).toEqual([undefined, 'SAPISID=fresh-value; SID=fresh']);
  });

  test('drops the base-browse cache, so the sign-in is not verified against the session it replaced', async () => {
    // The mutation this catches, and the reason the cache moved onto
    // `BrowseAuth` at all: leave the cache in place across a session swap and
    // `verify` is answered from the *anonymous* response cached moments
    // earlier — zero tiles, cookie present — which is `degraded` reported for
    // a sign-in that worked perfectly. Silent, and indistinguishable from a
    // genuinely stale cookie.
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, undefined);

    // Prime the cache with the anonymous empty feed.
    await auth.baseBrowse('FEwhat_to_watch');
    expect((await auth.verify()).state).toBe('anonymous');

    expect((await auth.setCookie('SAPISID=fresh-value; SID=fresh')).state).toBe('authenticated');
  });

  test('a stale cookie sets degraded rather than failing', async () => {
    const { factory } = fakeFactory(() => EMPTY_FEED);
    const auth = new BrowseAuth(factory, undefined);
    expect((await auth.setCookie('SAPISID=stale-value; SID=stale')).state).toBe('degraded');
  });

  test('an empty cookie is BAD_REQUEST, not a silent sign-out', async () => {
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    let thrown: unknown;
    try {
      await auth.setCookie('   ');
    } catch (error) {
      thrown = error;
    }
    expect(isRpcError(thrown)).toBe(true);
    expect((thrown as { code: string }).code).toBe('BAD_REQUEST');
    // And it did not sign anyone out on the way.
    expect(auth.hasCookie).toBe(true);
  });

  test('the error message never carries the cookie', async () => {
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, undefined);
    try {
      await auth.setCookie('');
    } catch (error) {
      expect((error as Error).message).not.toContain('cookie=');
      expect((error as Error).message).toBe('auth.setCookie requires a non-empty cookie');
    }
  });
});

// ---------------------------------------------------------------------------
// signOut — asserted on what is left, not on the flag
// ---------------------------------------------------------------------------

describe('auth.signOut', () => {
  test('the next session is built with no cookie at all', async () => {
    // Task 22's mutation check, applied to the sidecar half: "assert the store
    // is empty, not that the flag flipped". Setting `#verified = 'anonymous'`
    // and nothing else passes a state assertion while every subsequent request
    // still goes out carrying the old identity. This asserts the *cookie the
    // factory receives*, which is the thing that actually reaches YouTube.
    const { factory, recorder } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, undefined);
    await auth.setCookie('SAPISID=signed-in-value; SID=in');
    expect(recorder.cookies.at(-1)).toBe('SAPISID=signed-in-value; SID=in');

    auth.signOut();
    await auth.session();
    expect(recorder.cookies.at(-1)).toBeUndefined();
    expect(auth.hasCookie).toBe(false);
  });

  test('a subsequent verify returns anonymous', async () => {
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    expect((await auth.verify()).state).toBe('authenticated');
    auth.signOut();
    expect((await auth.verify()).state).toBe('anonymous');
  });

  test('the cached feed goes with it', async () => {
    // A sign-out that keeps the cache serves the signed-in home feed to an
    // anonymous session for up to 30 seconds — the user's own recommendations,
    // after they asked to be signed out.
    const { factory, recorder } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    await auth.baseBrowse('FEwhat_to_watch');
    const callsBefore = recorder.calls.length;

    auth.signOut();
    const after = await auth.baseBrowse('FEwhat_to_watch');
    expect(recorder.calls.length).toBeGreaterThan(callsBefore);
    expect(after).toEqual(EMPTY_FEED);
  });

  test('the cached account goes with it', async () => {
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    expect((await auth.status()).accountName).toBe('Ada Lovelace');
    auth.signOut();
    const status = await auth.status();
    expect(status.state).toBe('anonymous');
    expect(status.accountName).toBeNull();
    expect(status.accountHandle).toBeNull();
    expect(status.accountAvatarUrl).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------

describe('auth.status', () => {
  test('carries the account name, handle and widest avatar', async () => {
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    expect(await auth.status()).toEqual({
      state: 'authenticated',
      accountName: 'Ada Lovelace',
      accountHandle: '@ada',
      // Protocol-relative, as avatars arrive; absolutised the same way
      // `ChannelItem.avatarUrl` is.
      accountAvatarUrl: 'https://yt3.ggpht.com/big',
    });
  });

  test('verifies on its own when nothing has verified yet', async () => {
    const { factory } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, undefined);
    expect(auth.lastVerifiedState).toBeNull();
    expect((await auth.status()).state).toBe('anonymous');
  });

  test('an unreadable account menu is still an authenticated status', async () => {
    // The state drives a re-auth prompt; the name is decoration. Answering an
    // error here would send a perfectly good session to a login page because a
    // menu endpoint hiccuped.
    const { factory } = fakeFactory(goodCookie, { accountThrows: true });
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    const status = await auth.status();
    expect(status.state).toBe('authenticated');
    expect(status.accountName).toBeNull();
  });

  test('a degraded session reports no account', async () => {
    const { factory } = fakeFactory(() => EMPTY_FEED);
    const auth = new BrowseAuth(factory, 'SAPISID=stale-value; SID=stale');
    const status = await auth.status();
    expect(status.state).toBe('degraded');
    expect(status.accountName).toBeNull();
  });

  test('the account menu is fetched once and cached with the session', async () => {
    const { factory, recorder } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    await auth.status();
    await auth.status();
    const menuCalls = recorder.calls.filter((c) => c === '/account/account_menu');
    expect(menuCalls.length).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// YT_COOKIE precedence — Task 22 §8
// ---------------------------------------------------------------------------

describe('YT_COOKIE seeds, the client overrides', () => {
  test('the first session is built from the environment cookie', async () => {
    const { factory, recorder } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, '  SAPISID=env-value; SID=env  ');
    await auth.session();
    // Trimmed, and otherwise verbatim.
    expect(recorder.cookies).toEqual(['SAPISID=env-value; SID=env']);
  });

  test('a blank YT_COOKIE is anonymous, not a cookie made of spaces', async () => {
    const { factory, recorder } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, '   ');
    await auth.session();
    expect(recorder.cookies).toEqual([undefined]);
    expect(auth.hasCookie).toBe(false);
  });

  test('auth.setCookie wins over the environment for the life of the process', async () => {
    const { factory, recorder } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    await auth.session();
    await auth.setCookie('SAPISID=app-value; SID=app');
    await auth.session();
    expect(recorder.cookies.at(-1)).toBe('SAPISID=app-value; SID=app');
  });

  test('sign-out does not fall back to the environment cookie', async () => {
    // The one that would make sign-out a lie on a development machine: falling
    // back to `YT_COOKIE` means the user asks to be signed out and stays signed
    // in, with the UI showing anonymous. The variable is still set — a
    // *restarted* sidecar picks it up again, which is the environment, not this
    // process — and `signOut` warns about exactly that.
    const { factory, recorder } = fakeFactory(goodCookie);
    const auth = new BrowseAuth(factory, 'SAPISID=env-value; SID=env');
    await auth.session();
    auth.signOut();
    await auth.session();
    expect(recorder.cookies.at(-1)).toBeUndefined();
  });
});
