import { createSession } from '../src/innertube/session.ts';
import { getCaptionTrack } from '../src/captions/service.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const track = await getCaptionTrack(session, 'L-BgxLtMxh0', '.en', {
    style: {
      textColor: { r: 0, g: 255, b: 0, a: 1 },
      background: { r: 255, g: 255, b: 255, a: 0.8 },
      window: { r: 0, g: 0, b: 0, a: 0 }
    },
    renderer: 'libass_layer'
  });
  console.log(track.content);
}

main().catch(console.error);
