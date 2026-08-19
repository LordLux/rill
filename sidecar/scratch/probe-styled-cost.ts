/**
 * What it would cost to know `styled` for every track when the menu opens.
 *
 * The track list rides on a cached `/player`, so it is free; the styling arrays
 * live in the *document*, which is one `timedtext` GET per track. This measures
 * that: how many real tracks a video has, how big each document is, and how long
 * fetching all of them takes.
 */
import { createSession } from '../src/innertube/session.ts';
import { listCaptionTracks } from '../src/captions/service.ts';

const ids = process.argv.slice(2);
const session = await createSession({ clientType: 'MWEB' });

for (const videoId of ids) {
  const { sources } = await listCaptionTracks(session, videoId);
  const started = Date.now();
  let bytes = 0;
  let styled = 0;

  const results = await Promise.all(
    sources.map(async (source) => {
      const url = new URL(source.baseUrl);
      url.searchParams.set('fmt', 'json3');
      const at = Date.now();
      const body = await (await fetch(url)).text();
      const doc = JSON.parse(body) as Record<string, unknown[]>;
      const populated = (key: string) =>
        ((doc[key] ?? []) as object[]).filter((entry) => Object.keys(entry).length > 0).length;
      const pens = populated('pens');
      bytes += body.length;
      if (pens > 0) styled++;
      return (
        `${source.track.id.padEnd(8)} ${(body.length / 1024).toFixed(0).padStart(4)}KB ` +
        `${String(Date.now() - at).padStart(4)}ms  pens=${String(pens).padStart(4)} ` +
        `winStyles=${populated('wsWinStyles')} winPos=${String(populated('wpWinPositions')).padStart(3)}`
      );
    }),
  );

  console.error(`${videoId}: ${sources.length} track(s), ${styled} styled`);
  for (const line of results) console.error(`   ${line}`);
  console.error(
    `   all in parallel: ${Date.now() - started}ms, ${(bytes / 1024).toFixed(0)}KB total`,
  );
}
