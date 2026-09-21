#!/usr/bin/env bun
/**
 * Fixture capture — `bun run capture`.
 *
 * Writes raw, unparsed InnerTube responses to `fixtures/`. Those files are the
 * offline corpus the parser is tested against; they are the only way to test
 * tolerant parsing, since the live feed cannot be pinned.
 *
 * Two rules that have already cost us once each:
 *
 *   - `parse: false`, always. Parsed objects are lossy (F2) and make a useless
 *     corpus.
 *   - The directory is cleared first. Mixing runs once produced a completely
 *     wrong reading of the live feed — a stale file from an earlier capture was
 *     read as evidence about the current one.
 *
 * Every capture is independent: one failing endpoint is recorded in the manifest
 * and the rest continue. A degraded session, however, aborts the whole run —
 * fixtures captured through an empty shell are worse than no fixtures.
 *
 * Clearing wholesale is only safe because this run knows what it owns. It does
 * not delete a file it cannot account for, and it does not delete a file it
 * failed to replace: `fixtures.ts` declares both sides and this script refuses
 * rather than guesses. See `todo.md` 41 for the three fixtures that sat here
 * owned by nothing.
 */

import { cp, mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { logger, logUnknownRendererSummary } from './log.ts';
import { createSession, playerPayload, verifyAuth, type Session } from './innertube/session.ts';
import { parseFeed } from './parser/index.ts';
import { parseComments } from './parser/comments.ts';
import { parseVideoDetail } from './parser/video.ts';
import { CARRIED, CAPTURE_FILES, lostFixtures, unownedEntries } from './fixtures.ts';

const log = logger('capture');

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURES = join(ROOT, 'fixtures');
/**
 * Captures land here first and replace `fixtures/` only once the run completes.
 *
 * The rule is that a fixture set is exactly one run — clearing up front would
 * satisfy that too, but it also means a capture that dies halfway leaves you
 * with no corpus at all, at the exact moment you need one to debug with.
 */
const STAGING = join(ROOT, 'fixtures.partial');

/** A video that is safe to resolve: long, public, not age-restricted. */
const PLAYER_VIDEO = process.env.YT_VIDEO_STANDARD ?? 'aqz-KE-bpKQ';
const SEARCH_QUERY = process.env.YT_SEARCH_QUERY ?? 'lofi hip hop';
/**
 * A separate, purpose-built search query for Task 21 §3's artist panel
 * (`officialCardViewModel`) — kept independent of `SEARCH_QUERY` because the
 * mix/playlist chaining below depends on that query's own result shape, and
 * an artist-name query is a worse source for either.
 */
const ARTIST_SEARCH_QUERY = process.env.YT_ARTIST_QUERY ?? 'Ado';

interface ManifestEntry {
  file: string;
  endpoint: string;
  params: Record<string, unknown>;
  client: string;
  bytes: number;
  capturedAt: string;
  /** Present only when the capture failed; the file is then absent. */
  error?: string;
}

const manifest: ManifestEntry[] = [];

/** Every entry of a directory, or `[]` when it does not exist. */
async function listDir(path: string): Promise<string[]> {
  try {
    return await readdir(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw error;
  }
}

async function capture(
  name: string,
  endpoint: string,
  params: Record<string, unknown>,
  run: () => Promise<unknown>,
  client = 'WEB',
): Promise<unknown> {
  // Outside the try on purpose: an undeclared stage is a programming error, not
  // a failed endpoint, and recording it as one would hide it. Without this the
  // mistake surfaces a whole run later, as the *next* run refusing to promote
  // over the file this one left behind.
  if (!CAPTURE_FILES.some((file) => file.name === `${name}.json`)) {
    throw new Error(`capture('${name}') is not declared in src/fixtures.ts — add it there first`);
  }
  const capturedAt = new Date().toISOString();
  try {
    const raw = await run();
    const json = JSON.stringify(raw, null, 2);
    await writeFile(join(STAGING, `${name}.json`), json, 'utf8');
    manifest.push({
      file: `${name}.json`,
      endpoint,
      params,
      client,
      bytes: json.length,
      capturedAt,
    });
    log.info(`${name.padEnd(20)} ${(json.length / 1024).toFixed(0).padStart(6)} KB  ${endpoint}`);
    return raw;
  } catch (error) {
    const message = (error as Error).message;
    manifest.push({
      file: `${name}.json`,
      endpoint,
      params,
      client,
      bytes: 0,
      capturedAt,
      error: message,
    });
    log.error(`${name.padEnd(20)} FAILED  ${endpoint}: ${message}`);
    return null;
  }
}

/**
 * Fresh staging directory. Never mix runs. Answers `false` when it refused,
 * having said why — the caller exits.
 *
 * The one thing it will not delete is a carried entry. `promoteStaging` copies
 * those in before the swap, so a run that dies in that window leaves the only
 * copy here — and clearing staging on the next run would finish the job. That
 * is the failure this guard exists for; it cannot be reached by a run that
 * completed.
 */
export async function prepareStaging(staging = STAGING): Promise<boolean> {
  const stranded = (await listDir(staging)).filter((entry) => CARRIED.includes(entry));
  if (stranded.length > 0) {
    log.error(`fixtures.partial/ holds carried fixtures: ${stranded.join(', ')}`);
    log.error('A previous run died mid-promote and this may be the only copy.');
    log.error('Move them back into fixtures/ yourself, then re-run. Nothing was deleted.');
    return false;
  }
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  return true;
}

/**
 * Replace `fixtures/` with this run, wholesale. A stale file left behind from an
 * earlier run once produced a completely wrong reading of the live feed, so the
 * old directory goes in its entirety — no merging, ever.
 *
 * "Wholesale" is bounded by `fixtures.ts`: this refuses to delete anything it
 * cannot account for, and anything required that it failed to replace. Carried
 * entries are **copied** rather than moved, so until the swap the originals are
 * still where they were.
 *
 * Answers `false` when it refused, having said why, and having changed nothing.
 * Returning rather than exiting is what makes the destructive path testable
 * against real directories instead of reasoned about.
 */
export async function promoteStaging(fixtures = FIXTURES, staging = STAGING): Promise<boolean> {
  const live = await listDir(fixtures);

  const unowned = unownedEntries(live);
  if (unowned.length > 0) {
    log.error(
      `refusing to replace fixtures/: ${unowned.length} entr${unowned.length === 1 ? 'y' : 'ies'} owned by nothing`,
    );
    for (const entry of unowned) log.error(`  ${entry}`);
    log.error('This run is intact in fixtures.partial/ and fixtures/ is untouched.');
    log.error('Declare each one in src/fixtures.ts — as a capture stage or as carried —');
    log.error("or delete it deliberately and re-run. Deleting is not this script's to do.");
    return false;
  }

  const lost = lostFixtures(live, await listDir(staging));
  if (lost.length > 0) {
    log.error(`refusing to replace fixtures/: this run did not produce ${lost.join(', ')}`);
    log.error('Promoting would delete a good copy and put nothing in its place.');
    log.error('The manifest above says why each failed. Re-run, or delete the stale file');
    log.error('deliberately if the stage is genuinely gone.');
    return false;
  }

  for (const entry of CARRIED) {
    if (!live.includes(entry)) continue;
    await cp(join(fixtures, entry), join(staging, entry), { recursive: true });
    log.info(`carried ${entry} across`);
  }

  await rm(fixtures, { recursive: true, force: true });
  await rename(staging, fixtures);
  log.info('fixtures/ replaced with this run');
  return true;
}

/** First id of a given kind in a parsed feed, so captures chain off real data. */
function firstId(raw: unknown, kind: 'video' | 'mix' | 'playlist'): string | null {
  if (!raw) return null;
  const { items } = parseFeed(raw, 'capture');
  return items.find((item) => item.kind === kind)?.id ?? null;
}

async function main(): Promise<void> {
  const cookie = process.env.YT_COOKIE;
  if (!cookie) {
    log.error('YT_COOKIE is not set.');
    log.error('Export cookies from an incognito window parked on youtube.com/robots.txt:');
    log.error('  YT_COOKIE="SID=…; HSID=…; SSID=…; APISID=…; SAPISID=…; __Secure-1PSID=…"');
    process.exit(1);
  }

  const session: Session = await createSession({ cookie, clientType: 'WEB' });

  // Fail loudly before writing anything. Fixtures captured from a degraded
  // session look plausible and are entirely empty.
  const auth = await verifyAuth(session);
  if (auth.state !== 'authenticated') {
    log.error(`refusing to capture: auth state is '${auth.state}' (${auth.tileCount} tiles).`);
    log.error('Re-export cookies and try again. Keep main-profile YouTube tabs closed.');
    process.exit(1);
  }

  if (!(await prepareStaging())) process.exit(1);

  // --- Feeds ---------------------------------------------------------------
  const home = await capture('home', '/browse', { browseId: 'FEwhat_to_watch' }, () =>
    session.execute('/browse', { browseId: 'FEwhat_to_watch' }),
  );

  if (!home) {
    log.error('the home feed capture failed — aborting without touching fixtures/');
    process.exit(1);
  }

  const homeContinuation = home ? parseFeed(home, 'capture').continuation : null;
  if (homeContinuation) {
    await capture('home-continuation', '/browse', { continuation: '<token>' }, () =>
      session.execute('/browse', { continuation: homeContinuation }),
    );
  } else {
    log.warn('no continuation token in the home feed — skipping home-continuation');
  }

  await capture('subscriptions', '/browse', { browseId: 'FEsubscriptions' }, () =>
    session.execute('/browse', { browseId: 'FEsubscriptions' }),
  );

  // Task 21 §4 — the channel list, a different browse endpoint from the video
  // feed above. Confirmed live: its own `GetChannels_rid` tracking param, page
  // title "All subscriptions".
  await capture('channels', '/browse', { browseId: 'FEchannels' }, () =>
    session.execute('/browse', { browseId: 'FEchannels' }),
  );

  await capture('history', '/browse', { browseId: 'FEhistory' }, () =>
    session.execute('/browse', { browseId: 'FEhistory' }),
  );

  await capture('watch-later', '/browse', { browseId: 'VLWL' }, () =>
    session.execute('/browse', { browseId: 'VLWL' }),
  );

  // --- Search --------------------------------------------------------------
  const search = await capture('search', '/search', { query: SEARCH_QUERY }, () =>
    session.execute('/search', { query: SEARCH_QUERY }),
  );

  // Task 21 §3 — a search for an artist's name, to capture the
  // officialCardViewModel panel. Live-confirmed absent for a topic query
  // (SEARCH_QUERY above) and for an ordinary creator's name.
  await capture('search-artist', '/search', { query: ARTIST_SEARCH_QUERY }, () =>
    session.execute('/search', { query: ARTIST_SEARCH_QUERY }),
  );

  // --- Playlist and Mix ----------------------------------------------------
  // Chain off whatever the live feeds actually contained rather than hardcoding
  // ids that rot. A Mix is a radio playlist; it only exists in a watch context,
  // so it comes from /next.
  let playlistId = firstId(search, 'playlist') ?? firstId(home, 'playlist');

  if (!playlistId) {
    // A general search returns mostly videos. `EgIQAw%3D%3D` is the stable
    // search filter for type=playlist — cheaper and far less brittle than
    // hardcoding a playlist id that will eventually be deleted.
    log.info('no playlist in home or search — running a playlist-filtered search');
    const playlistSearch = await capture(
      'search-playlists',
      '/search',
      { query: SEARCH_QUERY, params: 'EgIQAw%3D%3D' },
      () => session.execute('/search', { query: SEARCH_QUERY, params: 'EgIQAw%3D%3D' }),
    );
    playlistId = firstId(playlistSearch, 'playlist');
  }

  if (playlistId) {
    await capture('playlist', '/browse', { browseId: `VL${playlistId}` }, () =>
      session.execute('/browse', { browseId: `VL${playlistId}` }),
    );
  } else {
    log.warn('no playlist found anywhere — skipping playlist fixture');
  }

  const mixId = firstId(home, 'mix');
  const mixSeed = mixId ? mixId.replace(/^RD/, '') : firstId(home, 'video');
  if (mixSeed) {
    await capture(
      'mix',
      '/next',
      { videoId: mixSeed, playlistId: mixId ?? `RD${mixSeed}` },
      () =>
        session.execute('/next', {
          videoId: mixSeed,
          playlistId: mixId ?? `RD${mixSeed}`,
        }),
    );
  } else {
    log.warn('no video to seed a Mix from — skipping mix fixture');
  }

  // --- Watch page ----------------------------------------------------------
  await capture('watch', '/next', { videoId: PLAYER_VIDEO }, () =>
    session.execute('/next', { videoId: PLAYER_VIDEO }),
  );

  // --- Comments ------------------------------------------------------------
  // Both were captured ad hoc and lived here owned by nothing until `todo.md`
  // 41. Chained off live data like the playlist and mix stages above, for the
  // same reason: a hardcoded comment id rots.
  //
  // **Anonymous on purpose, and it is not an oversight.** `comments.json` is the
  // negative control for the viewer's like state — an anonymous page reads
  // `INDIFFERENT` on every comment (F33), which is what makes a liked one
  // anywhere else evidence of something. The signed-in counterpart is
  // `comments-viewer-state.json`, which this run carries across rather than
  // writes; `src/fixtures.ts` says why it cannot write it.
  const anonymousWeb = await createSession({ clientType: 'WEB' });
  const anonymousWatch = await anonymousWeb.execute('/next', { videoId: PLAYER_VIDEO });
  const commentsToken = parseVideoDetail(anonymousWatch, 'capture').commentsContinuation;

  let commentsRaw: unknown = null;
  if (commentsToken) {
    commentsRaw = await capture(
      'comments',
      '/next',
      { videoId: PLAYER_VIDEO, continuation: '<comments token>' },
      () => anonymousWeb.execute('/next', { continuation: commentsToken }),
    );
  } else {
    log.error(`no comments continuation on ${PLAYER_VIDEO} — comments fixtures will be missing`);
  }

  // A thread with replies. `repliesContinuation` is the load-more token, which
  // is button-shaped on a reply and endpoint-shaped on a thread (F30) —
  // `parseComments` reads both, so this does not care which it got.
  const repliesToken = commentsRaw
    ? (parseComments(commentsRaw, 'capture').items.find((item) => item.repliesContinuation)
        ?.repliesContinuation ?? null)
    : null;
  if (repliesToken) {
    await capture(
      'comments-replies',
      '/next',
      { videoId: PLAYER_VIDEO, continuation: '<replies token>' },
      () => anonymousWeb.execute('/next', { continuation: repliesToken }),
    );
  } else if (commentsRaw) {
    log.error('no thread on the first comments page has replies — comments-replies will be missing');
  }

  // --- Player responses ----------------------------------------------------
  // Two clients, two independent calls (§2.3). WEB is expected to come back
  // SABR-only (F3) — capturing it anyway is the point: it is the fixture that
  // proves the resolution ladder has something to fall through from.
  await capture(
    'player-web',
    '/player',
    { videoId: PLAYER_VIDEO, client: 'WEB' },
    () => session.execute('/player', playerPayload(session, PLAYER_VIDEO, 'WEB')),
    'WEB',
  );

  const anonymous = await createSession({ clientType: 'MWEB' });
  await capture(
    'player-mweb',
    '/player',
    { videoId: PLAYER_VIDEO, client: 'MWEB' },
    () => anonymous.execute('/player', playerPayload(anonymous, PLAYER_VIDEO, 'MWEB')),
    'MWEB',
  );

  // Ladder tier 1. Same anonymous session, different client on the call — what
  // makes this one work is the server-issued visitor id `createSession` fetches
  // by default (F5), so a capture run that produces an empty `player-vr` is
  // saying something about the visitor id and not about the video.
  await capture(
    'player-vr',
    '/player',
    { videoId: PLAYER_VIDEO, client: 'VISIONOS' },
    () => anonymous.execute('/player', playerPayload(anonymous, PLAYER_VIDEO, 'VISIONOS')),
    'VISIONOS',
  );

  // --- Manifest ------------------------------------------------------------
  const summary = {
    capturedAt: new Date().toISOString(),
    auth: { state: auth.state, tileCount: auth.tileCount },
    note: 'Raw parse:false responses. Do not mix with any other capture run.',
    entries: manifest,
  };
  await writeFile(join(STAGING, 'manifest.json'), JSON.stringify(summary, null, 2), 'utf8');

  const failed = manifest.filter((entry) => entry.error);
  log.info(`captured ${manifest.length - failed.length}/${manifest.length} fixtures`);
  if (failed.length > 0) {
    log.warn(`failed: ${failed.map((entry) => entry.file).join(', ')}`);
  }

  // Parse everything we just captured so a vocabulary gap shows up now, on real
  // data, rather than as missing tiles in the UI weeks later. This is the log
  // that tells us YouTube changed something.
  for (const entry of manifest) {
    if (entry.error || entry.file.startsWith('player-')) continue;
    const name = entry.file.replace(/\.json$/, '');
    try {
      const raw = JSON.parse(await readFile(join(STAGING, entry.file), 'utf8'));
      // A comments page is not a feed. Running `parseFeed` over one reports zero
      // items and fills the unknown-renderer summary with comment renderers,
      // which reads as a vocabulary gap and is not one.
      if (name.startsWith('comments')) {
        const { items, continuation } = parseComments(raw, name);
        log.info(
          `${name.padEnd(20)} ${String(items.length).padStart(4)} comments  ` +
            `continuation=${continuation ? 'yes' : 'no'}`,
        );
        continue;
      }
      const { items, chips, continuation } = parseFeed(raw, name);
      log.info(
        `${name.padEnd(20)} ${String(items.length).padStart(4)} items  ` +
          `${String(chips.length).padStart(3)} chips  ` +
          `continuation=${continuation ? 'yes' : 'no'}`,
      );
    } catch (error) {
      log.error(`${name}: re-parse failed: ${(error as Error).message}`);
    }
  }

  logUnknownRendererSummary();

  if (!(await promoteStaging())) process.exit(1);
}

// Guarded so the test can import `prepareStaging` / `promoteStaging` and drive
// them against temporary directories. Without it, importing this module runs a
// live capture — which is the very thing under test.
if (import.meta.main) await main();
