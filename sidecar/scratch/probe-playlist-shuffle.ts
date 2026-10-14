/**
 * What YouTube's own "Shuffle play" does for a playlist (2026-10-14).
 *
 * The playlist page carries a shuffle button that is a `watchEndpoint`: a start
 * video the server chose, the playlist id, and an opaque `params`. Unknown: does
 * a `/next` with those params return the watch page's panel already shuffled,
 * over the whole playlist or a window of it, and the same order each time?
 *
 * Anonymous. Reads every page of the playlist (one `/browse` each), the page
 * twice more for its shuffle button, then `/next` three times: with the params
 * twice, without them once.
 *
 * Run: bun run scratch/probe-playlist-shuffle.ts [PL… id]
 */
import { createSession } from '../src/innertube/session.ts';
import { parseMixPanel, mixItemIds } from '../src/parser/mix.ts';
import { getPlaylist } from '../src/parser/playlist.ts';
import { get, isObject, type Json } from '../src/parser/tree.ts';

// Public; the playlist the `playlist-public-anon` fixture was captured from.
const playlistId = process.argv[2] ?? 'PLgX4C330lEOe6u83vf-qZcv2UvuFdSpGv';

type Shuffle = { videoId: string; params: string | null };

function findShuffle(node: unknown): Shuffle | null {
  if (Array.isArray(node)) {
    for (const child of node) {
      const found = findShuffle(child);
      if (found) return found;
    }
    return null;
  }
  if (!isObject(node)) return null;
  if (get(node, 'icon', 'iconType') === 'SHUFFLE') {
    const endpoint = get(node, 'navigationEndpoint', 'watchEndpoint');
    if (isObject(endpoint) && typeof endpoint['videoId'] === 'string') {
      return { videoId: endpoint['videoId'], params: typeof endpoint['params'] === 'string' ? endpoint['params'] : null };
    }
  }
  for (const child of Object.values(node)) {
    const found = findShuffle(child);
    if (found) return found;
  }
  return null;
}

/** Keys anywhere under [node] whose name mentions shuffle. */
function shuffleKeys(node: unknown, path = '', out: string[] = []): string[] {
  if (Array.isArray(node)) {
    node.forEach((child, i) => shuffleKeys(child, `${path}.${i}`, out));
  } else if (isObject(node)) {
    for (const [key, child] of Object.entries(node)) {
      if (/shuffle/i.test(key)) out.push(`${path}.${key}=${JSON.stringify(child).slice(0, 60)}`);
      shuffleKeys(child, `${path}.${key}`, out);
    }
  }
  return out;
}

async function main(): Promise<void> {
  const session = await createSession({ clientType: 'WEB', serverVisitorId: true });

  // The whole playlist, in its own order.
  const all: string[] = [];
  let continuation: string | null = null;
  let pages = 0;
  let videoCount: number | null = null;
  do {
    const page = await getPlaylist(session, { playlistId, continuation });
    if (pages === 0) videoCount = page.videoCount;
    all.push(...page.items.map((item) => item.id));
    continuation = page.continuation;
    pages++;
  } while (continuation && pages < 30);
  const firstPage = all.slice(0, 100).length;
  console.log(`playlist ${playlistId}: header says ${videoCount} videos; read ${all.length} in ${pages} page(s)${continuation ? ' (stopped at 30)' : ''}`);
  const at = (id: string): string => {
    const i = all.indexOf(id);
    return i < 0 ? 'absent' : `${i + 1}`;
  };

  // The shuffle button, from three separate reads of the first page.
  const starts: Shuffle[] = [];
  for (let i = 0; i < 3; i++) {
    const raw = (await session.execute('/browse', { browseId: `VL${playlistId}` })) as Json;
    const shuffle = findShuffle(raw);
    if (!shuffle) throw new Error('no shuffle button on the playlist page');
    starts.push(shuffle);
    console.log(`page read ${i + 1}: shuffle starts at ${shuffle.videoId} (row ${at(shuffle.videoId)} of ${all.length}; page one holds ${firstPage}) params=${shuffle.params}`);
  }

  const start = starts[0]!;
  const params = start.params ? decodeURIComponent(start.params) : undefined;

  async function panel(label: string, withParams: boolean): Promise<string[]> {
    const raw = (await session.execute('/next', {
      videoId: start.videoId,
      playlistId,
      ...(withParams && params ? { params } : {}),
    })) as Json;
    const parsed = parseMixPanel(raw, 'probe');
    if (!parsed) {
      console.log(`${label}: no panel`);
      return [];
    }
    const ids = mixItemIds(parsed);
    const rows = ids.map(at);
    let inOrder = 0;
    for (let i = 1; i < ids.length; i++) {
      if (all.indexOf(ids[i]!) === all.indexOf(ids[i - 1]!) + 1) inOrder++;
    }
    const holder = get(raw, 'contents', 'twoColumnWatchNextResults', 'playlist', 'playlist');
    const keys = isObject(holder) ? Object.keys(holder).join(',') : '-';
    console.log(`${label}: ${ids.length} rows, currentIndex=${parsed.currentIndex}, ${inOrder} of ${Math.max(ids.length - 1, 0)} neighbours consecutive in the playlist`);
    console.log(`${label}: playlist rows of the first 20: ${rows.slice(0, 20).join(' ')}`);
    console.log(`${label}: rows not in the playlist: ${rows.filter((r) => r === 'absent').length}`);
    console.log(`${label}: panel keys: ${keys}`);
    const flagged = shuffleKeys(holder);
    console.log(`${label}: shuffle-named keys in the panel: ${flagged.length ? flagged.slice(0, 6).join(' | ') : 'none'}`);
    return ids;
  }

  const a = await panel('with params, 1', true);
  const b = await panel('with params, 2', true);
  await panel('without params ', false);

  const same = a.length === b.length && a.every((id, i) => id === b[i]);
  console.log(`the two shuffled panels are ${same ? 'identical' : 'different'}`);
}

await main();
