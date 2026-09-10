import { openPlayback } from './src/playback/resolve.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'MWEB' });
  const res = await openPlayback({ session }, { videoId: '5zCAOBHQ8Z0', preload: false });
  const variant = res.variants.find(v => v.height === 144) || res.variants[res.variants.length - 1]; // low quality
  console.log('Testing audioUrl:', variant.audioUrl);
  
  const start = Date.now();
  const fetchRes = await fetch(variant.audioUrl, { headers: { 'Range': 'bytes=0-' }});
  const reader = fetchRes.body.getReader();
  let totalBytes = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    totalBytes += value.length;
  }
  const end = Date.now();
  console.log('Audio stream bytes:', totalBytes, 'Time:', (end - start)/1000, 's');
}
main().catch(console.error);
