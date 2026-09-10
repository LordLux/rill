import { openPlayback } from './src/playback/resolve.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const mwebSession = await createSession({ clientType: 'MWEB' });
  const res = await openPlayback({ session: mwebSession }, { videoId: 'DojPYy5lPiM', preload: false });
  console.log('Keys in res:', Object.keys(res));
  console.log('hlsManifestUrl:', (res as any).hlsManifestUrl);
}
main().catch(console.error);
