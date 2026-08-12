/**
 * Network tests — the point of the decipher task.
 *
 * Everything else in the suite runs offline against fixtures. These two cannot,
 * and substituting a fixture for either of them would be substituting an
 * assumption for the finding:
 *
 *   1. **Sustained throughput.** A wrongly-deciphered `n` is present,
 *      well-formed, and throttled to ~50 KB/s. No offline assertion can tell it
 *      from a correct one — only pulling bytes can. This is the only test that
 *      proves the decipher path works.
 *
 *   2. **`signatureTimestamp` is mandatory.** Omitting it returns `UNPLAYABLE —
 *      "The page needs to be reloaded."`, which reads like a dead or
 *      region-locked video and is not (hard invariant 7). Pinning both halves
 *      means nobody has to re-learn it from a confusing bug report.
 *
 * No cookie required: streams resolve through an anonymous session (§2.3),
 * asking as `ANDROID_VR` at tier 1 and `MWEB` at tier 2. What that session does
 * need is a server-issued visitor id, which is `createSession`'s default and the
 * first thing to check if tier 1 starts declining (F5).
 *
 * Opt-in: these run only under `bun run test:network` (`RUN_NETWORK_TESTS=1`),
 * because they are real requests and ~24 MB of traffic. Understand what is
 * being skipped the rest of the time — with these off, a completely broken
 * decipher path is a green suite.
 */

import { beforeAll, describe, expect, test } from 'bun:test';
import { Platform } from 'youtubei.js';
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { resolveYtDlp } from '../src/capabilities.ts';
import { logger } from '../src/log.ts';
import { createSession, type Session } from '../src/innertube/session.ts';
import { getPlayer, rebuildPlayer } from '../src/innertube/player.ts';
import { sign } from '../src/innertube/signed-url.ts';
import { parsePlayer } from '../src/parser/index.ts';
import {
  openPlayback,
  tierPlainAdaptive,
  tierProgressive,
  tierYtDlp,
} from '../src/playback/resolve.ts';
import { forgetPlayerResponse, getPlayerResponse } from '../src/innertube/player-response.ts';
import { isSabrOnly } from '../src/playback/sabr-detect.ts';
import { playbackSessionCount, resetPlaybackSessions } from '../src/playback/sessions.ts';
import { forgetStoryboards, getStoryboard } from '../src/video/storyboard.ts';

/**
 * Can this machine reach YouTube at all?
 *
 * `SIDECAR_SKIP_NETWORK=1` is the deliberate opt-out. This probe is the other
 * case: a clean checkout on a machine with no route out should skip these, not
 * report a broken decipher path it never tested. The distinction that matters
 * is *unreachable* versus *reachable and wrong* — only the first is a skip, so
 * the probe asks the cheapest possible question and lets everything else fail
 * loudly as before.
 *
 * `robots.txt` because it is small, unauthenticated, and not a InnerTube
 * endpoint — a 200 here says the network works, nothing about the API.
 */
async function youtubeReachable(): Promise<boolean> {
  try {
    const response = await fetch('https://www.youtube.com/robots.txt', {
      method: 'HEAD',
      signal: AbortSignal.timeout(5000),
    });
    return response.ok;
  } catch {
    return false;
  }
}

/**
 * Live tests are opt-in.
 *
 * They issue real requests to YouTube and pull ~12 MB twice to measure
 * sustained throughput — roughly 19 s. Someone who has just cloned the repo and
 * typed `bun test` has not asked for that, and defaulting to it spends their
 * bandwidth, appends to the tripwire history, and puts this machine's traffic
 * in front of YouTube without anyone deciding to. `bun run test:network` (or
 * `RUN_NETWORK_TESTS=1`) is that decision.
 */
const REQUESTED = process.env['RUN_NETWORK_TESTS'] === '1';
const ONLINE = REQUESTED && (await youtubeReachable());

if (!ONLINE) {
  console.warn(
    REQUESTED
      ? '[network] youtube.com is unreachable — skipping the live tests.'
      : '[network] skipped (opt-in) — run `bun run test:network` to include them.',
    'These are the only tests that prove the decipher path: a wrongly-deciphered' +
      ' n is well-formed and throttles to ~50 KB/s, which no offline assertion can' +
      ' detect. With them skipped, a completely broken decipher path is a green suite.',
  );
}

/** stderr, like everything else — hard invariant 3 applies to the suite too. */
const log = logger('network-test');

/**
 * Where the Phase 2 tripwire writes what it saw.
 *
 * A rollout is a rate, and a rate is invisible from one run: the 2026-08-02
 * sighting was one response in ~17, which is indistinguishable from noise until
 * you have the denominator. So **every** execution is appended, not just the
 * ones that saw SABR — a file containing only sightings can say "it happened
 * four times" and never "four times out of how many".
 *
 * It lives in the per-user state directory, **not** in the checkout. The
 * observation is about what YouTube served *this machine*, so its natural unit
 * is the machine: a second clone on the same box must extend the same history,
 * and a clone on a different box must start its own. Keeping it in the repo
 * gave one history per working copy, which is the one arrangement that makes
 * the number meaningless — two files of 92 and 1 runs answer no question that
 * a single file of 93 does not answer better, and they silently disagree about
 * the denominator.
 *
 * `NY_TRIPWIRE_LOG` overrides the location, for a throwaway run that should not
 * touch the real history.
 */
function tripwirePath(): string {
  const override = process.env['NY_TRIPWIRE_LOG'];
  if (override) return override;

  const home = homedir();
  const dir =
    process.platform === 'win32'
      ? join(process.env['LOCALAPPDATA'] ?? join(home, 'AppData', 'Local'), 'NativeYouTube')
      : process.platform === 'darwin'
        ? join(home, 'Library', 'Application Support', 'NativeYouTube')
        : join(process.env['XDG_STATE_HOME'] ?? join(home, '.local', 'state'), 'native-youtube');

  return join(dir, 'tripwire-mweb-sabr.ndjson');
}

const TRIPWIRE_LOG = tripwirePath();

/** The in-repo location this used to write to, kept only to migrate off it. */
const LEGACY_TRIPWIRE_LOG = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'tripwire-mweb-sabr.ndjson',
);

/**
 * Fold a checkout-local history into the machine-level one, once.
 *
 * Appends rather than replaces: on a machine with two checkouts, both partial
 * histories are real observations of the same machine and both belong in the
 * total. The legacy file is renamed rather than deleted — it is unreproducible
 * observational data, and a migration that eats it on a bad day is worse than
 * one that leaves a stray file behind. Renaming is also what makes this run
 * once: the second run finds nothing to migrate.
 *
 * Never throws, for the same reason `recordTripwire` never throws.
 */
function migrateLegacyTripwire(): void {
  try {
    if (!existsSync(LEGACY_TRIPWIRE_LOG)) return;
    mkdirSync(dirname(TRIPWIRE_LOG), { recursive: true });
    const legacy = readFileSync(LEGACY_TRIPWIRE_LOG, 'utf8');
    if (legacy.trim() !== '') {
      appendFileSync(TRIPWIRE_LOG, legacy.endsWith('\n') ? legacy : `${legacy}\n`, 'utf8');
    }
    renameSync(LEGACY_TRIPWIRE_LOG, `${LEGACY_TRIPWIRE_LOG}.migrated`);
    log.info(
      `migrated ${legacy.split('\n').filter((l) => l.trim() !== '').length} tripwire ` +
        `entries from the checkout into ${TRIPWIRE_LOG}`,
    );
  } catch (error) {
    log.warn(`could not migrate the legacy tripwire log: ${(error as Error).message}`);
  }
}

interface TripwireEntry {
  at: string;
  video: string;
  samples: boolean[];
  sabrCount: number;
}

/**
 * Append this run and return the rate so far, or `null` if the file cannot be
 * used.
 *
 * Never throws. This is a diagnostic; a read-only checkout or a locked file must
 * not turn into a failing suite, which would invert the whole point of it.
 */
function recordTripwire(samples: boolean[], sabrCount: number): string | null {
  const entry: TripwireEntry = {
    at: new Date().toISOString(),
    video: VIDEO,
    samples,
    sabrCount,
  };

  try {
    migrateLegacyTripwire();
    mkdirSync(dirname(TRIPWIRE_LOG), { recursive: true });
    appendFileSync(TRIPWIRE_LOG, `${JSON.stringify(entry)}\n`, 'utf8');
  } catch (error) {
    log.warn(`could not record the tripwire result: ${(error as Error).message}`);
    return null;
  }

  try {
    const entries = readFileSync(TRIPWIRE_LOG, 'utf8')
      .split('\n')
      .filter((line) => line.trim() !== '')
      // A malformed line is skipped rather than fatal — same rule as the parser.
      .flatMap((line): TripwireEntry[] => {
        try {
          return [JSON.parse(line) as TripwireEntry];
        } catch {
          return [];
        }
      });

    const runs = entries.length;
    const runsWithSabr = entries.filter((e) => e.sabrCount > 0).length;
    const totalSamples = entries.reduce((sum, e) => sum + e.samples.length, 0);
    const sabrSamples = entries.reduce((sum, e) => sum + e.sabrCount, 0);
    const since = entries[0]?.at ?? entry.at;

    return (
      `${runsWithSabr}/${runs} runs and ${sabrSamples}/${totalSamples} samples SABR-only ` +
      `since ${since} — ${TRIPWIRE_LOG}`
    );
  } catch (error) {
    log.warn(`could not read back the tripwire history: ${(error as Error).message}`);
    return null;
  }
}

/**
 * Tier 4's binary, if this machine has one.
 *
 * yt-dlp is an optional fallback, not a dependency, so its absence skips rather
 * than fails — with the usual caveat about skipped tests: on a machine without
 * it, tier 4 is entirely unproven and the ladder is effectively four rungs.
 *
 * Resolved through `capabilities.ts`, the same lookup the startup warning and
 * `tierYtDlp` use. A private copy here could decide the binary exists while the
 * sidecar decides it does not, and the test would then skip or fail for reasons
 * that have nothing to do with YouTube.
 */
const YT_DLP: string | null = resolveYtDlp();

/** Long, public, not age-restricted, and 4K — so a quality regression shows. */
const VIDEO = process.env['YT_VIDEO_STANDARD'] ?? 'aqz-KE-bpKQ';

/** 12 MB is enough to see the throttle; at 50 KB/s it would take four minutes. */
const SAMPLE_BYTES = 12 * 1024 * 1024;
/** Above this is unambiguously unthrottled. The spike measured 4.0 MB/s (F4). */
const HEALTHY_MBPS = 1.5;

const MINUTE = 60_000;

let session: Session;

beforeAll(async () => {
  if (!ONLINE) return;
  session = await createSession({ clientType: 'MWEB' });
});

/**
 * A sprite sheet's pixel dimensions, from the file header — JPEG *or* WebP, because the format
 * is not ours to pin: the same video's level 0 answered `image/webp` on 2026-08-01 and
 * `image/jpeg` on 2026-08-11, differing only in the `sqp` YouTube minted. An unrecognised header
 * returns nulls so the assertion fails loudly rather than comparing `undefined` to a grid.
 */
function imageSize(bytes: Uint8Array): [number | null, number | null] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

  // JPEG: walk the marker segments to the frame header, which is the only place
  // the dimensions live.
  if (bytes[0] === 0xff && bytes[1] === 0xd8) {
    let i = 2;
    while (i + 9 < bytes.byteLength) {
      if (bytes[i] !== 0xff) break;
      const marker = bytes[i + 1]!;
      // SOF0..SOF15, minus the three that are not frame headers (DHT, JPG, DAC).
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return [view.getUint16(i + 7), view.getUint16(i + 5)];
      }
      i += 2 + view.getUint16(i + 2);
    }
    return [null, null];
  }

  if (String.fromCharCode(...bytes.subarray(0, 4)) === 'RIFF' && bytes.byteLength >= 30) {
    const fourcc = String.fromCharCode(...bytes.subarray(12, 16));
    if (fourcc === 'VP8 ') return [view.getUint16(26, true) & 0x3fff, view.getUint16(28, true) & 0x3fff];
    if (fourcc === 'VP8X') {
      const read24 = (at: number) => bytes[at]! | (bytes[at + 1]! << 8) | (bytes[at + 2]! << 16);
      return [read24(24) + 1, read24(27) + 1];
    }
  }

  return [null, null];
}

interface Throughput {
  mbps: number;
  received: number;
  seconds: number;
  status: number;
}

async function measure(url: string): Promise<Throughput> {
  const started = Date.now();
  let received = 0;

  const response = await fetch(url, { headers: { range: `bytes=0-${SAMPLE_BYTES - 1}` } });
  if (!response.ok && response.status !== 206) {
    return { mbps: 0, received: 0, seconds: 0, status: response.status };
  }

  for await (const chunk of response.body!) {
    received += chunk.length;
    if (received >= SAMPLE_BYTES) break;
  }

  const seconds = (Date.now() - started) / 1000;
  return { mbps: received / 1024 / 1024 / seconds, received, seconds, status: response.status };
}

// ---------------------------------------------------------------------------

describe.if(ONLINE)('the resolution session', () => {
  test('carries a server-issued visitor id, not a fabricated one', () => {
    // F5: a fabricated id is 32 characters and gets ANDROID_VR refused on ~93%
    // of attempts; a server-issued one is ~558 and passed 13/13. youtubei.js
    // falls back to fabricating one when `/sw.js_data` fails and does not raise,
    // so this is the assertion that says which one we actually got.
    expect(session.visitorId).toBeString();
    expect(session.visitorId!.length).toBeGreaterThan(64);
  });
});

// ---------------------------------------------------------------------------

describe.if(ONLINE)('tier 1 — ANDROID_VR', () => {
  test(
    'a real video resolves to two plain URLs, with no n on either',
    async () => {
      const source = await openPlayback({ session }, { videoId: VIDEO });
      const best = source.variants[0]!;

      expect(source.transport).toBe('plain');
      expect(best.videoUrl).toStartWith('https://');
      expect(best.audioUrl).toStartWith('https://');
      expect(source.qualityDegraded).toBe(false);
      expect(best.height).toBeGreaterThanOrEqual(1080);

      // Which tier served is not on the DTO — `transport` is 'plain' for tiers 1
      // and 2 alike — but YouTube stamps the requesting client into the URL, so
      // `c=` is the honest way to ask. Anything else here means tier 1 declined
      // and something below it served, which the ladder does silently by design.
      for (const url of [best.videoUrl, best.audioUrl!]) {
        const parsed = new URL(url);
        expect(parsed.searchParams.get('c')).toBe('ANDROID_VR');
        // The point of the reorder: no `n` on the primary path, so the silent
        // ~50 KB/s throttle cannot happen there at all.
        expect(parsed.searchParams.has('n')).toBe(false);
      }

      expect(source.durationMs).toBeGreaterThan(0);
      expect(source.storyboardTemplate).toStartWith('http');
    },
    2 * MINUTE,
  );

  test(
    'sustained throughput is above the bar',
    async () => {
      const source = await openPlayback({ session }, { videoId: VIDEO });
      const result = await measure(source.variants[0]!.videoUrl);

      // Say what happened before asserting — a bare `expect(mbps).toBeGreaterThan`
      // failure tells you nothing about whether it was slow or refused.
      const detail =
        `HTTP ${result.status}, ${(result.received / 1024 / 1024).toFixed(1)} MB in ` +
        `${result.seconds.toFixed(1)}s = ${result.mbps.toFixed(2)} MB/s`;

      expect({ detail, ok: result.status === 206 || result.status === 200 }).toEqual({
        detail,
        ok: true,
      });
      expect(result.received).toBeGreaterThanOrEqual(SAMPLE_BYTES);
      expect({ detail, healthy: result.mbps > HEALTHY_MBPS }).toEqual({ detail, healthy: true });
    },
    5 * MINUTE,
  );

  test(
    'an open-ended range is answered — the F10 property that made this tier 1',
    async () => {
      // ffmpeg opens every HTTP stream with `Range: bytes=0-`. An `MWEB` URL
      // answers that with 403 at every offset (F10); an `ANDROID_VR` URL answers
      // 206 (F11), and that single difference is why the ladder was reordered.
      // If it ever regresses, playback breaks in libmpv while every other test
      // here stays green, because a bounded range keeps working.
      //
      // Two attempts, five seconds apart, each on a freshly resolved URL — not
      // to make a red test green, but because the claim is about this *class* of
      // URL and a single refusal is not evidence the class changed. A real
      // regression 403s every attempt and still fails here.
      //
      // The history, because the numbers matter more than the conclusion: on
      // 2026-08-02 this failed 2 live runs in ~20, and the one captured in full
      // 403'd both attempts ~200 ms apart — a window, not a coin flip. It never
      // reproduced deliberately: 28/28 open-ended requests answered 206 across
      // fresh URLs, URLs that had already served 12 MB, and back-to-back /
      // 1 s / 4 s spacings. The cause was never identified. What changed after
      // that was this probe: it now aborts as soon as the status line arrives
      // instead of cancelling a 712 MB body, and 12 consecutive live runs have
      // been clean. Suggestive, not conclusive — at the old ~10% rate, 12 clean
      // runs happen by chance about a quarter of the time.
      // Only the status line is wanted, and the response behind it is the whole
      // 712 MB file. Abort as soon as the headers land rather than cancelling
      // the body afterwards: `body.cancel()` on a response that size left Bun
      // 1.3.14 buffering it — two probe scripts here died with
      // `panic: Out of memory while copying request body` — and a client
      // half-abandoning a multi-hundred-megabyte stream repeatedly is also the
      // most plausible thing we were doing to earn a refusal.
      const statuses: number[] = [];

      for (let attempt = 0; attempt < 2 && !statuses.includes(206); attempt++) {
        // A fresh URL per attempt: the cached /player response is shared with
        // the throughput test above, and a retry on the same URL would be a
        // weaker question than the one being asked.
        forgetPlayerResponse(VIDEO);
        const source = await openPlayback({ session }, { videoId: VIDEO });

        const abort = new AbortController();
        try {
          const response = await fetch(source.variants[0]!.videoUrl, {
            headers: { range: 'bytes=0-' },
            signal: abort.signal,
          });
          statuses.push(response.status);
        } finally {
          abort.abort();
        }

        if (!statuses.includes(206) && attempt === 0) await Bun.sleep(5_000);
      }

      if (statuses[0] !== 206) {
        log.warn(
          `an ANDROID_VR URL answered HTTP ${statuses[0]} to an open-ended range; ` +
            `retry gave ${statuses[1] ?? '(not attempted)'}. One-off refusals are known ` +
            '(2026-08-02); a persistent one means F11 no longer holds and the ladder ' +
            'is serving URLs libmpv cannot open.',
        );
      }

      expect({ statuses, accepted: statuses.includes(206) }).toEqual({ statuses, accepted: true });
    },
    3 * MINUTE,
  );

  test(
    'the audio track streams too — mpv gets two working URLs',
    async () => {
      const source = await openPlayback({ session }, { videoId: VIDEO });
      const response = await fetch(source.variants[0]!.audioUrl!, { headers: { range: 'bytes=0-262143' } });
      expect([200, 206]).toContain(response.status);
      expect((await response.arrayBuffer()).byteLength).toBeGreaterThan(0);
    },
    2 * MINUTE,
  );
});

// ---------------------------------------------------------------------------

describe.if(ONLINE)('tier 2 — MWEB, and the decipher path', () => {
  test(
    'a deciphered n streams unthrottled',
    async () => {
      // With `ANDROID_VR` leading, nothing on the default path deciphers
      // anything — so this is the only test that proves the `n` transform
      // lands, and hard invariant 2 has no other live evidence. It is called
      // directly rather than through `openPlayback`, because the ladder is
      // supposed to never reach it.
      //
      // The adaptive ladder is the preferred subject, but on 2026-08-02 one
      // response in ~17 came back SABR-only (see the tripwire below). That must
      // not cost us the decipher evidence: a SABR-only response still carries a
      // working itag 18 (F9), and that URL still carries an `n`. So fall back to
      // the progressive format rather than skipping — the transform under test
      // is the same one, and a wrong `n` throttles it identically.
      forgetPlayerResponse(VIDEO);
      const response = await getPlayerResponse(session, VIDEO, 'MWEB');

      let source;
      if (isSabrOnly(response)) {
        log.warn(
          'MWEB came back SABR-only; proving the decipher path on the itag 18 ' +
            'progressive URL instead (F9). The tripwire test is the one to read.',
        );
        source = await tierProgressive({ session }, VIDEO, null, response);
      } else {
        source = await tierPlainAdaptive({ session }, VIDEO, 'MWEB', null, response);
      }

      const url = new URL(source.variants[0]!.videoUrl);
      expect(url.searchParams.get('c')).toBe('MWEB');
      expect(url.searchParams.get('n')).toBeString();

      // A bounded range, because F10: `MWEB` refuses the open-ended kind. That
      // refusal is about request shape and does not touch throughput — a wrong
      // `n` is served, at ~50 KB/s, and only pulling bytes can tell them apart.
      const result = await measure(source.variants[0]!.videoUrl);
      const detail =
        `HTTP ${result.status}, ${(result.received / 1024 / 1024).toFixed(1)} MB in ` +
        `${result.seconds.toFixed(1)}s = ${result.mbps.toFixed(2)} MB/s`;

      expect({ detail, ok: result.status === 206 || result.status === 200 }).toEqual({
        detail,
        ok: true,
      });
      // If this lands near 0.05 MB/s the `n` transform is wrong, not the
      // network: check that the player cache is keyed by playerId and that the
      // node:vm shim is executing the current player JS before suspecting
      // anything else.
      expect({ detail, healthy: result.mbps > HEALTHY_MBPS }).toEqual({ detail, healthy: true });
    },
    5 * MINUTE,
  );
});

// ---------------------------------------------------------------------------

describe.if(ONLINE)('signatureTimestamp (hard invariant 7)', () => {
  test(
    'omitting it returns UNPLAYABLE; including it returns streaming data',
    async () => {
      // Deliberately the bare payload — no playbackContext, no sts. This is the
      // request everyone writes first.
      const without = parsePlayer(await session.execute('/player', { videoId: VIDEO }));

      // The invariant: a malformed request comes back as an unplayable video
      // with nothing to stream. Both halves are YouTube's contract with us and
      // are asserted hard.
      expect(without.playabilityStatus).toBe('UNPLAYABLE');
      expect(without.formats).toEqual([]);

      // The reason is the trap — "The page needs to be reloaded." reads like a
      // broken video rather than a missing `signatureTimestamp`, which is the
      // whole hazard hard invariant 7 exists to name. But the wording is
      // YouTube's, not a contract, and it is not stable: on 2026-08-02 one live
      // run answered `UNPLAYABLE — "Video unavailable"` to this same request.
      //
      // That was not reproducible: 8 attempts on a fresh server-visitor session,
      // 8 on a fabricated-visitor one in the same minute, and 25 more after five
      // `openPlayback` calls all returned the reload wording — 0/41. The run it
      // did appear in was the first with `yt-dlp` hitting the same video from
      // the same IP in the same seconds, so the working hypothesis is a
      // transient soft-block of the anonymous caller on the most bot-like
      // request in the suite. Unproven, and one observation.
      //
      // So: warn, do not fail. A wording change is worth knowing about — it
      // would mean the trap now reads differently and the docs describing it
      // have drifted — but it is not evidence that the sidecar broke, and
      // failing on it costs a red suite roughly one live run in six.
      if (!/reload/i.test(without.playabilityReason ?? '')) {
        log.warn(
          'the sts-less /player reason has changed wording: expected ' +
            '"The page needs to be reloaded." (or "Video unavailable", seen once on ' +
            `2026-08-02), got "${without.playabilityReason ?? '(none)'}". ` +
            'Hard invariant 7 still holds — status and formats asserted above — but ' +
            'if this becomes the usual answer, the wording in CLAUDE.md, ' +
            'architecture.md and resolve.ts is now stale.',
        );
      }

      const player = await getPlayer(session);
      const withSts = parsePlayer(
        await session.execute('/player', {
          videoId: VIDEO,
          contentCheckOk: true,
          racyCheckOk: true,
          playbackContext: {
            contentPlaybackContext: {
              vis: 0,
              splay: false,
              lactMilliseconds: '-1',
              signatureTimestamp: player.signatureTimestamp,
            },
          },
        }),
      );

      expect(withSts.playabilityStatus).toBe('OK');
      expect(withSts.formats.length).toBeGreaterThan(0);
    },
    2 * MINUTE,
  );
});

// ---------------------------------------------------------------------------

describe.if(ONLINE)('ladder tier 5 — itag 18 progressive', () => {
  test(
    'the floor signs and streams',
    async () => {
      // The rung nothing falls past. In normal operation it never runs, so a
      // break here would only ever show up on a video the tiers above already
      // refused — the worst possible time to discover it.
      //
      // One retry on a fresh response, because on 2026-08-02 one run in ~5 got
      // an MWEB response carrying no progressive format at all and tier 5 threw
      // "no progressive format either". That did not reproduce: 14/14 controlled
      // MWEB fetches in the same hour carried itag 18 with an address. It is the
      // third shape of intermittently-degraded MWEB response seen that day — see
      // F3 and F9 — and the floor genuinely being gone is what this test has to
      // keep catching, so a second empty response still fails.
      let response = await getPlayerResponse(session, VIDEO, 'MWEB');
      if (!response.formats.some((format) => !format.isAdaptive)) {
        log.warn(
          'the MWEB response carried no progressive format — F9 says itag 18 survives ' +
            'even a SABR-only response. Re-fetching once before calling the floor gone.',
        );
        forgetPlayerResponse(VIDEO);
        response = await getPlayerResponse(session, VIDEO, 'MWEB');
      }

      const source = await tierProgressive({ session }, VIDEO, null, response);
      const best = source.variants[0]!;

      expect(best.height).toBe(360);
      expect(best.audioUrl).toBeNull(); // muxed: one URL, no --audio-file
      expect(source.qualityDegraded).toBe(true);
      // A muxed format lists both codecs in one string; they must land in the
      // right two fields, not both in one.
      expect(best.videoCodec).toStartWith('avc1');
      expect(best.audioCodec).toStartWith('mp4a');

      const fetched = await fetch(best.videoUrl, { headers: { range: 'bytes=0-1048575' } });
      expect([200, 206]).toContain(fetched.status);
      expect((await fetched.arrayBuffer()).byteLength).toBeGreaterThan(0);
    },
    2 * MINUTE,
  );
});

// ---------------------------------------------------------------------------

describe.if(ONLINE && YT_DLP !== null)('ladder tier 4 — yt-dlp', () => {
  test(
    'resolves a real video to streamable URLs',
    async () => {
      // Tier 4 exists for the videos the plain tiers refuse — age-restricted,
      // Vevo — and
      // those cannot be used as a fixture. So this proves the mechanism on an
      // ordinary video instead: that the subprocess runs, that the dump maps to
      // a `PlaybackSource`, and that URLs deciphered by someone else's
      // implementation actually stream.
      const source = await tierYtDlp({ session, ytDlpPath: YT_DLP! }, VIDEO, null, null);
      const best = source.variants[0]!;

      expect(source.transport).toBe('ytdlp');
      expect(best.height).toBeGreaterThanOrEqual(1080);
      expect(source.durationMs).toBeGreaterThan(0);
      expect(best.videoUrl).toStartWith('https://');

      for (const url of [best.videoUrl, best.audioUrl].filter((u) => u !== null)) {
        const response = await fetch(url, { headers: { range: 'bytes=0-1048575' } });
        expect([200, 206]).toContain(response.status);
        expect((await response.arrayBuffer()).byteLength).toBeGreaterThan(0);
      }
    },
    3 * MINUTE,
  );
});

// ---------------------------------------------------------------------------

describe.if(ONLINE)('video.storyboard', () => {
  test(
    'resolves a real video without opening a session or resolving a stream',
    async () => {
      // Both claims are invisible from the result alone — a storyboard that quietly went through
      // the resolution ladder returns exactly the same spec. So count requests and sessions.
      forgetStoryboards();
      forgetPlayerResponse(VIDEO);
      resetPlaybackSessions();

      // Two things about this spy, each of which silently records *nothing* and leaves the
      // assertions below passing vacuously: it must go on `Platform.shim.fetch` rather than
      // `globalThis.fetch` (youtubei.js never reads the global), and it must be installed
      // *before* the session it watches, since `Innertube.create` captures the shim's fetch.
      // Hence a session of its own, with the log cleared once it is up. The
      // `toBeGreaterThan(0)` below guards against this arrangement quietly breaking again.
      const requested: string[] = [];
      const realFetch = Platform.shim.fetch;
      Platform.shim.fetch = ((input: Parameters<typeof fetch>[0], init?: RequestInit) => {
        requested.push(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
        return realFetch(input, init);
      }) as typeof Platform.shim.fetch;

      let result;
      try {
        const watched = await createSession({ clientType: 'MWEB' });
        requested.length = 0;
        result = await getStoryboard(watched, VIDEO);
      } finally {
        Platform.shim.fetch = realFetch;
      }

      // The spy has to see something, or every assertion below is vacuous.
      expect(requested.length).toBeGreaterThan(0);

      const spec = result.storyboard;
      expect(spec).not.toBeNull();
      expect(spec!.url).toStartWith('https://i.ytimg.com/sb/');
      expect(spec!.frameCount).toBeGreaterThan(0);
      expect(spec!.frameCount).toBeLessThanOrEqual(spec!.columns * spec!.rows);
      expect(spec!.intervalMs).toBeGreaterThan(0);

      // Phase 2's cap of 3 makes a preview that opened one a denial of service on the player.
      expect(playbackSessionCount()).toBe(0);

      // No stream resolution: nothing was asked of googlevideo, and no player
      // script was downloaded to decipher anything with.
      const stream = requested.filter((url) => url.includes('googlevideo.com'));
      const playerJs = requested.filter((url) => /\/s\/player\/|base\.js|iframe_api/.test(url));
      expect({ stream, playerJs }).toEqual({ stream: [], playerJs: [] });

      // One InnerTube call, the `/player` one `video.info` and tier 1 share. A second would be
      // the cost a hover preview is not allowed to have.
      const innertube = requested.filter((url) => url.includes('youtubei/v1/'));
      expect(innertube).toHaveLength(1);
      expect(innertube[0]).toContain('/player');
    },
    2 * MINUTE,
  );

  test(
    'the substituted URL fetches an image — not a URL that merely looks right',
    async () => {
      // A URL missing `sigh`, missing `sqp`, or with an unresolved `$M` passes every string
      // assertion in `storyboard.test.ts` and answers 403. Only pulling the bytes separates them.
      forgetStoryboards();
      const spec = (await getStoryboard(session, VIDEO)).storyboard!;

      const response = await fetch(spec.url);
      const bytes = new Uint8Array(await response.arrayBuffer());
      const contentType = response.headers.get('content-type') ?? '';
      const detail = `HTTP ${response.status} ${contentType} ${bytes.byteLength}B ${spec.url}`;

      expect({ detail, ok: response.status === 200 }).toEqual({ detail, ok: true });
      // `image/*` and deliberately neither one: which comes back has been observed to differ
      // between captures of the same video, so pinning either pins something untrue.
      expect({ detail, image: contentType.startsWith('image/') }).toEqual({ detail, image: true });

      // A sheet that is not `columns × frameWidth` puts every frame at the wrong offset, which
      // renders as a smear rather than an error.
      const size = imageSize(bytes);
      expect({ detail, size }).toEqual({
        detail,
        size: [spec.columns * spec.frameWidth, spec.rows * spec.frameHeight],
      });
    },
    2 * MINUTE,
  );

  test(
    'a re-hover costs no request at all',
    async () => {
      // `player-response.ts`'s own 5-minute TTL is not enough: a scroll back up an hour later is
      // the same gesture.
      forgetStoryboards();
      await getStoryboard(session, VIDEO);

      const requested: string[] = [];
      const realFetch = Platform.shim.fetch;
      Platform.shim.fetch = ((input: Parameters<typeof fetch>[0], init?: RequestInit) => {
        requested.push(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
        return realFetch(input, init);
      }) as typeof Platform.shim.fetch;

      try {
        // Past the underlying TTL too, so this is genuinely the storyboard cache answering.
        forgetPlayerResponse(VIDEO);
        const again = await getStoryboard(session, VIDEO);
        expect(again.storyboard).not.toBeNull();
      } finally {
        Platform.shim.fetch = realFetch;
      }

      expect(requested).toEqual([]);
    },
    2 * MINUTE,
  );
});

// ---------------------------------------------------------------------------

describe.if(ONLINE)('the player revision rollout branch', () => {
  test(
    'a rebuilt player deciphers as well as the adopted one',
    async () => {
      // `getPlayer` normally adopts the player the session already downloaded.
      // The rebuild path fires only past the TTL, once YouTube has shipped a new
      // revision — so without this test its first ever execution would be on a
      // user's machine, on the day a mistake there brings the throttle back.
      //
      // It costs a ~2 MB download and a full JS analysis. That is the price of
      // the branch not being theoretical.
      const adopted = await getPlayer(session);
      const rebuilt = await rebuildPlayer(session, adopted.playerId);

      expect(rebuilt.playerId).toBe(adopted.playerId);
      expect(rebuilt.signatureTimestamp).toBe(adopted.signatureTimestamp);

      // Same input, both players, same answer — and not the input itself.
      const raw = 'https://r1.googlevideo.com/videoplayback?itag=315&c=MWEB&n=SJgdj5tYRJi06z7';
      const fromAdopted = new URL(await sign(raw, adopted)).searchParams.get('n');
      const fromRebuilt = new URL(await sign(raw, rebuilt)).searchParams.get('n');

      expect(fromRebuilt).toBe(fromAdopted!);
      expect(fromRebuilt).not.toBe('SJgdj5tYRJi06z7');
    },
    3 * MINUTE,
  );
});

// ---------------------------------------------------------------------------

describe.if(ONLINE)('the Phase 2 tripwire, live', () => {
  test(
    'MWEB still serves plain adaptive URLs',
    async () => {
      // The fixture assertion in playback.test.ts says this was true when the
      // corpus was captured. This one says it is true now. When it stops being
      // true, the SABR → DASH bridge has stopped being deferrable — and this is
      // how we find out, rather than from a user watching 360p.
      //
      // Three samples rather than one, because on 2026-08-02 this started coming
      // back mixed: one response in ~17 live runs was SABR-only while 12/12
      // controlled calls in the same hour were plain. That is what a bucketed
      // rollout looks like from the outside, and it is the leading edge of the
      // thing this test exists to catch.
      //
      // So the two signals are separated. **One** SABR-only sample warns and is
      // recorded — that is the rollout widening, and failing the suite on it
      // would train everyone to re-run, which is how a real flip gets missed.
      // **Two of three** fails: at that point most requests are SABR-only, tier 2
      // is effectively gone whatever the remaining third does, and Phase 2 has
      // stopped being deferrable. Waiting for 3/3 would let a two-thirds rollout
      // sit green.
      const sts = (await getPlayer(session)).signatureTimestamp;
      const samples: boolean[] = [];

      for (let i = 0; i < 3; i++) {
        const response = parsePlayer(
          await session.execute('/player', {
            videoId: VIDEO,
            contentCheckOk: true,
            racyCheckOk: true,
            playbackContext: { contentPlaybackContext: { signatureTimestamp: sts } },
          }),
        );
        expect(response.playabilityStatus).toBe('OK');
        samples.push(isSabrOnly(response));
      }

      const sabrCount = samples.filter(Boolean).length;
      const history = recordTripwire(samples, sabrCount);

      if (sabrCount > 0) {
        log.warn(
          `MWEB returned SABR-only on ${sabrCount}/${samples.length} samples. F3 says ` +
            'MWEB still serves plain adaptive URLs; that is now partly untrue. Phase 2 ' +
            '(SABR → DASH) is becoming relevant — ladder tier 2 is what degrades, and ' +
            'tier 1 (ANDROID_VR) is unaffected. Re-read F3 before trusting it.',
        );
      }
      if (history !== null) log.info(`tripwire history: ${history}`);

      // Two of three is the flip. One is the rollout, and it warned above.
      expect({ samples, sabrCount, flipped: sabrCount >= 2 }).toEqual({
        samples,
        sabrCount,
        flipped: false,
      });
    },
    2 * MINUTE,
  );
});
