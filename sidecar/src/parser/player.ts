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
import type { PlayerFormat, PlayerResult, Storyboard } from '../types.ts';
import { asArray, deepFind, get, isObject, num, str, type Json } from './tree.ts';

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
  const isLive = get(details, 'isLive') === true || get(details, 'isLiveContent') === true;

  return {
    videoId: str(get(details, 'videoId')),
    formats,
    storyboards: extractStoryboards(body),
    cpn: extractCpn(body),
    playabilityStatus: str(get(body, 'playabilityStatus', 'status')),
    playabilityReason:
      str(get(body, 'playabilityStatus', 'reason')) ??
      str(get(body, 'playabilityStatus', 'messages', '0')),
    durationSeconds: isLive ? null : lengthSeconds,
    isLive,
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
