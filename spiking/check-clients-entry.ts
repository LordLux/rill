import { getPlayerEntry } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const clients = ['VISIONOS', 'MWEB', 'WEB', 'IOS', 'TVHTML5'];
  for (const clientType of clients) {
    try {
      const session = await createSession({ clientType });
      const entry = await getPlayerEntry(session, 'DojPYy5lPiM', clientType as any);
      const sd = entry.raw.streamingData || {};
      console.log(clientType + ' - hlsManifestUrl:', !!sd.hlsManifestUrl);
      console.log(clientType + ' - dashManifestUrl:', !!sd.dashManifestUrl);
    } catch(e) {
      console.log(clientType + ' - error:', e.message);
    }
  }
}
main().catch(console.error);
