import { createSession } from './src/innertube/session.ts';
import { getPlayerEntry } from './src/innertube/player-response.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const player = await getPlayerEntry(session, 'h4hy2Gn-FVE');
  console.log(JSON.stringify(player.raw.videoDetails, null, 2));
}
main().catch(console.error);
