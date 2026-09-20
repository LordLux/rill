#!/usr/bin/env bun
/**
 * Task 07 — resolve one `ANDROID_VR` video for the media_kit harness.
 *
 * No RPC in task 07, so the harness cannot ask the sidecar for a stream. This
 * script is the stand-in: it drives the *existing sidecar code* — the same
 * session, the same tier 1, the same `SignedUrl` door — and writes what came
 * back to a JSON file the Flutter harness reads at startup.
 *
 *   bun run spiking/07-resolve.ts [videoId]     → spiking/07-out/stream.json
 *
 * Two things it deliberately does beyond `tierVisionOs`:
 *
 *   - It signs itag 401 (AV1) and 315 (VP9) explicitly as `variants`, because
 *     Q3 asks for a decoder measurement on *both* codecs and the ladder only
 *     ever returns one pair (VP9 first, by `VIDEO_CODEC_RANK`). Both come from
 *     the one cached `/player` response, so this is one round trip, not three.
 *   - It records `expiresAt`. Stream URLs are ~6 h and IP-bound; a stale-URL
 *     403 that reads like a media_kit fault is exactly the debugging session
 *     the brief says not to have.
 *
 * Everything human-readable goes to stderr — hard invariant 3, even here.
 */

import { mkdir, writeFile } from 'node:fs/promises';

import { getPlayer } from '../sidecar/src/innertube/player.ts';
import { getPlayerResponse } from '../sidecar/src/innertube/player-response.ts';
import { createSession } from '../sidecar/src/innertube/session.ts';
import { sign } from '../sidecar/src/innertube/signed-url.ts';
import { logger } from '../sidecar/src/log.ts';
import { tierVisionOs } from '../sidecar/src/playback/resolve.ts';
import type { PlayerFormat, PlayerResult } from '../sidecar/src/types.ts';

const log = logger('07-resolve');

const videoId = process.argv[2] ?? process.env['YT_VIDEO_STANDARD'] ?? 'aqz-KE-bpKQ';
const outDir = new URL('./07-out/', import.meta.url);

/**
 * The two itags Q3 names, plus their 1080p60 counterparts.
 *
 * The 1080p pair is a control, not part of the brief: 401 and 315 are both
 * 2160p60, and without a second resolution a dropped-frame count cannot be told
 * apart from "this iGPU cannot push 4K60 through ANGLE". `codecPrefix` is the
 * fallback when a video's ladder has no such itag — the itag is a request, not
 * a contract.
 */
const VARIANTS = [
  { key: 'av1', itag: 401, codecPrefix: 'av01', height: 2160 },
  { key: 'vp9', itag: 315, codecPrefix: 'vp9', height: 2160 },
  { key: 'av1-1080', itag: 399, codecPrefix: 'av01', height: 1080 },
  { key: 'vp9-1080', itag: 303, codecPrefix: 'vp9', height: 1080 },
] as const;

function pickVideo(
  response: PlayerResult,
  itag: number,
  codecPrefix: string,
  height: number,
): PlayerFormat | null {
  const exact = response.formats.find((f) => f.itag === itag && f.hasVideo && !f.hasAudio);
  if (exact) return exact;

  // Nearest of the same codec by height, so a video whose ladder lacks the exact
  // itag still yields a measurable variant rather than silently measuring the
  // wrong codec or the wrong resolution.
  return (
    response.formats
      .filter(
        (f) =>
          f.isAdaptive &&
          f.hasVideo &&
          !f.hasAudio &&
          (f.codecs ?? '').startsWith(codecPrefix) &&
          (f.rawUrl ?? f.signatureCipher) !== null,
      )
      .sort((a, b) => Math.abs((a.height ?? 0) - height) - Math.abs((b.height ?? 0) - height))[0] ??
    null
  );
}

/** `expire=` is a unix timestamp on the `videoplayback` URL itself. */
function expiryOf(url: string): string | null {
  const seconds = Number(new URL(url).searchParams.get('expire'));
  return Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000).toISOString() : null;
}

// Anonymous, exactly as `probe-playback.ts` does it: the browse session is a
// separate concern and a separate call. What tier 1 needs from this session is
// the server-issued visitor id `createSession` fetches by default (F5).
const session = await createSession({ clientType: 'MWEB' });

// Tier 1 itself, not a reimplementation of it — including the fresh-visitor-id
// retry. Its pair is what the harness plays by default.
const source = await tierVisionOs({ session }, videoId, null);

// Cached from the call tier 1 just made; no second round trip.
const response = await getPlayerResponse(session, videoId, 'ANDROID_VR');
const player = await getPlayer(session);

const variants = [];
for (const { key, itag, codecPrefix, height } of VARIANTS) {
  const format = pickVideo(response, itag, codecPrefix, height);
  if (!format) {
    log.warn(`no ${key} format on ${videoId} (wanted itag ${itag}) — Q3 cannot cover it`);
    continue;
  }
  const address = format.rawUrl ?? format.signatureCipher;
  variants.push({
    key,
    itag: format.itag,
    codec: format.codecs,
    height: format.height,
    fps: format.fps,
    contentLength: format.contentLength,
    videoUrl: await sign(address!, player, { poToken: null }),
  });
}

if (variants.length === 0) {
  throw new Error(`${videoId}: neither itag 401 nor 315 resolved — nothing for Q3 to measure`);
}

const best = source.variants[0];
const payload = {
  videoId,
  capturedAt: new Date().toISOString(),
  expiresAt: expiryOf(best.videoUrl),
  transport: source.transport,
  durationMs: source.durationMs,
  // The ladder's own pick, in the shape the brief asks for.
  videoUrl: best.videoUrl,
  audioUrl: best.audioUrl,
  itag: variants.find((v) => v.videoUrl === best.videoUrl)?.itag ?? best.itag,
  codec: best.videoCodec,
  audioCodec: best.audioCodec,
  height: best.height,
  ladderVariants: source.variants,
  spikeVariants: variants,
};

await mkdir(outDir, { recursive: true });
await writeFile(new URL('stream.json', outDir), `${JSON.stringify(payload, null, 2)}\n`);

log.info(`${videoId}: ${best.height ?? '?'}p ${best.videoCodec ?? '?'} + ${best.audioCodec ?? '?'}`);
log.info(`ladder variants: ${source.variants.length}`);
for (const v of source.variants) log.info(`  itag ${v.itag}: ${v.height}p${v.fps} ${v.videoCodec}`);
log.info(`spike variants: ${variants.length}`);
for (const v of variants) log.info(`  ${v.key}: itag ${v.itag} ${v.codec} ${v.height}p${v.fps ?? ''}`);
log.info(`duration ${source.durationMs === null ? 'live' : `${Math.round(source.durationMs / 1000)}s`}`);
log.info(`expires  ${payload.expiresAt ?? '(no expire parameter)'}`);
log.info(`wrote    ${new URL('stream.json', outDir).pathname.slice(1)}`);
