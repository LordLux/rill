import { getPlayerEntry } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const entry = await getPlayerEntry(session, 'DojPYy5lPiM', 'MWEB');
  console.log(JSON.stringify(entry.raw.videoDetails, null, 2));
}
main().catch(console.error);
