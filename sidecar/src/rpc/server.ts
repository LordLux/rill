import { createInterface } from 'node:readline';
import type { Session } from '../innertube/session.ts';
import { RpcError, isRpcError, messageOf, nameOf } from '../errors.ts';
import { logger } from '../log.ts';
import { announceCapabilities } from '../capabilities.ts';

const log = logger('rpc');

let browseSessionPromise: Promise<Session> | null = null;
let resolveSessionPromise: Promise<Session> | null = null;

// Memoise the promise, not the resolved value: two concurrent callers arriving
// before the first session settles would otherwise each create one.
/**
 * The browse session, and the only one that ever sees a cookie.
 *
 * `YT_COOKIE` is read from the environment rather than a file: the sidecar
 * inherits it from whatever launched it (Dart's `Process.start` passes the
 * parent environment through by default), so nothing has to live on disk next
 * to the code. Unset or blank means anonymous, which is a supported state and
 * not an error — `auth.verify` reports `anonymous` and the feed says so.
 *
 * Browse and resolve are deliberately different clients (§2.3): this session
 * browses and reports as `WEB` with cookies, while `getResolveSession` stays
 * anonymous on purpose. Do not pass the cookie there — the two are independent
 * calls and bridging them is a rejected alternative.
 *
 * A cookie present is not a session accepted. Hard invariant 5: `logged_in`
 * reflects cookie presence only, a degraded session answers HTTP 200 with an
 * empty feed, and `auth.verify` is what tells the difference.
 */
function getBrowseSession(): Promise<Session> {
  if (!browseSessionPromise) {
    browseSessionPromise = (async () => {
      try {
        const { createSession } = await import('../innertube/session.ts');
        return await createSession({
          clientType: 'WEB',
          cookie: process.env.YT_COOKIE?.trim() || undefined,
        });
      } catch (e) {
        browseSessionPromise = null;
        throw e;
      }
    })();
  }
  return browseSessionPromise;
}

function getResolveSession(): Promise<Session> {
  if (!resolveSessionPromise) {
    resolveSessionPromise = (async () => {
      try {
        const { createSession } = await import('../innertube/session.ts');
        return await createSession({ clientType: 'MWEB' });
      } catch (e) {
        resolveSessionPromise = null;
        throw e;
      }
    })();
  }
  return resolveSessionPromise;
}

/**
 * `auth.verify` and `feed.home` both fetch base home, and the app calls them
 * back to back at startup — auth.verify counts tiles and throws the payload
 * away. Hold it briefly so the feed.home moments later is free.
 *
 * Base browse ids only. A continuation or a chip token is a different request
 * and is never served from, or written to, this cache.
 */
const BROWSE_CACHE_TTL_MS = 30_000;
const browseCache = new Map<string, { at: number; data: unknown }>();

async function fetchBaseBrowse(session: Session, browseId: string): Promise<unknown> {
  const hit = browseCache.get(browseId);
  if (hit && Date.now() - hit.at < BROWSE_CACHE_TTL_MS) {
    return hit.data;
  }
  const data = await session.execute('/browse', { browseId });
  browseCache.set(browseId, { at: Date.now(), data });
  return data;
}

const abortControllers = new Map<number | string, AbortController>();

function emitResponse(id: number | string, result: unknown) {
  process.stdout.write(JSON.stringify({ id, result }) + '\n');
}

function emitError(id: number | string, error: unknown) {
  let envelope;
  if (isRpcError(error)) {
    try {
      envelope = error.toEnvelope();
    } catch (e) {
      // `toEnvelope` throws on an internal signal rather than inventing a
      // `retry` for it (§4). Reaching Flutter as an upstream error is the least
      // wrong answer: the request did fail, and the app must not be told a
      // `retry` the protocol never defined for this code.
      //
      // Both messages. `error` says what actually failed; `e` says why it could
      // not be enveloped. Keeping only the second — which is what this line used
      // to do — reports "internal signal cannot be enveloped" and drops every
      // clue about what the signal was about, on the one path that only runs
      // when something has already gone wrong in an unanticipated way.
      envelope = {
        code: 'UPSTREAM_ERROR',
        message: `${messageOf(error)} (${messageOf(e)})`,
        retry: 'auto',
      };
    }
  } else {
    envelope = {
      code: 'UPSTREAM_ERROR',
      message: error instanceof Error ? error.message : String(error),
      retry: 'auto'
    };
  }
  process.stdout.write(JSON.stringify({ id, error: envelope }) + '\n');
}

function emitEvent(method: string, params: unknown) {
  process.stdout.write(JSON.stringify({ method, params }) + '\n');
}

/**
 * One decoded line off stdin.
 *
 * Deliberately permissive: this is whatever `JSON.parse` produced, not something
 * the type system can vouch for. Every field is optional because a malformed
 * frame is a thing the transport has to survive, not a thing it may assume away
 * — `handleRequest` checks for a missing `id` two lines in for exactly that
 * reason. What this buys over `any` is that the checks cannot be forgotten.
 */
interface RpcRequest {
  id?: number;
  method?: string;
  params?: Record<string, unknown>;
}

/**
 * A required string parameter, or `BAD_REQUEST`.
 *
 * Shared rather than open-coded per method because §3 is about to grow five more
 * methods that all take params, and the failure mode of open-coding it is that
 * one of them forgets and the missing check surfaces as a `TypeError` from deep
 * inside whatever the param was passed to.
 */
function requireString(
  params: Record<string, unknown> | undefined,
  name: string,
  method: string,
): string {
  const value = params?.[name];
  // Trimmed, not just non-empty. `"   "` is a string and it is not empty, so the
  // exact-emptiness check waved it through to be used as a video id — which
  // fails much further downstream, as an upstream error about a video that was
  // never asked for.
  if (typeof value !== 'string' || value.trim() === '') {
    throw new RpcError('BAD_REQUEST', `${method} requires a non-empty string '${name}'`);
  }
  return value.trim();
}

async function handleRequest(request: RpcRequest) {
  const { id, method, params } = request;

  if (method === '$cancel') {
    // Narrowed rather than asserted: the id arrived over a wire, and a frame
    // carrying `{"id": {}}` must be ignored, not used as a Map key.
    const cancelId = params?.id;
    if (typeof cancelId === 'number' || typeof cancelId === 'string') {
      abortControllers.get(cancelId)?.abort();
    }
    return;
  }

  if (id === undefined) {
    return;
  }

  // Checked before anything interpolates it. `{"method": {"toString": null}}` is
  // a real frame the transport has to survive, and `${method}` on that object
  // throws "Cannot convert object to primitive value" — from inside the line
  // building the error message, so the failure arrives as an UPSTREAM_ERROR
  // about a client bug. Which is `auto`, so the app would retry it.
  if (typeof method !== 'string') {
    emitError(id, new RpcError('BAD_REQUEST', `method must be a string, got ${typeof method}`));
    return;
  }

  const abortController = new AbortController();
  abortControllers.set(id, abortController);

  try {
    if (method === 'auth.verify') {
      const { verifyAuth } = await import('../innertube/session.ts');
      const session = await getBrowseSession();
      const result = await verifyAuth(session, (s) => fetchBaseBrowse(s, 'FEwhat_to_watch'));
      emitResponse(id, result);
    } else if (method === 'feed.home') {
      const { parseFeed } = await import('../parser/feed.ts');
      const session = await getBrowseSession();
      // `||` over both, exactly as before: a non-string is absent, and an empty
      // string falls through to the next candidate and then to a base browse.
      // The "All" chip's token *is* `''`, so that last step is load-bearing.
      const continuation = typeof params?.continuation === 'string' ? params.continuation : '';
      const chipToken = typeof params?.chipToken === 'string' ? params.chipToken : '';
      const token = continuation || chipToken;
      const raw = token
        ? await session.execute('/browse', { browseId: 'FEwhat_to_watch', continuation: token })
        : await fetchBaseBrowse(session, 'FEwhat_to_watch');
      const result = parseFeed(raw, 'home');
      emitResponse(id, result);
    } else if (method === 'playback.open') {
      // Validate *before* the dynamic import. `videoId` is the one parameter the
      // ladder cannot proceed without, and it comes off a wire — checking here
      // makes a malformed frame a BAD_REQUEST the app can act on, rather than a
      // `TypeError` from five tiers down arriving as UPSTREAM_ERROR, which is
      // `auto`, so the app would have retried a request that can never succeed.
      //
      // Order matters beyond tidiness: `import('../playback/resolve.ts')` pulls
      // in the whole resolution module graph, and doing that first made a
      // rejected request pay for a ladder it was never going to use.
      const videoId = requireString(params, 'videoId', 'playback.open');
      const { openPlayback } = await import('../playback/resolve.ts');
      const session = await getResolveSession();
      const result = await openPlayback(
        { session },
        { videoId, preload: params?.preload === true },
      );
      emitResponse(id, result);
    } else {
      emitError(id, new RpcError('BAD_REQUEST', `Unknown method: ${method}`));
    }
  } catch (error) {
    if (nameOf(error) === 'AbortError') {
      // Aborted, don't send a response
    } else {
      emitError(id, error);
    }
  } finally {
    abortControllers.delete(id);
  }
}

export function startRpcServer() {
  const capabilities = announceCapabilities();
  emitEvent('event.ready', {
    protocolVersion: 1,
    capabilities
  });

  // No `output`. stdout is the protocol (hard invariant 3), and handing it to
  // readline hands readline a writer into the NDJSON stream. `terminal: false`
  // means it does not use that writer *today* — it makes the gun silent, not
  // unloaded. Anything that later flips `terminal`, or calls `rl.prompt()` or
  // `rl.write()`, corrupts the stream from inside a module that has no business
  // writing to it, and the failure lands on the Flutter side as a frame that
  // will not parse.
  const rl = createInterface({
    input: process.stdin,
    terminal: false
  });

  rl.on('line', (line) => {
    if (!line.trim()) return;
    try {
      const request = JSON.parse(line) as RpcRequest;
      handleRequest(request).catch(e => log.error(`Unhandled request error: ${e}`));
    } catch (e) {
      log.error(`Malformed JSON: ${messageOf(e)}`);
    }
  });

  rl.on('close', () => {
    process.exit(0);
  });
}
