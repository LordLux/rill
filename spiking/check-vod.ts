import { getVideoInfo } from './src/video/info.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'WEB' });
  const res = await getVideoInfo({ session }, 'DojPYy5lPiM');
  console.log('isLive:', res.video.isLive);
  console.log('isShort:', res.video.isShort);
  console.log('duration:', res.video.durationSeconds);
}
main().catch(console.error);
