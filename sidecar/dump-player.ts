import { createSession } from './src/innertube/session.ts';
import { getPlayerEntry } from './src/innertube/player-response.ts';
import fs from 'fs';

async function main() {
  const session = await createSession({ cookieFile: null } as any);
  const { raw } = await getPlayerEntry(session, 'dQw4w9WgXcQ', 'ANDROID_VR');
  fs.writeFileSync('test-player.json', JSON.stringify(raw, null, 2));
  console.log('done');
}
main();
