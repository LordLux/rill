/**
 * `playback.open` — the resolution ladder from `protocol.md` §3.5.
 *
 * Five tiers, tried in order, each of which either returns a `PlaybackSource` or
 * throws to decline:
 *
 *   1. `ANDROID_VR` plain adaptive — the primary path (F5, F11, F13)
 *   2. `MWEB` plain adaptive       — the only proven decipher path (F3/F4)
 *   3. SABR → local DASH           — Phase 2, deliberately unbuilt; throws
 *   4. `yt-dlp` subprocess         — age-restricted, Vevo, whatever else refuses
 *   5. itag 18 progressive         — 360p, nearly always there, `qualityDegraded`
 *
 * `ANDROID_VR` leads because it is the only client measured that satisfies every
 * constraint at once: plain URLs, no `n` to decipher, open-ended ranges accepted
 * (F10 is an `MWEB` property, not a YouTube one), bare GETs accepted, throughput
 * above the bar, hardware decode, and seeks on the libmpv media_kit ships with no
 * options set (F13). Its one condition is a server-issued visitor id — see
 * `tierAndroidVr`.
 *
 * `MWEB` stays a tier rather than being deleted. It is the only client with a
 * proven decipher path, and F10 constrains how its URLs can be *consumed*, not
 * whether they resolve — so as a fallback that reaches a lower tier's floor it
 * still earns its place, and deleting it would throw away the decipher coverage
 * the network suite depends on.
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
import { RpcError, hasCode } from '../errors.ts';
import { logger } from '../log.ts';
import { getPlayer, type Player } from '../innertube/player.ts';
import { getPlayerResponse, forgetPlayerResponse } from '../innertube/player-response.ts';
import { refreshVisitorId, type PlayerClient, type Session } from '../innertube/session.ts';
import { sign, adoptExternallyDeciphered, type SignedUrl } from '../innertube/signed-url.ts';
import type { PlaybackSource, PlaybackTransport, PlaybackVariant, PlayerFormat, PlayerResult } from '../types.ts';
import { isSabrOnly } from './sabr-detect.ts';
import { nullPoTokenProvider, type PoTokenProvider } from './po-token.ts';
import { openPlaybackSession } from './sessions.ts';
import { isPoisonedMint, MAX_REMINTS, POISONED_FEXP_FLAGS } from './bucket.ts';

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
    storyboardTemplate: parts.response ? storyboardTemplate(parts.response) : null,
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
// Tiers 1 and 2 — plain adaptive, from whichever client
// ---------------------------------------------------------------------------

/**
 * Video + audio from a response's adaptive ladder.
 *
 * Shared by both plain tiers because the difference between them is which client
 * the `/player` call named, and nothing after that: the same ranking, the same
 * `SignedUrl` door, the same assembly. `ANDROID_VR` formats carry no cipher and
 * no `n`, so `sign` passes them through untouched and its client gate does not
 * fire (`CLIENTS_WITH_N_PARAM` in `signed-url.ts`); `MWEB` formats go through the
 * full decipher. Routing both through `sign` rather than short-circuiting the
 * one that "does not need it" means a day when `ANDROID_VR` starts shipping a
 * cipher is a non-event instead of a silent throttle.
 */
export async function tierPlainAdaptive(
  deps: PlaybackDeps,
  videoId: string,
  client: PlayerClient,
  poToken: string | null,
  response: PlayerResult | null,
): Promise<PlaybackSource> {
  if (!response) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `${videoId}: the ${client} /player call did not return`,
    );
  }
  assertPlayable(response, videoId);

  if (isSabrOnly(response)) {
    // The Phase 2 trigger fired on this client. Decline so the ladder continues;
    // the suite is what is supposed to tell us about this, not a user.
    throw new RpcError(
      'STREAM_REQUIRES_SABR',
      `${videoId}: ${client} adaptive formats are SABR-only`,
    );
  }

  const rankedVideos = rankVideo(response.formats);
  const rankedAudios = rankAudio(response.formats);
  if (rankedVideos.length === 0 || rankedAudios.length === 0) {
    throw new RpcError(
      'STREAM_REQUIRES_SABR',
      `${videoId}: no usable adaptive pair (video=${rankedVideos.length > 0} audio=${rankedAudios.length > 0})`,
    );
  }

  const player = await getPlayer(deps.session);
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

  const source = assemble({ variants, response, transport: 'plain' });
  if (isPoisonedMint(source)) {
    throw new RpcError('UPSTREAM_ERROR', `${videoId}: ${client} adaptive formats are in a poisoned bucket`);
  }
  return source;
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
 * `ANDROID_VR` because that is the only client whose refusals are plausibly
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
    `${videoId}: ANDROID_VR returned ${refusal} — retrying with a fresh visitor id`,
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
    log.warn(`${videoId}: ANDROID_VR still returning ${stillRefused} after a fresh visitor id`);
  }
  return second;
}

/**
 * Tier 1 — `ANDROID_VR`, anonymous, server-issued visitor id.
 *
 * The whole tier is the ordinary plain-adaptive path plus one condition: the
 * request has to carry a visitor id YouTube issued. F5 measured that at 13/13
 * `OK` for a server-issued id against 2/28 for a locally fabricated one, with
 * headers, cookies and client version making no difference either way.
 * `createSession` fetches one by default; this only has to handle the case where
 * the one in hand stopped convincing YouTube.
 */
export async function tierAndroidVr(
  deps: PlaybackDeps & { remintResolveSession?: () => Promise<Session> },
  videoId: string,
  poToken: string | null,
): Promise<PlaybackSource> {
  let currentDeps = deps;
  for (let attempt = 1; attempt <= MAX_REMINTS + 1; attempt++) {
    const response = await fetchWithVisitorRetry(
      videoId,
      (refresh) => getPlayerResponse(currentDeps.session, videoId, 'ANDROID_VR', { refresh }),
      () => refreshVisitorId(currentDeps.session),
    );

    let source: PlaybackSource | null = null;
    let poisonedError: unknown = null;
    try {
      source = await tierPlainAdaptive(currentDeps, videoId, 'ANDROID_VR', poToken, response);
    } catch (error) {
      if (error instanceof RpcError && error.message.includes('poisoned bucket')) {
        poisonedError = error;
      } else {
        throw error;
      }
    }

    if (source) {
      return source;
    }

    if (attempt <= MAX_REMINTS) {
      log.info(
        `${videoId}: mint is in a poisoned bucket (fexp ${POISONED_FEXP_FLAGS.join('/')}) — ` +
          `re-minting the resolve session, attempt ${attempt} of ${MAX_REMINTS}`,
      );
      if (currentDeps.remintResolveSession) {
        currentDeps = { ...currentDeps, session: await currentDeps.remintResolveSession() };
        forgetPlayerResponse(videoId);
      }
    }
  }

  throw new RpcError(
    'UPSTREAM_ERROR',
    `${videoId}: ANDROID_VR mint is in a poisoned bucket (fexp ${POISONED_FEXP_FLAGS.join('/')}) ` +
      `and refused to clear after ${MAX_REMINTS} re-mints.`,
  );
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
    // yt-dlp does not give us an itag reliably; 0 signals "unknown".
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
  poToken: string | null,
  response: PlayerResult | null,
): Promise<PlaybackSource> {
  if (!response) {
    throw new RpcError('UPSTREAM_ERROR', `${videoId}: the MWEB /player call did not return`);
  }
  assertPlayable(response, videoId);

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

  const player = await getPlayer(deps.session);
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
      // **A premiere ends the ladder rather than declining down it.** No lower
      // tier can resolve a video that has not started — tier 5's progressive
      // floor least of all — so continuing spends four more `/player` calls to
      // arrive at "every tier declined", which is both slower and the wrong
      // answer: the UI would offer *Try again* on something that cannot succeed
      // until a date. Rethrown as-is so the scheduled time and YouTube's own
      // wording survive to Flutter.
      if (hasCode(error, 'VIDEO_UPCOMING')) {
        log.info(`${videoId}: not resolving — ${error instanceof Error ? error.message : error}`);
        throw error;
      }

      const message = error instanceof Error ? error.message : String(error);
      declined.push(`${tier.name}: ${message}`);
      if (hasCode(error, 'STREAM_REQUIRES_SABR')) {
        log.debug(`${videoId}: tier ${index + 1} (${tier.name}) declined — ${message}`);
      } else {
        log.warn(`${videoId}: tier ${index + 1} (${tier.name}) declined — ${message}`);
      }
    }
  }

  // Never `STREAM_REQUIRES_SABR`: that code is internal to this loop and must
  // not reach Flutter.
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

  // The `MWEB` response, fetched at most once and only if something below tier 1
  // asks for it. Tiers 2 and 5 read their formats from it, and tier 4 wants its
  // storyboards and duration even though yt-dlp finds its own streams.
  //
  // Lazy because tier 1 is expected to serve: pre-fetching would put a second
  // `/player` round trip on every successful open, for a response nothing reads.
  // A failure resolves to null rather than throwing — yt-dlp does not need us to
  // have reached InnerTube at all, and the tiers that do need it decline.
  let mwebRequest: Promise<PlayerResult | null> | null = null;
  const mwebResponse = (): Promise<PlayerResult | null> =>
    (mwebRequest ??= getPlayerResponse(deps.session, videoId, 'MWEB').catch(
      (error: unknown): null => {
        log.warn(
          `${videoId}: MWEB /player failed (${(error as Error).message}); ` +
            'lower tiers may still serve it',
        );
        return null;
      },
    ));

  const source = await descendLadder(
    videoId,
    [
      {
        name: 'ANDROID_VR plain adaptive',
        run: () => tierAndroidVr(deps, videoId, poToken),
      },
      {
        name: 'MWEB plain adaptive',
        run: async () => tierPlainAdaptive(deps, videoId, 'MWEB', poToken, await mwebResponse()),
      },
      { name: 'SABR → DASH', run: () => tierSabrDash(videoId) },
      { name: 'yt-dlp', run: async () => tierYtDlp(deps, videoId, poToken, await mwebResponse()) },
      {
        name: 'itag 18 progressive',
        run: async () => tierProgressive(deps, videoId, poToken, await mwebResponse()),
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
    openPlaybackSession(source.sessionId, videoId);
  }

  return source;
}
