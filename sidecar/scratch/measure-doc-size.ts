/**
 * Task 19, question 3: is a multi-megabyte caption document an outlier or a
 * category?
 *
 * `8Oos6D4_Bjo` is 3.1 MB and takes 59 ms to convert, against 3–4 ms for two
 * ordinary documents. If documents that size are a class of content, the style
 * menu needs a fast path that does not re-parse; if it is one demo video, the
 * cue cache is enough and the outlier is allowed to cost what it costs.
 *
 * What actually drives the cost is measured alongside the size, because they are
 * not the same thing: `renderAss` emits a run per *segment*, so segments per cue
 * predicts the render better than bytes do.
 *
 *   bun run scratch/measure-doc-size.ts [count-per-query]
 */
import { createSession } from '../src/innertube/session.ts';
import { listCaptionTracks } from '../src/captions/service.ts';
import { parseJson3 } from '../src/captions/json3.ts';
import { normalizeCues } from '../src/captions/cues.ts';

const PER_QUERY = Number(process.argv[2] ?? '12');

/** Deliberately ordinary, plus one aimed at the content that produces the outlier. */
const QUERIES = [
  'TED talks',
  'news today',
  'cooking recipe',
  'music video 2024',
  'game trailer',
  'karaoke subtitles effect',
];

function videoIds(node: unknown, into: Set<string>): void {
  if (node === null || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    for (const item of node) videoIds(item, into);
    return;
  }
  const record = node as Record<string, unknown>;
  const id = record['videoId'];
  if (typeof id === 'string' && id.length === 11) into.add(id);
  for (const value of Object.values(record)) videoIds(value, into);
}

interface Row {
  videoId: string;
  trackId: string;
  bytes: number;
  cues: number;
  segs: number;
  styledSegs: number;
}

async function main(): Promise<void> {
  const session = await createSession({ clientType: 'MWEB' });
  const ids = new Set<string>();
  for (const query of QUERIES) {
    const feed = await session.execute('/search', { query });
    const found = new Set<string>();
    videoIds(feed, found);
    for (const id of [...found].slice(0, PER_QUERY)) ids.add(id);
  }
  console.error(`sampling ${ids.size} videos`);

  const rows: Row[] = [];
  for (const videoId of ids) {
    try {
      const { sources } = await Promise.race([
        listCaptionTracks(session, videoId),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), 4000)),
      ]);
      for (const source of sources) {
        const url = new URL(source.baseUrl);
        url.searchParams.set('fmt', 'json3');
        const body = await (await fetch(url)).text();
        if (body.trim() === '') continue;
        const cues = normalizeCues(parseJson3(JSON.parse(body)));
        rows.push({
          videoId,
          trackId: source.track.id,
          bytes: body.length,
          cues: cues.length,
          segs: cues.reduce((total, cue) => total + cue.segments.length, 0),
          styledSegs: cues.reduce(
            (total, cue) => total + cue.segments.filter((seg) => seg.style !== null).length,
            0,
          ),
        });
      }
    } catch (error) {
      console.error(`  ${videoId}: ${(error as Error).message}`);
    }
  }

  rows.sort((a, b) => b.bytes - a.bytes);
  console.error(`\n${rows.length} track(s), largest first:`);
  for (const row of rows.slice(0, 12)) {
    console.error(
      `  ${row.videoId} ${row.trackId.padEnd(6)} ` +
        `${(row.bytes / 1024).toFixed(0).padStart(6)} KB  ` +
        `${String(row.cues).padStart(4)} cues  ` +
        `${String(row.segs).padStart(6)} segs  ` +
        `${(row.segs / Math.max(1, row.cues)).toFixed(1).padStart(6)} segs/cue  ` +
        `${row.styledSegs > 0 ? 'styled-segs' : ''}`,
    );
  }

  const sizes = rows.map((row) => row.bytes).sort((a, b) => a - b);
  const at = (q: number) => sizes[Math.min(sizes.length - 1, Math.floor(q * sizes.length))] ?? 0;
  console.error(`\nbytes: p50 ${(at(0.5) / 1024).toFixed(0)} KB  p90 ${(at(0.9) / 1024).toFixed(0)} KB  ` +
    `p99 ${(at(0.99) / 1024).toFixed(0)} KB  max ${(sizes[sizes.length - 1]! / 1024).toFixed(0)} KB`);
  console.error(`over 1 MB: ${rows.filter((row) => row.bytes > 1024 * 1024).length} / ${rows.length}`);
  console.error(`with any per-segment style: ${rows.filter((row) => row.styledSegs > 0).length} / ${rows.length}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
