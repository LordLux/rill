import { getPlayerEntry } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const entry = await getPlayerEntry(session, 'jXAEIWcGXwE', 'MWEB');
  console.log('HLS:', entry.raw.streamingData?.hlsManifestUrl);
  console.log('DASH:', entry.raw.streamingData?.dashManifestUrl);
}
main().catch(console.error);
