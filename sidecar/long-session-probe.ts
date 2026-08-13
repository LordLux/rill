/**
 * Does a **long-lived** session ever land in the poisoned bucket?
 *
 * F20's reproduction gap: the app mints one resolve session at startup and
 * reuses it for every resolution (33% of launches poisoned); a standalone script
 * makes a fresh one per run (0/12). If the bucket is assigned per session, a
 * short-lived one would never carry it. This is the standalone half of that
 * test — one session, twenty resolutions, spread over minutes.
 *
 * Results to stderr (hard invariant 3).
 *
 *   SIDECAR_PLAYER_RESPONSE_TTL_MS=0 bun run long-session-probe.ts
 */
import { createSession } from './src/innertube/session.ts';
import { openPlayback } from './src/playback/resolve.ts';

const FLAG = '51946838';
const videos = [
  'aqz-KE-bpKQ', 'jNQXAC9IVRw', 'dQw4w9WgXcQ', 'kJQP7kiw5Fk',
  'fJ9rUzIMcZQ', 'YQHsXMglC9A', '9bZkp7q19f0', 'CevxZvSJLk8',
];

const session = await createSession({ clientType: 'MWEB' });
const started = Date.now();
let flagged = 0;
let n = 0;

for (let round = 0; round < 20; round++) {
  const videoId = videos[round % videos.length]!;
  try {
    const src = await openPlayback({ session }, { videoId });
    const fexp = new URL(src.variants[0]!.videoUrl).searchParams.get('fexp') ?? '';
    const has = fexp.split(',').includes(FLAG);
    n += 1;
    if (has) flagged += 1;
    process.stderr.write(
      JSON.stringify({ round, ageSec: Math.round((Date.now() - started) / 1000), videoId, flagged: has }) + '\n',
    );
  } catch (e) {
    process.stderr.write(JSON.stringify({ round, videoId, error: (e as Error).message.slice(0, 80) }) + '\n');
  }
  // Spread over minutes: a bucket that only appears on an aged session would be
  // invisible to twenty requests fired back to back.
  await new Promise((r) => setTimeout(r, 12_000));
}

process.stderr.write(`\none session, ${n} resolutions over ${Math.round((Date.now() - started) / 1000)}s: flagged ${flagged}/${n}\n`);
process.exit(0);
