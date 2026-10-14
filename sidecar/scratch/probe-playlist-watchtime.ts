/**
 * F25 for playlists (Task 34 §3.4): does a playlist watch's watchtime URL carry
 * `list=`?
 *
 * F25 measured it for a mix (`RD…`). A playlist is a different kind of list
 * and nothing recorded that the same holds. Anonymous, three requests: the
 * playlist's first page (for a video that is really in it), then `WEB /player`
 * for that video twice, with the playlist id and without.
 *
 * Run: bun run scratch/probe-playlist-watchtime.ts [PL… id]
 */
import { getPlayerResponse } from '../src/innertube/player-response.ts';
import { createSession } from '../src/innertube/session.ts';
import { getPlaylist } from '../src/parser/playlist.ts';

// Public; the playlist the `playlist` fixture was captured from. (The one F54's
// evidence names, PLbpi6ZahtOH6Ar_3GPy3workfmzvjLun4, answered "The playlist
// does not exist." on 2026-10-13.)
const playlistId = process.argv[2] ?? 'PLOzDu-MXXLlgKMA3S2FXY_XVyDrukc0si';

function describe(label: string, url: string | null): void {
  if (!url) {
    console.log(`${label}: no videostatsWatchtimeUrl`);
    return;
  }
  const parsed = new URL(url);
  const list = parsed.searchParams.get('list');
  console.log(`${label}: host=${parsed.host} path=${parsed.pathname}`);
  console.log(`${label}: list=${list === null ? '(absent)' : list}`);
  console.log(`${label}: params=${[...parsed.searchParams.keys()].sort().join(',')}`);
}

async function main(): Promise<void> {
  const session = await createSession({ clientType: 'WEB', serverVisitorId: true });

  const page = await getPlaylist(session, { playlistId, continuation: null });
  const video = page.items[0];
  if (!video) throw new Error(`playlist ${playlistId} returned no videos`);
  console.log(`playlist ${playlistId}: ${page.items.length} videos on page one; probing with ${video.id}`);

  const inPlaylist = await getPlayerResponse(session, video.id, 'WEB', { playlistId, refresh: true });
  describe('with playlistId', inPlaylist.videostatsWatchtimeUrl);

  const alone = await getPlayerResponse(session, video.id, 'WEB', { refresh: true });
  describe('without        ', alone.videostatsWatchtimeUrl);
}

await main();
