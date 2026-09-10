import { openPlayback } from './src/playback/resolve.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const res = await openPlayback({ session }, { videoId: 'DojPYy5lPiM', preload: false });
  const variant = res.variants.find(v => v.height === 144) || res.variants[res.variants.length - 1];
  console.log('Testing videoUrl:', variant.videoUrl);

  const start = Date.now();
  try {
    const fetchRes = await fetch(variant.videoUrl, { headers: { 'Range': 'bytes=0-' }});
    console.log('Status:', fetchRes.status);
    if (!fetchRes.body) return;
    const reader = fetchRes.body.getReader();
    let totalBytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.length;
    }
    const end = Date.now();
    console.log('Finished stream. Bytes:', totalBytes, 'Time:', (end - start) / 1000, 's');
  } catch(e) {
    const end = Date.now();
    console.log('Error stream. Time:', (end - start) / 1000, 's', e.message);
  }
}
main().catch(console.error);
