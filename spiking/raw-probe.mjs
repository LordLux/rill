#!/usr/bin/env node
/**
 * Diagnostic probe. Two questions the spike can no longer answer:
 *
 *   A. Is the home feed genuinely empty, or is youtubei.js dropping content?
 *      -> dumps the RAW unparsed /youtubei/v1/browse response
 *
 *   B. Can the AUTHENTICATED WEB session record a watch event at all?
 *      -> the earlier test reported from an anonymous instance, which could
 *         never have landed. This reports from the cookie session.
 *
 * Writes to ./raw/ — a separate directory, so it cannot be confused with
 * fixtures/ from an older run. That mixing is what produced the misleading
 * "23 LockupView" reading.
 *
 * Run:  node raw-probe.mjs
 */

import { Innertube, Platform } from 'youtubei.js';
import { writeFile, mkdir, rm } from 'node:fs/promises';
import vm from 'node:vm';

const COOKIE = process.env.YT_COOKIE;
const VIDEO = process.env.YT_VIDEO_STANDARD || 'aqz-KE-bpKQ';
const OUT = new URL('./raw/', import.meta.url);

const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };
const say = (s) => console.log(s);

async function save(name, data) {
  await writeFile(new URL(`${name}.json`, OUT), JSON.stringify(data, null, 2));
  say(`${C.d}      -> raw/${name}.json${C.x}`);
}

/** Count occurrences of a key anywhere in a raw JSON tree. */
function countKey(node, key, depth = 0, seen = new Set()) {
  if (!node || typeof node !== 'object' || depth > 40 || seen.has(node)) return 0;
  seen.add(node);
  let n = 0;
  if (!Array.isArray(node) && Object.hasOwn(node, key)) n++;
  for (const v of Array.isArray(node) ? node : Object.values(node)) {
    n += countKey(v, key, depth + 1, seen);
  }
  return n;
}

async function main() {
  if (!COOKIE) { console.error('YT_COOKIE not set.'); process.exit(1); }

  // Fresh directory every run — no cross-run contamination.
  await rm(OUT, { recursive: true, force: true });
  await mkdir(OUT, { recursive: true });

  Platform.shim.eval = (code) => {
    const text = typeof code === 'string' ? code : code.output;
    return vm.runInNewContext(`(function() { ${text} })()`, {});
  };

  const yt = await Innertube.create({
    cookie: COOKIE,
    client_type: 'WEB',
    device_category: 'DESKTOP',
    retrieve_player: true,
    enable_session_cache: false,     // never reuse a possibly-degraded session
    generate_session_locally: false,
  });

  say(`\n${C.b}A. RAW BROWSE RESPONSE${C.x}`);
  say(`${C.d}   logged_in=${yt.session.logged_in}${C.x}\n`);

  // parse:false gives the untouched JSON, bypassing the parser entirely.
  const raw = await yt.actions.execute('/browse', {
    browseId: 'FEwhat_to_watch',
    parse: false,
  });

  const body = raw?.data ?? raw;
  await save('browse-home-raw', body);

  const counts = {
    lockupViewModel: countKey(body, 'lockupViewModel'),
    richItemRenderer: countKey(body, 'richItemRenderer'),
    videoRenderer: countKey(body, 'videoRenderer'),
    chipCloudChipRenderer: countKey(body, 'chipCloudChipRenderer'),
    chipViewModel: countKey(body, 'chipViewModel'),
    continuationItemRenderer: countKey(body, 'continuationItemRenderer'),
    contents: countKey(body, 'contents'),
  };

  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  for (const [k, v] of Object.entries(counts)) {
    const tone = v > 0 ? C.g : C.d;
    say(`   ${tone}${String(v).padStart(4)}${C.x}  ${k}`);
  }

  say('');
  if (total === 0) {
    say(`   ${C.r}Raw response contains no feed content.${C.x}`);
    say(`   ${C.d}YouTube is serving an empty feed to this session — not a parser problem.${C.x}`);
    say(`   ${C.d}Most likely: browse now requires a PO token for this account/IP.${C.x}`);
  } else if (counts.lockupViewModel > 0 || counts.richItemRenderer > 0) {
    say(`   ${C.g}Raw response HAS content.${C.x}`);
    say(`   ${C.d}youtubei.js is dropping it during parsing. Walk the raw JSON in the${C.x}`);
    say(`   ${C.d}sidecar instead of using typed accessors — parse:false is the answer.${C.x}`);
  } else {
    say(`   ${C.y}Partial content — inspect raw/browse-home-raw.json directly.${C.x}`);
  }

  // -------------------------------------------------------------------------
  say(`\n${C.b}B. AUTHENTICATED WATCH-HISTORY REPORTING${C.x}\n`);

  // The earlier test called addToWatchHistory() on an ANONYMOUS instance, so it
  // could never have landed. Report from the cookie session instead.
  let reported = false;
  let cpn = null;
  try {
    const info = await yt.getInfo(VIDEO);          // authenticated WEB session
    cpn = info?.cpn ?? null;
    say(`   video:  ${VIDEO}`);
    say(`   cpn:    ${cpn ?? '(library-managed)'}`);

    if (typeof info.addToWatchHistory !== 'function') {
      say(`   ${C.y}addToWatchHistory() not available on this version.${C.x}`);
    } else {
      const res = await info.addToWatchHistory();
      await save('watch-report-response', res ?? { ok: true });
      reported = true;
      say(`   ${C.g}watch event reported from the authenticated session${C.x}`);
    }
  } catch (e) {
    say(`   ${C.r}reporting failed: ${e.message}${C.x}`);
  }

  if (reported) {
    say(`\n   ${C.d}waiting 25s, then re-reading history...${C.x}`);
    await new Promise((r) => setTimeout(r, 25_000));

    const rawHistory = await yt.actions.execute('/browse', {
      browseId: 'FEhistory',
      parse: false,
    });
    const hBody = rawHistory?.data ?? rawHistory;
    await save('history-raw', hBody);

    const json = JSON.stringify(hBody);
    const landed = json.includes(VIDEO);
    const entryCount = countKey(hBody, 'lockupViewModel') + countKey(hBody, 'videoRenderer');

    say('');
    say(`   history entries visible: ${entryCount}`);
    say(`   ${VIDEO} present:        ${landed ? C.g + 'YES' : C.r + 'NO'}${C.x}`);
    say('');
    if (landed) {
      say(`   ${C.g}Reporting works from the authenticated session.${C.x}`);
      say(`   ${C.d}Architecture: resolve streams via MWEB, report via the WEB session.${C.x}`);
      say(`   ${C.d}Two calls per playback — cheap, and CPN matching may not matter.${C.x}`);
    } else if (entryCount === 0) {
      say(`   ${C.y}History itself is empty in the raw response.${C.x}`);
      say(`   ${C.d}Check youtube.com/feed/history — if the browser shows entries but this${C.x}`);
      say(`   ${C.d}does not, the session is degraded (same cause as the empty home feed).${C.x}`);
    } else {
      say(`   ${C.r}History readable but the event did not land.${C.x}`);
      say(`   ${C.d}Reporting is genuinely blocked; the player client must be WEB,${C.x}`);
      say(`   ${C.d}which makes the SABR bridge mandatory rather than deferrable.${C.x}`);
    }
  }

  say('');
}

main().catch((e) => { console.error(`${C.r}${e.stack}${C.x}`); process.exit(1); });
