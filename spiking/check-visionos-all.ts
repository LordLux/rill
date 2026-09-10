import { getPlayerResponse } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'VISIONOS' });
  const entry = await getPlayerResponse(session, 'DojPYy5lPiM', 'VISIONOS');
  console.log(JSON.stringify(entry, null, 2));
}
main().catch(console.error);
