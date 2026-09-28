import { createInterface } from 'node:readline';
import type { Session } from '../innertube/session.ts';
import { browseAuth, HOME_BROWSE_ID } from '../innertube/auth.ts';
import { RpcError, isRpcError, messageOf, nameOf } from '../errors.ts';
import { logger } from '../log.ts';
import { redact } from '../redact.ts';
import { announceCapabilities } from '../capabilities.ts';
import { PLAYBACK_REPORT_STATES } from '../types.ts';
import type { CaptionOffset, CaptionStyle, PlaylistPrivacy } from '../types.ts';
import type { RgbaColor } from '../captions/cues.ts';
import type { SearchFilters } from '../parser/search-filters.ts';

const log = logger('rpc');

let resolveSessionPromise: Promise<Session> | null = null;

/**
 * The browse session, and the only one that ever sees a cookie.
 *
 * The state behind this now lives in `innertube/auth.ts` (Task 22), because the
 * cookie can change at runtime: `auth.setCookie` replaces the session, and the
 * base-browse cache below has to be replaced with it or a sign-in verifies
 * against the anonymous response it just superseded. That file has the rest.
 *
 * `YT_COOKIE` still seeds it — the development path is unchanged — and a client
 * `auth.setCookie` overrides that seed for the life of the process.
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
  return browseAuth.session();
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

/*
 * `remintResolveSession()` used to live here — its only caller was F20's
 * poisoned-bucket retry, which is retired (`architecture.md` F20, and the note
 * at `playback.open` below). Removed with it rather than left dead, because a
 * dead exported helper is what the revival reached for last time.
 *
 * Its safety property is the part worth keeping, and it applies to anything
 * that ever re-mints a session here: **replace the resolve session only.**
 * `browseSessionPromise` is the `WEB` session carrying the user's cookies, and
 * dropping it to fix a stream URL signs them out — silently, because a degraded
 * session answers HTTP 200 with an empty feed (F7). That is a worse failure
 * than the one being fixed.
 */

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
 * A base browse response, briefly cached — see `innertube/auth.ts`.
 *
 * The cache moved onto the session holder in Task 22, and it moved for a
 * reason: a cookie can change at runtime now, so an entry written by the
 * session a sign-in replaced would answer the `auth.verify` that immediately
 * follows it — reporting `degraded` for a session that just authenticated. The
 * session is no longer a parameter because it is no longer the caller's to
 * choose; it is whichever one the cookie currently implies.
 */
function fetchBaseBrowse(browseId: string): Promise<unknown> {
  return browseAuth.baseBrowse(browseId);
}

const abortControllers = new Map<number | string, AbortController>();

function emitResponse(id: number | string, result: unknown) {
  process.stdout.write(JSON.stringify({ id, result }) + '\n');
}

function emitError(id: number | string, error: unknown) {
  process.stdout.write(errorLine(id, error) + '\n');
}

/**
 * The NDJSON line a failure becomes — separated from the write so it can be
 * asserted on.
 *
 * Exported for `redact.test.ts`, which needs to prove that a cookie inside an
 * error message never reaches this wire. Proving that by spawning a sidecar and
 * provoking a real upstream failure would need a network and a way to make
 * YouTube fail on demand; proving it here needs neither and tests the same
 * bytes.
 */
export function errorLine(id: number | string, error: unknown): string {
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
  // The second chokepoint (Task 22 §5, `redact.ts`). An error envelope is the
  // one thing on this wire built from a message the sidecar did not write: a
  // rejection from youtubei.js or from `fetch` can quote the request it failed
  // on, cookie header included, and the app renders that message in a snackbar.
  // Redacting the whole envelope rather than the message field alone costs one
  // pass over a short string and cannot be got wrong later by a `code` or a
  // field someone adds.
  return redact(JSON.stringify({ id, error: envelope }));
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
      emitResponse(id, await browseAuth.verify());
    } else if (method === 'auth.setCookie') {
      // The cookie is validated for *shape* and never for content, and it never
      // appears in an error message. `requireString` reports the field name, not
      // the value — which is the whole of Task 22 §5 as it applies to this line.
      const cookie = requireString(params, 'cookie', 'auth.setCookie');
      const result = await browseAuth.setCookie(cookie);
      // `{state}` per §3.1, and the state is measured — `setCookie` fetched
      // home and counted tiles before answering. Never cookie presence.
      emitResponse(id, { state: result.state });
    } else if (method === 'auth.signOut') {
      browseAuth.signOut();
      emitResponse(id, {});
    } else if (method === 'auth.status') {
      emitResponse(id, await browseAuth.status());
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
        : await fetchBaseBrowse(HOME_BROWSE_ID);
      const result = parseFeed(raw, 'home');
      // Explicit rather than `emitResponse(id, result)`: `FeedResult` carries
      // an internal `artistPanel` field search.query uses (below), and the
      // wire contract for `feed.home` is exactly `{chips, items,
      // continuation}` — picking fields here is what keeps a field added to
      // the parser's return type from silently widening every surface's
      // response.
      emitResponse(id, { chips: result.chips, items: result.items, continuation: result.continuation });
    } else if (method === 'feed.subscriptions') {
      // Same base-browse cache as `feed.home` (`auth.verify`-then-`feed.home`
      // is exactly the pattern the app also runs on this surface for the
      // anonymous/degraded check — Task 20 §1), and the same continuation
      // shape §3.2 already promises. No chip bar: `feed.subscriptions` never
      // carried one, so this never calls `mapChip` and the result omits it —
      // `ItemListResult`, not `FeedResult`, per the table in `types.ts`.
      const { parseFeed } = await import('../parser/feed.ts');
      const session = await getBrowseSession();
      const continuation = optionalString(params, 'continuation', 'feed.subscriptions');
      const raw = continuation
        ? await session.execute('/browse', { continuation })
        : await fetchBaseBrowse('FEsubscriptions');
      const result = parseFeed(raw, 'subscriptions');
      emitResponse(id, { items: result.items, continuation: result.continuation });
    } else if (method === 'subscriptions.channels') {
      // Task 21 §4. A different browse endpoint entirely from the video feed
      // above — `FEchannels` (confirmed live: its own `GetChannels_rid`
      // tracking param, page title "All subscriptions") rather than
      // `FEsubscriptions`. Items are plain `channelRenderer` nodes, so this
      // needs no parser code of its own: `mapClassicChannel` already handles
      // the shape, including Task 20's protocol-relative-avatar and
      // videoCountText-carries-subscribers fixes, both confirmed live on this
      // endpoint too. Same base-browse cache and continuation shape as every
      // other list method here. Sort order is fixed (server returns
      // alphabetical, confirmed stable across a page boundary) — there is no
      // sort parameter to expose.
      const { parseFeed } = await import('../parser/feed.ts');
      const session = await getBrowseSession();
      const continuation = optionalString(params, 'continuation', 'subscriptions.channels');
      const raw = continuation
        ? await session.execute('/browse', { continuation })
        : await fetchBaseBrowse('FEchannels');
      const result = parseFeed(raw, 'channels');

      // The app's A–Z scrubber depends on that fixed order, and nothing in the
      // request asks for it — so if YouTube's default ever changes, every
      // letter jump silently lands on the wrong row. Check the base page (a
      // continuation resumes mid-alphabet and has no first bucket to compare
      // against) and say so on stderr rather than let it be a wrong answer
      // nobody notices.
      if (!continuation) {
        const { firstChannelOrderViolation } = await import('../parser/channel-order.ts');
        const violation = firstChannelOrderViolation(result.items);
        if (violation) {
          log.error(
            `subscriptions.channels is NOT alphabetical: channel ${violation.index} buckets to ` +
              `'${violation.bucket}' after '${violation.previousBucket}'. The A–Z index in the ` +
              `app assumes this order (protocol.md §3.3) and will jump to the wrong rows.`,
          );
        }
      }

      emitResponse(id, { items: result.items, continuation: result.continuation });
    } else if (method === 'search.query') {
      // Browse-generation, per §2.3's client table: `WEB` with cookies, same
      // session `feed.home` uses. A continuation carries its own context —
      // verified live 2026-08-27, `{continuation}` alone pages a search result
      // exactly like a browse continuation does — so `q` and `filters` are not
      // resent on page 2 even though the caller may still be holding them.
      const q = requireString(params, 'q', 'search.query');
      const continuation = optionalString(params, 'continuation', 'search.query');
      const filters = searchFiltersParam(params);
      const { parseFeed } = await import('../parser/feed.ts');
      const { buildSearchParams } = await import('../parser/search-filters.ts');
      const session = await getBrowseSession();
      const raw = continuation
        ? await session.execute('/search', { continuation })
        : await session.execute('/search', {
            query: q,
            ...(buildSearchParams(filters) ? { params: buildSearchParams(filters) } : {}),
          });
      const result = parseFeed(raw, 'search');
      // ItemListResult, not FeedResult: search carries no chip bar of its own
      // (protocol.md §3.3), so `chips` is dropped here rather than shipped
      // empty — an empty `chips: []` would invite a caller to render one.
      // `artist` is Task 21 §3: populated only when the response carried an
      // `officialCardViewModel`, `null` on every ordinary search.
      emitResponse(id, { items: result.items, continuation: result.continuation, artist: result.artistPanel });
    } else if (method === 'search.suggest') {
      // Not InnerTube — a different, unauthenticated endpoint entirely. See
      // `search/suggest.ts` for what was actually measured here; §3.3's
      // assumption that this rides the same `/search` surface as
      // `search.query` does not hold.
      const q = requireString(params, 'q', 'search.suggest');
      const { getSearchSuggestions } = await import('../search/suggest.ts');
      const result = await getSearchSuggestions(q, abortController.signal);
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
      //
      // **`openPlayback`, not `openPlaybackPastBucket` — F20's re-mint is
      // retired, and this line is where it gets revived by accident.** Read
      // `architecture.md` F20 before touching it. Short version: the re-mint
      // worked in August only because it randomly drew *unflagged* buckets;
      // the PO-token rollout it was escaping is now at 100%, so there is
      // nothing left to draw and `MAX_REMINTS` is 0. `bucket.test.ts` asserts
      // this call site stays on the bare ladder.
      //
      // It has already been revived once. `663edb1` (a captions refactor)
      // unwired it by accident but left `remintResolveSession` in the argument
      // object; `c53fb54` retired the mechanism the next day and left the call
      // site alone, correctly. Task 22 then read that leftover argument — an
      // excess property `PlaybackDeps` does not declare, and a real typecheck
      // error — as evidence the wiring was *broken* and restored the wrapper.
      // Dropping the argument, not restoring the wrapper, was the fix.
      const videoId = requireString(params, 'videoId', 'playback.open');
      // Task 26: recorded on the playback session so `playback.report` can put
      // `list=` on the watchtime ping. It is deliberately *not* passed to the
      // resolution ladder — see `OpenParams.playlistId`.
      const playlistId = optionalString(params, 'playlistId', 'playback.open');
      const { openPlayback } = await import('../playback/resolve.ts');
      const session = await getResolveSession();
      // A plain cookie string for tier 4 (`yt-dlp`) alone, never a session —
      // the resolve `session` above stays the anonymous identity
      // `resolve-anonymous.test.ts` guards, and this value never reaches
      // `createSession`. `architecture.md` A12, `todo.md` 54.
      const result = await openPlayback(
        { session, cookie: browseAuth.cookieForYtDlp() },
        { videoId, preload: params?.preload === true, playlistId },
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
    } else if (method === 'video.comments') {
      const videoId = optionalString(params, 'videoId', 'video.comments');
      const continuation = optionalString(params, 'continuation', 'video.comments');
      const { getComments } = await import('../video/info.ts');
      const result = await getComments(await getBrowseSession(), { videoId, continuation });
      emitResponse(id, result);
    } else if (method === 'mix.start') {
      // `playlistId`, not `videoId` — §3.3's old signature could not name
      // which of a video's several mixes was meant. `videoId` is the optional
      // seed. Task 26.
      const playlistId = requireString(params, 'playlistId', 'mix.start');
      const videoId = optionalString(params, 'videoId', 'mix.start');
      // `MixItem.startParams`, passed back verbatim. Opaque to both ends of the
      // wire except here.
      const startParams = optionalString(params, 'params', 'mix.start');
      const { startMix } = await import('../mix/service.ts');
      const result = await startMix(
        { browse: await getBrowseSession() },
        { playlistId, videoId, params: startParams },
      );
      emitResponse(id, result);
    } else if (method === 'mix.extend') {
      const playlistId = requireString(params, 'playlistId', 'mix.extend');
      const afterVideoId = requireString(params, 'afterVideoId', 'mix.extend');
      const { extendMix } = await import('../mix/service.ts');
      const result = await extendMix(
        { browse: await getBrowseSession() },
        { playlistId, afterVideoId },
      );
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
    } else if (method === 'action.removeFromPlaylist') {
      const playlistId = requireString(params, 'playlistId', 'action.removeFromPlaylist');
      const removeToken = requireString(params, 'removeToken', 'action.removeFromPlaylist');
      const { removeFromPlaylist } = await import('../actions/playlist.ts');
      const result = await removeFromPlaylist(await getBrowseSession(), playlistId, removeToken);
      emitResponse(id, result);
    } else if (method === 'playlist.forVideo') {
      const videoId = requireString(params, 'videoId', 'playlist.forVideo');
      const { playlistsForVideo } = await import('../actions/playlist.ts');
      const result = await playlistsForVideo(await getBrowseSession(), videoId);
      emitResponse(id, result);
    } else if (method === 'playlist.create') {
      const title = requireString(params, 'title', 'playlist.create');
      const privacy = playlistPrivacyParam(params);
      const { createPlaylist } = await import('../actions/playlist.ts');
      const result = await createPlaylist(await getBrowseSession(), title, privacy);
      emitResponse(id, result);
    } else if (method === 'playlist.delete') {
      const playlistId = requireString(params, 'playlistId', 'playlist.delete');
      const { deletePlaylist } = await import('../actions/playlist.ts');
      const result = await deletePlaylist(await getBrowseSession(), playlistId);
      emitResponse(id, result);
    } else if (method === 'action.like') {
      const videoId = requireString(params, 'videoId', 'action.like');
      const { like } = await import('../actions/interaction.ts');
      const result = await like(await getBrowseSession(), videoId);
      emitResponse(id, result);
    } else if (method === 'action.dislike') {
      const videoId = requireString(params, 'videoId', 'action.dislike');
      const { dislike } = await import('../actions/interaction.ts');
      const result = await dislike(await getBrowseSession(), videoId);
      emitResponse(id, result);
    } else if (method === 'action.removeRating') {
      const videoId = requireString(params, 'videoId', 'action.removeRating');
      const { removeRating } = await import('../actions/interaction.ts');
      const result = await removeRating(await getBrowseSession(), videoId);
      emitResponse(id, result);
    } else if (method === 'action.postComment') {
      const createParams = requireString(params, 'createParams', 'action.postComment');
      const commentText = requireString(params, 'commentText', 'action.postComment');
      const { postComment } = await import('../actions/comments.ts');
      const result = await postComment(await getBrowseSession(), createParams, commentText);
      emitResponse(id, result);
    } else if (method === 'action.replyToComment') {
      const replyParams = requireString(params, 'replyParams', 'action.replyToComment');
      const commentText = requireString(params, 'commentText', 'action.replyToComment');
      const { replyToComment } = await import('../actions/comments.ts');
      const result = await replyToComment(await getBrowseSession(), replyParams, commentText);
      emitResponse(id, result);
    } else if (method === 'action.deleteComment') {
      const deleteParams = requireString(params, 'deleteParams', 'action.deleteComment');
      const { deleteComment } = await import('../actions/comments.ts');
      const result = await deleteComment(await getBrowseSession(), deleteParams);
      emitResponse(id, result);
    } else if (method === 'action.rateComment') {
      // One of the comment's four server-supplied vote blobs, verbatim — the
      // client picks which transition it wants, because it is the one holding
      // the state the user is looking at.
      const voteParams = requireString(params, 'params', 'action.rateComment');
      const { rateComment } = await import('../actions/comments.ts');
      const result = await rateComment(await getBrowseSession(), voteParams);
      emitResponse(id, result);
    } else if (method === 'action.subscribe') {
      const channelId = requireString(params, 'channelId', 'action.subscribe');
      const { subscribe } = await import('../actions/interaction.ts');
      const result = await subscribe(await getBrowseSession(), channelId);
      emitResponse(id, result);
    } else if (method === 'action.unsubscribe') {
      const channelId = requireString(params, 'channelId', 'action.unsubscribe');
      const { unsubscribe } = await import('../actions/interaction.ts');
      const result = await unsubscribe(await getBrowseSession(), channelId);
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
  // Every forceXxx field was missing here entirely until this fix: none of
  // them were ever read off `record`, so `resolved.style?.forceTextColor ??
  // true` (and the other eight, plus the master) always saw `undefined` and
  // read as force-on regardless of what the client actually sent. Silent —
  // nothing threw, nothing logged — and unnoticed because force is a no-op
  // on any track with nothing authored to defer to (ASR, most plain tracks),
  // which is what every prior check of "does force do anything" happened to
  // be tested against.
  const boolOrUndefined = (value: unknown): boolean | undefined =>
    typeof value === 'boolean' ? value : undefined;
  return {
    fontFamily: typeof record['fontFamily'] === 'string' ? record['fontFamily'] : null,
    fontSizePercent: finiteOrNull(record['fontSizePercent']),
    textColor: colorOrNull(record['textColor'], 'style.textColor'),
    textOpacity: opacityOrNull(record['textOpacity']),
    background: colorOrNull(record['background'], 'style.background'),
    backgroundOpacity: opacityOrNull(record['backgroundOpacity']),
    window: colorOrNull(record['window'], 'style.window'),
    windowOpacity: opacityOrNull(record['windowOpacity']),
    edgeStyle: (edge ?? null) as CaptionStyle['edgeStyle'],
    forceStyleEnabled: boolOrUndefined(record['forceStyleEnabled']),
    forceFontFamily: boolOrUndefined(record['forceFontFamily']),
    forceFontSize: boolOrUndefined(record['forceFontSize']),
    forceTextColor: boolOrUndefined(record['forceTextColor']),
    forceTextOpacity: boolOrUndefined(record['forceTextOpacity']),
    forceBackgroundColor: boolOrUndefined(record['forceBackgroundColor']),
    forceBackgroundOpacity: boolOrUndefined(record['forceBackgroundOpacity']),
    forceWindowColor: boolOrUndefined(record['forceWindowColor']),
    forceWindowOpacity: boolOrUndefined(record['forceWindowOpacity']),
    forceEdgeStyle: boolOrUndefined(record['forceEdgeStyle']),
  };
}

// ---------------------------------------------------------------------------
// `search.query`'s `filters` parameter
// ---------------------------------------------------------------------------

/**
 * `search.query`'s `filters` object, or `BAD_REQUEST` naming the bad field —
 * same shape-checked-before-use policy as every other param here, and the same
 * reason: an unvalidated filter value would otherwise reach
 * `buildSearchParams` as `undefined`, silently searching unfiltered rather than
 * failing loudly on a client bug.
 */
function searchFiltersParam(
  params: Record<string, unknown> | undefined,
): SearchFilters | null {
  const raw = params?.['filters'];
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== 'object') {
    throw new RpcError('BAD_REQUEST', "search.query: 'filters' must be an object if present");
  }
  const record = raw as Record<string, unknown>;

  function enumOrUndefined<T extends string>(field: string, allowed: readonly T[]): T | undefined {
    const value = record[field];
    if (value === undefined || value === null) return undefined;
    if (typeof value !== 'string' || !allowed.includes(value as T)) {
      throw new RpcError(
        'BAD_REQUEST',
        `search.query: 'filters.${field}' must be one of ${allowed.join(', ')}`,
      );
    }
    return value as T;
  }

  return {
    uploadDate: enumOrUndefined('uploadDate', ['hour', 'today', 'week', 'month', 'year'] as const),
    type: enumOrUndefined('type', ['video', 'channel', 'playlist', 'movie'] as const),
    duration: enumOrUndefined('duration', ['short', 'medium', 'long'] as const),
    sortBy: enumOrUndefined('sortBy', ['viewCount'] as const),
  };
}

/** `playlist.create`'s optional `privacy` — one of the closed set, or `BAD_REQUEST` naming it. */
function playlistPrivacyParam(
  params: Record<string, unknown> | undefined,
): PlaylistPrivacy | null {
  const raw = params?.['privacy'];
  if (raw === undefined || raw === null) return null;
  if (raw !== 'public' && raw !== 'unlisted' && raw !== 'private') {
    throw new RpcError(
      'BAD_REQUEST',
      "playlist.create: 'privacy' must be one of public, unlisted, private",
    );
  }
  return raw;
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

/**
 * RGB only — `a` is not read here. Opacity is `textOpacity`/
 * `backgroundOpacity`/`windowOpacity`'s job now, sent and parsed
 * separately (`opacityOrNull`), so a colour picked without touching opacity
 * cannot smuggle a stale or default alpha back in through this object. The
 * returned `RgbaColor.a` is a placeholder (`1`) that nothing downstream may
 * read.
 */
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
    a: 1,
  };
}

function opacityOrNull(value: unknown): number | null {
  const n = finiteOrNull(value);
  return n === null ? null : Math.max(0, Math.min(1, n));
}
