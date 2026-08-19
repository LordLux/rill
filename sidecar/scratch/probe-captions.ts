import { createSession } from '../src/innertube/session.ts';
import { listCaptionTracks, getCaptionTrack } from '../src/captions/service.ts';
import * as fs from 'fs';

const session = await createSession({ clientType: 'MWEB' });
for (const videoId of ['1S7uIQmkRzk', 'L-BgxLtMxh0']) {
  const result = await listCaptionTracks(session, videoId);
  const sources = result.sources;
  console.log(`${videoId} tracks: ${sources.length}`);
  if (sources.length > 0) {
    const track = await getCaptionTrack(session, videoId, sources[0].track.id!);
    console.log(`Writing ${videoId}.ass`);
    fs.writeFileSync(`../${videoId}.ass`, track.content);
  }
}
