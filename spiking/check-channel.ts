import { Innertube, UniversalCache } from 'youtubei.js';

async function main() {
  const yt = await Innertube.create({ cache: new UniversalCache(false) });
  const channel = await yt.getChannel('UCGmO0S4S-AunjRdmxA6TQYg');
  const liveTab = await channel.getTabByName('Live');
  // wait, maybe the home feed? Let's just find the video on the channel.
  if (liveTab && liveTab.memo.getVideos().length > 0) {
    const video = liveTab.memo.getVideos().find(v => v.id === 'h4hy2Gn-FVE');
    if (video) {
      console.log('Found video:', video.title.text);
      console.log('Badges:', JSON.stringify(video.raw.badges, null, 2));
      console.log('ThumbnailOverlays:', JSON.stringify(video.raw.thumbnailOverlays, null, 2));
    }
  }
}
main().catch(console.error);
