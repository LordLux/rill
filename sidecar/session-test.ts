import { createSession } from './src/innertube/session.ts';
import { playerPayload } from './src/innertube/session.ts';

async function main() {
  const videoId = 'L-BgxLtMxh0';
  console.log(`Fetching /player for ${videoId} using 10 fresh MWEB sessions (calling with ANDROID_VR)...`);
  
  let zeroCount = 0;
  let nonZeroCount = 0;
  
  for (let i = 0; i < 10; i++) {
    try {
      const session = await createSession({ clientType: 'MWEB' });
      const raw: any = await session.execute('/player', playerPayload(session, videoId, 'ANDROID_VR'));
      const tracks = raw?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
      const count = Array.isArray(tracks) ? tracks.length : 0;
      
      console.log(`Session ${i + 1}: ${count} tracks`);
      
      if (count === 0) zeroCount++;
      else nonZeroCount++;
    } catch (e) {
      console.error(`Session ${i + 1}: ERROR`, e);
    }
  }
  
  console.log(`\nResults: ${zeroCount} sessions got 0 tracks, ${nonZeroCount} sessions got >0 tracks`);
}

main().catch(console.error);
