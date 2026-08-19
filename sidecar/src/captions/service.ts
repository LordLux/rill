/**
 * `captions.list` and `captions.get` — `protocol.md` §3.8.
 *
 * Everything expensive is already paid for by the time this runs: the track list
 * rides on the cached `/player` response, and the only network this module does
 * on its own is one `timedtext` GET per track the user actually turns on.
 *
 * ## Why the empty-list fallback asks `MWEB` and not `WEB`
 *
 * The brief specified `WEB`. Measured 2026-08-18, that produces a track list
 * whose tracks cannot be fetched: a `WEB` `/player` signs its caption URLs with
 * `exp=xpe` inside `sparams`, and every one of them answers **HTTP 200 with a
 * zero-byte body**. Isolated to that one parameter — removing it from the query
 * invalidates the signature and answers 404, and the same URLs from `VISIONOS`
 * and `MWEB`, which carry no `exp`, return the document. So a `WEB` fallback
 * would populate a language picker whose every entry renders nothing, which is a
 * worse failure than showing no CC button: it looks like the captions are broken
 * rather than absent.
 *
 * `MWEB` returns the same track list and fetchable URLs, and it is already a
 * client this codebase resolves through (ladder tier 2), so it needs no new
 * session. `protocol.md` §3.5 also reserves `WEB` `/player` for the
 * *authenticated* report path; fetching one anonymously here to read captions
 * would put a second, differently-purposed `WEB` response in the shared cache.
 *
 * ## The negative cache
 *
 * A video with genuinely no captions — 10 of 42 playable videos in a real feed
 * sample, 2026-08-18 — hits the fallback every time the watch page opens unless
 * the *absence* is remembered. It is remembered with a TTL rather than
 * permanently, because a video can gain captions hours after upload and a
 * permanent negative would never notice.
 */

import { logger } from '../log.ts';
import { getPlayerEntry } from '../innertube/player-response.ts';
import type { PlayerClient, Session } from '../innertube/session.ts';
import { parseCaptionTracks, type CaptionTrackSource } from '../parser/captions.ts';
import { RpcError } from '../errors.ts';
import type { CaptionListResult, CaptionTrackContent } from '../types.ts';
import { groupAsrCues, normalizeCues } from './cues.ts';
import { parseJson3 } from './json3.ts';
import { renderAss } from './ass.ts';

const log = logger('captions');

/**
 * How long "this video has no captions" is believed.
 *
 * An hour: long enough that reopening a captionless video all afternoon costs
 * one fallback, short enough that a track added after upload shows up the same
 * session.
 */
const NEGATIVE_TTL_MS = Number(process.env['SIDECAR_CAPTIONS_NEGATIVE_TTL_MS'] ?? 60 * 60_000);

/** The format fetched from `timedtext`. See `json3.ts` for why this one. */
const FETCH_FORMAT = 'json3';

/** Videos known to have no captions, and when we last checked. */
const negativeCache = new Map<string, number>();

/** Rendered ASS, keyed `videoId\ntrackId`. Cheap to hold and expensive to rebuild. */
const assCache = new Map<string, CaptionTrackContent>();

/** Test seam, and what `playback.close` uses to let a video go. */
export function forgetCaptions(videoId?: string): void {
  if (videoId === undefined) {
    negativeCache.clear();
    assCache.clear();
    return;
  }
  negativeCache.delete(videoId);
  for (const key of [...assCache.keys()]) {
    if (key.startsWith(`${videoId}\n`)) assCache.delete(key);
  }
}

/** Diagnostics for the tests that assert the fallback does not fire twice. */
export function captionsNegativeCacheSize(): number {
  return negativeCache.size;
}

function negativeCacheHit(videoId: string): boolean {
  const at = negativeCache.get(videoId);
  if (at === undefined) return false;
  if (Date.now() - at < NEGATIVE_TTL_MS) return true;
  negativeCache.delete(videoId);
  return false;
}

async function tracksFrom(
  session: Session,
  videoId: string,
  client: PlayerClient,
): Promise<CaptionTrackSource[]> {
  const { raw } = await getPlayerEntry(session, videoId, client);
  return parseCaptionTracks(raw);
}

/**
 * Every caption track for a video, after the fallback.
 *
 * The list is what the CC button is shown or hidden on, so "after the fallback"
 * matters: hiding the control on tier 1's answer alone would hide it on any
 * video where `VISIONOS` is the client with the gap.
 */
export async function listCaptionTracks(
  session: Session,
  videoId: string,
  options: { allowFallback?: boolean } = {},
): Promise<{ sources: CaptionTrackSource[]; usedFallback: boolean }> {
  const primary = await tracksFrom(session, videoId, 'VISIONOS');
  if (primary.length > 0) return { sources: primary, usedFallback: false };

  // **The hover preview's mode.** Tier 1's `/player` is already cached by the
  // preload that resolved the preview (§3.6/§3.7), so a list read from it costs
  // nothing — but the fallback is a real round trip, and a pointer sweeping a
  // grid would spend one per tile whose primary list is empty. A hover is
  // deliberately incapable of that (§3.7 is built around exactly this), so it
  // asks for the free answer and accepts a CC toggle that is absent on the
  // minority of videos where only the fallback would have found tracks.
  if (options.allowFallback === false) return { sources: [], usedFallback: false };

  if (negativeCacheHit(videoId)) {
    log.debug(`${videoId}: no captions (cached negative)`);
    return { sources: [], usedFallback: false };
  }

  // INFO, with the video id, deliberately. If `VISIONOS`'s behaviour changes,
  // this line's rate moving is how anyone finds out — it was 0 rescues in 45
  // videos when it was written, and a silent fallback cannot be seen to change.
  log.info(`${videoId}: VISIONOS returned no caption tracks, falling back to MWEB`);
  const fallback = await tracksFrom(session, videoId, 'MWEB');

  if (fallback.length === 0) {
    negativeCache.set(videoId, Date.now());
    log.info(`${videoId}: no caption tracks on either client — negative cached`);
    return { sources: [], usedFallback: true };
  }

  log.info(`${videoId}: MWEB fallback recovered ${fallback.length} caption track(s)`);
  return { sources: fallback, usedFallback: true };
}

/** `captions.list` — the flat DTOs, and nothing that can be mistaken for a URL. */
export async function getCaptionList(
  session: Session,
  videoId: string,
  options: { allowFallback?: boolean } = {},
): Promise<CaptionListResult> {
  const { sources } = await listCaptionTracks(session, videoId, options);
  return { tracks: sources.map((source) => source.track) };
}

/**
 * `captions.get` — one track, fetched, converted, as an ASS document.
 *
 * Cached after the first conversion. A user toggling between two languages
 * should pay one fetch each and nothing after that, and the cache is what makes
 * the toggle feel free rather than merely fast.
 */
export async function getCaptionTrack(
  session: Session,
  videoId: string,
  trackId: string,
): Promise<CaptionTrackContent> {
  const key = `${videoId}\n${trackId}`;
  const cached = assCache.get(key);
  if (cached) return cached;

  const { sources } = await listCaptionTracks(session, videoId);
  const source = sources.find((candidate) => candidate.track.id === trackId);
  if (source === undefined) {
    // The client asked for a track this video does not have. That is a client
    // bug — a stale track list, or an id built rather than echoed — and `no` is
    // right: the same request will fail identically forever.
    throw new RpcError('BAD_REQUEST', `captions.get: no track '${trackId}' on ${videoId}`);
  }

  const url = new URL(source.baseUrl);
  url.searchParams.set('fmt', FETCH_FORMAT);

  const response = await fetch(url);
  if (!response.ok) {
    throw new RpcError(
      'UPSTREAM_ERROR',
      `captions.get: timedtext answered ${response.status} for ${videoId}/${trackId}`,
    );
  }
  const body = await response.text();
  if (body.trim() === '') {
    // A zero-byte 200 is what a `WEB`-signed URL does (see the header). Reaching
    // it from here means a URL got in from a client whose captions are not
    // fetchable, and saying so beats an empty caption track that looks like a
    // rendering bug.
    throw new RpcError(
      'UPSTREAM_ERROR',
      `captions.get: timedtext returned an empty body for ${videoId}/${trackId}`,
    );
  }

  const content = convert(body, source);
  assCache.set(key, content);
  return content;
}

/** The pipeline proper: parse → group (ASR only) → normalise → ASS. */
export function convert(body: string, source: CaptionTrackSource): CaptionTrackContent {
  const raw = normalizeCues(parseJson3(JSON.parse(body)));
  // Manual tracks are already cue-level and correctly timed. Grouping them would
  // move timings YouTube got right — see `groupAsrCues`.
  const cues = source.track.isAutoGenerated ? groupAsrCues(raw) : raw;

  log.debug(
    `${source.track.id}: ${raw.length} raw cue(s) -> ${cues.length} line(s)` +
      `${source.track.isAutoGenerated ? ' (asr grouped)' : ''}`,
  );

  return {
    trackId: source.track.id,
    languageCode: source.track.languageCode,
    format: 'ass',
    content: renderAss({
      cues,
      isAutoGenerated: source.track.isAutoGenerated,
      languageCode: source.track.languageCode,
    }),
    cueCount: cues.length,
  };
}
