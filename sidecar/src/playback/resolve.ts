/**
 * `playback.open` — the resolution ladder from `protocol.md` §3.5.
 *
 * Four tiers, tried in order, each of which either returns a `PlaybackSource` or
 * throws to decline:
 *
 *   1. `MWEB` plain adaptive  — the Phase 1 path (F3/F4)
 *   2. SABR → local DASH      — Phase 2, deliberately unbuilt; throws
 *   3. `yt-dlp` subprocess    — age-restricted, Vevo, whatever else 1 refuses
 *   4. itag 18 progressive    — 360p, always there, sets `qualityDegraded`
 *
 * The ladder is the error-handling strategy, not a fallback bolted onto one. A
 * tier that cannot serve a video throws; the ladder logs it and moves down. Only
 * when all four decline does the caller see `STREAM_UNAVAILABLE`.
 *
 * **Flutter must not be able to tell which tier served it.** `transport` is
 * telemetry and `qualityDegraded` drives a badge; neither changes how the client
 * opens the source. That is what makes the Phase 2 swap a transport change
 * rather than a protocol revision.
 */

import { RpcError, hasCode } from '../errors.ts';
import { logger } from '../log.ts';
import { getPlayer, type Player } from '../innertube/player.ts';
import { getPlayerResponse } from '../innertube/player-response.ts';
import type { Session } from '../innertube/session.ts';
import { sign, adoptExternallyDeciphered, type SignedUrl } from '../innertube/signed-url.ts';
import type { PlaybackSource, PlaybackTransport, PlayerFormat, PlayerResult } from '../types.ts';
import { isSabrOnly } from './sabr-detect.ts';
import { nullPoTokenProvider, type PoTokenProvider } from './po-token.ts';

const log = logger('playback');

/** Below this, the user is watching a visibly worse video than YouTube has. */
const DEGRADED_BELOW_HEIGHT = 720;

/** itag 18: 360p, muxed, and present even on a SABR-only response (F9). */
const PROGRESSIVE_FALLBACK_ITAG = 18;

export interface PlaybackDeps {
  /**
   * The anonymous `MWEB` session streams are resolved through (§2.3). Browsing
   * and reporting use the authenticated `WEB` session; they are separate calls
   * on purpose, and no CPN is bridged between them.
   */
  session: Session;
  poTokens?: PoTokenProvider;
  /** Override the `yt-dlp` binary for tier 3. Defaults to `YT_DLP_PATH` or PATH. */
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
  videoUrl: SignedUrl;
  audioUrl: SignedUrl | null;
  video: PlayerFormat | null;
  audio: PlayerFormat | null;
  response: PlayerResult | null;
  transport: PlaybackTransport;
  /** Set when the tier knows better than the format list — yt-dlp, say. */
  height?: number | null;
  videoCodec?: string | null;
  audioCodec?: string | null;
  durationMs?: number | null;
}

function assemble(parts: SourceParts): PlaybackSource {
  const height = parts.height ?? parts.video?.height ?? null;
  const durationSeconds = parts.response?.durationSeconds ?? null;

  return {
    sessionId: newSessionId(),
    videoUrl: parts.videoUrl,
    audioUrl: parts.audioUrl,
    durationMs: parts.durationMs ?? (durationSeconds === null ? null : durationSeconds * 1000),
    videoCodec: parts.videoCodec ?? parts.video?.codecs ?? null,
    audioCodec: parts.audioCodec ?? parts.audio?.codecs ?? null,
    height,
    storyboardTemplate: parts.response ? storyboardTemplate(parts.response) : null,
    // A uniform rule rather than a tier-4 special case: tier 4 is 360p so it is
    // always degraded, and a tier-1 resolution that could only find 360p is
    // degraded too, which the user deserves to be told either way.
    qualityDegraded: height === null || height < DEGRADED_BELOW_HEIGHT,
    transport: parts.transport,
  };
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

  if (status === 'UNPLAYABLE' && /page needs to be reloaded/i.test(reason)) {
    // Hard invariant 7. If this ever fires, the `/player` payload lost its
    // signatureTimestamp or it no longer matches the deciphering player.
    throw new RpcError(
      'UPSTREAM_ERROR',
      `${videoId}: UNPLAYABLE — "${reason}". That is a missing or stale ` +
        'signatureTimestamp on the /player call, not a broken video.',
      true,
    );
  }

  throw new RpcError('STREAM_UNAVAILABLE', `${videoId}: ${status} — ${reason}`);
}

// ---------------------------------------------------------------------------
// Tier 1 — MWEB plain adaptive
// ---------------------------------------------------------------------------

async function tierMwebAdaptive(
  deps: PlaybackDeps,
  videoId: string,
  poToken: string | null,
  response: PlayerResult | null,
): Promise<PlaybackSource> {
  if (!response) {
    throw new RpcError('UPSTREAM_ERROR', `${videoId}: the MWEB /player call did not return`, true);
  }
  assertPlayable(response, videoId);

  if (isSabrOnly(response)) {
    // The Phase 2 trigger fired on MWEB. Decline so the ladder continues; the
    // suite is what is supposed to tell us about this, not a user.
    throw new RpcError(
      'STREAM_REQUIRES_SABR',
      `${videoId}: MWEB adaptive formats are SABR-only`,
    );
  }

  const video = rankVideo(response.formats)[0];
  const audio = rankAudio(response.formats)[0];
  if (!video || !audio) {
    throw new RpcError(
      'STREAM_REQUIRES_SABR',
      `${videoId}: no usable adaptive pair (video=${Boolean(video)} audio=${Boolean(audio)})`,
    );
  }

  const player = await getPlayer(deps.session);
  const [videoUrl, audioUrl] = await Promise.all([
    signFormat(video, player, poToken),
    signFormat(audio, player, poToken),
  ]);

  log.debug(
    `${videoId}: MWEB itag ${video.itag} (${video.height}p ${video.codecs}) + ` +
      `itag ${audio.itag} (${audio.codecs})`,
  );

  return assemble({ videoUrl, audioUrl, video, audio, response, transport: 'plain' });
}

// ---------------------------------------------------------------------------
// Tier 2 — SABR → local DASH bridge
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
// Tier 3 — yt-dlp subprocess
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
    throw new RpcError('UPSTREAM_ERROR', `${tool} returned no stream URL`, true);
  }

  const height = video?.height ?? dump.height ?? null;

  return assemble({
    videoUrl: adoptExternallyDeciphered(videoAddress, tool),
    audioUrl: audio?.url ? adoptExternallyDeciphered(audio.url, tool) : null,
    // The formats are yt-dlp's, not InnerTube's, so the codec and height fields
    // are read off the dump rather than inferred from a PlayerFormat.
    video: null,
    audio: null,
    response,
    transport: 'ytdlp',
    height,
    videoCodec: video?.vcodec ?? dump.vcodec ?? null,
    audioCodec: audio?.acodec ?? dump.acodec ?? null,
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
  const binary = deps.ytDlpPath ?? process.env['YT_DLP_PATH'] ?? 'yt-dlp';

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
    stdout = await new Response(child.stdout).text();
    const exitCode = await child.exited;
    if (exitCode !== 0) {
      const stderr = (await new Response(child.stderr).text())
        .trim()
        .split('\n')
        .slice(-2)
        .join(' ');
      throw new Error(`exit ${exitCode}: ${stderr || '(no output)'}`);
    }
  } catch (error) {
    // Not installed is the ordinary case on a machine that has never needed it,
    // and declining is the right response — but name the binary, so "tier 3
    // never works" does not turn into a debugging session.
    throw new RpcError(
      'UPSTREAM_ERROR',
      `${videoId}: ${binary} failed (${(error as Error).message})`,
      true,
    );
  }

  let dump: YtDlpDump;
  try {
    dump = JSON.parse(stdout) as YtDlpDump;
  } catch {
    throw new RpcError('UPSTREAM_ERROR', `${videoId}: ${binary} returned unparseable JSON`, true);
  }

  const source = sourceFromYtDlpDump(dump, binary, response);
  log.debug(`${videoId}: yt-dlp resolved ${source.height ?? '?'}p`);
  return source;
}

// ---------------------------------------------------------------------------
// Tier 4 — itag 18 progressive
// ---------------------------------------------------------------------------

/**
 * The rung that always works.
 *
 * itag 18 is muxed H.264/AAC at 360p and survives even a SABR-only response
 * (F9), which is what makes it a real floor rather than a hopeful one. It sets
 * `qualityDegraded`, so the UI can say so instead of the user wondering why
 * their 4K monitor is showing a soft picture.
 */
export async function tierProgressive(
  deps: PlaybackDeps,
  videoId: string,
  poToken: string | null,
  response: PlayerResult | null,
): Promise<PlaybackSource> {
  if (!response) {
    throw new RpcError('UPSTREAM_ERROR', `${videoId}: the MWEB /player call did not return`, true);
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
  const [videoCodec = null, audioCodec = null] = (progressive.codecs ?? '')
    .split(',')
    .map((codec) => codec.trim())
    .filter(Boolean);

  return assemble({
    videoUrl,
    // Muxed: mpv gets one URL and no --audio-file.
    audioUrl: null,
    video: progressive,
    audio: null,
    response,
    transport: 'plain',
    videoCodec,
    audioCodec,
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
          `→ ${source.height ?? '?'}p transport=${source.transport}` +
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

  // One `/player` call for the whole ladder. Tiers 1 and 4 read their formats
  // from it, and tier 3 still wants its storyboards and duration even though
  // yt-dlp finds its own streams. If the call itself fails we carry on with
  // null: yt-dlp does not need us to have reached InnerTube at all.
  let response: PlayerResult | null = null;
  try {
    response = await getPlayerResponse(deps.session, videoId, 'MWEB');
  } catch (error) {
    log.warn(`${videoId}: MWEB /player failed (${(error as Error).message}); tier 3 may still serve it`);
  }

  return descendLadder(
    videoId,
    [
      { name: 'MWEB plain adaptive', run: () => tierMwebAdaptive(deps, videoId, poToken, response) },
      { name: 'SABR → DASH', run: () => tierSabrDash(videoId) },
      { name: 'yt-dlp', run: () => tierYtDlp(deps, videoId, poToken, response) },
      { name: 'itag 18 progressive', run: () => tierProgressive(deps, videoId, poToken, response) },
    ],
    preload,
  );
}
