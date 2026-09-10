import { createSession } from './src/innertube/session.ts';
import { performSearch } from './src/innertube/search.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  // search is exported from youtubei directly? No, search.ts doesn't exist.
}
main().catch(console.error);
