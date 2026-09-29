/**
 * Proof-of-origin tokens — the BotGuard attestation `todo.md` 54 needed.
 *
 * A PO token proves a `/player` request came from a real client. `VISIONOS`
 * (ladder tier 1) does not currently require one for an ordinary video, but an
 * age-restricted one answers `LOGIN_REQUIRED — "Sign in to confirm your age"`
 * to every anonymous client regardless of token (`architecture.md` F48) — the
 * missing piece there is the account's own cookie, not a token, and the two
 * are minted and carried independently. This file mints; `age-restricted.ts`
 * is the other consumer that also needs a cookie.
 *
 * **One minter, in this process, no second server.** `bgutil-ytdlp-pot-provider`
 * runs this exact logic (BotGuard via `bgutils-js`, in a headless DOM via
 * `jsdom`) behind an HTTP server for yt-dlp to call; there is no reason to
 * shell out to a sibling process for it when the code runs in-process just as
 * well — measured cold cost, compiled: ~812ms total, paid once per process
 * (`architecture.md` F48). `warm()` exists so that cost lands in the
 * background after `event.ready` rather than on the first video's open.
 *
 * **The homepage scrape, not the library's own `/att/get` fallback, is what
 * actually mints an accepted token.** `bgutils-js`'s documented flow asks
 * `/youtubei/v1/att/get` for a challenge with no page context attached, and
 * the integrity token that produces is rejected server-side. The challenge
 * embedded in youtube.com's own homepage HTML (`ytcfg.set(...)` for
 * `EVENT_ID`, `window.ytAtN(...)` for the challenge itself) is
 * self-consistent with a real page load, and only tokens minted from it were
 * observed to survive a live yt-dlp round trip. `/att/get` is kept as a
 * fallback for when the homepage scrape fails to parse — untested against a
 * real refusal, since the scrape has not yet failed — rather than removed,
 * since a partially-working fallback beats none.
 *
 * **No `canvas`.** BotGuard's challenge does exercise `HTMLCanvasElement`
 * (jsdom logs "Not implemented: ... without installing the canvas npm
 * package"), but a token minted with that stub still cleared a live
 * age-restricted video's gate, so the native `canvas` addon — which does not
 * bundle into a `bun build --compile` binary — is not carried. Measured,
 * not assumed: F48.
 */

import { JSDOM } from 'jsdom';
import { buildURL, getHeaders, parseLooseJSON, USER_AGENT } from 'bgutils-js/utils';
import type { IBotguardClientSideBgChallenge, IntegrityTokenData, WebPoSignalOutput } from 'bgutils-js/shared-types';
import { BotGuardClient } from 'bgutils-js/botguard';
import { WebPoMinter } from 'bgutils-js/webpo';
import { logger } from '../log.ts';

const log = logger('po-token');

export interface PoTokenProvider {
  /**
   * A token for this video, or `null` when none is needed or none can be
   * obtained. Returning `null` must always be safe: the caller treats it as
   * "carry on without one".
   */
  mint(videoId: string): Promise<string | null>;

  /**
   * Start building the shared minter now, without waiting on it.
   *
   * Safe to call more than once (idempotent) and safe never to call at all —
   * `mint()` builds it lazily on first use either way. Exists purely to move
   * the one-time cold cost earlier than the first `playback.open`; never
   * called before `event.ready` has already been emitted (`rpc/server.ts`).
   */
  warm(): void;
}

/** The Phase 1 provider. Mints nothing, never fails. */
export const nullPoTokenProvider: PoTokenProvider = {
  mint: async () => null,
  warm: () => {},
};

// ---------------------------------------------------------------------------
// BotGuard challenge
// ---------------------------------------------------------------------------

/** YouTube's own long-lived public request key for `GenerateIT` — not a secret this process holds. */
const REQUEST_KEY = 'O43z0dpjhgX20SCx4KAo';

let domInstalled = false;

/**
 * A headless DOM BotGuard's challenge script can run against.
 *
 * `bgutils-js` assumes a browser-shaped `globalThis` (`window`, `document`,
 * `navigator`) — it is a client-side attestation library, not a Node one.
 * Installed once per process: a second `JSDOM` would fight the first over the
 * same global properties.
 */
function installDom(): void {
  if (domInstalled) return;
  const dom = new JSDOM(
    '<!DOCTYPE html><html lang="en"><head><title></title></head><body></body></html>',
    { url: 'https://www.youtube.com/', referrer: 'https://www.youtube.com/', resources: { userAgent: USER_AGENT } },
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    origin: dom.window.origin,
  });
  if (!Reflect.has(globalThis, 'navigator')) {
    Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator });
  }
  domInstalled = true;
}

interface ChallengeData {
  interpreterUrl: { privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: string };
  interpreterHash: string;
  program: string;
  globalName: string;
}

/** The self-consistent (ytcfg, ytAtN) challenge embedded in the real homepage — see the file doc comment. */
async function challengeFromHomepage(): Promise<ChallengeData | undefined> {
  try {
    const response = await fetch('https://www.youtube.com', {
      headers: { accept: '*/*', 'accept-language': 'en-US,en;q=0.7', 'user-agent': USER_AGENT },
    });
    const html = await response.text();

    const ytcfgMatch = html.match(/ytcfg\.set\(({.+?})\);/s);
    if (ytcfgMatch) {
      // BotGuard's snapshot reads `yt.config_.EVENT_ID` off the page global.
      const ytObj = { config_: JSON.parse(ytcfgMatch[1]!) };
      const g = globalThis as unknown as { yt?: unknown; window?: { yt?: unknown } };
      g.yt = ytObj;
      if (g.window) g.window.yt = ytObj;
    } else {
      log.debug('homepage challenge: no ytcfg found (EVENT_ID missing)');
    }

    const attMatch = html.match(/window\.ytAtN\(\s*({[\s\S]*?})\s*\)/);
    if (!attMatch) {
      log.debug('homepage challenge: no ytAtN challenge in the page');
      return undefined;
    }
    const attData = parseLooseJSON(attMatch[1]!) as { R?: { bgChallenge?: ChallengeData } };
    const bgChallenge = attData.R?.bgChallenge;
    if (!bgChallenge?.program || !bgChallenge.interpreterUrl) {
      log.debug('homepage challenge: ytAtN payload missing bgChallenge');
      return undefined;
    }
    return bgChallenge;
  } catch (error) {
    log.debug(`homepage challenge unavailable (${(error as Error).message}); falling back to /att/get`);
    return undefined;
  }
}

/** The library's documented flow — kept as a fallback; see the file doc comment on why it is not primary. */
async function challengeFromAttGet(): Promise<ChallengeData> {
  const response = await fetch('https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false', {
    method: 'POST',
    headers: { ...getHeaders(), 'Content-Type': 'application/json' },
    body: JSON.stringify({
      context: { client: { clientName: 'WEB', clientVersion: '2.20260817.01.00' } },
      engagementType: 'ENGAGEMENT_TYPE_UNBOUND',
    }),
  });
  const attestation = (await response.json()) as { bgChallenge?: ChallengeData };
  if (!attestation.bgChallenge) throw new Error('/att/get returned no bgChallenge');
  return attestation.bgChallenge;
}

async function descrambledChallenge(): Promise<IBotguardClientSideBgChallenge> {
  const challenge = (await challengeFromHomepage()) ?? (await challengeFromAttGet());
  const { program, globalName, interpreterHash } = challenge;
  const { privateDoNotAccessOrElseTrustedResourceUrlWrappedValue } = challenge.interpreterUrl;
  const interpreterResponse = await fetch(`https:${privateDoNotAccessOrElseTrustedResourceUrlWrappedValue}`);
  const interpreterJs = await interpreterResponse.text();
  return {
    program,
    globalName,
    interpreterHash,
    interpreterJavascript: { privateDoNotAccessOrElseSafeScriptWrappedValue: interpreterJs },
    interpreterUrl: { privateDoNotAccessOrElseTrustedResourceUrlWrappedValue },
  };
}

// ---------------------------------------------------------------------------
// The shared minter
// ---------------------------------------------------------------------------

interface Minter {
  /** Epoch ms this integrity token stops being usable — from YouTube's own `estimatedTtlSecs`. */
  expiresAt: number;
  minter: WebPoMinter;
}

async function buildMinter(): Promise<Minter> {
  installDom();

  const challenge = await descrambledChallenge();
  const interpreterJs = challenge.interpreterJavascript?.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (!interpreterJs) throw new Error('BotGuard challenge carried no interpreter script');
  // Installs the interpreter's globals (`globalName`) onto `globalThis` — the
  // same trust boundary `installInterpreter()` in `session.ts` crosses for
  // YouTube's player script, for the same reason: there is no alternative to
  // running YouTube's own obfuscated challenge code.
  new Function(interpreterJs)();

  const bgClient = await BotGuardClient.create({
    program: challenge.program,
    globalName: challenge.globalName,
    globalObject: globalThis,
  });

  const webPoSignalOutput: WebPoSignalOutput = [];
  const botguardResponse = await bgClient.snapshot({ webPoSignalOutput });

  const integrityResponse = await fetch(buildURL('GenerateIT'), {
    method: 'POST',
    headers: { ...getHeaders(), 'Content-Type': 'application/json' },
    body: JSON.stringify([REQUEST_KEY, botguardResponse]),
  });
  const [integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken] =
    (await integrityResponse.json()) as [string, number, number, string];
  if (!integrityToken) throw new Error('YouTube returned an empty integrity token');

  const integrityTokenData: IntegrityTokenData = {
    integrityToken,
    estimatedTtlSecs,
    mintRefreshThreshold,
    websafeFallbackToken,
  };

  return {
    expiresAt: Date.now() + estimatedTtlSecs * 1000,
    minter: await WebPoMinter.create(integrityTokenData, webPoSignalOutput),
  };
}

let minterPromise: Promise<Minter> | null = null;

/** Build the minter if nothing is building or holding one already; never runs it twice concurrently. */
function ensureMinter(): Promise<Minter> {
  if (!minterPromise) {
    minterPromise = buildMinter().catch((error: unknown) => {
      // Do not memoize a failure — the next call (or the next `mint`) gets a
      // fresh attempt rather than a permanently rejected promise.
      minterPromise = null;
      throw error;
    });
  }
  return minterPromise;
}

class BotguardPoTokenProvider implements PoTokenProvider {
  warm(): void {
    ensureMinter().catch((error: unknown) => {
      log.error(
        `PO-token minter warm-up failed (${(error as Error).message}) — will retry on first ` +
          'use, but every mint until then declines. See `mint()` if this keeps happening.',
      );
    });
  }

  async mint(videoId: string): Promise<string | null> {
    // Two different failures, two different severities. Building the shared
    // minter failing (no network, BotGuard's challenge shape changed, the
    // interpreter shim rejects it) means every mint on this process will
    // keep failing until whatever broke is fixed — that is worth a loud
    // `error`, not a line indistinguishable from an ordinary per-video
    // hiccup. Once a minter exists, one video's `mintAsWebsafeString` call
    // failing is the isolated case a `warn` was always meant for.
    let entry;
    try {
      entry = await ensureMinter();
      if (Date.now() >= entry.expiresAt) {
        minterPromise = null;
        entry = await ensureMinter();
      }
    } catch (error) {
      log.error(
        `PO-token minter could not be built (${(error as Error).message}) — every mint on this ` +
          'process will decline until this is fixed. Interface contract still holds: the caller ' +
          'gets null, never a thrown error, so a video declines rather than crashes.',
      );
      return null;
    }
    try {
      const token = await entry.minter.mintAsWebsafeString(videoId);
      return token ?? null;
    } catch (error) {
      // Interface contract: `null` is always safe. A per-video mint failure
      // must decline the token, never the video.
      log.warn(`PO-token mint failed for ${videoId} (${(error as Error).message}); continuing without one`);
      return null;
    }
  }
}

export const botguardPoTokenProvider: PoTokenProvider = new BotguardPoTokenProvider();
