import { createSession, execute } from './src/innertube/session.ts';
import { parseBrowse } from './src/parser/browse.ts';

async function testClient(clientType) {
  try {
    const session = await createSession({ clientType });
    // Use browse endpoint to get home feed. 
    // Usually browseId for home is 'FEwhat_to_watch'
    const res = await execute(session, '/browse', { browseId: 'FEwhat_to_watch' });
    const parsed = parseBrowse(res);
    console.log(clientType, 'parsed items:', parsed.items?.length || 0);
  } catch (e) {
    console.log(clientType, 'Error:', e.message);
  }
}

async function main() {
  await testClient('MWEB');
  await testClient('ANDROID');
}
main().catch(console.error);
