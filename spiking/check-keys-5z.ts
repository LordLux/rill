import { openPlayback } from './src/playback/resolve.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const mwebSession = await createSession({ clientType: 'MWEB' });
  const res = await openPlayback({ session: mwebSession }, { videoId: '5zCAOBHQ8Z0', preload: false });
  console.log('5zCAOBHQ8Z0 - hlsManifestUrl:', (res as any).hlsManifestUrl);
  console.log('5zCAOBHQ8Z0 - dashManifestUrl:', (res as any).dashManifestUrl);
}
main().catch(console.error);
