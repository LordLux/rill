/**
 * How many real caption tracks are `styled` vs `plain`?
 *
 * The three videos Task 18 was built on are caption-art demos and are a sample of
 * nothing. This asks ordinary videos off a live search, because the plain/styled
 * split decides how much of the app a second caption renderer would own.
 *
 * Ids are pulled off a raw `/search` with a regex rather than through a parser,
 * because this is a one-off sampler and the sidecar has no search module yet.
 */
import { createSession } from '../src/innertube/session.ts';
import { listCaptionTracks, classifyDocument } from '../src/captions/service.ts';

const session = await createSession({ clientType: 'MWEB' });

const ids: string[] = [];
for (const query of process.argv.slice(2)) {
  const raw = await session.execute('/search', { query });
  for (const [, id] of JSON.stringify(raw).matchAll(/"videoId":"([\w-]{11})"/g)) {
    if (!ids.includes(id)) ids.push(id);
  }
}
console.error(`${ids.length} candidate videos`);

const tally: Record<string, number> = { plain: 0, styled: 0, karaoke: 0 };
let withCaptions = 0;
let checked = 0;

for (const videoId of ids) {
  if (withCaptions >= 20) break;
  checked++;

  let sources;
  try {
    ({ sources } = await listCaptionTracks(session, videoId, { allowFallback: false }));
  } catch {
    continue;
  }
  if (sources.length === 0) continue;
  withCaptions++;

  const rows = await Promise.all(
    sources.slice(0, 4).map(async (source) => {
      try {
        const url = new URL(source.baseUrl);
        url.searchParams.set('fmt', 'json3');
        const body = await (await fetch(url)).text();
        if (body.trim() === '') return null;
        const kind = classifyDocument(JSON.parse(body));
        tally[kind] = (tally[kind] ?? 0) + 1;
        return `${source.track.id}=${kind}`;
      } catch {
        return null;
      }
    }),
  );
  console.error(`  ${videoId}  ${rows.filter(Boolean).join('  ')}`);
}

const total = tally['plain']! + tally['styled']! + tally['karaoke']!;
console.error(`\nchecked ${checked} videos, ${withCaptions} had captions, ${total} tracks read`);
for (const kind of ['plain', 'styled', 'karaoke']) {
  const n = tally[kind]!;
  console.error(`  ${kind.padEnd(8)} ${String(n).padStart(3)}  ${((n / total) * 100).toFixed(0)}%`);
}
