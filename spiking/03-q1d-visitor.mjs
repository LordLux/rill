#!/usr/bin/env node
/**
 * Spike 03 / Q1d — confirm the visitor id is the whole story.
 *
 * Q1c pointed at X-Goog-Visitor-Id: every variant carrying a server-issued one
 * passed, every variant without one failed, and header spelling and cookies made
 * no difference either way. This holds that one field as the only variable —
 * identical body, identical headers otherwise, fresh id per round so a burnt id
 * cannot masquerade as a rejected shape.
 *
 *   node 03-q1d-visitor.mjs [videoId] [rounds]
 */

import { Innertube, Platform } from 'youtubei.js';
import { writeFile, mkdir } from 'node:fs/promises';
import vm from 'node:vm';

const VIDEO = process.argv[2] || 'aqz-KE-bpKQ';
const ROUNDS = Number(process.argv[3] || 5);
const OUT = new URL('./03-out/', import.meta.url);

const VR_UA =
  'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function watchPage(videoId) {
  const res = await fetch(
    `https://www.youtube.com/watch?v=${videoId}&bpctr=9999999999&has_verified=1`,
    { headers: { 'User-Agent': VR_UA, Cookie: 'PREF=hl=en&tz=UTC; SOCS=CAI' } },
  );
  const html = await res.text();
  const visitor = html.match(/"visitorData":"([^"]+)"/)?.[1];
  return {
    visitorData: visitor ? JSON.parse(`"${visitor}"`) : null,
    sts: Number(html.match(/"STS":\s*(\d+)/)?.[1] ?? 0) || null,
  };
}

async function localVisitor() {
  const yt = await Innertube.create({
    client_type: 'WEB',
    retrieve_player: false,
    generate_session_locally: true,
  });
  return yt.session.context.client.visitorData ?? null;
}

async function player(visitorData, sts) {
  const res = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': VR_UA,
      'X-Youtube-Client-Name': '28',
      'X-Youtube-Client-Version': '1.65.10',
      Origin: 'https://www.youtube.com',
      ...(visitorData ? { 'X-Goog-Visitor-Id': visitorData } : {}),
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
      videoId: VIDEO,
      playbackContext: {
        contentPlaybackContext: {
          html5Preference: 'HTML5_PREF_WANTS',
          signatureTimestamp: sts,
        },
      },
      contentCheckOk: true,
      racyCheckOk: true,
    }),
  });
  const raw = await res.json();
  const adaptive = raw?.streamingData?.adaptiveFormats ?? [];
  const maxHeight = adaptive.reduce((m, f) => Math.max(m, f.height ?? 0), 0);
  return {
    status: raw?.playabilityStatus?.status ?? '?',
    reason: raw?.playabilityStatus?.reason ?? null,
    adaptive: adaptive.length,
    maxHeight,
    pass: adaptive.length > 0 && maxHeight >= 1080,
  };
}

async function main() {
  Platform.shim.eval = (code) => {
    const text = typeof code === 'string' ? code : code.output;
    return vm.runInNewContext(`(function() { ${text} })()`, {});
  };
  await mkdir(OUT, { recursive: true });

  console.log(`${C.b}Spike 03 / Q1d — X-Goog-Visitor-Id held as the only variable${C.x}`);
  console.log(`${C.d}${new Date().toISOString()}  video=${VIDEO}  rounds=${ROUNDS}${C.x}\n`);

  const tally = { none: [], local: [], server: [] };

  for (let round = 0; round < ROUNDS; round++) {
    const boot = await watchPage(VIDEO);
    const local = await localVisitor();

    const cases = [
      ['none', null],
      ['local', local],
      ['server', boot.visitorData],
    ];
    if (round % 2 === 1) cases.reverse();

    console.log(`${C.b}round ${round + 1}${C.x}  ${C.d}sts=${boot.sts} local=${local?.length}ch server=${boot.visitorData?.length}ch${C.x}`);
    for (const [label, visitor] of cases) {
      const s = await player(visitor, boot.sts);
      tally[label].push(s);
      const flag = s.pass ? `${C.g}PASS${C.x}` : `${C.r}FAIL${C.x}`;
      console.log(
        `  ${flag}  visitor=${label.padEnd(7)} status=${String(s.status).padEnd(14)} ` +
          `adaptive=${String(s.adaptive).padStart(3)} max=${String(s.maxHeight).padStart(4)}p` +
          (s.reason ? `  ${C.y}${s.reason}${C.x}` : ''),
      );
      await sleep(1200);
    }
  }

  console.log(`\n${C.b}Tally over ${ROUNDS} rounds${C.x}`);
  for (const [label, runs] of Object.entries(tally)) {
    const passes = runs.filter((r) => r.pass).length;
    const tone = passes === runs.length ? C.g : passes === 0 ? C.r : C.y;
    console.log(`  ${tone}${passes}/${runs.length}${C.x}  visitor=${label}`);
  }

  await writeFile(new URL('q1d-tally.json', OUT), JSON.stringify(tally, null, 2));
}

main().catch((e) => {
  console.error(`\n${C.r}${e.stack}${C.x}`);
  process.exit(1);
});
