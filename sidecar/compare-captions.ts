import { createSession } from './src/innertube/session.ts';
import { playerPayload } from './src/innertube/session.ts';

const videos = [
  'L-BgxLtMxh0', // Styled Subtitles for YouTube Videos showcase
  'dQw4w9WgXcQ', // Never Gonna Give You Up
  'jNQXAC9IVRw', // Me at the zoo
  '9bZkp7q19f0', // Gangnam style
  'kffacxfA7G4', // Baby
  'JGwWNGJdvx8', // Shape of You
  'OPf0YbXqDm0', // Uptown Funk
  '09R8_2nJtjg', // Sugar
  'e-ORhEE9VVg', // Blank Space
  'YQHsXMglC9A', // Hello
  'fRh_vgS2dFE', // Sorry
  'lp-EO5I60KA', // Thinking Out Loud
  'CevxZvSJLk8', // Roar
  'pRpeEdMmi3I', // Waka Waka
  'RgKAFK5djSk', // See You Again
  'V1bFr2SWP1I', // The Lazy Song
  'nfWlot6h_JM', // Shake It Off
  'kJQP7kiw5Fk', // Despacito
  'SlPhMPnQ58k', // Memories
  'rtOvBOTyX00', // Believer
];

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const webSession = await createSession({ clientType: 'WEB' });
  
  let allOrNothing = true;
  let partial = false;
  let differingCount = 0;
  
  console.log('Video | ANDROID_VR | WEB');
  console.log('---|---|---');

  for (const v of videos) {
    let vrCount = 0;
    let webCount = 0;
    try {
      const vrRaw: any = await session.execute('/player', playerPayload(session, v, 'ANDROID_VR'));
      const tracks = vrRaw?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
      vrCount = Array.isArray(tracks) ? tracks.length : 0;
    } catch(e) {}
    try {
      const webRaw: any = await webSession.execute('/player', playerPayload(webSession, v, 'WEB'));
      const tracks = webRaw?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
      webCount = Array.isArray(tracks) ? tracks.length : 0;
    } catch(e) {}

    console.log(`${v} | ${vrCount} | ${webCount}`);

    if (vrCount !== webCount) {
      differingCount++;
      if (vrCount > 0 && webCount > 0) {
        allOrNothing = false;
        partial = true;
      }
    }
  }

  console.log(`\nDiffering fraction: ${differingCount}/${videos.length}`);
  console.log(`All-or-nothing: ${allOrNothing}`);
  console.log(`Partial: ${partial}`);
}

main().catch(console.error);
