import { Innertube } from 'youtubei.js';

async function main() {
  const yt = await Innertube.create();
  const next = await yt.actions.execute('/next', { videoId: 'L-BgxLtMxh0', client: 'WEB' });
  console.log('next response keys:', Object.keys(next.data));
  console.log('has captions in next?', !!next.data?.playerResponse?.captions || !!next.data?.captions);
}

main().catch(console.error);
