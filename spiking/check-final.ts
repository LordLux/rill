import { openPlayback } from './src/playback/resolve.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const res = await openPlayback({ session: session }, { videoId: 'DojPYy5lPiM', preload: false });
  console.log('Returned startTimestamp:', res.startTimestamp);
}
main().catch(console.error);
