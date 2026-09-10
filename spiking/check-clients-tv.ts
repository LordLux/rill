import { createSession } from './src/innertube/session.ts';

async function main() {
  const clients = ['IOS', 'TV_EMBEDDED', 'TVHTML5'];
  for (const clientType of clients) {
    try {
      const session = await createSession({ clientType });
      const raw = await session.execute('/player', { videoId: 'DojPYy5lPiM' });
      const streamingData = raw.streamingData || {};
      console.log(clientType + ' - hlsManifestUrl:', !!streamingData.hlsManifestUrl);
      console.log(clientType + ' - dashManifestUrl:', !!streamingData.dashManifestUrl);
    } catch(e) {
      console.log(clientType + ' - error:', e.message);
    }
  }
}
main().catch(console.error);
