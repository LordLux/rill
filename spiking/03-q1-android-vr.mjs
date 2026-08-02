#!/usr/bin/env node
/**
 * Spike 03 / Q1 — can ANDROID_VR be made to work?
 *
 * F5 records ANDROID_VR as "actively refused". yt-dlp resolves it fine, so the
 * hypothesis is that F5 describes our request construction. This script captures
 * exactly what youtubei.js puts on the wire for { client: 'ANDROID_VR' }, diffs
 * it against the yt-dlp capture, and re-requests with the difference ported.
 *
 * Throwaway. Nothing here is production code.
 *
 *   node 03-q1-android-vr.mjs [videoId]
 */

import { Innertube, Platform } from 'youtubei.js';
import { writeFile, mkdir } from 'node:fs/promises';
import vm from 'node:vm';

const VIDEO = process.argv[2] || 'aqz-KE-bpKQ';
const OUT = new URL('./03-out/', import.meta.url);

// What yt-dlp 2026.07.04 actually sent, lifted verbatim from --print-traffic.
const YTDLP = {
  headers: {
    'User-Agent':
      'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    'X-Youtube-Client-Name': '28',
    'X-Youtube-Client-Version': '1.65.10',
    'Content-Type': 'application/json',
    Origin: 'https://www.youtube.com',
  },
  client: {
    clientName: 'ANDROID_VR',
    clientVersion: '1.65.10',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    androidSdkVersion: 32,
    userAgent:
      'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    osName: 'Android',
    osVersion: '12L',
    hl: 'en',
    timeZone: 'UTC',
    utcOffsetMinutes: 0,
  },
};

const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };

async function dump(name, data) {
  await mkdir(OUT, { recursive: true });
  await writeFile(new URL(`${name}.json`, OUT), JSON.stringify(data, null, 2));
}

// ---------------------------------------------------------------------------
// Capture layer — record every /player request youtubei.js makes.
// ---------------------------------------------------------------------------

const captured = [];

function urlOf(input) {
  if (typeof input === 'string') return input;
  if (input instanceof URL) return input.href;
  return input?.url ?? String(input);
}

function recordingFetch(input, init) {
  const url = urlOf(input);
  if (url.includes('/youtubei/v1/player')) {
    const headers = {};
    const h = init?.headers ?? (input.headers ?? new Headers());
    if (typeof h.forEach === 'function') h.forEach((v, k) => (headers[k] = v));
    else Object.assign(headers, h);
    let body = null;
    try {
      body = JSON.parse(init?.body ?? '{}');
    } catch {
      body = init?.body ?? null;
    }
    captured.push({ url, headers, body });
  }
  return fetch(input, init);
}

// ---------------------------------------------------------------------------
// Summarising a raw (parse:false) player response.
// ---------------------------------------------------------------------------

function summarise(raw) {
  const sd = raw?.streamingData ?? {};
  const adaptive = sd.adaptiveFormats ?? [];
  const video = adaptive.filter((f) => (f.mimeType ?? '').startsWith('video/'));
  const audio = adaptive.filter((f) => (f.mimeType ?? '').startsWith('audio/'));
  const withUrl = adaptive.filter((f) => f.url);
  const maxHeight = video.reduce((m, f) => Math.max(m, f.height ?? 0), 0);
  const best = [...video].sort((a, b) => (b.height ?? 0) - (a.height ?? 0))[0];
  const bestAudio = [...audio].sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0))[0];
  return {
    status: raw?.playabilityStatus?.status ?? '?',
    reason: raw?.playabilityStatus?.reason ?? null,
    // The F5 signature: a PlayerErrorCommand carrying auth_required_command.
    errorCommand: JSON.stringify(raw?.playabilityStatus ?? {}).includes('auth_required')
      ? 'auth_required_command present'
      : null,
    adaptive: adaptive.length,
    video: video.length,
    audio: audio.length,
    withUrl: withUrl.length,
    maxHeight,
    sabrOnly: adaptive.length > 0 && adaptive.every((f) => !f.url && !f.signatureCipher),
    hasServerAbrUrl: Boolean(sd.serverAbrStreamingUrl),
    best: best && {
      itag: best.itag,
      mime: best.mimeType,
      height: best.height,
      fps: best.fps,
      hasUrl: Boolean(best.url),
      hasCipher: Boolean(best.signatureCipher),
      hasN: best.url ? /[?&]n=/.test(best.url) : null,
    },
    bestAudio: bestAudio && {
      itag: bestAudio.itag,
      mime: bestAudio.mimeType,
      bitrate: bestAudio.bitrate,
      hasUrl: Boolean(bestAudio.url),
    },
  };
}

function line(label, s) {
  const flag =
    s.adaptive > 0 && s.maxHeight >= 1080 ? `${C.g}PASS${C.x}` : `${C.r}FAIL${C.x}`;
  console.log(
    `  ${flag}  ${label.padEnd(34)} status=${String(s.status).padEnd(10)} ` +
      `adaptive=${String(s.adaptive).padStart(3)} url=${String(s.withUrl).padStart(3)} ` +
      `max=${String(s.maxHeight).padStart(4)}p` +
      (s.errorCommand ? `  ${C.y}${s.errorCommand}${C.x}` : '') +
      (s.reason ? `  ${C.y}${s.reason}${C.x}` : ''),
  );
}

// ---------------------------------------------------------------------------

function diffObjects(a, b, labelA, labelB) {
  const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
  const rows = [];
  for (const k of keys) {
    const va = a[k];
    const vb = b[k];
    if (JSON.stringify(va) === JSON.stringify(vb)) continue;
    rows.push({ field: k, [labelA]: va ?? '(absent)', [labelB]: vb ?? '(absent)' });
  }
  return rows;
}

function printDiff(title, rows, labelA, labelB) {
  console.log(`\n${C.b}${title}${C.x}`);
  if (!rows.length) return console.log(`  ${C.d}(identical)${C.x}`);
  const w = Math.max(...rows.map((r) => r.field.length));
  for (const r of rows) {
    const clip = (v) => {
      const s = typeof v === 'string' ? v : JSON.stringify(v);
      return s.length > 84 ? `${s.slice(0, 81)}…` : s;
    };
    console.log(`  ${r.field.padEnd(w)}  ${C.y}${labelA}:${C.x} ${clip(r[labelA])}`);
    console.log(`  ${' '.repeat(w)}  ${C.g}${labelB}:${C.x} ${clip(r[labelB])}`);
  }
}

// ---------------------------------------------------------------------------

async function main() {
  Platform.shim.eval = (code) => {
    const text = typeof code === 'string' ? code : code.output;
    return vm.runInNewContext(`(function() { ${text} })()`, {});
  };

  console.log(`${C.b}Spike 03 / Q1 — ANDROID_VR request shape${C.x}`);
  console.log(`${C.d}${new Date().toISOString()}  video=${VIDEO}${C.x}\n`);

  // Anonymous session, exactly as the sidecar builds one for stream resolution.
  const yt = await Innertube.create({
    client_type: 'WEB',
    device_category: 'desktop',
    retrieve_player: true,
    generate_session_locally: true,
    fetch: recordingFetch,
  });

  const sts = yt.session.player?.signature_timestamp;
  const visitor = yt.session.context.client.visitorData ?? '';
  console.log(`${C.d}player sts=${sts}  visitorData=${visitor.slice(0, 24)}…${C.x}\n`);

  const results = {};

  // -- A. youtubei.js default shape --------------------------------------------
  // The sidecar's playerPayload, with client swapped to ANDROID_VR.
  const defaultPayload = {
    videoId: VIDEO,
    contentCheckOk: true,
    racyCheckOk: true,
    playbackContext: {
      contentPlaybackContext: {
        vis: 0,
        splay: false,
        lactMilliseconds: '-1',
        signatureTimestamp: sts,
      },
    },
    client: 'ANDROID_VR',
    parse: false,
  };

  captured.length = 0;
  let rawA;
  try {
    const res = await yt.actions.execute('/player', defaultPayload);
    rawA = res?.data ?? res;
  } catch (e) {
    rawA = { playabilityStatus: { status: 'REQUEST_FAILED', reason: e.message } };
  }
  const reqA = captured[0];
  results.A = summarise(rawA);
  await dump('q1-A-youtubeijs-request', reqA);
  await dump('q1-A-youtubeijs-response', rawA);

  // -- B. Headers corrected to match the body's client --------------------------
  // youtubei.js derives X-Youtube-Client-* and User-Agent from the *session*
  // client, not the per-request one. Override them at the fetch layer.
  const headerOverrideFetch = (input, init) => {
    const url = urlOf(input);
    if (url.includes('/youtubei/v1/player') && init?.headers?.set) {
      init.headers.set('X-Youtube-Client-Name', '28');
      init.headers.set('X-Youtube-Client-Version', '1.65.10');
      init.headers.set('User-Agent', YTDLP.headers['User-Agent']);
    }
    return recordingFetch(input, init);
  };

  const ytB = await Innertube.create({
    client_type: 'WEB',
    device_category: 'desktop',
    retrieve_player: true,
    generate_session_locally: true,
    fetch: headerOverrideFetch,
  });

  captured.length = 0;
  let rawB;
  try {
    const res = await ytB.actions.execute('/player', {
      ...defaultPayload,
      playbackContext: {
        contentPlaybackContext: {
          vis: 0,
          splay: false,
          lactMilliseconds: '-1',
          signatureTimestamp: ytB.session.player?.signature_timestamp,
        },
      },
    });
    rawB = res?.data ?? res;
  } catch (e) {
    rawB = { playabilityStatus: { status: 'REQUEST_FAILED', reason: e.message } };
  }
  const reqB = captured[0];
  results.B = summarise(rawB);
  await dump('q1-B-headers-fixed-request', reqB);
  await dump('q1-B-headers-fixed-response', rawB);

  // -- C. yt-dlp's exact request, hand-built ------------------------------------
  const bodyC = {
    context: { client: { ...YTDLP.client } },
    videoId: VIDEO,
    playbackContext: {
      contentPlaybackContext: {
        html5Preference: 'HTML5_PREF_WANTS',
        signatureTimestamp: sts,
      },
    },
    contentCheckOk: true,
    racyCheckOk: true,
  };
  const headersC = { ...YTDLP.headers, 'X-Goog-Visitor-Id': visitor };

  const resC = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
    method: 'POST',
    headers: headersC,
    body: JSON.stringify(bodyC),
  });
  const rawC = await resC.json();
  results.C = summarise(rawC);
  await dump('q1-C-ytdlp-shape-request', { headers: headersC, body: bodyC });
  await dump('q1-C-ytdlp-shape-response', rawC);

  // -- D. Body-only fix: yt-dlp's context, youtubei.js's default headers ---------
  // Isolates whether the headers or the body context is the discriminator.
  const resD = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Visitor-Id': visitor,
      'X-Youtube-Client-Name': reqA?.headers?.['x-youtube-client-name'] ?? '1',
      'X-Youtube-Client-Version': reqA?.headers?.['x-youtube-client-version'] ?? '',
      'User-Agent': reqA?.headers?.['user-agent'] ?? '',
      Origin: 'https://www.youtube.com',
    },
    body: JSON.stringify(bodyC),
  });
  const rawD = await resD.json();
  results.D = summarise(rawD);
  await dump('q1-D-ytdlp-body-web-headers-response', rawD);

  // -- E. Header fix only: youtubei.js's full context, yt-dlp's headers ----------
  const resE = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
    method: 'POST',
    headers: headersC,
    body: JSON.stringify(reqA?.body ?? {}),
  });
  const rawE = await resE.json();
  results.E = summarise(rawE);
  await dump('q1-E-youtubeijs-body-ytdlp-headers-response', rawE);

  // -------------------------------------------------------------------------

  console.log(`${C.b}Results  (pass = >0 adaptive formats at >=1080p)${C.x}\n`);
  line('A youtubei.js as-is', results.A);
  line('B + headers corrected', results.B);
  line('C yt-dlp shape verbatim', results.C);
  line('D yt-dlp body / yt.js headers', results.D);
  line('E yt.js body / yt-dlp headers', results.E);

  printDiff(
    'Header diff — youtubei.js vs yt-dlp',
    diffObjects(
      Object.fromEntries(
        Object.entries(reqA?.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]),
      ),
      Object.fromEntries(Object.entries(YTDLP.headers).map(([k, v]) => [k.toLowerCase(), v])),
      'yt.js',
      'yt-dlp',
    ),
    'yt.js',
    'yt-dlp',
  );

  printDiff(
    'context.client diff — youtubei.js vs yt-dlp',
    diffObjects(reqA?.body?.context?.client ?? {}, YTDLP.client, 'yt.js', 'yt-dlp'),
    'yt.js',
    'yt-dlp',
  );

  const topA = Object.fromEntries(
    Object.entries(reqA?.body ?? {}).filter(([k]) => k !== 'context'),
  );
  const topB = Object.fromEntries(Object.entries(bodyC).filter(([k]) => k !== 'context'));
  printDiff(
    'body (non-context) diff — youtubei.js vs yt-dlp',
    diffObjects(topA, topB, 'yt.js', 'yt-dlp'),
    'yt.js',
    'yt-dlp',
  );

  console.log(`\n${C.b}Best formats${C.x}`);
  for (const [k, s] of Object.entries(results)) {
    if (!s.best) continue;
    console.log(
      `  ${k}: video itag ${s.best.itag} ${s.best.mime} ${s.best.height}p${s.best.fps ?? ''} ` +
        `url=${s.best.hasUrl} n=${s.best.hasN}  |  audio itag ${s.bestAudio?.itag} ${s.bestAudio?.mime}`,
    );
  }

  await dump('q1-summary', results);
  console.log(`\n${C.d}fixtures -> spiking/03-out/${C.x}`);
}

main().catch((e) => {
  console.error(`\n${C.r}${e.stack}${C.x}`);
  process.exit(1);
});
