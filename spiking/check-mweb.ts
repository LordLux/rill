import { getPlayerEntry } from './src/innertube/player-response.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const entry = await getPlayerEntry(session, 'DojPYy5lPiM', 'MWEB');
  console.log('MWEB formats:', entry.raw.streamingData?.formats?.length);
  console.log('MWEB adaptive:', entry.raw.streamingData?.adaptiveFormats?.length);
  console.log('MWEB cipher?', entry.raw.streamingData?.adaptiveFormats?.[0]?.signatureCipher ? 'YES' : 'NO');
}
main().catch(console.error);
