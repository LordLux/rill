#!/usr/bin/env bun
/**
 * `bun run probe [videoId]` — resolve one video and print the mpv command.
 *
 * The definition of done for the decipher task includes a manual check:
 * `mpv <videoUrl> --audio-file=<audioUrl>` plays with audio in sync. media_kit
 * integration is a later task, so this is how a human gets those two URLs out of
 * the ladder without one.
 *
 * It also measures throughput, because that is the only observation that
 * actually proves the `n` transform landed — a wrongly-deciphered `n` produces a
 * URL that looks perfect and streams at ~50 KB/s.
 *
 * Everything goes to stderr. Hard invariant 3: stdout is protocol.
 */

import { logger } from './log.ts';
import { createSession } from './innertube/session.ts';
import { openPlayback } from './playback/resolve.ts';

const log = logger('probe');

/** Enough to see the throttle; 12 MB at 50 KB/s would take four minutes. */
const SAMPLE_BYTES = 12 * 1024 * 1024;

const videoId = process.argv[2] ?? process.env['YT_VIDEO_STANDARD'] ?? 'aqz-KE-bpKQ';

// Streams resolve through an anonymous MWEB session (§2.3). No cookie, on
// purpose — the browse session is a separate concern and a separate call.
const session = await createSession({ clientType: 'MWEB' });
const source = await openPlayback({ session }, { videoId });

log.info(`video    ${videoId}`);
log.info(`transport ${source.transport}${source.qualityDegraded ? '  (DEGRADED)' : ''}`);
log.info(`quality  ${source.height ?? '?'}p  ${source.videoCodec ?? '?'} / ${source.audioCodec ?? '?'}`);
log.info(`duration ${source.durationMs === null ? 'live' : `${Math.round(source.durationMs / 1000)}s`}`);
log.info(`storyboard ${source.storyboardTemplate ? 'present' : 'absent'}`);

const started = Date.now();
let received = 0;
const response = await fetch(source.videoUrl, { headers: { range: `bytes=0-${SAMPLE_BYTES - 1}` } });
if (response.ok || response.status === 206) {
  for await (const chunk of response.body!) {
    received += chunk.length;
    if (received >= SAMPLE_BYTES) break;
  }
  const seconds = (Date.now() - started) / 1000;
  const mbps = received / 1024 / 1024 / seconds;
  log.info(`throughput ${mbps.toFixed(2)} MB/s (${(received / 1024 / 1024).toFixed(1)} MB in ${seconds.toFixed(1)}s)`);
  if (mbps < 1.5) {
    log.error('that is throttled territory — the n transform is wrong, not the network.');
    log.error('check that the player cache is keyed by playerId and the node:vm shim is running');
  }
} else {
  log.error(`throughput check failed: HTTP ${response.status}`);
}

log.info('');
log.info('play it:');
log.info(
  source.audioUrl
    ? `mpv "${source.videoUrl}" --audio-file="${source.audioUrl}"`
    : `mpv "${source.videoUrl}"`,
);
