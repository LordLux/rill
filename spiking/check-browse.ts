import { createSession } from './src/innertube/session.ts';
import { execute } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const req = await execute(session, '/browse', { browseId: 'UCGmO0S4S-AunjRdmxA6TQYg' });
  console.log(JSON.stringify(req, null, 2).substring(0, 100)); // Just check if it works
}
main().catch(console.error);
