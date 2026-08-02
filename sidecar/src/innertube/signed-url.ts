/**
 * `SignedUrl` — the type-level guard on hard invariant 2.
 *
 * An undeciphered `n` parameter is not rejected by YouTube. It is served, at
 * roughly 50 KB/s, and the failure surfaces as buffering that looks exactly like
 * a bad connection. Nothing in the request path errors, so nothing in the code
 * path can notice — which is why this is a type and not a code review comment.
 *
 * `SignedUrl` is a branded string: structurally a string, nominally something
 * only this module produces. Everything downstream of resolution accepts
 * `SignedUrl` and never `string`, so a raw URL cannot reach `PlaybackSource`
 * without someone writing a deliberate cast, in a file whose entire purpose is
 * to be the place where that does not happen.
 *
 * ## Two doors, not one
 *
 * `sign` is the only function that *runs the cipher*. There is one other
 * constructor, `adoptExternallyDeciphered`, because ladder tier 4 delegates
 * extraction to `yt-dlp`, which deciphers with its own implementation and hands
 * back a finished URL — there is nothing left for us to transform. It is a
 * separate, deliberately awkward name so it cannot be reached for by accident,
 * and it applies the same output checks.
 *
 * ## Why the checks are what they are
 *
 * Asserting that `n=` is *present* proves nothing: the raw URL already has one.
 * The real check is that the value **changed**. A shim that silently no-ops, a
 * player script that failed to extract, an evaluator that threw and got
 * swallowed — all of them leave the original `n` in place, and all of them
 * throttle. So `sign` fails when the transform is the identity.
 */

import { logger } from '../log.ts';
import { RpcError } from '../errors.ts';
import type { Player } from './player.ts';

const log = logger('signed-url');

declare const brand: unique symbol;

/** A URL whose signature and `n` parameter have been deciphered. */
export type SignedUrl = string & { readonly [brand]: 'SignedUrl' };

/**
 * Clients whose stream URLs carry an `n` challenge.
 *
 * `ANDROID_VR` and `TV` hand out unthrottled URLs with no `n` at all, so
 * asserting one there rejects a perfectly good URL. That is not a theoretical
 * allowance any more: `ANDROID_VR` is ladder tier 1, so the ordinary path
 * through here now has nothing to decipher, and this gate is what keeps `sign`
 * from refusing it. The `c=` parameter on a `videoplayback` URL names the client
 * that requested it, so the gate reads itself off the URL rather than needing to
 * be plumbed through.
 */
const CLIENTS_WITH_N_PARAM = new Set(['WEB', 'MWEB', 'WEB_REMIX', 'WEB_EMBEDDED_PLAYER']);

export interface SignOptions {
  /**
   * Override the client gate. Leave unset to read it from the URL's `c=`
   * parameter, which is what YouTube itself stamped there.
   */
  expectsN?: boolean;
  /**
   * Proof-of-origin token, appended as `pot=`. Anonymous `MWEB` needs none
   * today; see `playback/po-token.ts` for why the seam exists anyway.
   */
  poToken?: string | null;
}

/** `enhanced_except_…` is the player script's own way of saying it gave up. */
const PLAYER_GAVE_UP = /^enhanced_except_/;

interface Parsed {
  url: URL;
  /** Present when the format was cipher-protected rather than plainly signed. */
  signature: { s: string; sp: string } | null;
}

/**
 * Accept either form YouTube uses for a format's address:
 *
 *   - a plain `https://…/videoplayback?…` URL, already signature-stamped
 *   - a `signatureCipher` query string: `s=…&sp=sig&url=<percent-encoded>`
 *
 * Both arrive as `string`, and the difference is not worth a second parameter —
 * the shapes are unambiguous.
 */
function parseInput(input: string): Parsed {
  const trimmed = input.trim();
  if (!trimmed) throw new RpcError('STREAM_UNAVAILABLE', 'nothing to sign: empty URL');

  if (/^https?:\/\//i.test(trimmed)) {
    return { url: new URL(trimmed), signature: null };
  }

  const args = new URLSearchParams(trimmed);
  const inner = args.get('url');
  if (!inner) {
    throw new RpcError(
      'STREAM_UNAVAILABLE',
      'not a URL and not a signatureCipher (no `url=` member): ' + `${trimmed.slice(0, 60)}…`,
    );
  }
  const s = args.get('s');
  const sp = args.get('sp') ?? 'signature';
  return { url: new URL(inner), signature: s ? { s, sp } : null };
}

function expectsNParam(url: URL, override: boolean | undefined): boolean {
  if (override !== undefined) return override;
  const client = url.searchParams.get('c');
  return client !== null && CLIENTS_WITH_N_PARAM.has(client);
}

/**
 * Decipher a format's address into something safe to hand to a player.
 *
 * The only function in the codebase that runs the cipher, and — with the
 * documented exception of `adoptExternallyDeciphered` — the only one that
 * produces a `SignedUrl`.
 *
 * Async because youtubei.js's decipher path is: `Platform.shim.eval` is declared
 * as possibly-promise-returning and awaited internally. Making this synchronous
 * would mean reimplementing the library's player-script evaluation, which is the
 * one part of this that is genuinely not ours to own.
 */
export async function sign(
  rawUrl: string,
  player: Player,
  options: SignOptions = {},
): Promise<SignedUrl> {
  const { url, signature } = parseInput(rawUrl);

  if (signature) {
    const value = await player.decipherSignature(signature.s, signature.sp);
    if (value === signature.s) {
      throw new RpcError(
        'STREAM_UNAVAILABLE',
        `signature decipher was a no-op on player ${player.playerId} — ` +
          'the interpreter shim is not executing the player script',
      );
    }
    url.searchParams.set(signature.sp, value);
  }

  const n = url.searchParams.get('n');
  if (n !== null) {
    const deciphered = await player.decipherN(n);

    // The check that matters. A wrongly-deciphered `n` is present, well-formed,
    // and throttled; only comparing against the input catches a transform that
    // did not happen.
    if (deciphered === n) {
      throw new RpcError(
        'STREAM_UNAVAILABLE',
        `n decipher was a no-op on player ${player.playerId} (n=${n}) — ` +
          'this URL would stream at ~50 KB/s. Check the node:vm shim and the player cache.',
      );
    }
    if (PLAYER_GAVE_UP.test(deciphered)) {
      throw new RpcError(
        'STREAM_UNAVAILABLE',
        `player ${player.playerId} rejected n=${n} (${deciphered}) — ` +
          'the extracted transform does not match this player revision',
      );
    }
    url.searchParams.set('n', deciphered);
  }

  if (expectsNParam(url, options.expectsN) && !url.searchParams.has('n')) {
    throw new RpcError(
      'STREAM_UNAVAILABLE',
      `client ${url.searchParams.get('c') ?? '(unknown)'} serves throttled URLs but this one ` +
        'carries no `n` parameter — refusing to hand it to a player',
    );
  }

  if (options.poToken) url.searchParams.set('pot', options.poToken);

  return url.toString() as SignedUrl;
}

/**
 * Accept a URL that was deciphered by an external extractor.
 *
 * Ladder tier 4 shells out to `yt-dlp`, which runs its own `n` transform and
 * returns a finished URL. There is no cipher left to apply, so `sign` cannot be
 * the door — but the invariant still has to hold at the boundary, so the same
 * `n`-presence gate applies. What cannot be checked here is whether the value is
 * *correct*: that is the one case where the type says less than it does on the
 * `sign` path, and it is the price of delegating extraction.
 */
export function adoptExternallyDeciphered(url: string, tool: string): SignedUrl {
  const parsed = new URL(url);
  if (expectsNParam(parsed, undefined) && !parsed.searchParams.has('n')) {
    throw new RpcError(
      'STREAM_UNAVAILABLE',
      `${tool} returned a ${parsed.searchParams.get('c')} URL with no \`n\` parameter`,
    );
  }
  log.debug(`adopted a URL deciphered by ${tool}`);
  return parsed.toString() as SignedUrl;
}
