/**
 * Does a second `/player` for the same video poison the first one's URLs?
 *
 * The launch probe found 5 launches in 20 where mpv got `HTTP error 403` on the
 * open-ended range ffmpeg always sends, while the same URL answered a bounded
 * range with `206`. Resolving the same video 45 times standalone produced **no**
 * such URL — so it is not simply that YouTube sometimes issues a poisoned one.
 *
 * The app does something the standalone probe does not: it issues **two**
 * `/player` calls for the same video, seconds apart, on the same session.
 * `playback.open` is the first; `video.info` makes the second through
 * `durationFromPlayer`, because a `/next` response carries no duration. That is
 * the difference this measures.
 *
 * Per round: resolve twice on one session, then test the **first** resolution's
 * top URL both ways. If the first goes 403-on-open-ended once the second exists,
 * the app has been invalidating its own stream URL.
 *
 * Results go to **stderr**, not stdout: hard invariant 3 makes stdout the RPC
 * channel and the lint rule enforces it even for a standalone script.
 *
 * Read-only.
 *
 *   bun run double-resolve-probe.ts [rounds]
 */

import { createSession } from './src/innertube/session.ts';
import { openPlayback } from './src/playback/resolve.ts';

const rounds = Number(process.argv[2] ?? '10');
const videoId = process.env.PROBE_VIDEO ?? 'aqz-KE-bpKQ';

async function status(url: string, range: string): Promise<number | string> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch(url, { headers: { Range: range }, signal: controller.signal });
    controller.abort();
    return response.status;
  } catch (error) {
    return controller.signal.aborted ? 'aborted' : `threw:${(error as Error).name}`;
  } finally {
    clearTimeout(timer);
  }
}

/** Open-ended is what ffmpeg sends; bounded is the control. */
async function shape(url: string): Promise<{ open: number | string; bounded: number | string }> {
  return { open: await status(url, 'bytes=0-'), bounded: await status(url, 'bytes=0-1') };
}

let poisonedAfter = 0;
let poisonedBefore = 0;

for (let round = 1; round <= rounds; round++) {
  const session = await createSession();

  const first = await openPlayback({ session }, { videoId });
  const firstUrl = first.variants[0]!.videoUrl;

  // Before: the state the standalone probe measured, and found clean 45/45.
  const before = await shape(firstUrl);

  // The second `/player`, as `video.info` issues it moments after the open.
  const second = await openPlayback({ session }, { videoId });
  const secondUrl = second.variants[0]!.videoUrl;

  // After: is the *first* URL still usable?
  const after = await shape(firstUrl);
  const secondShape = await shape(secondUrl);

  const wasPoisoned = before.open === 403 && before.bounded === 206;
  const nowPoisoned = after.open === 403 && after.bounded === 206;
  if (wasPoisoned) poisonedBefore += 1;
  if (nowPoisoned && !wasPoisoned) poisonedAfter += 1;

  process.stderr.write(
    JSON.stringify({
      round,
      sameUrl: firstUrl === secondUrl,
      firstBefore: before,
      firstAfter: after,
      second: secondShape,
      poisonedBySecondResolve: nowPoisoned && !wasPoisoned,
    }) + '\n',
  );
}

process.stderr.write(
  `\nrounds=${rounds}\n` +
    `first URL already poisoned before the second resolve: ${poisonedBefore}\n` +
    `first URL poisoned *by* the second resolve: ${poisonedAfter}\n`,
);

process.exit(0);
