/**
 * Does a freshly resolved `ANDROID_VR` URL accept ffmpeg's request shape?
 *
 * F10 recorded that `c=MWEB` URLs refuse open-ended `Range: bytes=0-` and that
 * `ANDROID_VR` URLs do not — F11 measured 28/28 `206` and called the difference
 * settled. The launch probe found an `ANDROID_VR` URL that **persistently**
 * refuses the open-ended form (5/5 `403` over 40 s) while answering a bounded
 * one with `206`, which is F10's signature on the client F10 said was clear.
 *
 * ffmpeg opens every HTTP stream with `Range: bytes=0-`, so such a URL cannot be
 * played at all — mpv reports `HTTP error 403 Forbidden` and gives up.
 *
 * This resolves N times through the real ladder and tests every URL both ways,
 * to answer three things the launch loop cannot:
 *
 *  - the **rate** at which a resolution comes back poisoned;
 *  - whether it is the whole resolution or **individual variants**, which
 *    decides whether falling back to another rung would recover;
 *  - whether it tracks the **edge host** (`rr7---sn-…`), which would make it a
 *    property of where YouTube sent us rather than of the request.
 *
 * Results go to **stderr**, not stdout: hard invariant 3 makes stdout the RPC
 * channel and the lint rule enforces it even for a standalone script.
 *
 * Read-only. It resolves and issues HEAD-shaped GETs; it fixes nothing.
 *
 *   bun run url-shape-probe.ts [rounds]
 */

import { createSession } from './src/innertube/session.ts';
import { openPlayback } from './src/playback/resolve.ts';

const rounds = Number(process.argv[2] ?? '10');
const videoId = process.env.PROBE_VIDEO ?? 'aqz-KE-bpKQ';

/** The status a request of this shape gets, without reading the body. */
async function status(url: string, range: string | null): Promise<number | string> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch(url, {
      headers: range === null ? {} : { Range: range },
      signal: controller.signal,
    });
    // Abort at the status line. F11 records that reading a 712 MB body here
    // panicked Bun with `Out of memory while copying request body`.
    controller.abort();
    return response.status;
  } catch (error) {
    if (controller.signal.aborted && error instanceof Error && error.name === 'AbortError') {
      return 'aborted';
    }
    return `threw:${(error as Error).name}`;
  } finally {
    clearTimeout(timer);
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname.split('.')[0] ?? '?';
  } catch {
    return '?';
  }
}

const results: Array<Record<string, unknown>> = [];

for (let round = 1; round <= rounds; round++) {
  const session = await createSession();
  const source = await openPlayback({ session }, { videoId });

  // The rung the app would actually take, plus two more down the ladder — enough
  // to tell "this resolution is poisoned" from "this variant is".
  const sample = [source.variants[0], source.variants[2], source.variants[5]].filter(
    (v): v is NonNullable<typeof v> => v != null,
  );

  for (const [index, variant] of sample.entries()) {
    const open = await status(variant.videoUrl, 'bytes=0-');
    const bounded = await status(variant.videoUrl, 'bytes=0-1');
    const row = {
      round,
      rung: index === 0 ? 'top' : `+${index}`,
      itag: variant.itag,
      height: variant.height,
      host: hostOf(variant.videoUrl),
      openEnded: open,
      bounded,
      poisoned: open === 403 && bounded === 206,
    };
    results.push(row);
    process.stderr.write(JSON.stringify(row) + '\n');
  }
}

// --- summary ---------------------------------------------------------------
const top = results.filter((r) => r.rung === 'top');
const poisonedTop = top.filter((r) => r.poisoned);
const poisonedAny = results.filter((r) => r.poisoned);

process.stderr.write(
  `\nrounds=${rounds}\n` +
    `top rung poisoned: ${poisonedTop.length}/${top.length}\n` +
    `any variant poisoned: ${poisonedAny.length}/${results.length}\n`,
);

// Whole resolution, or just some rungs?
const byRound = new Map<number, typeof results>();
for (const r of results) {
  const list = byRound.get(r.round as number) ?? [];
  list.push(r);
  byRound.set(r.round as number, list);
}
for (const [round, rows] of byRound) {
  const bad = rows.filter((r) => r.poisoned).length;
  if (bad > 0 && bad < rows.length) {
    process.stderr.write(`round ${round}: PARTIAL — ${bad}/${rows.length} rungs poisoned\n`);
  }
}

// Does it track the edge host?
const hosts = new Map<string, { total: number; bad: number }>();
for (const r of results) {
  const h = hosts.get(r.host as string) ?? { total: 0, bad: 0 };
  h.total += 1;
  if (r.poisoned) h.bad += 1;
  hosts.set(r.host as string, h);
}
process.stderr.write('\nby host:\n');
for (const [host, { total, bad }] of hosts) {
  process.stderr.write(`  ${host}: ${bad}/${total} poisoned\n`);
}

process.exit(0);
