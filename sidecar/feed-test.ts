import { Innertube } from 'youtubei.js';
import { createSession } from './src/innertube/session.ts';
import { playerPayload } from './src/innertube/session.ts';

async function main() {
  console.log('Initializing youtubei.js to fetch feed...');
  const yt = await Innertube.create();
  const webSession = await createSession({ clientType: 'WEB' });
  const raw: any = await webSession.execute('/player', playerPayload(webSession, 'L-BgxLtMxh0', 'WEB'));
  
  const renderer = raw?.captions?.playerCaptionsTracklistRenderer;
  console.log(`translationLanguages present:`, !!renderer?.translationLanguages);
  if (renderer?.translationLanguages) {
    console.log(`Found ${renderer.translationLanguages.length} translation languages`);
  }
}

main().catch(console.error);
