import { getPlayerEntry } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'VISIONOS' });
  const entry = await getPlayerEntry(session, 'jXAEIWcGXwE', 'VISIONOS');
  console.log('HLS:', entry.raw.streamingData?.hlsManifestUrl);
}
main().catch(console.error);
