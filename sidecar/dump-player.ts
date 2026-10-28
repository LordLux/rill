import { createSession } from './src/innertube/session.ts';
import { getPlayerEntry } from './src/innertube/player-response.ts';
import fs from 'fs';

async function main() {
  const session = await createSession({ cookieFile: null } as any);
  const { raw } = await getPlayerEntry(session, 'dQw4w9WgXcQ', 'ANDROID_VR');
  // Into an ignored folder: a raw response carries the capturing machine's address and a visitor id,
  // and two of these sat in the repository for months (tools/check-text-files.ts refuses them now).
  fs.mkdirSync('scratch', { recursive: true });
  fs.writeFileSync('scratch/test-player.json', JSON.stringify(raw, null, 2));
  console.log('done');
}
main();
