import { getPlayerEntry } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const entry = await getPlayerEntry(session, 'jXAEIWcGXwE', 'MWEB');
  console.log('Start:', entry.raw.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.startTimestamp);
}
main().catch(console.error);
