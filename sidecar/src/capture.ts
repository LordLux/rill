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
 */

import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { logger, logUnknownRendererSummary } from './log.ts';
import { createSession, playerPayload, verifyAuth, type Session } from './innertube/session.ts';
import { parseFeed } from './parser/index.ts';

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

async function capture(
  name: string,
  endpoint: string,
  params: Record<string, unknown>,
  run: () => Promise<unknown>,
  client = 'WEB',
): Promise<unknown> {
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

/** Fresh staging directory. Never mix runs. */
async function prepareStaging(): Promise<void> {
  await rm(STAGING, { recursive: true, force: true });
  await mkdir(STAGING, { recursive: true });
}

/**
 * Replace `fixtures/` with this run, wholesale. A stale file left behind from an
 * earlier run once produced a completely wrong reading of the live feed, so the
 * old directory goes in its entirety — no merging, ever.
 */
async function promoteStaging(): Promise<void> {
  await rm(FIXTURES, { recursive: true, force: true });
  await rename(STAGING, FIXTURES);
  log.info('fixtures/ replaced with this run');
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

  await prepareStaging();

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
    { videoId: PLAYER_VIDEO, client: 'ANDROID_VR' },
    () => anonymous.execute('/player', playerPayload(anonymous, PLAYER_VIDEO, 'ANDROID_VR')),
    'ANDROID_VR',
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

  await promoteStaging();
}

await main();
