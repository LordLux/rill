import { getPlayerEntry } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'WEB' });
  const entry = await getPlayerEntry(session, 'jXAEIWcGXwE', 'WEB');
  console.log('HLS:', entry.raw.streamingData?.hlsManifestUrl);
  console.log('DASH:', entry.raw.streamingData?.dashManifestUrl);
}
main().catch(console.error);
