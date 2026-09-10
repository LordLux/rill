import { Innertube, UniversalCache } from 'youtubei.js';

async function main() {
  const yt = await Innertube.create({ cache: new UniversalCache(false) });
  const search = await yt.search('DECO*27');
  const video = search.videos.find(v => v.id === 'h4hy2Gn-FVE');
  console.log(JSON.stringify(video, null, 2));
}
main().catch(console.error);
