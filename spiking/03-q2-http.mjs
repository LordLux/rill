#!/usr/bin/env node
/**
 * Spike 03 / Q2 — do ANDROID_VR URLs survive F10 end to end?
 *
 * Checks 1-3 of the four. Check 4 is mpv and lives in 03-q2-mpv.ps1.
 *
 *   1. Range: bytes=0-   -> expect 206, not 403        (the exact shape ffmpeg opens with)
 *   2. bare GET, no headers -> record the status       (Task 02 measured 403 on MWEB)
 *   3. sustained throughput, >= 12 MB, assert > 1.5 MB/s
 *
 * Task 02's suite passed while playback was broken because it only ever issued
 * bounded ranges. So the throughput measurement here runs over an *open-ended*
 * range — the path that actually has to work — not a bounded one.
 *
 * Resolution uses a server-issued X-Goog-Visitor-Id, which Q1d established is
 * the difference between ANDROID_VR answering and ANDROID_VR refusing.
 *
 *   node 03-q2-http.mjs [videoId]
 */

import { writeFile, mkdir } from 'node:fs/promises';

const VIDEO = process.argv[2] || 'aqz-KE-bpKQ';
const OUT = new URL('./03-out/', import.meta.url);

const VR_UA =
  'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
const SAMPLE_BYTES = 12 * 1024 * 1024;
const HEALTHY_MBPS = 1.5;

const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };
const ok = (b) => (b ? `${C.g}PASS${C.x}` : `${C.r}FAIL${C.x}`);

// ---------------------------------------------------------------------------

async function resolveAndroidVr(videoId) {
  const page = await fetch(
    `https://www.youtube.com/watch?v=${videoId}&bpctr=9999999999&has_verified=1`,
    { headers: { 'User-Agent': VR_UA, Cookie: 'PREF=hl=en&tz=UTC; SOCS=CAI' } },
  );
  const html = await page.text();
  const visitorRaw = html.match(/"visitorData":"([^"]+)"/)?.[1];
  const visitorData = visitorRaw ? JSON.parse(`"${visitorRaw}"`) : null;
  const sts = Number(html.match(/"STS":\s*(\d+)/)?.[1] ?? 0) || null;
  if (!visitorData) throw new Error('no server-issued visitorData on the watch page');

  const res = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': VR_UA,
      'X-Youtube-Client-Name': '28',
      'X-Youtube-Client-Version': '1.65.10',
      'X-Goog-Visitor-Id': visitorData,
      Origin: 'https://www.youtube.com',
    },
    body: JSON.stringify({
      context: {
        client: {
          clientName: 'ANDROID_VR',
          clientVersion: '1.65.10',
          deviceMake: 'Oculus',
          deviceModel: 'Quest 3',
          androidSdkVersion: 32,
          userAgent: VR_UA,
          osName: 'Android',
          osVersion: '12L',
          hl: 'en',
          timeZone: 'UTC',
          utcOffsetMinutes: 0,
        },
      },
      videoId,
      playbackContext: {
        contentPlaybackContext: { html5Preference: 'HTML5_PREF_WANTS', signatureTimestamp: sts },
      },
      contentCheckOk: true,
      racyCheckOk: true,
    }),
  });
  const raw = await res.json();
  if (raw?.playabilityStatus?.status !== 'OK') {
    throw new Error(`player refused: ${raw?.playabilityStatus?.status} ${raw?.playabilityStatus?.reason ?? ''}`);
  }
  return { raw, sts, visitorData };
}

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------

/** Check 1 — the exact request ffmpeg opens every HTTP stream with. */
async function openEndedRange(url, offset = 0) {
  const ctl = new AbortController();
  try {
    const res = await fetch(url, {
      headers: { Range: `bytes=${offset}-` },
      signal: ctl.signal,
    });
    const status = res.status;
    const contentRange = res.headers.get('content-range');
    ctl.abort();
    return { status, contentRange };
  } catch (e) {
    return { status: 'ERR', error: e.message };
  }
}

/** Check 2 — no Range header at all. */
async function bareGet(url) {
  const ctl = new AbortController();
  try {
    const res = await fetch(url, { signal: ctl.signal });
    const status = res.status;
    const len = res.headers.get('content-length');
    ctl.abort();
    return { status, contentLength: len };
  } catch (e) {
    return { status: 'ERR', error: e.message };
  }
}

/** Check 3 — sustained throughput, measured over an open-ended range. */
async function sustained(url, bytes = SAMPLE_BYTES) {
  const ctl = new AbortController();
  const timeout = setTimeout(() => ctl.abort(), 90_000);
  const started = Date.now();
  let received = 0;
  try {
    const res = await fetch(url, { headers: { Range: 'bytes=0-' }, signal: ctl.signal });
    if (res.status !== 206 && res.status !== 200) {
      return { ok: false, status: res.status };
    }
    for await (const chunk of res.body) {
      received += chunk.length;
      if (received >= bytes) break;
    }
    const seconds = (Date.now() - started) / 1000;
    return { ok: true, status: res.status, mbps: received / 1024 / 1024 / seconds, received, seconds };
  } catch (e) {
    const seconds = (Date.now() - started) / 1000;
    return { ok: received >= bytes, status: 'ABORTED', error: e.message, received, seconds };
  } finally {
    clearTimeout(timeout);
    ctl.abort();
  }
}

// ---------------------------------------------------------------------------

async function main() {
  await mkdir(OUT, { recursive: true });
  console.log(`${C.b}Spike 03 / Q2 — ANDROID_VR URLs against F10${C.x}`);
  console.log(`${C.d}${new Date().toISOString()}  video=${VIDEO}${C.x}\n`);

  const { raw, sts } = await resolveAndroidVr(VIDEO);
  const adaptive = raw.streamingData.adaptiveFormats;
  const byItag = (i) => adaptive.find((f) => f.itag === i);

  const video = adaptive
    .filter((f) => (f.mimeType ?? '').startsWith('video/'))
    .sort((a, b) => (b.height ?? 0) - (a.height ?? 0));
  const audio = adaptive
    .filter((f) => (f.mimeType ?? '').startsWith('audio/'))
    .sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0));

  // Task 02 recorded ANDROID_VR returning AV1 (401) where MWEB returned VP9 (315).
  // Both are in this response, so test both rather than whichever sorts first.
  const av1 = byItag(401) ?? video.find((f) => (f.mimeType ?? '').includes('av01'));
  const vp9 = byItag(315) ?? video.find((f) => (f.mimeType ?? '').includes('vp9'));
  const bestAudio = byItag(251) ?? audio[0];

  console.log(`${C.b}Resolved${C.x}  sts=${sts}  ${adaptive.length} adaptive formats`);
  for (const [label, f] of [['AV1 ', av1], ['VP9 ', vp9], ['audio', bestAudio]]) {
    if (!f) continue;
    console.log(
      `  ${label} itag ${String(f.itag).padStart(3)}  ${f.mimeType}  ` +
        `${f.height ? `${f.height}p${f.fps ?? ''}` : `${Math.round((f.bitrate ?? 0) / 1000)}k`}  ` +
        `${(Number(f.contentLength ?? 0) / 1024 / 1024).toFixed(1)} MB  n=${/[?&]n=/.test(f.url ?? '')}`,
    );
  }

  const results = { videoId: VIDEO, capturedAt: new Date().toISOString(), checks: {} };

  for (const [label, f] of [
    ['itag 401 (AV1 2160p)', av1],
    ['itag 315 (VP9 2160p)', vp9],
    [`itag ${bestAudio?.itag} (audio)`, bestAudio],
  ]) {
    if (!f?.url) continue;
    console.log(`\n${C.b}${label}${C.x}`);
    const size = Number(f.contentLength ?? 0);

    // Check 1 — open-ended range at three offsets, mirroring what Task 02 did to MWEB.
    const offsets = [0, 100 * 1024 * 1024, Math.max(0, size - 5 * 1024 * 1024)];
    const ranges = [];
    for (const off of offsets) {
      if (off >= size && off !== 0) continue;
      const r = await openEndedRange(f.url, off);
      ranges.push({ offset: off, ...r });
      console.log(
        `  ${ok(r.status === 206)}  check 1  Range: bytes=${off}-  ->  HTTP ${r.status}` +
          (r.contentRange ? `  ${C.d}${r.contentRange}${C.x}` : ''),
      );
    }

    // Check 2 — bare GET.
    const bare = await bareGet(f.url);
    console.log(
      `  ${bare.status === 200 || bare.status === 206 ? C.g + 'OK  ' + C.x : C.y + 'NOTE' + C.x}  ` +
        `check 2  bare GET, no headers  ->  HTTP ${bare.status}` +
        (bare.contentLength ? `  ${C.d}content-length=${bare.contentLength}${C.x}` : ''),
    );

    // Check 3 — sustained throughput over an open-ended range.
    const t = await sustained(f.url);
    if (t.ok) {
      console.log(
        `  ${ok(t.mbps > HEALTHY_MBPS)}  check 3  sustained  ->  ${t.mbps.toFixed(2)} MB/s ` +
          `(${(t.received / 1024 / 1024).toFixed(1)} MB in ${t.seconds.toFixed(1)}s, open-ended)`,
      );
    } else {
      console.log(`  ${C.r}FAIL${C.x}  check 3  sustained  ->  HTTP ${t.status} ${t.error ?? ''}`);
    }

    results.checks[label] = { itag: f.itag, mimeType: f.mimeType, contentLength: size, ranges, bare, throughput: t };
  }

  // Hand the two URLs to the mpv check.
  const playVideo = av1 ?? video[0];
  await writeFile(
    new URL('q2-urls.json', OUT),
    JSON.stringify(
      {
        videoId: VIDEO,
        capturedAt: new Date().toISOString(),
        av1: av1 && { itag: av1.itag, mimeType: av1.mimeType, url: av1.url },
        vp9: vp9 && { itag: vp9.itag, mimeType: vp9.mimeType, url: vp9.url },
        audio: bestAudio && { itag: bestAudio.itag, mimeType: bestAudio.mimeType, url: bestAudio.url },
        play: { video: playVideo?.url, audio: bestAudio?.url },
      },
      null,
      2,
    ),
  );
  await writeFile(new URL('q2-http-results.json', OUT), JSON.stringify(results, null, 2));
  console.log(`\n${C.d}urls -> spiking/03-out/q2-urls.json${C.x}`);
}

main().catch((e) => {
  console.error(`\n${C.r}${e.stack}${C.x}`);
  process.exit(1);
});
