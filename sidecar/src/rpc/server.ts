import { createInterface } from 'node:readline';
import type { Session } from '../innertube/session.ts';
import { RpcError, isRpcError, messageOf, nameOf } from '../errors.ts';
import { logger } from '../log.ts';
import { announceCapabilities } from '../capabilities.ts';
import { PLAYBACK_REPORT_STATES } from '../types.ts';
import type { CaptionOffset, CaptionStyle } from '../types.ts';
import type { RgbaColor } from '../captions/cues.ts';

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

/**
 * Both sessions, for the methods that genuinely need one of each.
 *
 * `video.info` is the only one today: `/next` is a browse call and wants the
 * cookie, while the `/player` half is a resolution call and must ask as the same
 * client ladder tier 1 does, or the shared response is not shared at all. See
 * `video/info.ts` for why that split is the right reading of §2.3.
 */
async function videoDeps(): Promise<{ browse: Session; resolve: Session }> {
  const [browse, resolve] = await Promise.all([getBrowseSession(), getResolveSession()]);
  return { browse, resolve };
}

/**
 * Throw away the resolve session and mint a replacement.
 *
 * **Resolve only, and that is the whole safety property.** `browseSessionPromise`
 * is untouched: it is the `WEB` session carrying the user's cookies, and
 * dropping it would sign them out on a quarter of launches to fix a stream URL —
 * a worse failure, and a silent one, because a degraded session answers HTTP 200
 * with an empty feed (F7). Asserted in `bucket.test.ts`.
 *
 * Used only by the poisoned-bucket retry (`playback/bucket.ts`, F20).
 */
function remintResolveSession(): Promise<Session> {
  resolveSessionPromise = null;
  return getResolveSession();
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

/**
 * An optional string parameter: the value, or `null` when absent.
 *
 * Absent and empty are the same answer here, deliberately — a continuation token
 * is either a real token or there is no next page, and `""` has never meant the
 * latter to any caller. A non-string present is still `BAD_REQUEST`, because
 * that is a client bug rather than an omission.
 */
function optionalString(
  params: Record<string, unknown> | undefined,
  name: string,
  method: string,
): string | null {
  const value = params?.[name];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') {
    throw new RpcError('BAD_REQUEST', `${method}: '${name}' must be a string if present`);
  }
  return value.trim() === '' ? null : value.trim();
}

/**
 * A required finite number, or `BAD_REQUEST`.
 *
 * `Number.isFinite` rather than `typeof === 'number'`: `NaN` is a number, and a
 * `NaN` position reaches the stats endpoint as `st=NaN`, which answers 200 and
 * records nothing. The whole point of validating `playback.report`'s params is
 * that its failures are otherwise invisible.
 */
function requireNumber(
  params: Record<string, unknown> | undefined,
  name: string,
  method: string,
): number {
  const value = params?.[name];
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new RpcError('BAD_REQUEST', `${method} requires a finite number '${name}'`);
  }
  return value;
}

/** One of a closed set, or `BAD_REQUEST` naming what was allowed. */
function requireEnum<T extends string>(
  params: Record<string, unknown> | undefined,
  name: string,
  method: string,
  allowed: readonly T[],
): T {
  const value = params?.[name];
  if (typeof value !== 'string' || !allowed.includes(value as T)) {
    throw new RpcError(
      'BAD_REQUEST',
      `${method} requires '${name}' to be one of ${allowed.join(', ')}`,
    );
  }
  return value as T;
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
      const { openPlaybackPastBucket } = await import('../playback/bucket.ts');
      const session = await getResolveSession();
      const result = await openPlaybackPastBucket(
        { session, remintResolveSession },
        { videoId, preload: params?.preload === true },
      );
      emitResponse(id, result);
    } else if (method === 'video.info') {
      const videoId = requireString(params, 'videoId', 'video.info');
      const { getVideoInfo } = await import('../video/info.ts');
      const result = await getVideoInfo(await videoDeps(), videoId);
      emitResponse(id, result);
    } else if (method === 'video.storyboard') {
      // The resolve session only, deliberately not `videoDeps()`: this must not wait on — or
      // wake — the authenticated browse session (§3.7).
      const videoId = requireString(params, 'videoId', 'video.storyboard');
      const { getStoryboard } = await import('../video/storyboard.ts');
      const result = await getStoryboard(await getResolveSession(), videoId);
      emitResponse(id, result);
    } else if (method === 'captions.list') {
      // The resolve session only, like `video.storyboard`: the track list comes
      // off the `VISIONOS` `/player` response ladder tier 1 already cached, so
      // this must not wait on — or wake — the authenticated browse session.
      const videoId = requireString(params, 'videoId', 'captions.list');
      // `allowFallback: false` is the hover preview's mode — the free answer off
      // the cached tier-1 response, never the fallback's second `/player`. Any
      // value but an explicit `false` keeps the full behaviour, so a caller that
      // omits it gets the complete list.
      const allowFallback = params?.allowFallback !== false;
      // Opt-in, and the caption menu is the only caller that opts in. It costs a
      // `timedtext` GET per track — 69 KB and 73 ms for six, measured — which is
      // a menu's budget and not a video open's. §3.8 keeps this call off the
      // open path, and defaulting it on would put that cost on every video.
      const includeStyled = params?.includeStyled === true;
      const { getCaptionList } = await import('../captions/service.ts');
      const result = await getCaptionList(await getResolveSession(), videoId, {
        allowFallback,
        includeStyled,
        signal: abortController.signal,
      });
      emitResponse(id, result);
    } else if (method === 'captions.get') {
      const videoId = requireString(params, 'videoId', 'captions.get');
      const trackId = requireString(params, 'trackId', 'captions.get');
      // Task 19. Both are optional and both change the *document* rather than
      // anything about the fetch — `protocol.md` §3.8. They are applied here and
      // not through mpv properties because `sub-ass-override=force` overrides the
      // ASS `Style` and not the inline tags task 18 emits, so the property route
      // works on plain tracks and silently does nothing on styled ones. See
      // `captions/style.ts`.
      const { getCaptionTrack } = await import('../captions/service.ts');
      const result = await getCaptionTrack(await getResolveSession(), videoId, trackId, {
        signal: abortController.signal,
        style: captionStyleParam(params),
        offset: captionOffsetParam(params),
      });
      emitResponse(id, result);
    } else if (method === 'video.related') {
      const videoId = requireString(params, 'videoId', 'video.related');
      const continuation = optionalString(params, 'continuation', 'video.related');
      const { getRelated } = await import('../video/info.ts');
      const result = await getRelated(await videoDeps(), { videoId, continuation });
      emitResponse(id, result);
    } else if (method === 'action.addToWatchLater') {
      const videoId = requireString(params, 'videoId', 'action.addToWatchLater');
      const { addToWatchLater } = await import('../actions/playlist.ts');
      const result = await addToWatchLater(await getBrowseSession(), videoId);
      emitResponse(id, result);
    } else if (method === 'action.addToPlaylist') {
      const videoId = requireString(params, 'videoId', 'action.addToPlaylist');
      const playlistId = requireString(params, 'playlistId', 'action.addToPlaylist');
      const { addToPlaylist } = await import('../actions/playlist.ts');
      const result = await addToPlaylist(await getBrowseSession(), videoId, playlistId);
      emitResponse(id, result);
    } else if (method === 'playback.report') {
      // Validated before the import, like `playback.open`: a malformed report is
      // a client bug, and answering it with anything `auto` would have the app
      // retrying a ping that can never land while the real cadence carries on
      // around it.
      const sessionId = requireString(params, 'sessionId', 'playback.report');
      const positionMs = requireNumber(params, 'positionMs', 'playback.report');
      const state = requireEnum(params, 'state', 'playback.report', PLAYBACK_REPORT_STATES);
      const { reportPlayback } = await import('../playback/report.ts');
      const result = await reportPlayback(
        { browse: await getBrowseSession() },
        { sessionId, positionMs, state },
      );
      emitResponse(id, result);
    } else if (method === 'playback.close') {
      const sessionId = requireString(params, 'sessionId', 'playback.close');
      const { closePlaybackSession } = await import('../playback/sessions.ts');
      // Closing an unknown session is not an error. Phase 1 holds no server-side
      // state, so a double close — the app tearing down while a final report is
      // still in flight — has nothing to fail about.
      closePlaybackSession(sessionId);
      emitResponse(id, {});
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

// ---------------------------------------------------------------------------
// `captions.get`'s task-19 parameters
// ---------------------------------------------------------------------------

/**
 * Three optional parameters, validated the same way the rest of this file
 * validates: shape-checked here so a malformed one is a `BAD_REQUEST` naming the
 * field, rather than a document rendered with a `NaN` in a `\pos`.
 *
 * A `NaN` matters more here than it looks. `\pos(NaN,1020)` is not a parse error
 * in ASS — libass drops the tag and the cue reverts to the default position, so
 * a broken drag would present as "the caption sometimes ignores where I put it".
 */
function captionStyleParam(
  params: Record<string, unknown> | undefined,
): CaptionStyle | null {
  const raw = params?.['style'];
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== 'object') {
    throw new RpcError('BAD_REQUEST', "captions.get: 'style' must be an object if present");
  }
  const record = raw as Record<string, unknown>;
  const edge = record['edgeStyle'];
  if (edge != null && edge !== 'none' && edge !== 'outline' && edge !== 'dropShadow') {
    throw new RpcError(
      'BAD_REQUEST',
      "captions.get: 'style.edgeStyle' must be none, outline or dropShadow",
    );
  }
  return {
    fontFamily: typeof record['fontFamily'] === 'string' ? record['fontFamily'] : null,
    fontSizePercent: finiteOrNull(record['fontSizePercent']),
    textColor: colorOrNull(record['textColor'], 'style.textColor'),
    background: colorOrNull(record['background'], 'style.background'),
    window: colorOrNull(record['window'], 'style.window'),
    edgeStyle: (edge ?? null) as CaptionStyle['edgeStyle'],
  };
}

function captionOffsetParam(
  params: Record<string, unknown> | undefined,
): CaptionOffset | null {
  const raw = params?.['offset'];
  if (raw === undefined || raw === null) return null;
  const record = raw as Record<string, unknown>;
  const dx = finiteOrNull(record['dx']);
  const dy = finiteOrNull(record['dy']);
  if (dx === null || dy === null) {
    throw new RpcError('BAD_REQUEST', "captions.get: 'offset' needs finite 'dx' and 'dy'");
  }
  return { dx, dy };
}

function finiteOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function colorOrNull(value: unknown, name: string): RgbaColor | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object') {
    throw new RpcError('BAD_REQUEST', `captions.get: '${name}' must be an object if present`);
  }
  const record = value as Record<string, unknown>;
  const channel = (key: string) => Math.max(0, Math.min(255, finiteOrNull(record[key]) ?? 0));
  return {
    r: channel('r'),
    g: channel('g'),
    b: channel('b'),
    a: Math.max(0, Math.min(1, finiteOrNull(record['a']) ?? 1)),
  };
}
