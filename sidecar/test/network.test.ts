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
 * No cookie required: streams resolve through an anonymous `MWEB` session
 * (§2.3). Set `SIDECAR_SKIP_NETWORK=1` to skip, but understand what is being
 * skipped — with these off, a completely broken decipher path is a green suite.
 */

import { beforeAll, describe, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';

import { createSession, type Session } from '../src/innertube/session.ts';
import { getPlayer, rebuildPlayer } from '../src/innertube/player.ts';
import { sign } from '../src/innertube/signed-url.ts';
import { parsePlayer } from '../src/parser/index.ts';
import { openPlayback, tierProgressive, tierYtDlp } from '../src/playback/resolve.ts';
import { getPlayerResponse } from '../src/innertube/player-response.ts';
import { isSabrOnly } from '../src/playback/sabr-detect.ts';

const ONLINE = process.env['SIDECAR_SKIP_NETWORK'] !== '1';

/**
 * Tier 3's binary, if this machine has one.
 *
 * yt-dlp is an optional fallback, not a dependency, so its absence skips rather
 * than fails — with the usual caveat about skipped tests: on a machine without
 * it, tier 3 is entirely unproven and the ladder is effectively three rungs.
 */
const configured = process.env['YT_DLP_PATH'];
const YT_DLP: string | null =
  configured && existsSync(configured) ? configured : Bun.which('yt-dlp');

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

describe.if(ONLINE)('decipher, end to end', () => {
  test(
    'a real video resolves to two signed URLs',
    async () => {
      const source = await openPlayback({ session }, { videoId: VIDEO });

      // Tier 1. Anything else means MWEB stopped serving plain adaptive URLs
      // and Phase 2 just became relevant — which is worth failing over.
      expect(source.transport).toBe('plain');
      expect(source.videoUrl).toStartWith('https://');
      expect(source.audioUrl).toStartWith('https://');
      expect(source.qualityDegraded).toBe(false);
      expect(source.height).toBeGreaterThanOrEqual(1080);

      // Both carry a deciphered `n`. That it is *correct* is the next test's job.
      for (const url of [source.videoUrl, source.audioUrl!]) {
        expect(new URL(url).searchParams.get('n')).toBeString();
      }

      expect(source.durationMs).toBeGreaterThan(0);
      expect(source.storyboardTemplate).toStartWith('http');
    },
    2 * MINUTE,
  );

  test(
    'sustained throughput is unthrottled',
    async () => {
      const source = await openPlayback({ session }, { videoId: VIDEO });
      const result = await measure(source.videoUrl);

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

      // The assertion the whole task exists for. If this lands near 0.05 MB/s
      // the `n` transform is wrong, not the network: check that the player cache
      // is keyed by playerId and that the node:vm shim is executing the current
      // player JS, before suspecting anything else.
      expect({ detail, healthy: result.mbps > HEALTHY_MBPS }).toEqual({ detail, healthy: true });
    },
    5 * MINUTE,
  );

  test(
    'the audio track streams too — mpv gets two working URLs',
    async () => {
      const source = await openPlayback({ session }, { videoId: VIDEO });
      const response = await fetch(source.audioUrl!, { headers: { range: 'bytes=0-262143' } });
      expect([200, 206]).toContain(response.status);
      expect((await response.arrayBuffer()).byteLength).toBeGreaterThan(0);
    },
    2 * MINUTE,
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

      expect(without.playabilityStatus).toBe('UNPLAYABLE');
      // The reason is the trap: it reads like a broken video, not a malformed
      // request. Pinning the wording is the whole point of the test.
      expect(without.playabilityReason).toMatch(/reload/i);
      expect(without.formats).toEqual([]);

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

describe.if(ONLINE)('ladder tier 4 — itag 18 progressive', () => {
  test(
    'the floor signs and streams',
    async () => {
      // The rung nothing falls past. In normal operation it never runs, so a
      // break here would only ever show up on a video the tiers above already
      // refused — the worst possible time to discover it.
      const response = await getPlayerResponse(session, VIDEO, 'MWEB');
      const source = await tierProgressive({ session }, VIDEO, null, response);

      expect(source.height).toBe(360);
      expect(source.audioUrl).toBeNull(); // muxed: one URL, no --audio-file
      expect(source.qualityDegraded).toBe(true);
      // A muxed format lists both codecs in one string; they must land in the
      // right two fields, not both in one.
      expect(source.videoCodec).toStartWith('avc1');
      expect(source.audioCodec).toStartWith('mp4a');

      const fetched = await fetch(source.videoUrl, { headers: { range: 'bytes=0-1048575' } });
      expect([200, 206]).toContain(fetched.status);
      expect((await fetched.arrayBuffer()).byteLength).toBeGreaterThan(0);
    },
    2 * MINUTE,
  );
});

// ---------------------------------------------------------------------------

describe.if(ONLINE && YT_DLP !== null)('ladder tier 3 — yt-dlp', () => {
  test(
    'resolves a real video to streamable URLs',
    async () => {
      // Tier 3 exists for the videos tier 1 refuses — age-restricted, Vevo — and
      // those cannot be used as a fixture. So this proves the mechanism on an
      // ordinary video instead: that the subprocess runs, that the dump maps to
      // a `PlaybackSource`, and that URLs deciphered by someone else's
      // implementation actually stream.
      const source = await tierYtDlp({ session, ytDlpPath: YT_DLP! }, VIDEO, null, null);

      expect(source.transport).toBe('ytdlp');
      expect(source.height).toBeGreaterThanOrEqual(1080);
      expect(source.durationMs).toBeGreaterThan(0);
      expect(source.videoUrl).toStartWith('https://');

      for (const url of [source.videoUrl, source.audioUrl].filter((u) => u !== null)) {
        const response = await fetch(url, { headers: { range: 'bytes=0-1048575' } });
        expect([200, 206]).toContain(response.status);
        expect((await response.arrayBuffer()).byteLength).toBeGreaterThan(0);
      }
    },
    3 * MINUTE,
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
      // corpus was captured. This one says it is true now. When it starts
      // failing, the SABR → DASH bridge has stopped being deferrable — and this
      // is how we find out, rather than from a user watching 360p.
      const response = parsePlayer(
        await session.execute('/player', {
          videoId: VIDEO,
          contentCheckOk: true,
          racyCheckOk: true,
          playbackContext: {
            contentPlaybackContext: {
              signatureTimestamp: (await getPlayer(session)).signatureTimestamp,
            },
          },
        }),
      );

      expect(response.playabilityStatus).toBe('OK');
      expect(isSabrOnly(response)).toBe(false);
    },
    2 * MINUTE,
  );
});
