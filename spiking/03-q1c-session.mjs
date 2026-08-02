#!/usr/bin/env node
/**
 * Spike 03 / Q1c — session provenance, not header spelling.
 *
 * Q1b varied the headers one field at a time and every variant failed, including
 * one that had passed minutes earlier. A yt-dlp control run in between still
 * resolved ANDROID_VR fine, so the machine was not rate-limited — the difference
 * is in the request after all, just not in the headers.
 *
 * What is left: yt-dlp fetches /watch first, so its player POST carries a
 * server-issued visitor id and the cookie jar that page hands out. The sidecar's
 * anonymous session uses `generate_session_locally: true` — a fabricated visitor
 * id and no cookies at all. That is the axis this script varies.
 *
 *   node 03-q1c-session.mjs [videoId] [rounds]
 */

import { Innertube, Platform } from 'youtubei.js';
import { writeFile, mkdir } from 'node:fs/promises';
import vm from 'node:vm';

const VIDEO = process.argv[2] || 'aqz-KE-bpKQ';
const ROUNDS = Number(process.argv[3] || 2);
const OUT = new URL('./03-out/', import.meta.url);

const VR_UA =
  'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
const VR_HEADERS = {
  'X-Youtube-Client-Name': '28',
  'X-Youtube-Client-Version': '1.65.10',
  'User-Agent': VR_UA,
};
const VR_CLIENT = {
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
};

const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function summarise(raw) {
  const adaptive = raw?.streamingData?.adaptiveFormats ?? [];
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

// ---------------------------------------------------------------------------
// The watch-page bootstrap yt-dlp does before it ever touches /youtubei.
// ---------------------------------------------------------------------------

async function bootstrapFromWatchPage(videoId) {
  const res = await fetch(
    `https://www.youtube.com/watch?v=${videoId}&bpctr=9999999999&has_verified=1`,
    {
      headers: {
        'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)',
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-us,en;q=0.5',
        Cookie: 'PREF=hl=en&tz=UTC; SOCS=CAI',
      },
    },
  );
  const html = await res.text();

  const jar = new Map([
    ['PREF', 'hl=en&tz=UTC'],
    ['SOCS', 'CAI'],
  ]);
  for (const raw of res.headers.getSetCookie?.() ?? []) {
    const [pair] = raw.split(';');
    const idx = pair.indexOf('=');
    if (idx > 0) jar.set(pair.slice(0, idx).trim(), pair.slice(idx + 1).trim());
  }

  const visitor = html.match(/"visitorData":"([^"]+)"/)?.[1];
  const sts = Number(html.match(/"STS":\s*(\d+)/)?.[1] ?? 0);

  return {
    cookie: [...jar].map(([k, v]) => `${k}=${v}`).join('; '),
    visitorData: visitor ? JSON.parse(`"${visitor}"`) : null,
    sts: sts || null,
  };
}

// ---------------------------------------------------------------------------
// Variants
// ---------------------------------------------------------------------------

async function viaYoutubeiJs({ localSession, vrHeaders }) {
  const sent = [];
  const patched = (input, init) => {
    const url = typeof input === 'string' ? input : (input?.url ?? String(input));
    if (vrHeaders && url.includes('/youtubei/v1/player') && init?.headers?.set) {
      for (const [k, v] of Object.entries(VR_HEADERS)) init.headers.set(k, v);
    }
    if (url.includes('/youtubei/v1/player') && init?.headers) {
      const h = {};
      init.headers.forEach?.((val, key) => (h[key] = val));
      sent.push({ headers: h, body: JSON.parse(init.body) });
    }
    return fetch(input, init);
  };

  const yt = await Innertube.create({
    client_type: 'WEB',
    device_category: 'desktop',
    retrieve_player: true,
    generate_session_locally: localSession,
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

  const visitor = yt.session.context.client.visitorData ?? '';
  return { raw, sent: sent[0], note: `visitor(${visitor.length}ch)` };
}

async function viaHandBuilt({ bootstrap, body }) {
  const headers = {
    ...VR_HEADERS,
    'Content-Type': 'application/json',
    Origin: 'https://www.youtube.com',
    ...(bootstrap.visitorData ? { 'X-Goog-Visitor-Id': bootstrap.visitorData } : {}),
    ...(bootstrap.cookie ? { Cookie: bootstrap.cookie } : {}),
  };
  const res = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  return {
    raw: await res.json(),
    sent: { headers, body },
    note: `visitor(${bootstrap.visitorData?.length ?? 0}ch) cookies(${bootstrap.cookie ? bootstrap.cookie.split(';').length : 0})`,
  };
}

async function main() {
  Platform.shim.eval = (code) => {
    const text = typeof code === 'string' ? code : code.output;
    return vm.runInNewContext(`(function() { ${text} })()`, {});
  };
  await mkdir(OUT, { recursive: true });

  console.log(`${C.b}Spike 03 / Q1c — session provenance${C.x}`);
  console.log(`${C.d}${new Date().toISOString()}  video=${VIDEO}  rounds=${ROUNDS}${C.x}\n`);

  const variants = {
    'A local session, yt.js hdrs': () => viaYoutubeiJs({ localSession: true, vrHeaders: false }),
    'B local session, VR hdrs': () => viaYoutubeiJs({ localSession: true, vrHeaders: true }),
    'C server session, yt.js hdrs': () => viaYoutubeiJs({ localSession: false, vrHeaders: false }),
    'D server session, VR hdrs': () => viaYoutubeiJs({ localSession: false, vrHeaders: true }),
    'E watch-page boot, yt-dlp body': async () => {
      const boot = await bootstrapFromWatchPage(VIDEO);
      return viaHandBuilt({
        bootstrap: boot,
        body: {
          context: { client: { ...VR_CLIENT } },
          videoId: VIDEO,
          playbackContext: {
            contentPlaybackContext: {
              html5Preference: 'HTML5_PREF_WANTS',
              signatureTimestamp: boot.sts,
            },
          },
          contentCheckOk: true,
          racyCheckOk: true,
        },
      });
    },
    'F watch-page boot, no cookies': async () => {
      const boot = await bootstrapFromWatchPage(VIDEO);
      return viaHandBuilt({
        bootstrap: { ...boot, cookie: null },
        body: {
          context: { client: { ...VR_CLIENT } },
          videoId: VIDEO,
          playbackContext: {
            contentPlaybackContext: {
              html5Preference: 'HTML5_PREF_WANTS',
              signatureTimestamp: boot.sts,
            },
          },
          contentCheckOk: true,
          racyCheckOk: true,
        },
      });
    },
    'G watch-page boot, no visitor': async () => {
      const boot = await bootstrapFromWatchPage(VIDEO);
      return viaHandBuilt({
        bootstrap: { ...boot, visitorData: null },
        body: {
          context: { client: { ...VR_CLIENT } },
          videoId: VIDEO,
          playbackContext: {
            contentPlaybackContext: {
              html5Preference: 'HTML5_PREF_WANTS',
              signatureTimestamp: boot.sts,
            },
          },
          contentCheckOk: true,
          racyCheckOk: true,
        },
      });
    },
  };

  const names = Object.keys(variants);
  const tally = Object.fromEntries(names.map((n) => [n, []]));
  let winner = null;

  for (let round = 0; round < ROUNDS; round++) {
    const order = round % 2 === 0 ? names : [...names].reverse();
    console.log(`${C.b}round ${round + 1}${C.x}`);
    for (const name of order) {
      let out;
      try {
        out = await variants[name]();
      } catch (e) {
        out = { raw: { playabilityStatus: { status: 'THREW', reason: e.message } }, note: '' };
      }
      const s = summarise(out.raw);
      tally[name].push(s);
      const flag = s.pass ? `${C.g}PASS${C.x}` : `${C.r}FAIL${C.x}`;
      console.log(
        `  ${flag}  ${name.padEnd(30)} status=${String(s.status).padEnd(14)} ` +
          `adaptive=${String(s.adaptive).padStart(3)} max=${String(s.maxHeight).padStart(4)}p ` +
          `${C.d}${out.note ?? ''}${C.x}` +
          (s.reason ? `  ${C.y}${s.reason}${C.x}` : ''),
      );
      if (s.pass && !winner) winner = { name, raw: out.raw, sent: out.sent };
      await sleep(1500);
    }
    console.log('');
  }

  console.log(`${C.b}Tally${C.x}`);
  for (const name of names) {
    const runs = tally[name];
    const passes = runs.filter((r) => r.pass).length;
    const tone = passes === runs.length ? C.g : passes === 0 ? C.r : C.y;
    console.log(
      `  ${tone}${passes}/${runs.length}${C.x}  ${name.padEnd(30)} statuses=${[...new Set(runs.map((r) => r.status))].join(',')}`,
    );
  }

  if (winner) {
    console.log(`\n${C.g}first pass: ${winner.name}${C.x}`);
    const adaptive = winner.raw.streamingData.adaptiveFormats;
    const video = adaptive
      .filter((f) => (f.mimeType ?? '').startsWith('video/'))
      .sort((a, b) => (b.height ?? 0) - (a.height ?? 0));
    const audio = adaptive
      .filter((f) => (f.mimeType ?? '').startsWith('audio/'))
      .sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0));
    console.log(`${C.b}Formats${C.x}`);
    for (const f of video.slice(0, 14)) {
      console.log(
        `  video itag ${String(f.itag).padStart(3)}  ${String(f.height).padStart(4)}p${String(f.fps ?? '').padEnd(3)} ` +
          `${(f.mimeType ?? '').padEnd(36)} url=${Boolean(f.url)} n=${/[?&]n=/.test(f.url ?? '')}`,
      );
    }
    for (const f of audio.slice(0, 5)) {
      console.log(
        `  audio itag ${String(f.itag).padStart(3)}  ${String(Math.round((f.bitrate ?? 0) / 1000)).padStart(4)}k   ` +
          `${(f.mimeType ?? '').padEnd(36)} url=${Boolean(f.url)} n=${/[?&]n=/.test(f.url ?? '')}`,
      );
    }
    await writeFile(new URL('q1c-winner.json', OUT), JSON.stringify(winner, null, 2));
    await writeFile(
      new URL('q2-urls.json', OUT),
      JSON.stringify(
        {
          videoId: VIDEO,
          via: winner.name,
          capturedAt: new Date().toISOString(),
          video: video.slice(0, 8).map((f) => ({ itag: f.itag, mimeType: f.mimeType, height: f.height, fps: f.fps, contentLength: f.contentLength, url: f.url })),
          audio: audio.slice(0, 4).map((f) => ({ itag: f.itag, mimeType: f.mimeType, bitrate: f.bitrate, contentLength: f.contentLength, url: f.url })),
        },
        null,
        2,
      ),
    );
    console.log(`\n${C.d}urls -> spiking/03-out/q2-urls.json${C.x}`);
  }

  await writeFile(new URL('q1c-tally.json', OUT), JSON.stringify(tally, null, 2));
}

main().catch((e) => {
  console.error(`\n${C.r}${e.stack}${C.x}`);
  process.exit(1);
});
