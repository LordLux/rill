/**
 * The browse session and the cookie behind it — Task 22.
 *
 * This is the only place in the sidecar that holds a cookie. Everything about
 * authentication that used to be a module-level `browseSessionPromise` in
 * `rpc/server.ts` lives here instead, because a cookie that can *change* at
 * runtime turns three separate pieces of state into one thing that has to move
 * together: the session, the base-browse cache, and the last verified state.
 * Splitting them is what produces the failure below.
 *
 * ---
 *
 * **The cache is part of the session, and that is not obvious.** `feed.home`
 * and `auth.verify` share a 30-second cache of the base browse response, keyed
 * by `browseId`. Before Task 22 the session was created once and never
 * replaced, so the key was complete. It is not any more: signing in swaps the
 * session, and a cache entry written by the *anonymous* session answers the
 * `auth.verify` that immediately follows the sign-in — with an empty feed, from
 * a session that no longer exists. That is `degraded` reported for a session
 * that just authenticated perfectly, and it is silent in exactly the way F7 is.
 * So the cache is dropped on every session change, here, rather than being
 * something each caller of `setCookie` has to remember.
 *
 * ---
 *
 * **`YT_COOKIE` seeds; the client overrides.** The environment variable is the
 * development path (`CLAUDE.md`) and it keeps working unchanged: it is the
 * cookie the first session is built with. Any `auth.setCookie` or
 * `auth.signOut` replaces it for the life of the process — the user's own
 * action is more recent and more specific than an environment variable, and the
 * alternative (env wins) means a developer who once exported `YT_COOKIE` can
 * never sign in as anybody else, with the UI reporting success either way.
 *
 * The consequence worth stating: **sign-out cannot unset an environment
 * variable.** It clears the session here and the app clears its credential
 * store, but a sidecar restarted with `YT_COOKIE` still set comes back signed
 * in. That is the environment restoring it, not the sign-out failing, and
 * `signOut` logs a warning saying so rather than leaving it to be discovered.
 *
 * ---
 *
 * **Never trust `logged_in`** (hard invariant 5). Nothing here reports a state
 * that was not measured by `verifyAuth` fetching home and counting tiles.
 * `hasCookie` is an input to that answer, never the answer.
 */

import { logger } from '../log.ts';
import { registerSecret } from '../redact.ts';
import { RpcError } from '../errors.ts';
import type { AuthState, AuthStatus, AuthVerification } from '../types.ts';
import { EMPTY_ACCOUNT, parseAccountMenu, type AccountInfo } from '../parser/account.ts';
import type { Session } from './session.ts';

const log = logger('auth');

/** How a session is built from a cookie. Injected so the tests need no network. */
export type SessionFactory = (cookie: string | undefined) => Promise<Session>;

/**
 * `auth.verify` and `feed.home` both fetch base home, and the app calls them
 * back to back at startup — `auth.verify` counts tiles and throws the payload
 * away. Hold it briefly so the `feed.home` moments later is free.
 *
 * Base browse ids only. A continuation or a chip token is a different request
 * and is never served from, or written to, this cache.
 */
const BROWSE_CACHE_TTL_MS = 30_000;

/** The home feed. Named here because `verify` and `feed.home` must agree on it. */
export const HOME_BROWSE_ID = 'FEwhat_to_watch';

export class BrowseAuth {
  readonly #factory: SessionFactory;

  /**
   * The cookie the current session was built with.
   *
   * `#`-private, and never interpolated into anything. It is also registered
   * with `redact.ts` the moment it arrives, so that a *third party* quoting it
   * — youtubei.js raising on a failed request, say — cannot put it on stderr
   * either. Task 22 §5.
   */
  #cookie: string | undefined;

  #sessionPromise: Promise<Session> | null = null;
  #browseCache = new Map<string, { at: number; data: unknown }>();

  /** The last state `verifyAuth` actually measured. `null` until it has run. */
  #verified: AuthState | null = null;
  #account: AccountInfo = EMPTY_ACCOUNT;
  #accountFetched = false;

  /** Whether the seeding `YT_COOKIE` is still what the session is using. */
  #usingEnvCookie: boolean;

  constructor(factory: SessionFactory, envCookie: string | undefined) {
    this.#factory = factory;
    const seed = envCookie?.trim() || undefined;
    registerSecret(seed);
    this.#cookie = seed;
    this.#usingEnvCookie = seed !== undefined;
  }

  /** Whether a cookie is present at all. Says nothing about server acceptance. */
  get hasCookie(): boolean {
    return this.#cookie !== undefined;
  }

  /**
   * The cookie itself, for the one caller allowed to leave this class with it:
   * tier 4's `yt-dlp` subprocess (`playback/resolve.ts`), which needs the
   * account's session to have any chance at an account-level age gate that no
   * anonymous client can clear — see `architecture.md` A12. `undefined` when
   * signed out, same as [hasCookie].
   *
   * **Never log this.** It is already registered with `redact.ts` (the
   * constructor and `setCookie` both do it), which is the second line of
   * defence, not the first — the first is that nothing calls this except to
   * write a throwaway cookie-jar file for yt-dlp, deleted the moment the
   * subprocess exits.
   */
  cookieForYtDlp(): string | undefined {
    return this.#cookie;
  }

  /** The last measured state, or `null` if `verify` has never run. */
  get lastVerifiedState(): AuthState | null {
    return this.#verified;
  }

  session(): Promise<Session> {
    if (!this.#sessionPromise) {
      const cookie = this.#cookie;
      this.#sessionPromise = this.#factory(cookie).catch((error: unknown) => {
        // Clear the memo so the next caller retries rather than being handed a
        // permanently rejected promise — the same rule `getResolveSession` has
        // always followed.
        this.#sessionPromise = null;
        throw error;
      });
    }
    return this.#sessionPromise;
  }

  /**
   * A base browse response, cached for [BROWSE_CACHE_TTL_MS].
   *
   * Lives on this object rather than beside it so that it cannot outlive the
   * session that produced it — see the note at the top of this file.
   */
  async baseBrowse(browseId: string): Promise<unknown> {
    const hit = this.#browseCache.get(browseId);
    if (hit && Date.now() - hit.at < BROWSE_CACHE_TTL_MS) {
      return hit.data;
    }
    const session = await this.session();
    const data = await session.execute('/browse', { browseId });
    this.#browseCache.set(browseId, { at: Date.now(), data });
    return data;
  }

  /**
   * Fetch home, count tiles, decide (hard invariant 5, F7).
   *
   * Delegates the actual counting to `verifyAuth` in `session.ts`, which is
   * parser-independent on purpose: a parser regression must not be reported as
   * a login problem.
   */
  async verify(): Promise<AuthVerification> {
    const { verifyAuth } = await import('./session.ts');
    const session = await this.session();
    const result = await verifyAuth(session, () => this.baseBrowse(HOME_BROWSE_ID));
    this.#verified = result.state;
    return result;
  }

  /**
   * Install a cookie and say whether YouTube accepted it.
   *
   * The returned state is *measured*, not assumed: the session is replaced, the
   * cache dropped, and home fetched and counted. §3.1's `{state}` is therefore
   * the same answer the `auth.verify` the client sends next will give — and
   * that second call is free, because it hits the cache this one just filled.
   */
  async setCookie(cookie: string): Promise<AuthVerification> {
    const trimmed = cookie.trim();
    if (trimmed === '') {
      // Not a `signOut` in disguise. An empty cookie is a client bug — the
      // caller believed it had credentials — and answering it with "you are
      // now anonymous" would make that bug look like a successful sign-out.
      throw new RpcError('BAD_REQUEST', 'auth.setCookie requires a non-empty cookie');
    }
    registerSecret(trimmed);
    this.#reset(trimmed);
    this.#usingEnvCookie = false;
    const result = await this.verify();
    log.info(`auth.setCookie → ${result.state} (${result.tileCount} tiles)`);
    return result;
  }

  /**
   * Drop the cookie, the session, the cache and the cached account.
   *
   * Every one of those, and the list is the point: leaving any of them behind
   * is a sign-out that reads as successful while the next request still carries
   * the old identity. Asserted rather than described — `auth.test.ts` checks
   * the state *after* a sign-out on a live-looking session, not that a flag
   * flipped.
   */
  signOut(): void {
    const hadEnvCookie = this.#usingEnvCookie;
    this.#reset(undefined);
    this.#verified = 'anonymous';
    this.#usingEnvCookie = false;
    if (hadEnvCookie) {
      log.warn(
        'signed out of a session seeded from YT_COOKIE. This process is anonymous now, ' +
          'but the variable is still set: a restarted sidecar will sign back in with it. ' +
          'Unset YT_COOKIE if that is not what you want.',
      );
    } else {
      log.info('signed out; session, cookie, browse cache and account all dropped');
    }
  }

  /**
   * `{state, accountName, accountHandle, accountAvatarUrl}` — §3.1, extended.
   *
   * The state is verified rather than remembered when nothing has measured it
   * yet, so a first call after a restore answers the truth rather than `null`.
   * The account details are fetched once and cached with the session: they
   * change when the account changes, and the account changes only through
   * `setCookie` or `signOut`, both of which drop this.
   *
   * A failed account fetch is not a failed status. The state is the part that
   * drives a re-auth prompt; a name is decoration, and reporting the session
   * as degraded because a menu endpoint hiccuped would send the user to a
   * login page they do not need.
   */
  async status(): Promise<AuthStatus> {
    const state = this.#verified ?? (await this.verify()).state;
    if (state === 'authenticated' && !this.#accountFetched) {
      this.#account = await this.#fetchAccount();
      this.#accountFetched = true;
    }
    const account = state === 'authenticated' ? this.#account : EMPTY_ACCOUNT;
    return {
      state,
      accountName: account.name,
      accountHandle: account.handle,
      accountAvatarUrl: account.avatarUrl,
    };
  }

  async #fetchAccount(): Promise<AccountInfo> {
    try {
      const session = await this.session();
      const raw = await session.execute('/account/account_menu', {});
      const account = parseAccountMenu(raw);
      log.info(
        `account menu read: name=${account.name === null ? 'absent' : 'present'} ` +
          `handle=${account.handle ?? 'absent'} avatar=${account.avatarUrl ? 'present' : 'absent'}`,
      );
      return account;
    } catch (error) {
      log.warn(`account menu unavailable: ${(error as Error).message}`);
      return EMPTY_ACCOUNT;
    }
  }

  /** Session, cache, account and verified state, all replaced together. */
  #reset(cookie: string | undefined): void {
    this.#cookie = cookie;
    this.#sessionPromise = null;
    this.#browseCache.clear();
    this.#account = EMPTY_ACCOUNT;
    this.#accountFetched = false;
    this.#verified = null;
  }
}

/**
 * The process-wide browse session.
 *
 * A singleton because there is exactly one signed-in identity, and because
 * `rpc/server.ts` reached for a module-level one before this file existed. The
 * class is exported separately so tests can build one over a fake factory and
 * never touch the network.
 */
export const browseAuth = new BrowseAuth(async (cookie) => {
  const { createSession } = await import('./session.ts');
  return createSession({ clientType: 'WEB', cookie });
}, process.env.YT_COOKIE);
