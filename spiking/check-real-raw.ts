import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'VISIONOS' });
  const raw = await session.execute('/player', { videoId: 'DojPYy5lPiM' });
  const streamingData = raw.streamingData || {};
  console.log('hlsManifestUrl:', streamingData.hlsManifestUrl);
  console.log('dashManifestUrl:', streamingData.dashManifestUrl);
  console.log('isLive:', raw.videoDetails?.isLiveContent);
}
main().catch(console.error);
