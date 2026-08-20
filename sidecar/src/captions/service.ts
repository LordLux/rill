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
import type { CaptionListResult, CaptionStyling, CaptionTrackContent } from '../types.ts';
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
    styledCache.clear();
    return;
  }
  negativeCache.delete(videoId);
  for (const cache of [assCache, styledCache]) {
    for (const key of [...cache.keys()]) {
      if (key.startsWith(`${videoId}\n`)) cache.delete(key);
    }
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

/**
 * Which badge a document earns.
 *
 * **Styling is `pens`, and deliberately not "any of the three arrays".**
 * Measured on `dQw4w9WgXcQ`'s six tracks: `pens` was empty on all of them, while
 * the auto-generated one had one populated `wsWinStyles` and one populated
 * `wpWinPositions` — its rolling window. Every ASR track has those, so the loose
 * predicate answers "styled" for the plainest tracks in the app.
 *
 * **Karaoke is the narrower claim and only wins when nothing wider is true** —
 * it is a subset of styled, so a track that karaokes *and* changes font is
 * styled. [isKaraokeOnly] is both halves of that.
 */
export function classifyDocument(raw: unknown): CaptionStyling {
  const doc = raw as StyleDoc;
  const pens = (Array.isArray(doc?.pens) ? doc.pens : []).filter(isPopulated);
  if (pens.length === 0) return 'plain';
  return isKaraokeOnly(doc, pens) ? 'karaoke' : 'styled';
}

interface StyleDoc {
  pens?: Record<string, unknown>[];
  wpWinPositions?: Record<string, unknown>[];
  events?: { segs?: { utf8?: unknown; pPenId?: unknown }[] }[];
}

function isPopulated(entry: unknown): entry is Record<string, unknown> {
  return entry !== null && typeof entry === 'object' && Object.keys(entry).length > 0;
}

/**
 * Zero-width spaces, which YouTube sprinkles between segments.
 *
 * Stripped before anything is compared, and it is not cosmetic: the separators
 * sit *at the split*, so the same karaoke line concatenates to a different
 * string on every step and grouping by raw text finds no repeats at all. That is
 * what a first attempt at [isKaraokeOnly] did, and it reported zero karaoke on
 * the one document that visibly has it.
 */
function withoutZeroWidth(text: string): string {
  return text.split(ZERO_WIDTH_SPACE).join('');
}

/** Written as an escape: the character itself is invisible in a source file. */
const ZERO_WIDTH_SPACE = '\u200B';

/** Everything a caption can carry that karaoke does not need. */
function hasStylingBeyondColour(doc: StyleDoc, pens: Record<string, unknown>[]): boolean {
  const beyond = pens.some(
    (pen) =>
      'fsFontStyle' in pen ||
      'ofOffset' in pen ||
      'bAttr' in pen ||
      'iAttr' in pen ||
      'uAttr' in pen ||
      (typeof pen['szPenSize'] === 'number' && pen['szPenSize'] !== 100) ||
      (typeof pen['boBackAlpha'] === 'number' && pen['boBackAlpha'] > 0),
  );
  if (beyond) return true;

  // Any window but the default bottom-centre one is placement, which is a
  // feature in its own right — see the ASR note above for why an unpopulated
  // window array is not evidence of anything.
  return (Array.isArray(doc.wpWinPositions) ? doc.wpWinPositions : [])
    .filter(isPopulated)
    .some((w) => w['apPoint'] !== 7 || w['ahHorPos'] !== 50 || w['avVerPos'] !== 100);
}

/**
 * Whether karaoke is the *only* thing this track does.
 *
 * **Karaoke is a subset of styled, so the badge has to be the narrower claim
 * only when nothing wider is true.** A first cut answered `karaoke` for any
 * `pPenId` on a `seg`, which badged all three test documents — per-segment pens
 * are also how a track colours one word, or sweeps a gradient across 23 000
 * pens, neither of which is karaoke.
 *
 * The pattern that *is* karaoke is temporal, not a field: the same line is
 * re-emitted with the split between two pens moving forward. Measured
 * 2026-08-19 across the three, this finds exactly the two cues in `L-BgxLtMxh0`
 * that visibly karaoke and nothing in the other two — including the
 * 42 000-segment gradient, which repeats text but never moves a boundary.
 *
 * Two increases rather than one, because a single step could be a line that
 * happens to be re-split once.
 */
function isKaraokeOnly(doc: StyleDoc, pens: Record<string, unknown>[]): boolean {
  if (hasStylingBeyondColour(doc, pens)) return false;

  const sweeps = new Map<string, number>();
  const previous = new Map<string, number>();
  for (const event of Array.isArray(doc.events) ? doc.events : []) {
    const segs = Array.isArray(event?.segs) ? event.segs : [];
    if (segs.length < 2 || !segs.some((seg) => typeof seg.pPenId === 'number')) continue;

    const line = withoutZeroWidth(segs.map((seg) => String(seg.utf8 ?? '')).join(''));
    const head = withoutZeroWidth(String(segs[0]?.utf8 ?? '')).length;
    const before = previous.get(line);
    if (before !== undefined && head > before) {
      sweeps.set(line, (sweeps.get(line) ?? 0) + 1);
      if ((sweeps.get(line) ?? 0) >= 2) return true;
    }
    previous.set(line, head);
  }
  return false;
}

/** `styled` answers, keyed `videoId\ntrackId`. One fetch per track per session. */
const styledCache = new Map<string, CaptionStyling>();

/**
 * Fill in `styled` for a list of tracks, fetching whatever is not cached.
 *
 * **Measured cost, 2026-08-19**: `dQw4w9WgXcQ`'s six real tracks are 69 KB and
 * **73 ms** fetched together — they parallelise, so it is one round trip's
 * latency and not six. That is affordable *for a menu*, and not for a video open,
 * which is why the caller opts in rather than this being the default: `protocol.md`
 * §3.8 keeps `captions.list` off the open path on purpose, and making it fetch
 * every track would put ~70 KB and N requests on every video the user watches for
 * a badge most of them will never see.
 *
 * Failures are swallowed to `null`. A badge is not worth failing a menu over.
 */
async function fillStyled(videoId: string, sources: CaptionTrackSource[], signal?: AbortSignal): Promise<void> {
  await Promise.all(
    sources.map(async (source) => {
      const key = `${videoId}\n${source.track.id}`;
      const cached = styledCache.get(key);
      if (cached !== undefined) {
        source.track.styled = cached;
        return;
      }
      try {
        const url = new URL(source.baseUrl);
        url.searchParams.set('fmt', FETCH_FORMAT);
        const response = await fetch(url, { signal });
        if (!response.ok) return;
        const body = await response.text();
        if (body.trim() === '') return;
        const styled = classifyDocument(JSON.parse(body));
        styledCache.set(key, styled);
        source.track.styled = styled;
      } catch {
        // Leaves `styled: null` — "not known", which is a state the DTO has.
      }
    }),
  );
}

/**
 * `captions.list` — the flat DTOs, and nothing that can be mistaken for a URL.
 *
 * `includeStyled` costs a `timedtext` GET per track; see [fillStyled] for what
 * that measures at and why it is not the default.
 */
export async function getCaptionList(
  session: Session,
  videoId: string,
  options: { allowFallback?: boolean; includeStyled?: boolean; signal?: AbortSignal } = {},
): Promise<CaptionListResult> {
  const { sources } = await listCaptionTracks(session, videoId, options);
  if (options.includeStyled === true) await fillStyled(videoId, sources, options.signal);
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
  options: { signal?: AbortSignal } = {},
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

  const response = await fetch(url, { signal: options.signal });
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
