import { openPlayback } from './src/playback/resolve.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'VISIONOS' });
  const res = await openPlayback({ session: session }, { videoId: 'jXAEIWcGXwE', preload: false });
  console.log(res.variants[0].videoUrl);
}
main().catch(console.error);
