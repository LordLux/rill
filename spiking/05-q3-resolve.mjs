#!/usr/bin/env node
/**
 * Spike 05 — resolve a fresh ANDROID_VR stream for the seek harness.
 *
 * Same resolution path as spike 03's 03-q2-http.mjs (server-issued visitor id,
 * per F5). Writes to 05-out/ rather than 03-out/ so spike 03's corpus is not
 * clobbered — CLAUDE.md forbids mixing capture runs.
 *
 *   node 05-q3-resolve.mjs [videoId]
 */
import { writeFile, mkdir } from 'node:fs/promises';

const VIDEO = process.argv[2] || 'aqz-KE-bpKQ';
const OUT = new URL('./05-out/', import.meta.url);
const VR_UA =
  'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

const page = await fetch(
  `https://www.youtube.com/watch?v=${VIDEO}&bpctr=9999999999&has_verified=1`,
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
        clientName: 'ANDROID_VR', clientVersion: '1.65.10',
        deviceMake: 'Oculus', deviceModel: 'Quest 3', androidSdkVersion: 32,
        userAgent: VR_UA, osName: 'Android', osVersion: '12L',
        hl: 'en', timeZone: 'UTC', utcOffsetMinutes: 0,
      },
    },
    videoId: VIDEO,
    playbackContext: {
      contentPlaybackContext: { html5Preference: 'HTML5_PREF_WANTS', signatureTimestamp: sts },
    },
    contentCheckOk: true, racyCheckOk: true,
  }),
});
const raw = await res.json();
if (raw?.playabilityStatus?.status !== 'OK') {
  throw new Error(`player refused: ${raw?.playabilityStatus?.status} ${raw?.playabilityStatus?.reason ?? ''}`);
}

const adaptive = raw.streamingData.adaptiveFormats;
const byItag = (i) => adaptive.find((f) => f.itag === i);
const audio = adaptive.filter((f) => (f.mimeType ?? '').startsWith('audio/'))
  .sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0));

const av1 = byItag(401) ?? adaptive.find((f) => (f.mimeType ?? '').includes('av01'));
const vp9 = byItag(315) ?? adaptive.find((f) => (f.mimeType ?? '').includes('vp9'));
const bestAudio = byItag(251) ?? audio[0];

await mkdir(OUT, { recursive: true });
const pick = (f) => f && { itag: f.itag, mimeType: f.mimeType, contentLength: f.contentLength, url: f.url };
await writeFile(
  new URL('urls.json', OUT),
  JSON.stringify({ videoId: VIDEO, capturedAt: new Date().toISOString(), sts,
    formats: adaptive.length, av1: pick(av1), vp9: pick(vp9), audio: pick(bestAudio) }, null, 2),
);
console.error(`resolved ${adaptive.length} formats  av1=${av1?.itag} vp9=${vp9?.itag} audio=${bestAudio?.itag}`);
