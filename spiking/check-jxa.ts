import { openPlayback } from './src/playback/resolve.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const res = await openPlayback({ session: session }, { videoId: 'jXAEIWcGXwE', preload: false });
  console.log(JSON.stringify(res, null, 2));
}
main().catch(console.error);
