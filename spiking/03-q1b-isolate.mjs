#!/usr/bin/env node
/**
 * Spike 03 / Q1b — which header is the discriminator?
 *
 * The first pass showed youtubei.js's default ANDROID_VR request refused and the
 * same request with corrected headers accepted. But every variant after the first
 * reused one visitorData, and a visitor id that has just been handed
 * "Sign in to confirm you're not a bot" is a confound. So: one fresh session per
 * variant, variants interleaved across rounds, and the header set varied one
 * field at a time.
 *
 *   node 03-q1b-isolate.mjs [videoId] [rounds]
 */

import { Innertube, Platform } from 'youtubei.js';
import { writeFile, mkdir } from 'node:fs/promises';
import vm from 'node:vm';

const VIDEO = process.argv[2] || 'aqz-KE-bpKQ';
const ROUNDS = Number(process.argv[3] || 2);
const OUT = new URL('./03-out/', import.meta.url);

const VR_UA =
  'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Each variant is a mutation applied to the headers youtubei.js would otherwise
 * send. `null` removes the header.
 */
const VARIANTS = {
  'baseline (yt.js as-is)': {},
  'client-name only': { 'X-Youtube-Client-Name': '28' },
  'client-version only': { 'X-Youtube-Client-Version': '1.65.10' },
  'user-agent only': { 'User-Agent': VR_UA },
  'name + version': { 'X-Youtube-Client-Name': '28', 'X-Youtube-Client-Version': '1.65.10' },
  'name + version + UA': {
    'X-Youtube-Client-Name': '28',
    'X-Youtube-Client-Version': '1.65.10',
    'User-Agent': VR_UA,
  },
  'all three, no visitor-id': {
    'X-Youtube-Client-Name': '28',
    'X-Youtube-Client-Version': '1.65.10',
    'User-Agent': VR_UA,
    'X-Goog-Visitor-Id': null,
  },
};

function summarise(raw) {
  const sd = raw?.streamingData ?? {};
  const adaptive = sd.adaptiveFormats ?? [];
  const video = adaptive.filter((f) => (f.mimeType ?? '').startsWith('video/'));
  const maxHeight = video.reduce((m, f) => Math.max(m, f.height ?? 0), 0);
  return {
    status: raw?.playabilityStatus?.status ?? '?',
    reason: raw?.playabilityStatus?.reason ?? null,
    adaptive: adaptive.length,
    withUrl: adaptive.filter((f) => f.url).length,
    maxHeight,
    pass: adaptive.length > 0 && maxHeight >= 1080,
  };
}

async function runVariant(name, overrides) {
  const sent = [];
  const patched = (input, init) => {
    const url = typeof input === 'string' ? input : (input?.url ?? String(input));
    if (url.includes('/youtubei/v1/player') && init?.headers?.set) {
      for (const [k, v] of Object.entries(overrides)) {
        if (v === null) init.headers.delete(k);
        else init.headers.set(k, v);
      }
      const h = {};
      init.headers.forEach((val, key) => (h[key] = val));
      sent.push({ headers: h, body: JSON.parse(init.body) });
    }
    return fetch(input, init);
  };

  const yt = await Innertube.create({
    client_type: 'WEB',
    device_category: 'desktop',
    retrieve_player: true,
    generate_session_locally: true,
    fetch: patched,
  });

  let raw;
  try {
    const res = await yt.actions.execute('/player', {
      videoId: VIDEO,
      contentCheckOk: true,
      racyCheckOk: true,
      playbackContext: {
        contentPlaybackContext: {
          vis: 0,
          splay: false,
          lactMilliseconds: '-1',
          signatureTimestamp: yt.session.player?.signature_timestamp,
        },
      },
      client: 'ANDROID_VR',
      parse: false,
    });
    raw = res?.data ?? res;
  } catch (e) {
    raw = { playabilityStatus: { status: 'REQUEST_FAILED', reason: e.message } };
  }

  return { summary: summarise(raw), sent: sent[0], raw };
}

async function main() {
  Platform.shim.eval = (code) => {
    const text = typeof code === 'string' ? code : code.output;
    return vm.runInNewContext(`(function() { ${text} })()`, {});
  };
  await mkdir(OUT, { recursive: true });

  console.log(`${C.b}Spike 03 / Q1b — isolating the refused field${C.x}`);
  console.log(`${C.d}${new Date().toISOString()}  video=${VIDEO}  rounds=${ROUNDS}${C.x}\n`);

  const names = Object.keys(VARIANTS);
  const tally = Object.fromEntries(names.map((n) => [n, []]));
  let winnerRaw = null;

  for (let round = 0; round < ROUNDS; round++) {
    // Reverse the order each round so position in the sequence cannot masquerade
    // as an effect of the header set.
    const order = round % 2 === 0 ? names : [...names].reverse();
    console.log(`${C.b}round ${round + 1}${C.x}`);
    for (const name of order) {
      const { summary, raw } = await runVariant(name, VARIANTS[name]);
      tally[name].push(summary);
      const flag = summary.pass ? `${C.g}PASS${C.x}` : `${C.r}FAIL${C.x}`;
      console.log(
        `  ${flag}  ${name.padEnd(26)} status=${String(summary.status).padEnd(14)} ` +
          `adaptive=${String(summary.adaptive).padStart(3)} max=${String(summary.maxHeight).padStart(4)}p` +
          (summary.reason ? `  ${C.y}${summary.reason}${C.x}` : ''),
      );
      if (summary.pass && !winnerRaw) winnerRaw = raw;
      await sleep(1500);
    }
    console.log('');
  }

  console.log(`${C.b}Tally across ${ROUNDS} rounds${C.x}`);
  for (const name of names) {
    const runs = tally[name];
    const passes = runs.filter((r) => r.pass).length;
    const tone = passes === runs.length ? C.g : passes === 0 ? C.r : C.y;
    console.log(
      `  ${tone}${String(passes)}/${runs.length}${C.x}  ${name.padEnd(26)} ` +
        `statuses=${[...new Set(runs.map((r) => r.status))].join(',')}`,
    );
  }

  if (winnerRaw) {
    const adaptive = winnerRaw.streamingData.adaptiveFormats;
    console.log(`\n${C.b}Formats from a passing ANDROID_VR response${C.x}`);
    const video = adaptive
      .filter((f) => (f.mimeType ?? '').startsWith('video/'))
      .sort((a, b) => (b.height ?? 0) - (a.height ?? 0));
    const audio = adaptive
      .filter((f) => (f.mimeType ?? '').startsWith('audio/'))
      .sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0));
    for (const f of video.slice(0, 12)) {
      console.log(
        `  video itag ${String(f.itag).padStart(3)}  ${String(f.height).padStart(4)}p${String(f.fps ?? '').padEnd(3)} ` +
          `${(f.mimeType ?? '').padEnd(34)} n=${/[?&]n=/.test(f.url ?? '')}`,
      );
    }
    for (const f of audio.slice(0, 6)) {
      console.log(
        `  audio itag ${String(f.itag).padStart(3)}  ${String(Math.round((f.bitrate ?? 0) / 1000)).padStart(4)}k   ` +
          `${(f.mimeType ?? '').padEnd(34)} n=${/[?&]n=/.test(f.url ?? '')}`,
      );
    }
    await writeFile(new URL('q1b-winner-response.json', OUT), JSON.stringify(winnerRaw, null, 2));
    // Hand the URLs to Q2 without a second /player call.
    await writeFile(
      new URL('q2-urls.json', OUT),
      JSON.stringify(
        {
          videoId: VIDEO,
          capturedAt: new Date().toISOString(),
          video: video.slice(0, 6).map((f) => ({ itag: f.itag, mimeType: f.mimeType, height: f.height, fps: f.fps, contentLength: f.contentLength, url: f.url })),
          audio: audio.slice(0, 4).map((f) => ({ itag: f.itag, mimeType: f.mimeType, bitrate: f.bitrate, contentLength: f.contentLength, url: f.url })),
        },
        null,
        2,
      ),
    );
  }

  await writeFile(new URL('q1b-tally.json', OUT), JSON.stringify(tally, null, 2));
}

main().catch((e) => {
  console.error(`\n${C.r}${e.stack}${C.x}`);
  process.exit(1);
});
