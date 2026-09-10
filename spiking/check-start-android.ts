import { getPlayerEntry } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'ANDROID' });
  const entry = await getPlayerEntry(session, 'DojPYy5lPiM', 'ANDROID');
  console.log(JSON.stringify(entry.raw.microformat, null, 2));
}
main().catch(console.error);
