/**
 * `video.storyboard` — one fetchable sprite sheet per video (`protocol.md` §3.7). Currently
 * unused: it was built for hover previews, which now play real video, and is kept for the
 * scrubber.
 *
 * Reads the spec out of the `ANDROID_VR` `/player` response `video.info` and ladder tier 1
 * already share, so it opens no session and resolves no stream. No `MWEB` fallback: measured
 * 2026-08-11, `MWEB` carries one extra level (320×180) that `selectSheet` would decline anyway,
 * and a second round trip is the expense this is not allowed to have.
 */

import { logger } from '../log.ts';
import { getPlayerResponse } from '../innertube/player-response.ts';
import type { Session } from '../innertube/session.ts';
import { sheetUrl } from '../parser/player.ts';
import type { PlayerResult, Storyboard, StoryboardResult, StoryboardSpec } from '../types.ts';

const log = logger('storyboard');

/**
 * How long a resolved spec is served from cache. There is nothing to re-sign with — `sqp` and
 * `sigh` are minted inside the `/player` response — so this caches the finished URL. Measured:
 * URLs captured 2026-08-01 still fetched on 2026-08-11, so expiry is not the binding constraint;
 * six hours just bounds how long a dead URL could be served if one ever did expire sooner.
 */
const TTL_MS = Number(process.env['SIDECAR_STORYBOARD_TTL_MS'] ?? 6 * 60 * 60_000);

/** Entries, not bytes — a spec is a URL and seven numbers. ~45 feed pages' worth. */
const MAX_ENTRIES = 1024;

interface Entry {
  result: StoryboardResult;
  at: number;
}

const cache = new Map<string, Entry>();
const inFlight = new Map<string, Promise<StoryboardResult>>();

/** Insertion-ordered eviction, as in `player-response.ts`. */
function evictIfFull(): void {
  while (cache.size > MAX_ENTRIES) {
    const oldest = cache.keys().next();
    if (oldest.done) return;
    cache.delete(oldest.value);
  }
}

// ---------------------------------------------------------------------------
// Level selection
// ---------------------------------------------------------------------------

/** A level whose numbers are all present and positive — anything else is unusable. */
function isUsable(board: Storyboard): boolean {
  return (
    (board.columns ?? 0) > 0 &&
    (board.rows ?? 0) > 0 &&
    (board.thumbnailCount ?? 0) > 0 &&
    (board.thumbnailWidth ?? 0) > 0 &&
    (board.thumbnailHeight ?? 0) > 0 &&
    board.templateUrl.startsWith('http')
  );
}

/**
 * The level to use: **the largest whose whole frame set is one sheet** — one image request, and
 * the frames span the whole video rather than its first fraction. On a typical VOD that is
 * level 0 (100 frames, 10×10, one 480×270 sheet); on a short video a higher level can fit and
 * wins on width. When nothing fits, the lowest level is truncated to its first sheet rather than
 * declining, since that is the most of the video one request can show.
 */
export function selectSheet(boards: Storyboard[], durationSeconds: number | null): StoryboardSpec | null {
  const usable = boards.filter(isUsable);
  if (usable.length === 0) return null;

  const cells = (b: Storyboard): number => (b.columns ?? 0) * (b.rows ?? 0);
  const singleSheet = usable.filter((b) => (b.thumbnailCount ?? 0) <= cells(b));

  const board =
    singleSheet.length > 0
      ? singleSheet.reduce((best, b) => ((b.thumbnailWidth ?? 0) > (best.thumbnailWidth ?? 0) ? b : best))
      : usable.reduce((best, b) => (b.level < best.level ? b : best));

  const totalFrames = board.thumbnailCount!;
  const frameCount = Math.min(totalFrames, cells(board));

  // A level-0 `0` means "these frames span the video", so the interval is the division — over
  // `totalFrames`, since what a frame represents does not change if we show only some.
  const intervalMs =
    (board.intervalMs ?? 0) > 0
      ? board.intervalMs!
      : durationSeconds !== null && durationSeconds > 0
        ? Math.round((durationSeconds * 1000) / totalFrames)
        : null;

  if (intervalMs === null || intervalMs <= 0) {
    // No cadence and no duration — live content, in practice. Inventing one would ship a spec
    // whose only meaningful number is a guess.
    log.debug(`level ${board.level}: interval 0 and no duration to divide — no preview`);
    return null;
  }

  return {
    url: sheetUrl(board, 0),
    columns: board.columns!,
    rows: board.rows!,
    frameCount,
    frameWidth: board.thumbnailWidth!,
    frameHeight: board.thumbnailHeight!,
    intervalMs,
    level: board.level,
  };
}

/** Exported so the offline tests can drive selection off a parsed response. */
export function storyboardFrom(response: PlayerResult): StoryboardResult {
  return { storyboard: selectSheet(response.storyboards, response.durationSeconds) };
}

// ---------------------------------------------------------------------------

/** The sheet for one video, from cache when it has one. Concurrent callers share one request. */
export async function getStoryboard(session: Session, videoId: string): Promise<StoryboardResult> {
  const cached = cache.get(videoId);
  if (cached && Date.now() - cached.at < TTL_MS) return cached.result;

  const pending = inFlight.get(videoId);
  if (pending) return pending;

  const request = (async (): Promise<StoryboardResult> => {
    const response = await getPlayerResponse(session, videoId, 'ANDROID_VR');
    const result = storyboardFrom(response);

    if (result.storyboard === null) {
      // Ordinary, not broken: YouTube builds no sheets for some videos at all (§3.7).
      log.debug(`${videoId}: no usable storyboard (${response.storyboards.length} levels)`);
    } else {
      const s = result.storyboard;
      log.debug(
        `${videoId}: level ${s.level}, ${s.frameCount} frames ${s.columns}x${s.rows} ` +
          `@ ${s.frameWidth}x${s.frameHeight}, ${s.intervalMs}ms/frame`,
      );
    }
    return result;
  })()
    .then((result) => {
      cache.set(videoId, { result, at: Date.now() });
      evictIfFull();
      return result;
    })
    .finally(() => {
      if (inFlight.get(videoId) === request) inFlight.delete(videoId);
    });

  inFlight.set(videoId, request);
  return request;
}

/** Test seam. */
export function forgetStoryboards(): void {
  cache.clear();
  inFlight.clear();
}

/** Test seam — how many videos are resolved right now. */
export function storyboardCacheSize(): number {
  return cache.size;
}
