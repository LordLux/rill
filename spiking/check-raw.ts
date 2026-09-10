import { getPlayerResponse } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'VISIONOS' });
  const res = await getPlayerResponse(session, 'DojPYy5lPiM', 'VISIONOS');
  console.log('keys in res:', Object.keys(res));
  if (res.formats) {
     console.log('res.formats keys:', res.formats.map(f => Object.keys(f)));
  }
  console.log('raw keys:', Object.keys((res as any)._raw || res));
  console.log('hlsManifestUrl:', (res as any).hlsManifestUrl || (res as any)._raw?.streamingData?.hlsManifestUrl);
  console.log('dashManifestUrl:', (res as any).dashManifestUrl || (res as any)._raw?.streamingData?.dashManifestUrl);
}
main().catch(console.error);
