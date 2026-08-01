#!/usr/bin/env node
/**
 * Feasibility spike for a native Windows YouTube client.
 *
 * Answers four architecture-blocking questions. Nothing here is production code —
 * it exists to turn guesses into facts before any real code gets written.
 *
 *   Q1  WEB + cookies  -> real homepage with filter chips (incl. Mixes)?
 *   Q2  non-WEB player -> 1080p+ adaptive URLs, deciphered, at full throughput?
 *   Q3  cross-client   -> does watch history actually land on the WEB account?
 *   Q4  movingThumbnail hover previews with no playback session?
 *
 * Every test is independent and self-contained: one failing does not block the rest.
 * Raw API responses are dumped to ./fixtures/ — those become the offline test corpus
 * for the tolerant renderer parser later, so don't delete them.
 *
 * Usage:
 *   1. npm install
 *   2. Export cookies from a logged-in youtube.com session (see README)
 *   3. YT_COOKIE="..." node spike.mjs
 */

import { Innertube, Platform, UniversalCache } from 'youtubei.js';
import { writeFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import vm from 'node:vm';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const COOKIE = process.env.YT_COOKIE;

// Pick videos you have NOT watched recently — Q3 depends on detecting a new
// history entry, so a video already in your history gives a false positive.
const VIDEO_STANDARD = process.env.YT_VIDEO_STANDARD || 'aqz-KE-bpKQ'; // Big Buck Bunny 4K
const VIDEO_MUSIC    = process.env.YT_VIDEO_MUSIC    || 'jNQXAC9IVRw'; // short, safe fallback

// Player clients to race for plain (non-SABR) URLs, in preference order.
// MWEB first: returned 41 adaptive formats on every run so far. ANDROID_VR is
// flaky (0 formats one run, 28 the next) — YouTube is actively blocking it.
// TVHTML5 is not a valid client constant in youtubei.js; the constant is 'TV'.
const PLAYER_CLIENTS = (process.env.YT_PLAYER_CLIENTS || 'MWEB,ANDROID_VR,TV,WEB').split(',');

// Clients whose URLs legitimately carry no `n` parameter. ANDROID_VR/TV hand out
// unthrottled URLs with no cipher challenge, so "n absent" there is expected,
// not a decipher failure.
const CLIENTS_WITH_N_PARAM = new Set(['MWEB', 'WEB']);

// Throughput classification. YouTube's n-param throttle lands around ~50 KB/s.
const THROUGHPUT_SAMPLE_BYTES = 12 * 1024 * 1024; // 12 MB is enough to see the throttle
const THROUGHPUT_THROTTLED    = 0.25;             // MB/s — below this is definitely throttled
const THROUGHPUT_HEALTHY      = 1.5;              // MB/s — above this is definitely fine

const FIXTURES = new URL('./fixtures/', import.meta.url);

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

const results = [];
const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };

function record(id, question, status, detail, impact) {
  results.push({ id, question, status, detail, impact });
  const tone = status === 'PASS' ? C.g : status === 'FAIL' ? C.r : C.y;
  console.log(`\n${tone}[${status}]${C.x} ${C.b}${id}${C.x} ${question}`);
  for (const line of String(detail).split('\n')) console.log(`       ${line}`);
}

function note(msg) { console.log(`${C.d}       · ${msg}${C.x}`); }

async function dump(name, data) {
  try {
    await mkdir(FIXTURES, { recursive: true });
    const path = new URL(`${name}.json`, FIXTURES);
    await writeFile(path, JSON.stringify(data, null, 2));
    note(`fixture -> fixtures/${name}.json`);
  } catch (e) {
    note(`fixture dump failed (${e.message})`);
  }
}

/** Walk any object tree looking for the first value matching a predicate. */
function deepFind(node, predicate, depth = 0, seen = new Set()) {
  if (!node || typeof node !== 'object' || depth > 14 || seen.has(node)) return undefined;
  seen.add(node);
  if (predicate(node)) return node;
  for (const value of Array.isArray(node) ? node : Object.values(node)) {
    const hit = deepFind(value, predicate, depth + 1, seen);
    if (hit !== undefined) return hit;
  }
  return undefined;
}

/** Collect every value matching a predicate. */
function deepCollect(node, predicate, out = [], depth = 0, seen = new Set()) {
  if (!node || typeof node !== 'object' || depth > 14 || seen.has(node)) return out;
  seen.add(node);
  if (predicate(node)) out.push(node);
  for (const value of Array.isArray(node) ? node : Object.values(node)) {
    deepCollect(value, predicate, out, depth + 1, seen);
  }
  return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- View-based layout helpers ---------------------------------------------
// YouTube now serves LockupView tiles instead of videoRenderer/Video. None of
// youtubei.js's typed accessors map these, so everything below works on shape.

/** Video/playlist tiles in the current layout. */
function collectTiles(root) {
  return deepCollect(root, (n) => typeof n?.type === 'string' && /^LockupView$/.test(n.type));
}
function countTiles(root) {
  return collectTiles(root).length;
}

/** Video ID off a tile, whatever the field is called this week. */
function tileId(node) {
  return node?.content_id ?? node?.video_id ?? node?.videoId ?? null;
}

/** Any human-readable label on a node. */
function labelOf(node) {
  const candidates = [
    node?.text?.text, node?.text, node?.label,
    node?.title?.text, node?.title, node?.content, node?.simpleText,
  ];
  for (const c of candidates) if (typeof c === 'string' && c.trim()) return c.trim();
  return null;
}

/** Raw continuation token — the typed getContinuation() misses View layouts. */
function findContinuationToken(root) {
  const node = deepFind(root, (n) =>
    typeof n?.token === 'string' && n.token.length > 20
  );
  if (node?.token) return node.token;
  const cmd = deepFind(root, (n) =>
    typeof n?.type === 'string' && /ContinuationCommand|ContinuationItem/.test(n.type)
  );
  return cmd?.token ?? cmd?.endpoint?.payload?.token ?? null;
}

// ---------------------------------------------------------------------------
// JS interpreter shim
//
// YouTube.js does not ship an interpreter for YouTube's obfuscated player code.
// Without this, signature + `n` deciphering silently fails and Q2 reports a
// throttle that is entirely our own fault. Set it up before anything else.
// ---------------------------------------------------------------------------

function installInterpreter() {
  try {
    Platform.shim.eval = (code) => {
      const text = typeof code === 'string' ? code : code.output;
      return vm.runInNewContext(`(function() { ${text} })()`, {});
    };
    return true;
  } catch (e) {
    console.error(`${C.r}Could not install JS interpreter shim: ${e.message}${C.x}`);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Q1 — WEB + cookies -> homepage with chips including Mixes
// ---------------------------------------------------------------------------

async function q1_homeFeedChips(yt) {
  const Q = 'WEB+cookies returns the real homepage with filter chips (incl. Mixes)';
  try {
    const home = await yt.getHomeFeed();
    await dump('q1-home-feed', home?.page ?? home);

    // YouTube serves this account the View-based layout. The typed accessors
    // (.videos, .getContinuation) do not map LockupView, so count by shape.
    const tilesPage1 = countTiles(home?.page ?? home);

    // Chips: ChipView inside ChipsShelfView. Widened from the old /^Chip$/ probe.
    const chipNodes = deepCollect(
      home?.page ?? home,
      (n) => typeof n.type === 'string' && /^ChipView$/.test(n.type)
    );
    const uniqueChips = [...new Set(chipNodes.map(labelOf).filter(Boolean))];

    // Mixes are CollectionThumbnailView tiles carrying a "Mix" badge — a tile
    // type, not a filter chip. Detect both independently.
    const mixTiles = deepCollect(
      home?.page ?? home,
      (n) => typeof n.type === 'string' && /^CollectionThumbnailView$/.test(n.type)
    );
    const mixBadges = deepCollect(
      home?.page ?? home,
      (n) => typeof n?.text === 'string' && /^mix$/i.test(n.text)
    );
    const hasMixesChip = uniqueChips.some((t) => /^mix(es)?$/i.test(t));

    // Shorts: no ShortsLockupView observed so far. Sweep broadly.
    const shortsNodes = deepCollect(
      home?.page ?? home,
      (n) => typeof n.type === 'string' && /Reel|Shorts/i.test(n.type)
    );

    // Continuation: pull the raw token instead of the typed helper.
    let continuationOk = false;
    let tilesPage2 = 0;
    try {
      const token = findContinuationToken(home?.page ?? home);
      if (!token) throw new Error('no continuation token found in payload');
      const more = await yt.actions.execute('/browse', { continuation: token, parse: true });
      tilesPage2 = countTiles(more?.page ?? more);
      continuationOk = tilesPage2 > 0;
      await dump('q1-home-continuation', more?.page ?? more);
    } catch (e) {
      note(`continuation failed: ${e.message}`);
      // Fall back to the typed helper in case the layout reverts.
      try {
        const more = await home.getContinuation();
        tilesPage2 = countTiles(more?.page ?? more);
        continuationOk = tilesPage2 > 0;
        await dump('q1-home-continuation', more?.page ?? more);
      } catch { /* already reported */ }
    }

    const isLoggedIn = yt.session.logged_in;
    const lines = [
      `logged_in:       ${isLoggedIn}`,
      `tiles (page 1):  ${tilesPage1}  (LockupView)`,
      `tiles (page 2):  ${tilesPage2}`,
      `ChipView labels: ${uniqueChips.length ? uniqueChips.join(' | ') : '(none)'}`,
      `Mix tiles:       ${mixTiles.length} CollectionThumbnailView / ${mixBadges.length} "Mix" badges`,
      `Mixes as chip:   ${hasMixesChip ? 'YES' : 'NO (only as tiles)'}`,
      `shorts nodes:    ${shortsNodes.length} (need to be filterable)`,
    ].join('\n');

    const hasMixes = hasMixesChip || mixTiles.length > 0;

    if (!isLoggedIn) {
      return record('Q1', Q, 'FAIL', lines + '\nSession is anonymous — cookie was rejected or incomplete.',
        'Cookie auth is the primary plan. If this fails, fall back to device-code OAuth and accept TV-layout renderers.');
    }
    if (uniqueChips.length && hasMixes && continuationOk) {
      return record('Q1', Q, 'PASS', lines,
        'Primary auth plan confirmed: WEB + cookies for all browse calls.');
    }
    return record('Q1', Q, 'PARTIAL', lines,
      'Inspect fixtures/q1-home-feed.json — chips may exist under a renderer name this probe missed.');
  } catch (e) {
    return record('Q1', Q, 'FAIL', `${e.name}: ${e.message}`,
      'Blocks everything. Nothing else matters if the authenticated homepage will not load.');
  }
}

// ---------------------------------------------------------------------------
// Q2 — non-WEB player client -> 1080p+ adaptive, deciphered, full speed
// ---------------------------------------------------------------------------

function summariseFormats(info) {
  const adaptive = info?.streaming_data?.adaptive_formats ?? [];
  const video = adaptive.filter((f) => f.has_video && !f.has_audio);
  const audio = adaptive.filter((f) => f.has_audio && !f.has_video);
  const maxHeight = video.reduce((m, f) => Math.max(m, f.height ?? 0), 0);
  const sabrOnly = adaptive.length > 0 && adaptive.every((f) => !f.url && !f.signature_cipher);
  return {
    adaptiveCount: adaptive.length,
    videoCount: video.length,
    audioCount: audio.length,
    maxHeight,
    sabrOnly,
    hasServerAbrUrl: Boolean(info?.streaming_data?.server_abr_streaming_url),
    hasDashManifest: Boolean(info?.streaming_data?.dash_manifest_url),
    hasHlsManifest: Boolean(info?.streaming_data?.hls_manifest_url),
    bestVideo: video.sort((a, b) => (b.height ?? 0) - (a.height ?? 0))[0],
    bestAudio: audio.sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0))[0],
  };
}

async function measureThroughput(url) {
  const started = Date.now();
  let received = 0;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 45_000);
  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: { range: `bytes=0-${THROUGHPUT_SAMPLE_BYTES - 1}` },
    });
    if (!res.ok && res.status !== 206) {
      return { ok: false, error: `HTTP ${res.status}` };
    }
    for await (const chunk of res.body) {
      received += chunk.length;
      if (received >= THROUGHPUT_SAMPLE_BYTES) break;
    }
    const seconds = (Date.now() - started) / 1000;
    return { ok: true, mbps: received / 1024 / 1024 / seconds, received, seconds };
  } catch (e) {
    return { ok: false, error: e.message };
  } finally {
    clearTimeout(timeout);
  }
}

async function q2_playerClients(yt) {
  const Q = 'A non-WEB player client yields 1080p+ plain URLs at full throughput';
  const report = [];
  let winner = null;

  // Anonymous instance for player requests
  const ytPlayer = await Innertube.create({ generate_session_locally: true });

  for (const client of PLAYER_CLIENTS) {
    try {
      const info = await ytPlayer.getInfo(VIDEO_STANDARD, { client });
      const s = summariseFormats(info);
      await dump(`q2-streaming-data-${client}`, info?.streaming_data);

      let flags = [];
      if (s.sabrOnly) flags.push('SABR-ONLY');
      if (s.hasServerAbrUrl) flags.push('has-abr-url');
      if (s.hasDashManifest) flags.push('has-dash-mpd');
      if (s.hasHlsManifest) flags.push('has-hls');

      report.push(
        `${client.padEnd(10)} adaptive=${String(s.adaptiveCount).padStart(3)} ` +
        `max=${String(s.maxHeight).padStart(4)}p ${flags.join(',') || 'plain-urls'}`
      );

      // Prefer the client offering the most formats rather than the first that
      // works — ANDROID_VR intermittently returns 0 and would otherwise "win"
      // on one run and vanish on the next.
      const viable = !s.sabrOnly && s.maxHeight >= 1080 && s.bestVideo;
      if (viable && (!winner || s.adaptiveCount > winner.adaptiveCount)) {
        winner = { client, info, ...s };
      }
    } catch (e) {
      report.push(`${client.padEnd(10)} ERROR: ${e.message}`);
    }
  }

  if (!winner) {
    return record('Q2', Q, 'FAIL', report.join('\n'),
      'Phase 1 does not exist. SABR -> local DASH bridge becomes mandatory before any playback works.');
  }

  // Decipher, then measure. An undeciphered URL is the classic silent throttle.
  let videoUrl;
  try {
    videoUrl = await winner.bestVideo.decipher(ytPlayer.session.player);
  } catch (e) {
    return record('Q2', Q, 'FAIL', report.join('\n') + `\ndecipher failed: ${e.message}`,
      'Interpreter shim or player retrieval is broken — fix before trusting any throughput number.');
  }

  const hasN = /[?&]n=/.test(videoUrl);
  const expectsN = CLIENTS_WITH_N_PARAM.has(winner.client);
  const nStatus = hasN
    ? 'present (deciphered)'
    : expectsN
      ? 'ABSENT — decipher likely incomplete'
      : `absent (expected for ${winner.client} — no cipher challenge)`;
  const t = await measureThroughput(videoUrl);

  const lines = [
    ...report,
    '',
    `winner:        ${winner.client} @ ${winner.maxHeight}p`,
    `video itag:    ${winner.bestVideo.itag} (${winner.bestVideo.mime_type})`,
    `audio itag:    ${winner.bestAudio?.itag} (${winner.bestAudio?.mime_type})`,
    `n param:       ${nStatus}`,
    t.ok
      ? `throughput:    ${t.mbps.toFixed(2)} MB/s (${(t.received / 1024 / 1024).toFixed(1)} MB in ${t.seconds.toFixed(1)}s)`
      : `throughput:    FAILED (${t.error})`,
  ].join('\n');

  if (!t.ok) {
    return record('Q2', Q, 'FAIL', lines, 'URL resolved but would not stream.');
  }
  if (t.mbps < THROUGHPUT_THROTTLED) {
    return record('Q2', Q, 'FAIL', lines,
      'Throttled. The n-param decipher is not landing — mpv would buffer forever. Do not proceed to Phase 1.');
  }
  if (t.mbps < THROUGHPUT_HEALTHY) {
    record('Q2', Q, 'PARTIAL', lines,
      'Ambiguous speed. Re-run on a wired connection before drawing conclusions.');
    return winner.client;
  }
  record('Q2', Q, 'PASS', lines,
    `Phase 1 is viable: browse as WEB, resolve streams as ${winner.client}, hand two signed URLs to mpv.`);
  return winner.client;
}

// ---------------------------------------------------------------------------
// Q3 — cross-client CPN: does watch history land on the WEB account?
//
// This is the silent one. Everything appears to work whether or not it passes;
// the only symptom of failure is recommendations drifting over weeks.
//
// We deliberately use YouTube.js's own reporting path rather than hand-rolling
// the /api/stats/watchtime payload. The library tracks the parameter set YouTube
// currently expects; a hand-built ping that is subtly wrong produces a false
// negative that looks exactly like a cross-client block.
// ---------------------------------------------------------------------------

async function fetchHistoryIds(yt, label = 'history') {
  try {
    const history = await yt.getHistory();
    const root = history?.page ?? history;
    await dump(`q3-${label}-raw`, root);

    // The old probe looked for `video_id` and found nothing, because the View
    // layout puts the id on LockupView.content_id. Sweep both, plus any
    // watch endpoint, so a layout change cannot silently blank this again.
    const ids = new Set();
    for (const tile of collectTiles(root)) {
      const id = tileId(tile);
      if (id) ids.add(id);
    }
    deepCollect(root, (n) => typeof n?.video_id === 'string')
      .forEach((n) => ids.add(n.video_id));
    deepCollect(root, (n) => typeof n?.videoId === 'string')
      .forEach((n) => ids.add(n.videoId));

    return [...ids];
  } catch (e) {
    note(`history fetch failed: ${e.message}`);
    return null;
  }
}

async function q3_watchHistory(yt, winningClient) {
  const Q = 'Playback reported via a cross-client CPN lands on the real WEB history';
  try {
    const before = await fetchHistoryIds(yt, 'before');
    if (before === null) {
      return record('Q3', Q, 'SKIP', 'Could not read watch history — is history paused on this account?',
        'Cannot verify. Re-run with history enabled; this question is worth answering properly.');
    }
    if (before.length === 0) {
      return record('Q3', Q, 'SKIP',
        'History returned 0 entries. Either history is paused on this account, or the probe\n' +
        'still cannot read this layout — check fixtures/q3-before-raw.json before going further.\n' +
        'A before/after diff against an unreadable list proves nothing either way.',
        'Fix the reader first. Meanwhile settle this manually: youtube.com -> History.');
    }
    if (before.includes(VIDEO_STANDARD)) {
      return record('Q3', Q, 'SKIP',
        `${VIDEO_STANDARD} is already in history — result would be a false positive.\n` +
        `Set YT_VIDEO_STANDARD to something you have never watched and re-run.`,
        'Inconclusive by construction.');
    }

    note(`history before: ${before.length} entries`);

    // Create an anonymous instance for the player
    const ytPlayer = await Innertube.create({ generate_session_locally: true });

    // Resolve with the client Q2 actually proved works — not PLAYER_CLIENTS[0],
    // which was ANDROID_VR returning zero formats on the first run.
    const playerClient = winningClient || 'MWEB';
    const info = await ytPlayer.getInfo(VIDEO_STANDARD, { client: playerClient });

    const cpn = info?.cpn ?? yt.session?.context?.client?.visitorData?.slice(0, 16);
    note(`player client:  ${playerClient}`);
    note(`cpn:            ${cpn ?? '(library-managed)'}`);

    // Library-managed reporting. Probe for the method rather than assuming a name.
    const reporter =
      typeof info?.addToWatchHistory === 'function' ? info.addToWatchHistory.bind(info) : null;

    if (!reporter) {
      return record('Q3', Q, 'SKIP',
        'No addToWatchHistory() on VideoInfo in this version.\n' +
        'Check the API docs for the current reporting method before hand-rolling a ping.',
        'Do not hand-roll this blind — a malformed payload is indistinguishable from a cross-client block.');
    }

    await reporter();
    note('watch event reported; waiting 20s for propagation');
    await sleep(20_000);

    const after = await fetchHistoryIds(yt, 'after');
    const landed = after?.includes(VIDEO_STANDARD);

    const lines = [
      `browse client:  WEB (cookies)`,
      `player client:  ${playerClient}`,
      `history before: ${before.length} entries`,
      `history after:  ${after?.length ?? '?'} entries`,
      `target video:   ${VIDEO_STANDARD}`,
      `landed:         ${landed ? 'YES' : 'NO'}`,
    ].join('\n');

    if (landed) {
      return record('Q3', Q, 'PASS', lines,
        'Client decoupling is safe. Recommendations will keep training normally.');
    }
    return record('Q3', Q, 'PARTIAL', lines,
      'Not proven. Before concluding it is blocked: open youtube.com in a browser and check manually — ' +
      'the history API can lag the UI. If genuinely dropped, the player client must also be WEB, ' +
      'which makes the SABR bridge mandatory rather than deferrable.');
  } catch (e) {
    return record('Q3', Q, 'FAIL', `${e.name}: ${e.message}`,
      'Unresolved. This is the question most likely to be wrong silently — do not skip it.');
  }
}

// ---------------------------------------------------------------------------
// Q4 — movingThumbnail hover previews, no playback session
// ---------------------------------------------------------------------------

async function q4_hoverPreviews(yt, winningClient) {
  const Q = 'Hover previews + tile action buttons are available without a session';
  try {
    const home = await yt.getHomeFeed();
    const root = home?.page ?? home;

    // The View layout ships dedicated hover nodes. Capture them — the toggle
    // actions one is where Watch Later / Add to queue live.
    const hoverOverlays = deepCollect(root, (n) =>
      typeof n?.type === 'string' && /^ThumbnailHoverOverlayView$/.test(n.type));
    const hoverActions = deepCollect(root, (n) =>
      typeof n?.type === 'string' && /^ThumbnailHoverOverlayToggleActionsView$/.test(n.type));
    const playlistCmds = deepCollect(root, (n) =>
      typeof n?.type === 'string' && /AddToPlaylistCommand|PlaylistEditEndpoint/.test(n.type));

    await dump('q4-hover-overlay', hoverOverlays.slice(0, 3));
    await dump('q4-hover-actions', hoverActions.slice(0, 3));

    const moving = deepCollect(root, (n) =>
      typeof n?.type === 'string' && /MovingThumbnail/i.test(n.type));

    const urls = deepCollect(root, (n) =>
      typeof n?.url === 'string' && /\.(mp4|webm)(\?|$)/i.test(n.url)
    ).map((n) => n.url);

    const unique = [...new Set(urls)];
    await dump('q4-moving-thumbnails', unique.slice(0, 20));

    const actionSummary = [
      `hover overlays:     ${hoverOverlays.length} ThumbnailHoverOverlayView`,
      `hover action nodes: ${hoverActions.length} ThumbnailHoverOverlayToggleActionsView`,
      `playlist commands:  ${playlistCmds.length} (Watch Later / queue endpoints)`,
      `moving thumbnails:  ${moving.length} typed / ${unique.length} media URLs`,
    ].join('\n');

    if (!unique.length) {
      // No inline preview media. Check whether storyboards can back hover
      // instead — sprite sheets from the player response, always present.
      let storyboardLine = 'storyboards:        not checked';
      try {
        const ytPlayer = await Innertube.create({ generate_session_locally: true });
        const info = await ytPlayer.getInfo(VIDEO_STANDARD, { client: winningClient || 'MWEB' });
        const boards = info?.storyboards;
        await dump('q4-storyboards', boards);
        const boardUrl = deepFind(boards, (n) => typeof n?.template_url === 'string')?.template_url
          ?? deepFind(boards, (n) => typeof n?.url === 'string')?.url;
        storyboardLine = boards
          ? `storyboards:        PRESENT${boardUrl ? ' (template url resolved)' : ''}`
          : 'storyboards:        absent';
      } catch (e) {
        storyboardLine = `storyboards:        check failed (${e.message})`;
      }

      const status = hoverActions.length ? 'PARTIAL' : 'FAIL';
      return record('Q4', Q, status,
        `${actionSummary}\n${storyboardLine}`,
        hoverActions.length
          ? 'Tile action buttons ARE served in the feed — that requirement is met. Only the video ' +
            'preview is missing; back it with storyboard sprites or a lazy per-hover fetch.'
          : 'Neither previews nor action nodes found. Revisit the tile design.');
    }

    const target = unique[0];
    const started = Date.now();
    const res = await fetch(target, { headers: { range: 'bytes=0-262143' } });
    const bytes = res.ok || res.status === 206 ? (await res.arrayBuffer()).byteLength : 0;
    const ms = Date.now() - started;

    const lines = [
      actionSummary,
      `sample status:      HTTP ${res.status}`,
      `content-type:       ${res.headers.get('content-type')}`,
      `first 256KB in:     ${ms}ms (${bytes} bytes)`,
      `signed (sqp/rs):    ${/[?&](sqp|rs)=/.test(target) ? 'yes — expires, needs feed TTL' : 'no'}`,
    ].join('\n');

    if (res.ok || res.status === 206) {
      return record('Q4', Q, 'PASS', lines,
        'Tile hover costs one cheap ranged GET. Keep the feed cache TTL under ~1h so URLs stay fresh.');
    }
    return record('Q4', Q, 'FAIL', lines, 'Preview URLs present but not fetchable.');
  } catch (e) {
    return record('Q4', Q, 'FAIL', `${e.name}: ${e.message}`, 'Tile hover design needs rethinking.');
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  console.log(`${C.b}YouTube desktop client — feasibility spike${C.x}`);
  console.log(`${C.d}${new Date().toISOString()}${C.x}\n`);

  if (!COOKIE) {
    console.error(`${C.r}YT_COOKIE is not set.${C.x}`);
    console.error('Export cookies from a logged-in youtube.com session and re-run:');
    console.error('  YT_COOKIE="SID=...; HSID=...; SSID=...; APISID=...; SAPISID=...; __Secure-1PSID=..." node spike.mjs');
    process.exit(1);
  }

  if (!installInterpreter()) process.exit(1);

  let yt;
  try {
    yt = await Innertube.create({
      cookie: COOKIE,
      client_type: 'WEB',
      device_category: 'DESKTOP',
      retrieve_player: true,       // required for decipher — do not disable
      enable_session_cache: true,
      cache: new UniversalCache(true, './.cache'),
      generate_session_locally: false,
    });
    console.log(`${C.g}session created${C.x}  logged_in=${yt.session.logged_in}  player=${yt.session.player?.sts ?? 'n/a'}`);
  } catch (e) {
    console.error(`${C.r}Session creation failed: ${e.message}${C.x}`);
    process.exit(1);
  }

  await q1_homeFeedChips(yt);
  const winningClient = await q2_playerClients(yt);
  await q3_watchHistory(yt, winningClient);
  await q4_hoverPreviews(yt, winningClient);

  // -------------------------------------------------------------------------
  console.log(`\n${C.b}${'='.repeat(72)}${C.x}`);
  console.log(`${C.b}SUMMARY${C.x}\n`);
  for (const r of results) {
    const tone = r.status === 'PASS' ? C.g : r.status === 'FAIL' ? C.r : C.y;
    console.log(`  ${tone}${r.status.padEnd(8)}${C.x} ${r.id}  ${r.question}`);
    console.log(`  ${C.d}         -> ${r.impact}${C.x}`);
  }

  const q1 = results.find((r) => r.id === 'Q1')?.status;
  const q2 = results.find((r) => r.id === 'Q2')?.status;
  const q3 = results.find((r) => r.id === 'Q3')?.status;

  console.log(`\n${C.b}VERDICT${C.x}\n`);
  if (q1 !== 'PASS') {
    console.log('  Auth is unresolved. Settle Q1 before designing anything else.');
  } else if (q2 === 'PASS' && q3 === 'PASS') {
    console.log('  Phase 1 confirmed. Browse as WEB, resolve streams via a non-WEB client,');
    console.log('  hand mpv two signed URLs. The SABR -> DASH bridge can wait.');
  } else if (q2 === 'PASS') {
    console.log('  Streams work but history reporting is unproven. Verify manually on youtube.com');
    console.log('  before committing — a silent failure here erodes the whole point of the app.');
  } else {
    console.log('  No plain-URL path. The SABR -> local DASH bridge is mandatory, not deferrable.');
    console.log('  Plan Phase 2 first and budget accordingly.');
  }

  await dump('_results', results);
  console.log('');
}

main().catch((e) => {
  console.error(`\n${C.r}Spike crashed: ${e.stack}${C.x}`);
  process.exit(1);
});
