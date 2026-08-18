import { Innertube } from 'youtubei.js';

async function main() {
  const yt = await Innertube.create();
  const info = await yt.getBasicInfo('L-BgxLtMxh0');
  console.log(JSON.stringify(info.page[0]?.player_response?.captions, null, 2));
}

main().catch(console.error);
