/**
 * `parsePlayer` — raw `/player` response → formats, storyboards, cpn.
 *
 * Hard invariant 2 lives here in the negative: this module never produces a
 * `SignedUrl`. It reports what YouTube sent as `rawUrl` / `signatureCipher`, and
 * the decipher path — not the parser — is the only thing allowed to mint a URL
 * fit to cross the RPC boundary. An unsigned `n` throttles to ~50 KB/s and looks
 * exactly like a bad connection, so the type system has to be the thing that
 * stops it, not a code review.
 */

import { isSabrOnlyAdaptive } from '../playback/sabr-detect.ts';
import { premiereStartMs } from './premiere.ts';
import type { PlayerFormat, PlayerResult, Storyboard } from '../types.ts';
import { asArray, deepFind, get, isObject, num, str, type Json } from './tree.ts';

/**
 * YouTube's refusal text for members-only content, in the wordings observed.
 *
 * Loose on purpose — it matches the phrase rather than a whole sentence, so the
 * two known variants ("Join this channel from your computer or mobile app to
 * get access to members-only content like this video." on VISIONOS/MWEB, and
 * "…and other exclusive perks." on WEB/ANDROID) both hit, and a reworded
 * English string very likely still does.
 */
const MEMBERS_ONLY_REASON = /members[- ]only|members[- ]first|channel membership/i;

/** `video/mp4; codecs="avc1.640028"` → `{ mime: 'video/mp4', codecs: 'avc1.640028' }`. */
function splitMimeType(value: string | null): { mime: string | null; codecs: string | null } {
  if (!value) return { mime: null, codecs: null };
  const [mime = null, ...rest] = value.split(';');
  const codecMatch = /codecs="([^"]+)"/.exec(rest.join(';'));
  return { mime: mime?.trim() ?? null, codecs: codecMatch?.[1] ?? null };
}

function mapFormat(entry: Json, isAdaptive: boolean): PlayerFormat | null {
  if (!isObject(entry)) return null;
  const itag = num(entry['itag']);
  if (itag === null) return null;

  const { mime, codecs } = splitMimeType(str(entry['mimeType']) ?? str(entry['mime_type']));
  const hasVideo = num(entry['width']) !== null || /^video\//.test(mime ?? '');
  const hasAudio =
    str(entry['audioQuality']) !== null ||
    num(entry['audioSampleRate']) !== null ||
    /^audio\//.test(mime ?? '');

  return {
    itag,
    mimeType: mime,
    codecs,
    bitrate: num(entry['bitrate']),
    width: num(entry['width']),
    height: num(entry['height']),
    fps: num(entry['fps']),
    audioQuality: str(entry['audioQuality']),
    audioSampleRate: num(entry['audioSampleRate']),
    audioChannels: num(entry['audioChannels']),
    isDrc: entry['isDrc'] === true,
    contentLength: num(entry['contentLength']),
    approxDurationMs: num(entry['approxDurationMs']),
    hasVideo,
    hasAudio,
    isAdaptive,
    rawUrl: str(entry['url']),
    signatureCipher: str(entry['signatureCipher']) ?? str(entry['cipher']),
  };
}

/**
 * Storyboard specs are a pipe-delimited string, not JSON:
 *
 *   <baseUrl>|w#h#count#cols#rows#intervalMs#name#sigh|w#h#…
 *
 * Each trailing segment is one zoom level. The substitution was measured against real responses
 * and verified by fetching (`protocol.md` §3.7), on `aqz-KE-bpKQ`, 2026-08-11:
 *
 *   base `…/storyboard3_L$L/$N.jpg?sqp=…`
 *   L0   `48#27#100#10#10#0#default#rs$AOn4CL…` → `…_L0/default.jpg?sqp=…&sigh=rs$AOn4CL…`
 *   L1   `80#45#128#10#10#5000#M$M#rs$AOn4CL…`  → `…_L1/M0.jpg?sqp=…&sigh=rs$AOn4CL…`
 *
 * `$L` is the level's index, `$N` its own name field (a literal, or `M$M` leaving `$M` for the
 * sheet index), and `sigh` is appended as a query parameter. Substitutions go through a function
 * and `sigh` through a concat, because a value containing `$&` or `$'` would otherwise be read
 * as a replacement pattern — every real signature starts `rs$…`.
 */
function parseStoryboardSpec(spec: string): Storyboard[] {
  const [baseUrl, ...levels] = spec.split('|');
  if (!baseUrl || levels.length === 0) return [];

  const boards: Storyboard[] = [];
  levels.forEach((level, index) => {
    const parts = level.split('#');
    const [width, height, count, columns, rows, interval, name, sigh] = parts;
    if (!width) return;

    const templateUrl = baseUrl
      .replace('$L', () => String(index))
      .replace('$N', () => name ?? 'M$M')
      .concat(sigh ? `&sigh=${sigh}` : '');

    boards.push({
      level: index,
      templateUrl,
      thumbnailWidth: num(width),
      thumbnailHeight: num(height),
      thumbnailCount: num(count),
      columns: num(columns),
      rows: num(rows),
      intervalMs: num(interval),
    });
  });
  return boards;
}

/**
 * The URL of one sheet within a level. Level 0's name is a literal, so it carries no `$M` and
 * this is the identity — correct, because level 0 is always a single sheet.
 */
export function sheetUrl(board: Storyboard, index: number): string {
  return board.templateUrl.replace('$M', () => String(index));
}

function extractStoryboards(body: Json): Storyboard[] {
  const spec =
    str(get(body, 'storyboards', 'playerStoryboardSpecRenderer', 'spec')) ??
    str(get(body, 'storyboards', 'playerLiveStoryboardSpecRenderer', 'spec'));
  if (spec) return parseStoryboardSpec(spec);

  // Layout moved: find any node carrying a spec-looking string.
  const holder = deepFind(body, (node) => {
    const value = node['spec'];
    return typeof value === 'string' && value.includes('|') && value.startsWith('http');
  });
  const fallback = holder ? str(holder['spec']) : null;
  return fallback ? parseStoryboardSpec(fallback) : [];
}

/**
 * The client playback nonce.
 *
 * A raw `/player` response does not contain one — the CPN is generated by the
 * client and only appears once youtubei.js has attached it, or echoed back in
 * the playback-tracking URLs. We read it where it exists and return `null`
 * otherwise; `playback.report` supplies its own rather than inventing one here.
 */
function extractCpn(body: Json): string | null {
  const direct = str(get(body, 'cpn'));
  if (direct) return direct;

  const trackingUrl = str(get(body, 'playbackTracking', 'videostatsPlaybackUrl', 'baseUrl'));
  const match = trackingUrl ? /[?&]cpn=([\w-]+)/.exec(trackingUrl) : null;
  return match?.[1] ?? null;
}

/**
 * A playback-tracking base URL, by name.
 *
 * These are what `playback.report` pings (F6). They are read here rather than
 * rebuilt from `docid` because every one of them carries request-scoped
 * parameters — `ei`, `of`, `vm` — that cannot be reconstructed and that YouTube
 * checks; a hand-built URL answers 200 and lands nowhere.
 */
function trackingUrl(body: Json, name: string): string | null {
  return str(get(body, 'playbackTracking', name, 'baseUrl'));
}

/**
 * The largest still the response itself lists for this video.
 *
 * **Read, never constructed.** An `i.ytimg.com/vi/<id>/<name>.jpg` URL has to
 * be guessed, and the guess 404s on plenty of videos; this is server-supplied
 * and therefore always fetchable. It is also the *poster* rather than a tile
 * thumbnail: a tile carries whatever the surface that listed it shipped, which
 * on the watch page's related rail is 480x360 (F40), while this tops out at the
 * 1280x720 ceiling.
 *
 * Not `bestImageUrl`: that walks the whole subtree, and here the exact node is
 * known.
 */
function extractPosterUrl(details: Json): string | null {
  let best: { url: string; width: number } | null = null;
  for (const entry of asArray(get(details, 'thumbnail', 'thumbnails'))) {
    const url = str(get(entry, 'url'));
    if (url === null) continue;
    // Zero-width entries still beat nothing, which is why this starts at null
    // rather than at width 0.
    const width = num(get(entry, 'width')) ?? 0;
    if (best === null || width > best.width) best = { url, width };
  }
  return best?.url ?? null;
}

export function parsePlayer(raw: Json): PlayerResult {
  const body = isObject(raw) && isObject(raw['data']) ? (raw['data'] as Json) : raw;

  const streaming = get(body, 'streamingData') ?? get(body, 'streaming_data');
  const progressive = asArray(get(streaming, 'formats'))
    .map((entry) => mapFormat(entry, false))
    .filter((format): format is PlayerFormat => format !== null);
  const adaptive = asArray(get(streaming, 'adaptiveFormats') ?? get(streaming, 'adaptive_formats'))
    .map((entry) => mapFormat(entry, true))
    .filter((format): format is PlayerFormat => format !== null);

  const formats = [...adaptive, ...progressive];
  const details = get(body, 'videoDetails');

  const lengthSeconds = num(get(details, 'lengthSeconds'));

  // **`isLiveContent` is a permanent tag, not a current-status signal, and
  // must never be OR'd into "is live now."** Confirmed live 2026-09-11 on
  // `0QnMv0bRyk0` (NTO — a "Live Session" recording that ended in June 2024):
  // `videoDetails.isLiveContent` is still `true` on every client — VISIONOS,
  // MWEB and WEB alike — a year and a half after the broadcast finished,
  // while `videoDetails.isLive` is correctly `undefined` and MWEB/WEB's
  // `microformat…liveBroadcastDetails` explicitly says `isLiveNow: false`
  // (with `startTimestamp` from June 2024 still present, because that is a
  // historical fact, not a liveness flag). Treating `isLiveContent` as
  // sufficient for "is live" set `durationSeconds` (and downstream,
  // `PlaybackSource.durationMs`) to `null` for a perfectly ordinary
  // 2442-second VOD, which is what the Flutter live-scrubber gates on — the
  // reported symptom was a finished video computing its "live edge" from a
  // startTimestamp over a year old (a ~19680-hour clock) and refusing to seek
  // backward. `liveBroadcastDetails.isLiveNow` is the authoritative signal
  // where present; `videoDetails.isLive` covers `VISIONOS`, which carries no
  // `microformat` at all.
  const isLive =
    get(details, 'isLive') === true ||
    get(body, 'microformat', 'playerMicroformatRenderer', 'liveBroadcastDetails', 'isLiveNow') === true;

  // A premiere or scheduled stream. `isUpcoming` is the flag YouTube sets, and
  // `LIVE_STREAM_OFFLINE` is the status the ladder sees for the same video — both
  // are accepted because neither has been observed alone and a premiere that
  // reads as an ordinary dead video is the bug this exists to stop.
  const isUpcoming =
    get(details, 'isUpcoming') === true ||
    str(get(body, 'playabilityStatus', 'status')) === 'LIVE_STREAM_OFFLINE';

  // Members-only, classified from the refusal text — **and this one really is a
  // localised-string match**, which everything else in this parser avoids.
  //
  // There is no alternative in this response. Measured 2026-09-09 on
  // `rAWLNJoE5_Y`: the whole of `playabilityStatus` on the resolve clients is
  // `{status, reason, playableInEmbed}`. VISIONOS carries no `errorScreen` at
  // all, MWEB's is a generic `playerErrorMessageRenderer` with an
  // `ERROR_OUTLINE` icon, and only the authenticated `WEB` response — which the
  // resolve path deliberately never makes — has the specific
  // `playerLegacyDesktopYpcOfferRenderer`.
  //
  // It is safe *because of where it sits*: this only ever refines a response
  // that has already failed, so a locale this pattern does not cover falls back
  // to `STREAM_UNAVAILABLE`, which is exactly today's behaviour. It can make an
  // error more specific; it cannot make a working video fail.
  //
  // The **structural** answer lives on `VideoDetail.isMembersOnly`, read off
  // `/next`'s `BADGE_STYLE_TYPE_MEMBERS_ONLY`, and that is what the watch page
  // draws its slate from. This is here so the error envelope carries
  // `retry: "no"` rather than offering a Try again that cannot work.
  // **`messages` is an array, and `get` cannot walk into one.** `get` guards
  // every hop with `isObject`, which excludes arrays by design, so
  // `get(…, 'messages', '0')` — how this was written since the initial commit —
  // returned `null` for every response that had messages and no `reason`. The
  // fallback existed, was documented, and had never once fired. `asArray` is
  // how the rest of the parser reaches into a list.
  const playabilityReason =
    str(get(body, 'playabilityStatus', 'reason')) ??
    str(asArray(get(body, 'playabilityStatus', 'messages'))[0]);
  const isMembersOnly = playabilityReason !== null && MEMBERS_ONLY_REASON.test(playabilityReason);

  return {
    videoId: str(get(details, 'videoId')),
    formats,
    hlsManifestUrl: str(get(streaming, 'hlsManifestUrl')) ?? str(get(streaming, 'hls_manifest_url')),
    dashManifestUrl: str(get(streaming, 'dashManifestUrl')) ?? str(get(streaming, 'dash_manifest_url')),
    storyboards: extractStoryboards(body),
    posterUrl: extractPosterUrl(details),
    cpn: extractCpn(body),
    playabilityStatus: str(get(body, 'playabilityStatus', 'status')),
    playabilityReason,
    durationSeconds: isLive ? null : lengthSeconds,
    isLive,
    startTimestamp: str(get(body, 'microformat', 'playerMicroformatRenderer', 'liveBroadcastDetails', 'startTimestamp')),
    isUpcoming,
    isMembersOnly,
    scheduledStartMs: isUpcoming ? premiereStartMs(body) : null,
    // Deliberately about the *adaptive* ladder, not about every format — a
    // SABR-only WEB response still carries a working itag 18. The rule lives in
    // playback/sabr-detect.ts so there is exactly one copy of it.
    sabrOnly: isSabrOnlyAdaptive(adaptive),
    serverAbrStreamingUrl:
      str(get(streaming, 'serverAbrStreamingUrl')) ?? str(get(streaming, 'server_abr_streaming_url')),
    videostatsPlaybackUrl: trackingUrl(body, 'videostatsPlaybackUrl'),
    videostatsWatchtimeUrl: trackingUrl(body, 'videostatsWatchtimeUrl'),
  };
}
