/**
 * `playback.open` — the resolution ladder from `protocol.md` §3.5.
 *
 * Three tiers, tried in order, each of which either returns a `PlaybackSource` or
 * throws to decline. They keep the numbers of the original five, because tests,
 * logs and docs name them that way:
 *
 *   1. `VISIONOS` plain adaptive — the primary path (F5, F11, F13)
 *   4. `yt-dlp` subprocess         — age-restricted, Vevo, whatever else refuses
 *   5. itag 18 progressive         — 360p from the `ANDROID` response (F9),
 *                                    nearly always there, `qualityDegraded`
 *
 * Tier 2 (`MWEB` plain adaptive) was retired on 2026-08-19 in `c53fb54`, and
 * tier 3 (SABR → local DASH) is Phase 2: `tierSabrDash` below is its unbuilt
 * placeholder and nothing calls it. `architecture.md` §2.4 has the retirement.
 *
 * `VISIONOS` leads because it is the only client measured that satisfies every
 * constraint at once: plain URLs, no `n` to decipher, open-ended ranges accepted
 * (F10 is an `MWEB` property, not a YouTube one), bare GETs accepted, throughput
 * above the bar, hardware decode, and seeks on the libmpv media_kit ships with no
 * options set (F13). Its one condition is a server-issued visitor id — see
 * `tierVisionOs`.
 *
 * **Nothing in this ladder deciphers.** `VISIONOS` and `ANDROID` URLs carry no
 * `n`, and yt-dlp runs its own transform. Every address still crosses `sign()`
 * or `adoptExternallyDeciphered()`, so the `SignedUrl` boundary (hard
 * invariant 2) holds — but the signature/`n` transform behind `sign()` only
 * runs in the network suite, which still calls `tierPlainAdaptive` with
 * `MWEB`. Keep it: it is the only proven decipher path, and Phase 2 may need
 * it. Do not restore `MWEB` as a playback tier either — its URLs refuse the
 * open-ended range ffmpeg always sends (F10). `MWEB` is still asked for one
 * thing here: a live stream's start time, when tier 1's response lacks it.
 *
 * The ladder is the error-handling strategy, not a fallback bolted onto one. A
 * tier that cannot serve a video throws; the ladder logs it and moves down. Only
 * when every tier declines does the caller see `STREAM_UNAVAILABLE`.
 *
 * **Flutter must not be able to tell which tier served it.** `transport` is
 * telemetry and `qualityDegraded` drives a badge; neither changes how the client
 * opens the source. That is what makes the Phase 2 swap a transport change
 * rather than a protocol revision.
 */

import { ytDlpBinary } from '../capabilities.ts';
import { RpcError, hasCode, type EnvelopeErrorCode } from '../errors.ts';
import { logger } from '../log.ts';
import { getPlayer, type Player } from '../innertube/player.ts';
import { getPlayerEntry, getPlayerResponse } from '../innertube/player-response.ts';
import { refreshVisitorId, type PlayerClient, type Session } from '../innertube/session.ts';
import { sign, adoptExternallyDeciphered, type SignedUrl } from '../innertube/signed-url.ts';
import type { PlaybackSource, PlaybackTransport, PlaybackVariant, PlayerFormat, PlayerResult } from '../types.ts';
import { isSabrOnly } from './sabr-detect.ts';
import { nullPoTokenProvider, type PoTokenProvider } from './po-token.ts';
import { openPlaybackSession } from './sessions.ts';

/**
 * Refusals that end the ladder instead of declining down it.
 *
 * Each names a video that is **fine** and simply cannot be resolved by any
 * tier: a premiere has not started, and members-only content is behind a
 * purchase. Trying the remaining rungs costs four more `/player` calls and
 * arrives at `STREAM_UNAVAILABLE`, which is `retry: "user"` — so the UI offers
 * a *Try again* that provably cannot work, on a video nothing is wrong with.
 *
 * **A list rather than a check per code, because the check is easy to forget.**
 * `VIDEO_MEMBERS_ONLY` was thrown by `assertPlayable`, documented here and in
 * `protocol.md` as ending the ladder, and then quietly collected as an ordinary
 * decline for a day — the rethrow named `VIDEO_UPCOMING` alone. Adding a
 * terminal code now means adding it here, in one place, next to this note.
 */
const LADDER_TERMINAL_CODES: readonly EnvelopeErrorCode[] = [
  'VIDEO_UPCOMING',
  'VIDEO_MEMBERS_ONLY',
];

const log = logger('playback');

/** Below this, the user is watching a visibly worse video than YouTube has. */
const DEGRADED_BELOW_HEIGHT = 720;

/** itag 18: 360p, muxed, and present even on a SABR-only response (F9). */
const PROGRESSIVE_FALLBACK_ITAG = 18;

export interface PlaybackDeps {
  /**
   * The anonymous session streams are resolved through (§2.3). Browsing and
   * reporting use the authenticated `WEB` session; they are separate calls on
   * purpose, and no CPN is bridged between them.
   *
   * One session serves every tier — the client is chosen per `/player` call, not
   * per session — but it must carry a server-issued visitor id, which is
   * `createSession`'s default. See F5.
   */
  session: Session;
  poTokens?: PoTokenProvider;
  /** Override the `yt-dlp` binary for tier 4. Defaults to `YT_DLP_PATH` or PATH. */
  ytDlpPath?: string;
}

export interface OpenParams {
  videoId: string;
  /**
   * Resolve and warm the caches without treating this as a watch.
   *
   * Phase 1 keeps no session registry (that is `protocol.md` §5, Phase 2), so
   * today the difference is that a preload does not log as a real open and its
   * `sessionId` is not expected to be used. The parameter exists now so §3.6
   * does not need a protocol change later.
   */
  preload?: boolean;

  /**
   * The mix or playlist this watch belongs to (Task 26).
   *
   * **Recorded on the playback session, never sent to the resolution ladder.**
   * A playlist context changes nothing about which streams exist, so asking for
   * one here would split the `/player` cache by playlist and buy a second round
   * trip per open for nothing. It matters only at report time, where it becomes
   * `list=` on the watchtime ping.
   */
  playlistId?: string | null;
}

// ---------------------------------------------------------------------------
// Format selection
// ---------------------------------------------------------------------------

/**
 * Codec preference among equally-tall video formats.
 *
 * libmpv decodes all three. VP9 first because it is the one YouTube ships at
 * every resolution and the one with the widest hardware-decode coverage on the
 * Windows machines this targets; AV1 next; H.264 last, since above 1080p it
 * simply is not offered.
 */
const VIDEO_CODEC_RANK = ['vp9', 'vp09', 'av01', 'avc1'];

function codecRank(format: PlayerFormat, order: string[]): number {
  const codecs = format.codecs ?? '';
  const index = order.findIndex((prefix) => codecs.startsWith(prefix));
  return index === -1 ? order.length : index;
}

function compare(...values: number[]): number {
  for (const value of values) if (value !== 0) return value;
  return 0;
}

/** Video-only adaptive formats that actually carry an address, best first. */
function rankVideo(formats: PlayerFormat[]): PlayerFormat[] {
  return formats
    .filter((f) => f.isAdaptive && f.hasVideo && !f.hasAudio && addressOf(f) !== null)
    .sort((a, b) =>
      compare(
        (b.height ?? 0) - (a.height ?? 0),
        (b.fps ?? 0) - (a.fps ?? 0),
        codecRank(a, VIDEO_CODEC_RANK) - codecRank(b, VIDEO_CODEC_RANK),
        (b.bitrate ?? 0) - (a.bitrate ?? 0),
      ),
    );
}

/**
 * Audio-only adaptive formats, best first.
 *
 * Two filters that are not obvious:
 *
 *   - DRC duplicates are pushed last. They share an itag with the original and
 *     differ only in loudness, so picking one is silent and wrong.
 *   - Surround tracks are pushed behind stereo. mpv will happily downmix 5.1,
 *     but the result is quieter and muddier than the stereo master on the
 *     two-speaker setups this app runs on.
 */
function rankAudio(formats: PlayerFormat[]): PlayerFormat[] {
  return formats
    .filter((f) => f.isAdaptive && f.hasAudio && !f.hasVideo && addressOf(f) !== null)
    .sort((a, b) =>
      compare(
        Number(a.isDrc) - Number(b.isDrc),
        Number((a.audioChannels ?? 2) > 2) - Number((b.audioChannels ?? 2) > 2),
        (b.bitrate ?? 0) - (a.bitrate ?? 0),
      ),
    );
}

/** Whatever this format can be signed from: a plain URL, or its cipher. */
function addressOf(format: PlayerFormat): string | null {
  return format.rawUrl ?? format.signatureCipher;
}

async function signFormat(
  format: PlayerFormat,
  player: Player,
  poToken: string | null,
): Promise<SignedUrl> {
  const address = addressOf(format);
  if (address === null) {
    throw new RpcError('STREAM_UNAVAILABLE', `itag ${format.itag} carries neither a URL nor a cipher`);
  }
  return sign(address, player, { poToken });
}

// ---------------------------------------------------------------------------
// Storyboards
// ---------------------------------------------------------------------------

/**
 * The sprite sheet hover previews use.
 *
 * Levels run small to large; we take the largest, because the preview surface is
 * a single shared overlay rather than a per-tile player (§2.6) and one sheet at
 * a usable resolution beats several at a thumbnail one.
 */
function storyboardTemplate(response: PlayerResult): string | null {
  const best = [...response.storyboards].sort(
    (a, b) => (b.thumbnailWidth ?? 0) - (a.thumbnailWidth ?? 0),
  )[0];
  return best?.templateUrl ?? null;
}

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

function newSessionId(): string {
  return crypto.randomUUID();
}

interface SourceParts {
  variants: PlaybackVariant[];
  response: PlayerResult | null;
  transport: PlaybackTransport;
  durationMs?: number | null;
}

function assemble(parts: SourceParts): PlaybackSource {
  const top = parts.variants[0];
  const topHeight = top?.height ?? null;
  const durationSeconds = parts.response?.durationSeconds ?? null;

  return {
    sessionId: newSessionId(),
    durationMs: parts.durationMs ?? (durationSeconds === null ? null : durationSeconds * 1000),
    startTimestamp: parts.response?.startTimestamp ?? null,
    storyboardTemplate: parts.response ? storyboardTemplate(parts.response) : null,
    posterUrl: parts.response?.posterUrl ?? null,
    // A uniform rule rather than a bottom-rung special case: tier 5 is 360p so
    // it is always degraded, and a tier-1 resolution that could only find 360p is
    // degraded too, which the user deserves to be told either way.
    qualityDegraded: topHeight === null || topHeight < DEGRADED_BELOW_HEIGHT,
    transport: parts.transport,
    variants: parts.variants,
  };
}

/** Convenience: the best variant's height, for logging. */
function topHeight(source: PlaybackSource): number | null {
  return source.variants[0]?.height ?? null;
}

/**
 * Turn a non-OK playability status into the right error.
 *
 * `LOGIN_REQUIRED` and `AGE_VERIFICATION_REQUIRED` are exactly the cases tier 3
 * exists for, so they decline rather than terminate. The distinction matters:
 * throwing `STREAM_UNAVAILABLE` here would surface an "Unavailable" state on a
 * video `yt-dlp` can play.
 */
function assertPlayable(response: PlayerResult, videoId: string): void {
  const status = response.playabilityStatus;
  if (status === null || status === 'OK') return;

  const reason = response.playabilityReason ?? '(no reason given)';

  // A premiere. Checked before everything else because `LIVE_STREAM_OFFLINE`
  // would otherwise fall through to `STREAM_UNAVAILABLE` and present a perfectly
  // healthy video as one that would not open.
  if (response.isUpcoming) {
    throw new RpcError('VIDEO_UPCOMING', reason);
  }

  // Members-only, and it ends the ladder for the same reason a premiere does:
  // no lower rung can buy a membership, so declining through all four spends
  // three more `/player` calls to arrive at a worse-worded version of this.
  //
  // It also matters that this is not `STREAM_UNAVAILABLE`: that code is `user`,
  // so the watch page would offer a *Try again* that can only ever fail, on a
  // video that is working exactly as the channel intends.
  if (response.isMembersOnly) {
    throw new RpcError('VIDEO_MEMBERS_ONLY', reason);
  }

  // Throttled — YouTube limiting this connection's anonymous resolution (F20
  // saw it after ~180 resolutions in an hour). `LOGIN_REQUIRED` alone is not
  // the signal: an age gate answers with the same status ("Sign in to confirm
  // your age"). So this reads YouTube's own wording, the same trade
  // `VIDEO_MEMBERS_ONLY` makes: it refines a response that has already failed,
  // and a locale the pattern misses falls back to `STREAM_UNAVAILABLE`, which
  // is what it was before. By the time tier 1 gets here it has already retried
  // with a fresh visitor id, so a bad id is ruled out. Not terminal — a lower
  // tier may still get through; `descendLadder` reports it if none does.
  if (status === 'LOGIN_REQUIRED' && /not a bot/i.test(reason)) {
    throw new RpcError('RATE_LIMITED', `${videoId}: ${status} — ${reason}`);
  }

  if (status === 'UNPLAYABLE' && /page needs to be reloaded/i.test(reason)) {
    // Hard invariant 7. If this ever fires, the `/player` payload lost its
    // signatureTimestamp or it no longer matches the deciphering player.
    throw new RpcError(
      'UPSTREAM_ERROR',
      `${videoId}: UNPLAYABLE — "${reason}". That is a missing or stale ` +
        'signatureTimestamp on the /player call, not a broken video.',
    );
  }

  throw new RpcError('STREAM_UNAVAILABLE', `${videoId}: ${status} — ${reason}`);
}

// ---------------------------------------------------------------------------
// Player-revision consistency — Task 04 §1
//
// `signatureTimestamp` is stamped onto a `/player` request from
// `session.innertube.session.player` at fetch time (hard invariant 7). The
// script that later deciphers the response's `s`/`n` comes from a separate
// `getPlayer()` call that, past its TTL, can have rebuilt the session onto a
// *newer* revision — either because the response came from a cache entry
// minted minutes ago under an older one, or because a concurrent caller's
// rebuild landed between this call's fetch and its decipher. Either way the
// response and the script would then describe two different revisions, and
// deciphering that pair is exactly the failure hard invariant 2 exists to
// prevent: a wrong `n` is not rejected, it streams at ~50 KB/s.
//
// `player-response.ts` records which revision produced each response
// (`Entry.playerId`) but does not act on it — the two tiers below are the
// ones that decipher, so they are the ones that check it, right before they
// do, against the `Player` they are about to decipher with.
// ---------------------------------------------------------------------------

/** What this file reads off a `getPlayerEntry` result. */
export interface PlayerEntry {
  result: PlayerResult;
  playerId: string | null;
}

/**
 * Whether anything in this response would actually be run through a player
 * script. Mirrors `sign()`'s own trigger condition in `signed-url.ts` — a
 * `signatureCipher`, or a URL carrying an `n` parameter — directly, rather
 * than importing that file's private client whitelist
 * (`CLIENTS_WITH_N_PARAM`), so this stays a self-contained check instead of
 * reaching into another module's internals for an optimisation.
 *
 * Used to skip the refetch below when a revision mismatch is found but
 * nothing in the response would be deciphered anyway — `VISIONOS` and
 * `ANDROID` formats carry neither, so without this every player rollout
 * would cost tier 1 and tier 5 a spare `/player` round trip for a check that
 * cannot matter.
 */
function responseNeedsDecipher(response: PlayerResult): boolean {
  const urlHasN = (raw: string | null): boolean => {
    if (!raw) return false;
    try {
      return new URL(raw).searchParams.has('n');
    } catch {
      // Unparsable is exactly the shape `sign()` itself declines on — safer
      // to say "this needs checking" than to assume it is harmless.
      return true;
    }
  };

  if (urlHasN(response.hlsManifestUrl) || urlHasN(response.dashManifestUrl)) return true;
  return response.formats.some(
    (format) => format.signatureCipher !== null || urlHasN(format.rawUrl),
  );
}

/**
 * Confirm `entry` was minted under `player`'s revision before anything
 * deciphers it, refetching once under the session's current player if it
 * was not. A `null` recorded revision — no player installed on the session
 * at fetch time — counts as a mismatch too: nothing vouches for it.
 *
 * If the revision has moved *again* by the time that refetch lands, this
 * declines the tier (an ordinary, non-terminal `RpcError` the ladder in
 * `descendLadder` treats like any other decline) rather than pairing a
 * response with a script from a different revision — a thrown error costs
 * one video, a wrong `n` costs a silent ~50 KB/s throttle nobody attributes
 * correctly.
 *
 * Exported so the reconciliation rule can be tested directly against the
 * real implementation with stub sessions, rather than against a second copy
 * of it written in the test file — the same reasoning as `descendLadder` and
 * `fetchWithVisitorRetry`.
 */
export async function responseForDecipher(
  session: Session,
  videoId: string,
  client: PlayerClient,
  entry: PlayerEntry,
  player: Player,
): Promise<PlayerResult> {
  if (entry.playerId === player.playerId) return entry.result;

  if (!responseNeedsDecipher(entry.result)) return entry.result;

  log.info(
    `${videoId}: ${client} /player response was minted under player ` +
      `${entry.playerId ?? '(unknown)'}, the session's current player is ` +
      `${player.playerId} — refetching`,
  );
  const fresh = await getPlayerEntry(session, videoId, client, { refresh: true });

  if (fresh.playerId !== player.playerId) {
    throw new RpcError(
      'STREAM_UNAVAILABLE',
      `${videoId}: ${client} player revision changed twice while resolving ` +
        `(refetched response minted under ${fresh.playerId ?? '(unknown)'}, ` +
        `decipher target ${player.playerId})`,
    );
  }
  return fresh.result;
}

// ---------------------------------------------------------------------------
// Tiers 1 and 2 — plain adaptive, from whichever client
// ---------------------------------------------------------------------------

/**
 * Video + audio from a response's adaptive ladder.
 *
 * Shared by both plain tiers because the difference between them is which client
 * the `/player` call named, and nothing after that: the same ranking, the same
 * `SignedUrl` door, the same assembly. `VISIONOS` formats carry no cipher and
 * no `n`, so `sign` passes them through untouched and its client gate does not
 * fire (`CLIENTS_WITH_N_PARAM` in `signed-url.ts`); `MWEB` formats go through the
 * full decipher. Routing both through `sign` rather than short-circuiting the
 * one that "does not need it" means a day when `VISIONOS` starts shipping a
 * cipher is a non-event instead of a silent throttle.
 */
export async function tierPlainAdaptive(
  deps: PlaybackDeps,
  videoId: string,
  client: PlayerClient,
  poToken: string | null,
  entry: PlayerEntry | null,
): Promise<PlaybackSource> {
  if (!entry) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `${videoId}: the ${client} /player call did not return`,
    );
  }

  const checkUsable = (candidate: PlayerResult): void => {
    assertPlayable(candidate, videoId);
    if (isSabrOnly(candidate)) {
      // The Phase 2 trigger fired on this client. Decline so the ladder
      // continues; the suite is what is supposed to tell us about this, not a
      // user.
      throw new RpcError(
        'STREAM_REQUIRES_SABR',
        `${videoId}: ${client} adaptive formats are SABR-only`,
      );
    }
  };

  // Playability first, before the player is touched. It does not depend on the
  // player revision, and it is where a premiere or a members-only video ends
  // the ladder (`LADDER_TERMINAL_CODES`) — a `getPlayer()` that has to rebuild
  // and fails must not be able to turn that into an ordinary failure.
  checkUsable(entry.result);

  // Then reconcile against the player that will decipher — see
  // "Player-revision consistency" above. A refetched response is judged again.
  const player = await getPlayer(deps.session);
  const response = await responseForDecipher(deps.session, videoId, client, entry, player);
  if (response !== entry.result) checkUsable(response);

  // **Gated on `isLive`.** `VISIONOS` hands back an `hlsManifestUrl` on
  // ordinary VOD responses too — confirmed live against `dQw4w9WgXcQ` and
  // three other unrelated non-live videos, all with a perfectly usable
  // adaptive ladder sitting right below this check. Without the gate this
  // branch hijacked essentially every open on tier 1, trading the single
  // direct `videoplayback` GET the plain-adaptive path below would have made
  // for mpv's multi-hop HLS fetch chain (master playlist → variant playlist →
  // segments) against a manifest-pinned edge host — measured as the cause of
  // the "mpv could not open the stream" / `WSAETIMEDOUT` reports on 2026-09-10,
  // ordinary videos only, healed by a retry because a re-resolve rarely lands
  // on the same fragile chain twice. Routed through `sign` now too, rather
  // than cast directly to `SignedUrl` — hard invariant 2 has to hold for the
  // genuine live case this branch exists for, even though `VISIONOS` manifest
  // URLs carry no cipher or `n` today.
  if (response.isLive && (response.hlsManifestUrl || response.dashManifestUrl)) {
    const isHls = !!response.hlsManifestUrl;
    const rawUrl = (response.hlsManifestUrl ?? response.dashManifestUrl) as string;
    const signedUrl = await sign(rawUrl, player, { poToken });

    // We can infer a max resolution from the available formats to satisfy the type.
    const maxVideo = rankVideo(response.formats)[0];

    return assemble({
      variants: [{
        videoUrl: signedUrl,
        audioUrl: null,
        itag: maxVideo?.itag ?? null,
        height: maxVideo?.height ?? 1080,
        fps: maxVideo?.fps ?? 30,
        videoCodec: maxVideo?.codecs ?? 'unknown',
        audioCodec: 'unknown',
      }],
      response,
      transport: isHls ? 'hls' : 'dash',
    });
  }

  const rankedVideos = rankVideo(response.formats);
  const rankedAudios = rankAudio(response.formats);
  if (rankedVideos.length === 0 || rankedAudios.length === 0) {
    throw new RpcError(
      'STREAM_REQUIRES_SABR',
      `${videoId}: no usable adaptive pair (video=${rankedVideos.length > 0} audio=${rankedAudios.length > 0})`,
    );
  }

  const bestAudio = rankedAudios[0]!;

  // Sign the best audio once — it serves every video variant (§3.5 rule 5).
  const audioUrl = await signFormat(bestAudio, player, poToken);
  const audioCodec = bestAudio.codecs ?? 'unknown';

  // Sign every video format that can be signed. A format that fails to sign is
  // silently omitted, not emitted with a null URL (task brief rule 3).
  const variants: PlaybackVariant[] = [];
  for (const video of rankedVideos) {
    let videoUrl: SignedUrl;
    try {
      videoUrl = await signFormat(video, player, poToken);
    } catch {
      log.debug(`${videoId}: ${client} itag ${video.itag} could not be signed — omitted`);
      continue;
    }
    variants.push({
      videoUrl,
      audioUrl,
      itag: video.itag,
      height: video.height ?? 0,
      fps: video.fps ?? 0,
      videoCodec: video.codecs ?? 'unknown',
      audioCodec,
    });
  }

  if (variants.length === 0) {
    throw new RpcError(
      'STREAM_UNAVAILABLE',
      `${videoId}: ${client} every video format failed to sign`,
    );
  }

  const bestVariant = variants[0]!;
  log.debug(
    `${videoId}: ${client} ${variants.length} variants, best itag ${bestVariant.itag} ` +
      `(${bestVariant.height}p${bestVariant.fps} ${bestVariant.videoCodec}) + ` +
      `audio itag ${bestAudio.itag} (${audioCodec})`,
  );

  return assemble({ variants, response, transport: 'plain' });
}

/**
 * Anything that is not a clean answer about the video, described for the log.
 *
 * Deliberately wider than `LOGIN_REQUIRED`, and the reason is what F14 does
 * *not* say. F14 measured a server-issued visitor id surviving 28 resolutions
 * across 38 minutes — and never saw one expire, so nobody knows what an expired
 * one produces. If it is a different playability status, or an `OK` with an
 * empty format list, a `LOGIN_REQUIRED`-only gate never fires and stream
 * resolution simply stops working after some number of hours, silently, on a
 * session that looks healthy. That is the same shape as `logged_in: true` on a
 * dead cookie (F7), and this codebase has now been bitten by that pattern
 * enough times to stop paying for it.
 *
 * The empty-format case is not hypothetical either: the original F5 reading was
 * "0 formats on 3 of 4 runs" — a refusal that arrived as a shape rather than as
 * a status.
 *
 * The cost of being wrong in this direction is one mint (~170 ms) and one
 * `/player` call on a video that really is private, deleted or region-locked,
 * before tier 1 declines exactly as it would have. The cost of being wrong in
 * the other direction is a client that stops resolving streams and says nothing.
 */
function identityRefusal(response: PlayerResult): string | null {
  const status = response.playabilityStatus;
  if (status !== null && status !== 'OK') {
    return `${status} — "${response.playabilityReason ?? 'no reason given'}"`;
  }
  if (!response.formats.some((format) => format.isAdaptive)) {
    return `${status ?? 'no status'} with zero adaptive formats`;
  }
  return null;
}

/**
 * Fetch a `/player` response, and if it is not a usable answer, mint a new
 * identity and ask exactly once more.
 *
 * Separated from the tier so the retry rule can be tested against the real
 * implementation with stubs, rather than against a second copy of it written in
 * the test file. Same reasoning as `descendLadder`. Its messages name
 * `VISIONOS` because that is the only client whose refusals are plausibly
 * about the visitor id rather than about the video.
 *
 * **The trigger is deliberately broad** — see `identityRefusal`. It is not
 * "LOGIN_REQUIRED", it is "anything that is not `OK` with adaptive formats",
 * because the failure this guards against is an expired visitor id whose error
 * shape nobody has observed.
 *
 * **Exactly one retry.** F5 puts a fabricated visitor id at 2/28 rather than
 * 0/28: the refusal is probabilistic, so a fresh server-issued id raises the odds
 * rather than satisfying a requirement. One retry converts the residual failure
 * rate into a much smaller one; a loop would only spend round trips discovering
 * that YouTube has decided about this caller, and the ladder has four more rungs
 * for that case.
 */
export async function fetchWithVisitorRetry(
  videoId: string,
  fetchResponse: (refresh: boolean) => Promise<PlayerResult>,
  mintVisitor: () => Promise<unknown>,
): Promise<PlayerResult> {
  const first = await fetchResponse(false);
  const refusal = identityRefusal(first);
  if (refusal === null) return first;

  log.info(
    `${videoId}: VISIONOS returned ${refusal} — retrying with a fresh visitor id`,
  );

  try {
    await mintVisitor();
  } catch (error) {
    // Declining on YouTube's refusal is more useful than declining on ours, so
    // the original response is what goes back — but a mint that cannot reach
    // YouTube is worth seeing on its own.
    log.warn(
      `${videoId}: could not mint a fresh visitor id (${(error as Error).message}); ` +
        'declining tier 1 on the original response',
    );
    return first;
  }

  const second = await fetchResponse(true);
  const stillRefused = identityRefusal(second);
  if (stillRefused !== null) {
    log.warn(`${videoId}: VISIONOS still returning ${stillRefused} after a fresh visitor id`);
  }
  return second;
}

/**
 * Tier 1 — `VISIONOS`, anonymous, server-issued visitor id.
 *
 * The whole tier is the ordinary plain-adaptive path plus one condition: the
 * request has to carry a visitor id YouTube issued. F5 measured that at 13/13
 * `OK` for a server-issued id against 2/28 for a locally fabricated one, with
 * headers, cookies and client version making no difference either way.
 * `createSession` fetches one by default; this only has to handle the case where
 * the one in hand stopped convincing YouTube.
 *
 * Also captures the `playerId` each fetch was minted under, alongside
 * `fetchWithVisitorRetry`'s own identity-refusal retry, and hands the whole
 * entry to `tierPlainAdaptive` — which does its own, independent check
 * against the session's *current* player before deciphering (Task 04 §1).
 * The two retry reasons (a refused identity, a moved revision) are unrelated
 * and are kept that way rather than merged into one loop.
 */
export async function tierVisionOs(
  deps: PlaybackDeps,
  videoId: string,
  poToken: string | null,
): Promise<PlaybackSource> {
  let lastEntry: PlayerEntry | null = null;

  await fetchWithVisitorRetry(
    videoId,
    async (refresh) => {
      const fetched = await getPlayerEntry(deps.session, videoId, 'VISIONOS', { refresh });
      lastEntry = fetched;
      return fetched.result;
    },
    () => refreshVisitorId(deps.session),
  );

  return tierPlainAdaptive(deps, videoId, 'VISIONOS', poToken, lastEntry);
}

// ---------------------------------------------------------------------------
// Tier 3 — SABR → local DASH bridge
// ---------------------------------------------------------------------------

/**
 * Phase 2. Not built, on purpose.
 *
 * The seam exists so the bridge lands in one file instead of being threaded
 * through the ladder later; `architecture.md` §3 is explicit that building it
 * speculatively is not wanted. Until it exists this rung always declines, which
 * is exactly what an unimplemented tier should do.
 */
// Unreferenced until Phase 2 lands. Deleting it is exactly what the comment
// above says not to do, so the rule is silenced rather than the seam removed.
// eslint-disable-next-line @typescript-eslint/no-unused-vars
async function tierSabrDash(videoId: string): Promise<PlaybackSource> {
  throw new RpcError(
    'STREAM_REQUIRES_SABR',
    `${videoId}: the SABR → DASH bridge is Phase 2 and is not implemented`,
  );
}

// ---------------------------------------------------------------------------
// Tier 4 — yt-dlp subprocess
// ---------------------------------------------------------------------------

interface YtDlpFormat {
  url?: string;
  vcodec?: string;
  acodec?: string;
  height?: number;
  ext?: string;
}

export interface YtDlpDump {
  duration?: number;
  requested_formats?: YtDlpFormat[];
  url?: string;
  vcodec?: string;
  acodec?: string;
  height?: number;
}

const YT_DLP_TIMEOUT_MS = 45_000;

/**
 * `yt-dlp --dump-single-json` → `PlaybackSource`.
 *
 * Split out from the subprocess so the mapping can be tested against a recorded
 * dump — the part most likely to be wrong is the shape-reading, and the part
 * least worth a live subprocess to exercise.
 *
 * `-f bv*+ba/b` returns either a `requested_formats` pair or, when no adaptive
 * pair exists, a single muxed format whose address is on the dump itself.
 */
export function sourceFromYtDlpDump(
  dump: YtDlpDump,
  tool: string,
  response: PlayerResult | null,
): PlaybackSource {
  const requested = dump.requested_formats ?? [];
  const video = requested.find((f) => f.vcodec && f.vcodec !== 'none') ?? null;
  const audio = requested.find((f) => f.acodec && f.acodec !== 'none' && f.vcodec === 'none') ?? null;

  const videoAddress = video?.url ?? dump.url ?? null;
  if (!videoAddress) {
    throw new RpcError('UPSTREAM_ERROR', `${tool} returned no stream URL`);
  }

  const height = video?.height ?? dump.height ?? null;

  const variant: PlaybackVariant = {
    videoUrl: adoptExternallyDeciphered(videoAddress, tool),
    audioUrl: audio?.url ? adoptExternallyDeciphered(audio.url, tool) : null,
    // yt-dlp does not give us an itag reliably; null signals "unknown".
    itag: null,
    height: height ?? 0,
    fps: 0,
    videoCodec: video?.vcodec ?? dump.vcodec ?? 'unknown',
    audioCodec: audio?.acodec ?? dump.acodec ?? 'unknown',
  };

  return assemble({
    variants: [variant],
    response,
    transport: 'ytdlp',
    durationMs: dump.duration ? Math.round(dump.duration * 1000) : null,
  });
}

/**
 * Shell out to `yt-dlp` for the videos InnerTube will not serve us directly:
 * age-restricted, Vevo, and the assorted edge cases that answer `LOGIN_REQUIRED`
 * to an anonymous client.
 *
 * yt-dlp runs its own `n` transform, so what comes back is already deciphered —
 * there is no cipher left for `sign` to apply. That is why this tier goes
 * through `adoptExternallyDeciphered` instead, which re-checks the boundary
 * condition it still can (`n` present for a client that throttles) and is named
 * so it cannot be reached for casually.
 */
export async function tierYtDlp(
  deps: PlaybackDeps,
  videoId: string,
  poToken: string | null,
  response: PlayerResult | null,
): Promise<PlaybackSource> {
  // One place decides which binary this is, so the startup warning and the
  // spawn cannot disagree about what "yt-dlp" means on this machine.
  const binary = ytDlpBinary(deps.ytDlpPath);

  const args = [
    '--dump-single-json',
    '--no-warnings',
    '--no-playlist',
    '--no-progress',
    '-f',
    'bv*+ba/b',
    ...(poToken ? ['--extractor-args', `youtube:po_token=web.gvs+${poToken}`] : []),
    `https://www.youtube.com/watch?v=${videoId}`,
  ];

  let stdout: string;
  try {
    const child = Bun.spawn([binary, ...args], {
      stdout: 'pipe',
      stderr: 'pipe',
      // yt-dlp can sit on a slow extractor indefinitely; the ladder has to move on.
      timeout: YT_DLP_TIMEOUT_MS,
    });

    // Both pipes, concurrently, before waiting on the exit. Draining stdout to
    // completion while nothing reads stderr is the classic subprocess deadlock:
    // a child that writes past the OS pipe buffer (~64 KB) blocks in `write`,
    // never finishes stdout and never exits, and the caller waits out the
    // timeout instead of getting an answer. Measured on Bun 1.3, `Bun.spawn`
    // drains both pipes into memory eagerly, so the deadlock does not currently
    // reproduce here — that is a property of this runtime's implementation, not
    // of the code, and it is not something to depend on.
    const [stdoutText, stderrText] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    stdout = stdoutText;

    const exitCode = await child.exited;
    if (exitCode !== 0) {
      const stderr = stderrText.trim().split('\n').slice(-2).join(' ');
      throw new Error(`exit ${exitCode}: ${stderr || '(no output)'}`);
    }
  } catch (error) {
    // Not installed is the ordinary case on a machine that has never needed it,
    // and declining is the right response — but name the binary, so "tier 4
    // never works" does not turn into a debugging session.
    throw new RpcError(
      'UPSTREAM_ERROR',
      `${videoId}: ${binary} failed (${(error as Error).message})`,
    );
  }

  let dump: YtDlpDump;
  try {
    dump = JSON.parse(stdout) as YtDlpDump;
  } catch {
    throw new RpcError('UPSTREAM_ERROR', `${videoId}: ${binary} returned unparseable JSON`);
  }

  const source = sourceFromYtDlpDump(dump, binary, response);
  log.debug(`${videoId}: yt-dlp resolved ${topHeight(source) ?? '?'}p`);
  return source;
}

// ---------------------------------------------------------------------------
// Tier 5 — itag 18 progressive
// ---------------------------------------------------------------------------

/**
 * The rung almost nothing falls past.
 *
 * itag 18 is muxed H.264/AAC at 360p and survives even a SABR-only response
 * (F9), which is what makes it a real floor rather than a hopeful one. It sets
 * `qualityDegraded`, so the UI can say so instead of the user wondering why
 * their 4K monitor is showing a soft picture.
 *
 * **Not a guarantee, though**, and the difference matters to the caller: on
 * 2026-08-02 an `MWEB` response arrived carrying no progressive format at all
 * and this tier threw (F9, amended). So `playback.open` can decline every rung
 * for a video that is fine, and `STREAM_UNAVAILABLE` has to be a state the user
 * can retry out of rather than a verdict on the video.
 */
export async function tierProgressive(
  deps: PlaybackDeps,
  videoId: string,
  client: PlayerClient,
  poToken: string | null,
  entry: PlayerEntry | null,
): Promise<PlaybackSource> {
  if (!entry) {
    throw new RpcError('UPSTREAM_ERROR', `${videoId}: the ${client} /player call did not return`);
  }

  // Playability before the player, then reconciliation — the same order and
  // the same reasons as `tierPlainAdaptive`.
  assertPlayable(entry.result, videoId);
  const player = await getPlayer(deps.session);
  const response = await responseForDecipher(deps.session, videoId, client, entry, player);
  if (response !== entry.result) assertPlayable(response, videoId);

  const progressive = response.formats
    .filter((f) => !f.isAdaptive && addressOf(f) !== null)
    .sort((a, b) =>
      compare(
        Number(b.itag === PROGRESSIVE_FALLBACK_ITAG) - Number(a.itag === PROGRESSIVE_FALLBACK_ITAG),
        (b.height ?? 0) - (a.height ?? 0),
      ),
    )[0];

  if (!progressive) {
    throw new RpcError('STREAM_UNAVAILABLE', `${videoId}: no progressive format either`);
  }

  const videoUrl = await signFormat(progressive, player, poToken);

  log.warn(`${videoId}: falling back to itag ${progressive.itag} (${progressive.height ?? '?'}p)`);

  // A muxed format reports both codecs in one `codecs="avc1.42001E, mp4a.40.2"`
  // list; split it so the DTO's two fields mean what they say.
  const [videoCodec = 'unknown', audioCodec = 'unknown'] = (progressive.codecs ?? '')
    .split(',')
    .map((codec) => codec.trim())
    .filter(Boolean);

  const variant: PlaybackVariant = {
    videoUrl,
    // Muxed: mpv gets one URL and no --audio-file.
    audioUrl: null,
    itag: progressive.itag,
    height: progressive.height ?? 0,
    fps: progressive.fps ?? 0,
    videoCodec,
    audioCodec,
  };

  return assemble({
    variants: [variant],
    response,
    transport: 'plain',
  });
}

// ---------------------------------------------------------------------------
// The ladder
// ---------------------------------------------------------------------------

export interface Tier {
  name: string;
  run: () => Promise<PlaybackSource>;
}

/**
 * Walk the tiers and return the first that serves.
 *
 * Separated from `openPlayback` so the ordering rule can be tested against the
 * real implementation with stub tiers, rather than against a second copy of the
 * loop written in the test file — which would prove only that the copy works.
 */
export async function descendLadder(
  videoId: string,
  tiers: Tier[],
  preload = false,
): Promise<PlaybackSource> {
  const declined: string[] = [];
  let throttled = false;

  for (const [index, tier] of tiers.entries()) {
    try {
      const source = await tier.run();
      log.info(
        `${preload ? 'preload' : 'open'} ${videoId}: tier ${index + 1} (${tier.name}) ` +
          `→ ${topHeight(source) ?? '?'}p (${source.variants.length} variant${source.variants.length === 1 ? '' : 's'}) transport=${source.transport}` +
          `${source.qualityDegraded ? ' DEGRADED' : ''}`,
      );
      return source;
    } catch (error) {
      // Anything a tier throws is a decline — including a TypeError from an
      // unexpected shape. A tier crashing must not turn a video a lower tier
      // could serve into "Unavailable".
      //
      // `STREAM_REQUIRES_SABR` is the designed decline and stays at debug; the
      // rest are worth seeing, because a tier failing for an unexpected reason
      // still looks like success from the outside once a lower tier serves it.
      // **Some refusals end the ladder rather than declining down it** — see
      // [LADDER_TERMINAL_CODES]. No lower tier can resolve a video that has not
      // started, or buy a membership; tier 5's progressive floor least of all.
      // Continuing spends four more `/player` calls to arrive at "every tier
      // declined", which is both slower and the wrong answer: the UI would
      // offer *Try again* on something that cannot succeed. Rethrown as-is so
      // the scheduled time, or YouTube's own wording, survives to Flutter.
      if (LADDER_TERMINAL_CODES.some((code) => hasCode(error, code))) {
        log.info(`${videoId}: not resolving — ${error instanceof Error ? error.message : error}`);
        throw error;
      }

      const message = error instanceof Error ? error.message : String(error);
      declined.push(`${tier.name}: ${message}`);
      if (hasCode(error, 'RATE_LIMITED')) throttled = true;
      if (hasCode(error, 'STREAM_REQUIRES_SABR')) {
        log.debug(`${videoId}: tier ${index + 1} (${tier.name}) declined — ${message}`);
      } else {
        log.warn(`${videoId}: tier ${index + 1} (${tier.name}) declined — ${message}`);
      }
    }
  }

  // Never `STREAM_REQUIRES_SABR`: that code is internal to this loop and must
  // not reach Flutter.
  //
  // Anything reaching here genuinely exhausted the ladder. A code that should
  // have stopped it belongs in [LADDER_TERMINAL_CODES], not here — arriving at
  // `STREAM_UNAVAILABLE` turns a specific, actionable refusal into "would not
  // open" with a *Try again* that cannot work, which is exactly what
  // `VIDEO_MEMBERS_ONLY` did until 2026-09-09: it was thrown, documented as
  // ending the ladder, and then collected as an ordinary decline because this
  // check named one code instead of a list.
  //
  // A throttle is the one decline that changes the answer without ending the
  // ladder: if any tier was throttled and none got through, the video is not
  // the problem, the connection is — and "would not open" would say otherwise.
  if (throttled) {
    throw new RpcError(
      'RATE_LIMITED',
      `${videoId}: YouTube is throttling this connection —\n  ${declined.join('\n  ')}`,
    );
  }
  throw new RpcError(
    'STREAM_UNAVAILABLE',
    `${videoId}: every resolution tier declined —\n  ${declined.join('\n  ')}`,
  );
}

export async function openPlayback(
  deps: PlaybackDeps,
  params: OpenParams,
): Promise<PlaybackSource> {
  const { videoId, preload = false } = params;
  const poToken = await (deps.poTokens ?? nullPoTokenProvider).mint(videoId);

  // The `ANDROID` entry, fetched at most once and only if something below
  // tier 1 asks for it. Tiers 2 and 3 read their formats from it, and tier 2
  // wants its storyboards and duration even though yt-dlp finds its own
  // streams. Kept as a full `PlayerEntry` (not just its `.result`) so tier 5
  // can check its `playerId` against the session's current player before
  // deciphering (Task 04 §1) — tier 2 (`yt-dlp`) never decichers through
  // `getPlayer`, so it only ever reads `.result`.
  let androidRequest: Promise<PlayerEntry | null> | null = null;
  const androidEntry = (): Promise<PlayerEntry | null> =>
    (androidRequest ??= getPlayerEntry(deps.session, videoId, 'ANDROID').catch(
      (error: unknown): null => {
        log.warn(
          `${videoId}: ANDROID /player failed (${(error as Error).message}); ` +
            'lower tiers may still serve it',
        );
        return null;
      },
    ));

  const source = await descendLadder(
    videoId,
    [
      { name: 'VISIONOS plain adaptive', run: () => tierVisionOs(deps, videoId, poToken) },
      {
        name: 'yt-dlp',
        run: async () => tierYtDlp(deps, videoId, poToken, (await androidEntry())?.result ?? null),
      },
      {
        name: 'itag 18 progressive',
        run: async () => tierProgressive(deps, videoId, 'ANDROID', poToken, await androidEntry()),
      },
    ],
    preload,
  );

  // A preload "resolves and caches without opening a session" (§3.6), so it
  // registers nothing and its `sessionId` is not reportable. That is not a gap
  // to paper over: a preloaded item that is never played must not appear in
  // anyone's watch history, and the item that *is* played opens for real —
  // paying nothing for it, because the `/player` response the preload fetched is
  // still cached.
  if (!preload) {
    openPlaybackSession(source.sessionId, videoId, params.playlistId ?? null);
  }

  if (source.durationMs === null && source.startTimestamp === null) {
    try {
      const mweb = await getPlayerResponse(deps.session, videoId, 'MWEB');
      if (mweb.startTimestamp) {
        source.startTimestamp = mweb.startTimestamp;
      }
    } catch {
      log.warn(`${videoId}: MWEB fallback for startTimestamp failed`);
    }
  }

  return source;
}
