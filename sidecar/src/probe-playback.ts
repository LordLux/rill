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
import { mpvCommand } from './playback/mpv-options.ts';
import { openPlayback } from './playback/resolve.ts';

const log = logger('probe');

/** Enough to see the throttle; 12 MB at 50 KB/s would take four minutes. */
const SAMPLE_BYTES = 12 * 1024 * 1024;

const videoId = process.argv[2] ?? process.env['YT_VIDEO_STANDARD'] ?? 'aqz-KE-bpKQ';

// Startup, such as it is. The RPC entrypoint does not exist yet; when it does,
// this call moves there and its result goes into `event.ready` (protocol.md §2).
// Until then this is the one place a missing tier 4 gets said out loud.


// Streams resolve through an anonymous session (§2.3). No cookie, on purpose —
// the browse session is a separate concern and a separate call. The client is
// chosen per `/player` call (tier 1 asks as `VISIONOS`), so `clientType` only
// sets the base context; what the ladder needs from this session is the
// server-issued visitor id `createSession` fetches by default (F5).
const session = await createSession({ clientType: 'MWEB' });
const source = await openPlayback({ session }, { videoId });
const best = source.variants[0]!;

log.info(`video    ${videoId}`);
log.info(`transport ${source.transport}${source.qualityDegraded ? '  (DEGRADED)' : ''}`);
log.info(`quality  ${best.height ?? '?'}p  ${best.videoCodec ?? '?'} / ${best.audioCodec ?? '?'}`);
log.info(`variants ${source.variants.length}`);
for (const v of source.variants) {
  log.info(`  itag ${v.itag}: ${v.height}p${v.fps} ${v.videoCodec}`);
}
log.info(`duration ${source.durationMs === null ? 'live' : `${Math.round(source.durationMs / 1000)}s`}`);
log.info(`storyboard ${source.storyboardTemplate ? 'present' : 'absent'}`);

const started = Date.now();
let received = 0;
const response = await fetch(best.videoUrl, { headers: { range: `bytes=0-${SAMPLE_BYTES - 1}` } });
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
// Carries `--stream-lavf-o=request_size=…`, same as the app will. The shipped
// libmpv ignores it (F13); a newer one needs it to seek. See `mpv-options.ts`.
log.info(mpvCommand(best.videoUrl, best.audioUrl));

if (process.env['YT_DUMP_ASS']) {
  const { listCaptionTracks, getCaptionTrack } = await import('./captions/service.ts');
  const fs = await import('fs');
  const list = await listCaptionTracks(session, videoId);
  const sources = list.sources;
  const first = sources[0];
  if (first !== undefined) {
    const track = await getCaptionTrack(session, videoId, first.track.id);
    const file = process.env['YT_DUMP_ASS'];
    fs.writeFileSync(file, track.content);
    log.info(`\nwrote first caption track to ${file}`);
  } else {
    log.info(`\nno caption tracks found for ${videoId}`);
  }
}
