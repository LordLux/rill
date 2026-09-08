/**
 * Fetch the caption tracks for a list of videos and save both the raw `json3`
 * and the rendered ASS, so a styling change can be re-checked offline afterwards
 * with `scratch/dump-ass.ts`.
 *
 *   bun run scratch/probe-captions.ts <videoId> [videoId...]
 */
import * as fs from 'fs';
import { createSession } from '../src/innertube/session.ts';
import { listCaptionTracks, getCaptionTrack } from '../src/captions/service.ts';

const ids = process.argv.slice(2);
if (ids.length === 0) throw new Error('usage: probe-captions.ts <videoId> [videoId...]');

const session = await createSession({ clientType: 'MWEB' });
const out = 'scratch/out';
fs.mkdirSync(out, { recursive: true });

for (const videoId of ids) {
  const { sources } = await listCaptionTracks(session, videoId);
  console.error(`${videoId}: ${sources.length} track(s)`);
  const first = sources[0];
  if (first === undefined) continue;

  const url = new URL(first.baseUrl);
  url.searchParams.set('fmt', 'json3');
  const raw = await (await fetch(url)).text();
  fs.writeFileSync(`${out}/${videoId}.json`, raw);

  const track = await getCaptionTrack(session, videoId, first.track.id);
  fs.writeFileSync(`${out}/${videoId}.ass`, track.content);
  console.error(`  ${first.track.id} (${first.track.languageCode}) -> ${track.cueCount} cue(s)`);
}
