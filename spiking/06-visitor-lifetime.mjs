#!/usr/bin/env node
/**
 * Task 06 — how long does one server-issued visitor id stay good?
 *
 * Spike 03 left this open, and it decides where the id is cached: a
 * session-scoped mint, or a round trip on every `playback.open`. The brief is
 * explicit that the number has to be measured rather than guessed.
 *
 * Design — one session, one variable. Every request goes through the same
 * youtubei.js session (same sts, same headers, same client override); the only
 * thing that changes between the two calls in a round is
 * `session.context.client.visitorData`, which is the field the sidecar's
 * `refreshVisitorId` mutates. So:
 *
 *   reused — the id minted once at the start, used for every round
 *   fresh  — a newly minted server-issued id, in the same minute
 *
 * The control matters. Spike 03 spent a whole run concluding "headers" because a
 * burnt id and a rate-limited machine look identical from one variant. If both
 * columns fail at the same time it is not the id's age.
 *
 * Two phases: a burst (does *reuse count* burn it?) and a slow tail (does *age*
 * burn it?).
 *
 *   node 06-visitor-lifetime.mjs [videoId] [burstRounds] [burstDelayS] [tailRounds] [tailDelayS]
 */

import { Innertube, Platform } from 'youtubei.js';
import { mkdir, writeFile } from 'node:fs/promises';
import vm from 'node:vm';

const VIDEO = process.argv[2] || 'aqz-KE-bpKQ';
const BURST_ROUNDS = Number(process.argv[3] || 10);
const BURST_DELAY_S = Number(process.argv[4] || 5);
const TAIL_ROUNDS = Number(process.argv[5] || 12);
const TAIL_DELAY_S = Number(process.argv[6] || 90);
const OUT = new URL('./06-out/', import.meta.url);

const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

Platform.shim.eval = (code) => {
  const text = typeof code === 'string' ? code : code.output;
  return vm.runInNewContext(`(function() { ${text} })()`, {});
};

/** A session that fetches its visitor id from YouTube — `generate_session_locally: false`. */
async function serverSession({ retrievePlayer }) {
  return Innertube.create({
    client_type: 'MWEB',
    device_category: 'desktop',
    retrieve_player: retrievePlayer,
    enable_session_cache: false,
    generate_session_locally: false,
    fail_fast: true,
  });
}

async function mintVisitorId() {
  const yt = await serverSession({ retrievePlayer: false });
  return yt.session.context.client.visitorData ?? null;
}

/** One ANDROID_VR /player call through `yt`, carrying `visitorId`. */
async function resolve(yt, visitorId) {
  yt.session.context.client.visitorData = visitorId;

  let raw;
  try {
    const response = await yt.actions.execute('/player', {
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
    raw = response?.data ?? response;
  } catch (error) {
    raw = { playabilityStatus: { status: 'REQUEST_FAILED', reason: error.message } };
  }

  const adaptive = raw?.streamingData?.adaptiveFormats ?? [];
  const maxHeight = adaptive.reduce((m, f) => Math.max(m, f.height ?? 0), 0);
  const withUrl = adaptive.filter((f) => f.url).length;
  const withN = adaptive.filter((f) => /[?&]n=/.test(f.url ?? '')).length;

  return {
    status: raw?.playabilityStatus?.status ?? '?',
    reason: raw?.playabilityStatus?.reason ?? null,
    adaptive: adaptive.length,
    withUrl,
    withN,
    maxHeight,
    ok: adaptive.length > 0 && withUrl === adaptive.length && maxHeight >= 1080,
  };
}

async function main() {
  await mkdir(OUT, { recursive: true });

  console.log(`${C.b}Task 06 — visitor id lifetime${C.x}`);
  console.log(
    `${C.d}${new Date().toISOString()}  video=${VIDEO}  ` +
      `burst=${BURST_ROUNDS}×${BURST_DELAY_S}s  tail=${TAIL_ROUNDS}×${TAIL_DELAY_S}s${C.x}\n`,
  );

  const yt = await serverSession({ retrievePlayer: true });
  const mintedAt = Date.now();
  const reusedId = yt.session.context.client.visitorData;
  console.log(
    `${C.d}session sts=${yt.session.player?.signature_timestamp} ` +
      `visitor=${reusedId?.length}ch (server-issued)${C.x}\n`,
  );

  const attempts = [];

  const round = async (phase, index) => {
    const elapsedMs = Date.now() - mintedAt;

    const reused = await resolve(yt, reusedId);
    attempts.push({ phase, index, which: 'reused', elapsedMs, uses: index + 1, ...reused });
    await sleep(2000);

    const freshId = await mintVisitorId();
    const fresh = await resolve(yt, freshId);
    attempts.push({ phase, index, which: 'fresh', elapsedMs: Date.now() - mintedAt, ...fresh });

    const flag = (r) => (r.ok ? `${C.g}PASS${C.x}` : `${C.r}FAIL${C.x}`);
    const minutes = (elapsedMs / 60000).toFixed(1);
    console.log(
      `${phase} ${String(index + 1).padStart(2)}  t+${minutes.padStart(5)}m  ` +
        `reused ${flag(reused)} ${String(reused.status).padEnd(14)} ` +
        `${String(reused.adaptive).padStart(3)}fmt ${String(reused.maxHeight).padStart(4)}p  │  ` +
        `fresh ${flag(fresh)} ${String(fresh.status).padEnd(14)} ` +
        `${String(fresh.adaptive).padStart(3)}fmt` +
        (reused.reason ? `  ${C.y}${reused.reason}${C.x}` : ''),
    );
  };

  for (let i = 0; i < BURST_ROUNDS; i++) {
    await round('burst', i);
    if (i < BURST_ROUNDS - 1) await sleep(BURST_DELAY_S * 1000);
  }
  console.log('');
  for (let i = 0; i < TAIL_ROUNDS; i++) {
    await sleep(TAIL_DELAY_S * 1000);
    await round('tail ', i);
  }

  // -------------------------------------------------------------------------

  const reused = attempts.filter((a) => a.which === 'reused');
  const fresh = attempts.filter((a) => a.which === 'fresh');
  const firstFailure = reused.find((a) => !a.ok) ?? null;
  const consecutive = reused.findIndex((a) => !a.ok);

  const summary = {
    video: VIDEO,
    mintedAt: new Date(mintedAt).toISOString(),
    visitorIdLength: reusedId?.length ?? null,
    reusedPasses: `${reused.filter((a) => a.ok).length}/${reused.length}`,
    freshPasses: `${fresh.filter((a) => a.ok).length}/${fresh.length}`,
    consecutiveReusesBeforeFirstFailure: consecutive === -1 ? reused.length : consecutive,
    survivedMinutes: Number(((reused.at(-1)?.elapsedMs ?? 0) / 60000).toFixed(1)),
    firstFailure: firstFailure
      ? {
          uses: firstFailure.uses,
          minutes: Number((firstFailure.elapsedMs / 60000).toFixed(1)),
          status: firstFailure.status,
          reason: firstFailure.reason,
        }
      : null,
    // Both columns failing together is a machine-level refusal, not an aged id.
    plainUrlsOnEveryPass: reused.filter((a) => a.ok).every((a) => a.withN === 0),
  };

  console.log(`\n${C.b}Summary${C.x}`);
  for (const [key, value] of Object.entries(summary)) {
    console.log(`  ${String(key).padEnd(36)} ${JSON.stringify(value)}`);
  }

  await writeFile(
    new URL('06-visitor-lifetime.json', OUT),
    JSON.stringify({ summary, attempts }, null, 2),
  );
  console.log(`\n${C.d}→ spiking/06-out/06-visitor-lifetime.json${C.x}`);
}

main().catch((error) => {
  console.error(`\n${C.r}${error.stack}${C.x}`);
  process.exit(1);
});
