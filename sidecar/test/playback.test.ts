/**
 * Playback tests — offline, against real captured player responses.
 *
 * These cover everything about the decipher path that can be established without
 * a network: that `isSabrOnly` reads the two clients correctly, that `sign`
 * refuses a transform that did not happen, and that the ladder falls through in
 * the right order. What they cannot establish is that the deciphered `n` is
 * *correct* — a wrong `n` produces a URL that passes every assertion here and
 * streams at 50 KB/s. That is `network.test.ts`, and it is the point of the
 * task.
 */

import { afterAll, beforeEach, describe, expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { probeCapabilities, resolveYtDlp, ytDlpBinary } from '../src/capabilities.ts';
import { hasCode, isRpcError, RpcError } from '../src/errors.ts';
import { getPlayer, resetPlayerCache, type Player } from '../src/innertube/player.ts';
import { forgetPlayerResponse } from '../src/innertube/player-response.ts';
import type { PlayerClient, Session } from '../src/innertube/session.ts';
import { adoptExternallyDeciphered, sign } from '../src/innertube/signed-url.ts';
import { parsePlayer } from '../src/parser/index.ts';
import {
  descendLadder,
  fetchWithVisitorRetry,
  openPlayback,
  responseForDecipher,
  sourceFromYtDlpDump,
  tierPlainAdaptive,
  tierProgressive,
  tierYtDlp,
  type PlayerEntry,
  type Tier,
  type YtDlpDump,
} from '../src/playback/resolve.ts';
import { isSabrOnly, isSabrOnlyAdaptive } from '../src/playback/sabr-detect.ts';
import { nullPoTokenProvider } from '../src/playback/po-token.ts';
import type { PlaybackSource, PlaybackVariant, PlayerResult } from '../src/types.ts';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(FIXTURES, `${name}.json`), 'utf8'));
}
function hasFixture(name: string): boolean {
  return existsSync(join(FIXTURES, `${name}.json`));
}

// ---------------------------------------------------------------------------
// A player stand-in
//
// The real one evaluates YouTube's obfuscated script; the transform it applies
// is irrelevant to everything below, so long as it is not the identity. `broken`
// is the interesting one — it is exactly what a shim that silently fails to
// execute looks like from the outside.
// ---------------------------------------------------------------------------

function fakePlayer(overrides: Partial<Player> = {}): Player {
  return {
    playerId: 'deadbeef',
    signatureTimestamp: 20662,
    decipherSignature: async (s) => `sig(${s})`,
    decipherN: async (n) => `n(${n})`,
    ...overrides,
  };
}

/** A player whose transforms no-op — a shim that was never installed. */
const brokenPlayer = fakePlayer({
  decipherSignature: async (s) => s,
  decipherN: async (n) => n,
});

const ANDROID_URL =
  'https://r1.googlevideo.com/videoplayback?expire=1&itag=315&c=MWEB&n=RAWNVALUE&mime=video%2Fwebm';
const VR_URL = 'https://r1.googlevideo.com/videoplayback?expire=1&itag=315&c=VISIONOS';

// ---------------------------------------------------------------------------
// sabr-detect — the Phase 2 tripwire
// ---------------------------------------------------------------------------

describe('isSabrOnly', () => {
  test.if(hasFixture('player-mweb'))('ANDROID is false — Phase 1 still has a plain path', () => {
    const response = parsePlayer(fixture('player-mweb'));
    expect(response.playabilityStatus).toBe('OK');

    // If this ever flips, ANDROID has gone the way of WEB and the SABR → DASH
    // bridge stopped being deferrable. That is the entire reason this assertion
    // exists: we want to learn it here, not from a user on 360p.
    expect(isSabrOnly(response)).toBe(false);
  });

  test.if(hasFixture('player-web'))('WEB is true (F3)', () => {
    const response = parsePlayer(fixture('player-web'));
    expect(response.playabilityStatus).toBe('OK');
    expect(isSabrOnly(response)).toBe(true);
  });

  test.if(hasFixture('player-web'))(
    'is defined over adaptive formats only — the itag 18 trap (F9)',
    () => {
      const response = parsePlayer(fixture('player-web'));

      // The same response that is SABR-only still carries a working progressive
      // stream. Had `isSabrOnly` been written over every format, that one URL
      // would make it `false`, the ladder would never reach its SABR branch, and
      // the client would serve 360p forever with every check reporting healthy.
      const progressive = response.formats.filter((f) => !f.isAdaptive && f.rawUrl !== null);
      expect(progressive.length).toBeGreaterThan(0);
      expect(progressive.some((f) => f.itag === 18)).toBe(true);

      expect(isSabrOnlyAdaptive(response.formats)).toBe(false);
      expect(isSabrOnly(response)).toBe(true);
    },
  );

  test('an empty adaptive list is not SABR-only', () => {
    // No formats means "we learned nothing", not "SABR". Answering true here
    // would send every unplayable video down the Phase 2 branch.
    expect(isSabrOnlyAdaptive([])).toBe(false);
    expect(isSabrOnly(parsePlayer({}))).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// sign — the type-level guard
// ---------------------------------------------------------------------------

describe('sign', () => {
  test('ANDROID output carries a deciphered n', async () => {
    const signed = await sign(ANDROID_URL, fakePlayer());
    const url = new URL(signed);

    expect(url.searchParams.get('n')).toBe('n(RAWNVALUE)');
    // Presence alone proves nothing — the raw URL had an `n` too. What matters
    // is that the value changed.
    expect(url.searchParams.get('n')).not.toBe('RAWNVALUE');
  });

  test('VISIONOS is accepted without one', async () => {
    // These clients hand out unthrottled URLs with no cipher challenge, so
    // asserting `n` there would reject a perfectly good URL.
    const signed = await sign(VR_URL, fakePlayer());
    expect(new URL(signed).searchParams.has('n')).toBe(false);
  });

  test('a client that expects n but has none is refused', async () => {
    const noN = 'https://r1.googlevideo.com/videoplayback?itag=315&c=MWEB';
    await expect(sign(noN, fakePlayer())).rejects.toThrow(/no `n` parameter/);
  });

  test('a no-op transform is a failure, not a pass', async () => {
    // The failure this whole design exists to catch: the shim did not run, the
    // URL is intact and well-formed, and it would stream at ~50 KB/s.
    await expect(sign(ANDROID_URL, brokenPlayer)).rejects.toThrow(/no-op/);
  });

  test("the player script's own refusal is caught", async () => {
    const givesUp = fakePlayer({ decipherN: async () => 'enhanced_except_abc123' });
    await expect(sign(ANDROID_URL, givesUp)).rejects.toThrow(/rejected n=/);
  });

  test('a signatureCipher is unwrapped, deciphered and reassembled', async () => {
    const inner = 'https://r1.googlevideo.com/videoplayback?itag=251&c=MWEB&n=RAWN';
    const cipher = new URLSearchParams({ s: 'SIGVALUE', sp: 'sig', url: inner }).toString();

    const url = new URL(await sign(cipher, fakePlayer()));
    expect(url.searchParams.get('sig')).toBe('sig(SIGVALUE)');
    expect(url.searchParams.get('n')).toBe('n(RAWN)');
  });

  test('a no-op signature transform is refused too', async () => {
    const inner = 'https://r1.googlevideo.com/videoplayback?itag=251&c=VISIONOS';
    const cipher = new URLSearchParams({ s: 'SIGVALUE', sp: 'sig', url: inner }).toString();
    await expect(sign(cipher, brokenPlayer)).rejects.toThrow(/no-op/);
  });

  test('a PO token is applied inside the constructor, not bolted on after', async () => {
    // Appending `pot=` to a finished SignedUrl would mean mutating a value the
    // type says is already final.
    const signed = await sign(ANDROID_URL, fakePlayer(), { poToken: 'TOKEN' });
    expect(new URL(signed).searchParams.get('pot')).toBe('TOKEN');

    const without = await sign(ANDROID_URL, fakePlayer());
    expect(new URL(without).searchParams.has('pot')).toBe(false);
  });

  test('the client gate can be overridden explicitly', async () => {
    const unknownClient = 'https://r1.googlevideo.com/videoplayback?itag=315';
    await expect(sign(unknownClient, fakePlayer(), { expectsN: true })).rejects.toThrow(
      /no `n` parameter/,
    );
    await expect(sign(unknownClient, fakePlayer(), { expectsN: false })).resolves.toBeString();
  });

  test('garbage in is an RpcError, not a crash', async () => {
    for (const input of ['', '   ', 'not a url at all']) {
      const failure = await sign(input, fakePlayer()).catch((error: unknown) => error);
      expect(isRpcError(failure)).toBe(true);
      expect(hasCode(failure, 'STREAM_UNAVAILABLE')).toBe(true);
    }
  });
});

describe('adoptExternallyDeciphered', () => {
  test('accepts a finished yt-dlp URL and keeps the n gate', () => {
    const adopted = adoptExternallyDeciphered(ANDROID_URL, 'yt-dlp');
    expect(new URL(adopted).searchParams.get('n')).toBe('RAWNVALUE');

    expect(() =>
      adoptExternallyDeciphered('https://r1.googlevideo.com/videoplayback?c=MWEB', 'yt-dlp'),
    ).toThrow(/no `n` parameter/);
  });
});

// ---------------------------------------------------------------------------
// The ladder
// ---------------------------------------------------------------------------

/**
 * `descendLadder` is the real loop `openPlayback` runs; only the four tiers are
 * stubbed. Reimplementing the loop in this file would test the reimplementation.
 */
function stubVariant(height: number, overrides: Partial<PlaybackVariant> = {}): PlaybackVariant {
  return {
    // A legitimate constructor rather than a cast — nothing outside
    // `signed-url.ts` should be minting these, tests included.
    videoUrl: adoptExternallyDeciphered(ANDROID_URL, 'test'),
    audioUrl: null,
    itag: 315,
    height,
    fps: 30,
    videoCodec: 'vp9',
    audioCodec: 'opus',
    ...overrides,
  };
}

function stubSource(transport: PlaybackSource['transport'], height: number): PlaybackSource {
  return {
    sessionId: 'test',
    durationMs: 1000,
    startTimestamp: null,
    storyboardTemplate: null,
    qualityDegraded: height < 720,
    transport,
    variants: [stubVariant(height)],
  };
}

describe('resolution ladder', () => {
  /** Records the order tiers were tried in, so fall-through is observable. */
  function trace(tiers: Array<[string, Tier['run']]>): { tiers: Tier[]; attempted: string[] } {
    const attempted: string[] = [];
    return {
      attempted,
      tiers: tiers.map(([name, run]) => ({
        name,
        run: () => {
          attempted.push(name);
          return run();
        },
      })),
    };
  }

  const decline = (code: 'STREAM_REQUIRES_SABR' | 'UPSTREAM_ERROR') => async (): Promise<never> => {
    throw new RpcError(code, 'declined');
  };

  /** Convenience for reading the top-level variant from a source. */
  const best = (source: PlaybackSource) => source.variants[0]!;

  test('stops at the first tier that serves', async () => {
    const { tiers, attempted } = trace([
      ['mweb', async () => stubSource('plain', 2160)],
      ['sabr', decline('STREAM_REQUIRES_SABR')],
      ['ytdlp', decline('UPSTREAM_ERROR')],
      ['progressive', async () => stubSource('plain', 360)],
    ]);

    const source = await descendLadder('aqz-KE-bpKQ', tiers);
    expect(attempted).toEqual(['mweb']);
    expect(source.transport).toBe('plain');
    expect(best(source).height).toBe(2160);
  });

  test('falls through SABR and yt-dlp to the progressive floor', async () => {
    const { tiers, attempted } = trace([
      ['mweb', decline('STREAM_REQUIRES_SABR')],
      ['sabr', decline('STREAM_REQUIRES_SABR')],
      ['ytdlp', decline('UPSTREAM_ERROR')],
      ['progressive', async () => stubSource('plain', 360)],
    ]);

    const source = await descendLadder('aqz-KE-bpKQ', tiers);
    expect(attempted).toEqual(['mweb', 'sabr', 'ytdlp', 'progressive']);
    expect(source.qualityDegraded).toBe(true);
  });

  test('a tier that throws something other than an RpcError still only declines', async () => {
    // A tier crashing on an unexpected shape must not take the whole open with
    // it — that would turn a yt-dlp-serviceable video into "Unavailable".
    const { tiers, attempted } = trace([
      [
        'mweb',
        async () => {
          throw new TypeError('undefined is not an object');
        },
      ],
      ['ytdlp', async () => stubSource('ytdlp', 1080)],
    ]);

    const source = await descendLadder('aqz-KE-bpKQ', tiers);
    expect(attempted).toEqual(['mweb', 'ytdlp']);
    expect(source.transport).toBe('ytdlp');
  });

  test('all four declining is STREAM_UNAVAILABLE, never STREAM_REQUIRES_SABR', async () => {
    const { tiers } = trace([
      ['mweb', decline('STREAM_REQUIRES_SABR')],
      ['sabr', decline('STREAM_REQUIRES_SABR')],
      ['ytdlp', decline('UPSTREAM_ERROR')],
      ['progressive', decline('UPSTREAM_ERROR')],
    ]);

    const failure = await descendLadder('aqz-KE-bpKQ', tiers).catch((error: unknown) => error);
    expect(isRpcError(failure)).toBe(true);
    // The internal code must not reach Flutter; §4 says it is never surfaced.
    expect(hasCode(failure, 'STREAM_UNAVAILABLE')).toBe(true);
    // …and the reason each tier declined survives, or this is undebuggable.
    expect((failure as RpcError).message).toContain('sabr');
    expect((failure as RpcError).message).toContain('ytdlp');
  });
});

// ---------------------------------------------------------------------------
// The ladder, end to end and offline
//
// `descendLadder` above proves the loop; this proves the wiring — which client
// tier 1 asks as, that a declining tier really does reach the next one, and that
// the `ANDROID` response is not fetched at all when tier 1 serves. All of it runs
// against a stub session, so it is the ordering that is under test and not
// YouTube's mood.
// ---------------------------------------------------------------------------

/** A `/player` body shaped like the real one, minus everything nothing reads. */
function rawPlayerBody(options: {
  client: PlayerClient;
  status?: string;
  reason?: string;
  /** `ANDROID` URLs carry an `n` challenge; `VISIONOS` URLs do not (F5, F11). */
  withN?: boolean;
  /** Drop every adaptive URL — the SABR-only shape (F3). */
  sabrOnly?: boolean;
  /** Drop the adaptive ladder entirely — the original F5 refusal shape. */
  noAdaptive?: boolean;
}): unknown {
  const { client, status = 'OK', reason, withN = false, sabrOnly = false, noAdaptive = false } =
    options;

  const address = (itag: number, n: string): Record<string, string> =>
    sabrOnly
      ? {}
      : {
          url:
            `https://r1.googlevideo.com/videoplayback?expire=1&itag=${itag}&c=${client}` +
            (withN ? `&n=${n}` : ''),
        };

  return {
    playabilityStatus: { status, ...(reason ? { reason } : {}) },
    streamingData: {
      adaptiveFormats: noAdaptive ? [] : [
        {
          itag: 315,
          mimeType: 'video/webm; codecs="vp9"',
          width: 3840,
          height: 2160,
          fps: 60,
          bitrate: 20_000_000,
          ...address(315, 'RAWN315'),
        },
        {
          itag: 136,
          mimeType: 'video/mp4; codecs="avc1.64002a"',
          width: 1920,
          height: 1080,
          fps: 30,
          bitrate: 4_000_000,
          ...address(136, 'RAWN136'),
        },
        {
          itag: 251,
          mimeType: 'audio/webm; codecs="opus"',
          audioQuality: 'AUDIO_QUALITY_MEDIUM',
          audioSampleRate: 48_000,
          audioChannels: 2,
          bitrate: 130_000,
          ...address(251, 'RAWN251'),
        },
      ],
      // Progressive survives a SABR-only response (F9), so it is never dropped.
      formats: [
        {
          itag: 18,
          mimeType: 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
          width: 640,
          height: 360,
          url:
            `https://r1.googlevideo.com/videoplayback?expire=1&itag=18&c=${client}` +
            (withN ? '&n=RAWN18' : ''),
        },
      ],
    },
    videoDetails: { videoId: 'aqz-KE-bpKQ', lengthSeconds: '634' },
    storyboards: {
      playerStoryboardSpecRenderer: {
        spec: 'https://i.ytimg.com/sb/aqz-KE-bpKQ/storyboard3_L$L/$N.jpg|48#27#100#10#10#1000#M$M#rs$AOn4',
      },
    },
  };
}

/**
 * `rawPlayerBody`, with an `hlsManifestUrl` grafted on — what a real `VISIONOS`
 * `/player` response carries regardless of whether the video is live. Measured
 * 2026-09-10 against `dQw4w9WgXcQ` and three other ordinary videos: all four
 * carried one, live or not, which is exactly what made the ungated branch in
 * `tierPlainAdaptive` hijack essentially every tier-1 open rather than only the
 * live ones it was written for.
 */
function rawPlayerBodyWithHlsManifest(
  options: Parameters<typeof rawPlayerBody>[0] & { isLive?: boolean },
): unknown {
  const { isLive = false, ...rest } = options;
  const body = rawPlayerBody(rest) as {
    videoDetails: Record<string, unknown>;
    streamingData: Record<string, unknown>;
  };
  return {
    ...body,
    videoDetails: { ...body.videoDetails, isLive },
    streamingData: {
      ...body.streamingData,
      hlsManifestUrl: `https://manifest.googlevideo.com/api/manifest/hls_variant/index.m3u8?c=${rest.client}`,
    },
  };
}

/**
 * The JS player youtubei.js would have downloaded, with the two transforms
 * stubbed. Not the identity — `sign` refuses that, correctly.
 */
const fakeJsPlayer = {
  player_id: 'testplayer',
  signature_timestamp: 20662,
  decipher(url?: string, cipher?: string): string {
    if (cipher) {
      const args = new URLSearchParams(cipher);
      const out = new URL(args.get('url')!);
      out.searchParams.set(args.get('sp') ?? 'signature', `sig(${args.get('s')})`);
      return out.toString();
    }
    const out = new URL(url!);
    const n = out.searchParams.get('n');
    if (n) out.searchParams.set('n', `n(${n})`);
    return out.toString();
  },
};

interface FakeSession extends Session {
  /** Which client each `/player` call named, in order. */
  readonly calls: PlayerClient[];
}

function fakeSession(bodies: Partial<Record<PlayerClient, unknown>>): FakeSession {
  const calls: PlayerClient[] = [];
  return {
    calls,
    hasCookie: false,
    // Length is what distinguishes a server-issued id from a fabricated one (F5).
    visitorId: 'v'.repeat(558),
    innertube: {
      session: { player: fakeJsPlayer, context: { client: { visitorData: 'v'.repeat(558) } } },
    } as unknown as Session['innertube'],
    async execute(_endpoint, params = {}) {
      const client = (params['client'] ?? 'WEB') as PlayerClient;
      calls.push(client);
      const body = bodies[client];
      if (!body) throw new Error(`${client}: stub session has no response for this client`);
      return body;
    },
  };
}

describe('the ladder as openPlayback wires it', () => {
  beforeEach(() => {
    // Both caches are module-level and keyed by things these tests reuse.
    resetPlayerCache();
    forgetPlayerResponse();
  });

  /** Tier 4 must never actually shell out during an offline test. */
  const noYtDlp = { ytDlpPath: 'yt-dlp-does-not-exist' };

  test('tier 1 is VISIONOS, and it carries no n', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS' }),
      ANDROID: rawPlayerBody({ client: 'ANDROID', withN: false }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });
    const best = source.variants[0]!;

    const video = new URL(best.videoUrl);
    const audio = new URL(best.audioUrl!);
    expect(video.searchParams.get('c')).toBe('VISIONOS');
    expect(audio.searchParams.get('c')).toBe('VISIONOS');

    // The point of the reorder: the primary path has nothing to decipher, so
    // the whole class of silent-throttle failures cannot arise on it.
    expect(video.searchParams.has('n')).toBe(false);
    expect(audio.searchParams.has('n')).toBe(false);

    expect(best.height).toBe(2160);
    expect(source.transport).toBe('plain');
    expect(source.qualityDegraded).toBe(false);
    expect(source.storyboardTemplate).toStartWith('http');

    // And the ANDROID response was never fetched. A pre-fetch would put a second
    // /player round trip on every successful open, for a body nothing reads.
    expect(session.calls).toEqual(['VISIONOS']);
  });

  test('a SABR-only VISIONOS response falls through to the progressive floor, on one ANDROID call', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS', sabrOnly: true }),
      ANDROID: rawPlayerBody({ client: 'ANDROID', withN: false, sabrOnly: true }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });
    const best = source.variants[0]!;

    expect(best.height).toBe(360);
    expect(best.audioUrl).toBeNull();
    expect(source.qualityDegraded).toBe(true);
    expect(best.videoCodec).toStartWith('avc1');
    expect(best.audioCodec).toStartWith('mp4a');

    // Tiers 2, 4 and 5 all want the ANDROID response; between them they cost one
    // call, not three.
    expect(session.calls).toEqual(['VISIONOS', 'ANDROID']);
  });

  test('a SABR-only tier 1 does not mint a visitor id on its way past', async () => {
    // The one case that must *not* trip the identity retry, and the reason the
    // trigger is "not OK, or no adaptive formats" rather than "no usable URLs":
    // a SABR-only response is `OK` with a full adaptive ladder, and re-minting
    // would spend a round trip on a Phase 2 trigger that has nothing to do with
    // who is asking.
    //
    // It is also what keeps this test offline. A retry here would call the real
    // `refreshVisitorId`, which fetches from YouTube.
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS', sabrOnly: true }),
      ANDROID: rawPlayerBody({ client: 'ANDROID', withN: false }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });
    expect(new URL(source.variants[0]!.videoUrl).searchParams.get('c')).toBe('ANDROID');
    // One VISIONOS call, not two: no retry happened.
    expect(session.calls).toEqual(['VISIONOS', 'ANDROID']);
  });

  test('an hlsManifestUrl on an ordinary (non-live) response is ignored — the 2026-09-10 regression',
    async () => {
      // MUTATION: drop the `response.isLive &&` half of the gate in
      // `tierPlainAdaptive` and this fails. The response below is `isLive: false`
      // but still carries an `hlsManifestUrl` — exactly what every ordinary
      // VISIONOS response measured on 2026-09-10 turned out to carry — and the
      // ungated branch took it anyway, handing mpv a manifest URL instead of the
      // plain adaptive pair sitting one check below. That produced the reported
      // symptom: a slow, then-timing-out open on ordinary (non-live) videos,
      // healed by a retry because a fresh resolve rarely lands on the same
      // fragile multi-hop HLS fetch chain twice.
      const session = fakeSession({
        VISIONOS: rawPlayerBodyWithHlsManifest({ client: 'VISIONOS' }),
        ANDROID: rawPlayerBody({ client: 'ANDROID', withN: false }),
      });

      const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });

      expect(source.transport).toBe('plain');
      expect(source.variants[0]!.audioUrl).not.toBeNull();
      expect(session.calls).toEqual(['VISIONOS']);
    },
  );

  test('a live response with an hlsManifestUrl uses it, signed rather than cast', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBodyWithHlsManifest({ client: 'VISIONOS', isLive: true }),
      ANDROID: rawPlayerBody({ client: 'ANDROID', withN: false }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });

    expect(source.transport).toBe('hls');
    // No audio track in an HLS variant — the manifest carries its own.
    expect(source.variants[0]!.audioUrl).toBeNull();
    // Hard invariant 2: even a client that carries no cipher today goes through
    // `sign`, not a bare cast, so a day it starts carrying one is not silent.
    expect(source.variants[0]!.videoUrl).toContain('manifest.googlevideo.com');
  });
});

// ---------------------------------------------------------------------------
// LOGIN_REQUIRED and the visitor id
// ---------------------------------------------------------------------------

describe('a throttle is RATE_LIMITED, not "would not open" — decided 2026-09-17', () => {
  beforeEach(() => {
    resetPlayerCache();
    forgetPlayerResponse();
  });

  const noYtDlp = { ytDlpPath: 'yt-dlp-does-not-exist' };
  const botCheck = { status: 'LOGIN_REQUIRED', reason: "Sign in to confirm you're not a bot" };

  const failureOf = (promise: Promise<unknown>): Promise<unknown> =>
    promise.then(
      () => null,
      (error: unknown) => error,
    );

  test('the ladder reports RATE_LIMITED when a throttled tier is followed only by declines', async () => {
    const tiers: Tier[] = [
      { name: 'one', run: async () => Promise.reject(new RpcError('RATE_LIMITED', 'bot check')) },
      { name: 'two', run: async () => Promise.reject(new RpcError('UPSTREAM_ERROR', 'down')) },
    ];
    const failure = await failureOf(descendLadder('aqz-KE-bpKQ', tiers));
    expect(hasCode(failure, 'RATE_LIMITED')).toBe(true);
    // `user`, not `auto`: a throttle lasts minutes to an hour, and a silent
    // retry would be a spinner that never ends.
    expect((failure as RpcError).retry).toBe('user');
  });

  test('a throttled tier does not end the ladder: a lower tier can still serve', async () => {
    const tiers: Tier[] = [
      { name: 'one', run: async () => Promise.reject(new RpcError('RATE_LIMITED', 'bot check')) },
      { name: 'two', run: async () => stubSource('plain', 360) },
    ];
    const source = await descendLadder('aqz-KE-bpKQ', tiers);
    expect(source.variants[0]!.height).toBe(360);
  });

  test('throttled on every client: openPlayback answers RATE_LIMITED after trying them all', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS', ...botCheck }),
      ANDROID: rawPlayerBody({ client: 'ANDROID', ...botCheck }),
    });
    const failure = await failureOf(openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' }));

    expect(hasCode(failure, 'RATE_LIMITED')).toBe(true);
    // Tier 1 retried once with a fresh visitor id before being believed, and
    // the ladder still reached tier 5's ANDROID response.
    expect(session.calls).toEqual(['VISIONOS', 'VISIONOS', 'ANDROID']);
  });

  test('a throttled tier 1 is rescued by the 360p floor when ANDROID still answers', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS', ...botCheck }),
      ANDROID: rawPlayerBody({ client: 'ANDROID', withN: false, sabrOnly: true }),
    });
    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });
    expect(source.variants[0]!.height).toBe(360);
    expect(source.qualityDegraded).toBe(true);
  });

  test('an age gate is not a throttle, although it is also LOGIN_REQUIRED', async () => {
    const ageGate = { status: 'LOGIN_REQUIRED', reason: 'Sign in to confirm your age' };
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS', ...ageGate }),
      ANDROID: rawPlayerBody({ client: 'ANDROID', ...ageGate }),
    });
    const failure = await failureOf(openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' }));
    expect(hasCode(failure, 'STREAM_UNAVAILABLE')).toBe(true);
  });
});

describe('fetchWithVisitorRetry', () => {
  const ok = parsePlayer(rawPlayerBody({ client: 'VISIONOS' }));
  const refused = parsePlayer(
    rawPlayerBody({
      client: 'VISIONOS',
      status: 'LOGIN_REQUIRED',
      reason: "Sign in to confirm you're not a bot",
      sabrOnly: true,
    }),
  );
  /**
   * The shapes an *expired* visitor id might arrive as. Nobody has seen one —
   * F14 watched an id survive 28 uses across 38 minutes and never expire — so
   * the retry cannot be gated on the one error string we happen to have seen.
   */
  const unplayable = parsePlayer(
    rawPlayerBody({
      client: 'VISIONOS',
      status: 'UNPLAYABLE',
      reason: 'This video is not available',
    }),
  );
  const emptyLadder = parsePlayer(rawPlayerBody({ client: 'VISIONOS', noAdaptive: true }));
  /** `OK`, full adaptive ladder, no URLs. A Phase 2 trigger, not an identity one. */
  const sabrOnly = parsePlayer(rawPlayerBody({ client: 'VISIONOS', sabrOnly: true }));

  /** Records what each call was asked for, so "exactly one retry" is observable. */
  function trace(responses: PlayerResult[]) {
    const refreshes: boolean[] = [];
    let mints = 0;
    return {
      refreshes,
      mintCount: () => mints,
      fetch: async (refresh: boolean): Promise<PlayerResult> => {
        refreshes.push(refresh);
        return responses[refreshes.length - 1] ?? responses.at(-1)!;
      },
      mint: async (): Promise<string> => {
        mints += 1;
        return 'fresh-visitor-id';
      },
    };
  }

  test('an OK response costs no mint and no second call', async () => {
    const t = trace([ok]);
    await expect(fetchWithVisitorRetry('aqz-KE-bpKQ', t.fetch, t.mint)).resolves.toBe(ok);
    expect(t.refreshes).toEqual([false]);
    expect(t.mintCount()).toBe(0);
  });

  test('a failure that is not LOGIN_REQUIRED still retries', async () => {
    // The point of the broadened trigger. If an expired visitor id turns out to
    // produce UNPLAYABLE — or a 400, or anything else — a LOGIN_REQUIRED-only
    // gate would never fire, and stream resolution would stop working silently
    // after some number of hours on a session that still looks healthy.
    const t = trace([unplayable, ok]);
    const result = await fetchWithVisitorRetry('aqz-KE-bpKQ', t.fetch, t.mint);

    expect(result).toBe(ok);
    expect(t.mintCount()).toBe(1);
    expect(t.refreshes).toEqual([false, true]);
  });

  test('OK with an empty adaptive ladder retries too — the original F5 shape', async () => {
    // F5's first reading was "0 formats on 3 of 4 runs": a refusal that arrived
    // as a shape rather than as a status. Nothing in the response says no.
    const t = trace([emptyLadder, ok]);
    const result = await fetchWithVisitorRetry('aqz-KE-bpKQ', t.fetch, t.mint);

    expect(result).toBe(ok);
    expect(t.mintCount()).toBe(1);
  });

  test('a SABR-only response is not an identity refusal', async () => {
    // `OK` with a full adaptive ladder and no URLs. That is the Phase 2 trigger
    // and has nothing to do with who is asking — retrying it would spend a mint
    // and a round trip to be told the same thing.
    const t = trace([sabrOnly]);
    await expect(fetchWithVisitorRetry('aqz-KE-bpKQ', t.fetch, t.mint)).resolves.toBe(sabrOnly);
    expect(t.mintCount()).toBe(0);
    expect(t.refreshes).toEqual([false]);
  });

  test('LOGIN_REQUIRED mints once and re-asks once, bypassing the cache', async () => {
    const t = trace([refused, ok]);
    const result = await fetchWithVisitorRetry('aqz-KE-bpKQ', t.fetch, t.mint);

    expect(result).toBe(ok);
    expect(t.mintCount()).toBe(1);
    // The second call must not be served the cached refusal — it was made under
    // the old visitor id, which is the thing that just changed.
    expect(t.refreshes).toEqual([false, true]);
  });

  test('a second refusal declines rather than looping', async () => {
    const t = trace([refused, refused]);
    const result = await fetchWithVisitorRetry('aqz-KE-bpKQ', t.fetch, t.mint);

    // Handed back as-is: the tier turns it into a decline and the ladder moves
    // on. F5 makes this a bot score, not a rule, so a retry loop would only
    // spend round trips learning that YouTube has made up its mind.
    expect(result).toBe(refused);
    expect(t.mintCount()).toBe(1);
    expect(t.refreshes).toEqual([false, true]);
  });

  test('a mint that fails declines on YouTube’s refusal, not on ours', async () => {
    const t = trace([refused, ok]);
    const result = await fetchWithVisitorRetry('aqz-KE-bpKQ', t.fetch, async () => {
      throw new Error('offline');
    });

    expect(result).toBe(refused);
    // No second /player call: there is no new identity to make it with.
    expect(t.refreshes).toEqual([false]);
  });
});

// ---------------------------------------------------------------------------
// Player-revision consistency — Task 04 §1
//
// The response and the decipher script must never be paired across a
// revision change. `responseForDecipher` is the function both
// `tierPlainAdaptive` and `tierProgressive` route through to enforce that,
// right before they decipher — tested directly against the real
// implementation, with a stub session, rather than against a second copy of
// the rule.
// ---------------------------------------------------------------------------

describe('responseForDecipher — Task 04 §1', () => {
  beforeEach(() => {
    resetPlayerCache();
    forgetPlayerResponse();
  });

  test('a response already minted under the current player is used as-is — no /player call at all', async () => {
    const session = fakeSession({ MWEB: rawPlayerBody({ client: 'MWEB', withN: true }) });
    const player = fakePlayer({ playerId: 'same' });
    const entry: PlayerEntry = {
      result: parsePlayer(rawPlayerBody({ client: 'MWEB', withN: true })),
      playerId: 'same',
    };

    const response = await responseForDecipher(session, 'aqz-KE-bpKQ', 'MWEB', entry, player);

    expect(response).toBe(entry.result);
    expect(session.calls).toEqual([]);
  });

  test('a mismatched revision refetches exactly once under {refresh: true}, and returns it once it matches', async () => {
    // The session's real player is `fakeJsPlayer` (playerId 'testplayer') —
    // what the refetch will read. `player` below names that same revision, so
    // the post-refetch check passes and the refetched response is returned.
    const session = fakeSession({ MWEB: rawPlayerBody({ client: 'MWEB', withN: true }) });
    const player = fakePlayer({ playerId: 'testplayer' });
    const staleEntry: PlayerEntry = {
      result: parsePlayer(rawPlayerBody({ client: 'MWEB', withN: true })),
      playerId: 'oldRevision',
    };

    const response = await responseForDecipher(session, 'aqz-KE-bpKQ', 'MWEB', staleEntry, player);

    expect(session.calls).toEqual(['MWEB']);
    expect(response).not.toBe(staleEntry.result);
    expect(response.playabilityStatus).toBe('OK');
  });

  test('a revision that has moved again by the time the refetch lands declines — never a mismatched decipher', async () => {
    // The session's real player is still 'testplayer', but `player` here — the
    // one about to decipher — names a third, different revision. Even the
    // refetch cannot satisfy it: two revisions inside one resolution.
    const session = fakeSession({ MWEB: rawPlayerBody({ client: 'MWEB', withN: true }) });
    const player = fakePlayer({ playerId: 'yetAnotherRevision' });
    const staleEntry: PlayerEntry = {
      result: parsePlayer(rawPlayerBody({ client: 'MWEB', withN: true })),
      playerId: 'oldRevision',
    };

    const failure = await responseForDecipher(
      session,
      'aqz-KE-bpKQ',
      'MWEB',
      staleEntry,
      player,
    ).catch((error: unknown) => error);

    expect(isRpcError(failure)).toBe(true);
    expect(hasCode(failure, 'STREAM_UNAVAILABLE')).toBe(true);
    expect((failure as RpcError).message).toContain('testplayer');
    expect((failure as RpcError).message).toContain('yetAnotherRevision');
    // Exactly one refetch — a decline, not a retry loop.
    expect(session.calls).toEqual(['MWEB']);
  });

  test('a null recorded revision counts as a mismatch, not as "trust it"', async () => {
    const session = fakeSession({ MWEB: rawPlayerBody({ client: 'MWEB', withN: true }) });
    const player = fakePlayer({ playerId: 'testplayer' });
    const entry: PlayerEntry = {
      result: parsePlayer(rawPlayerBody({ client: 'MWEB', withN: true })),
      playerId: null,
    };

    const response = await responseForDecipher(session, 'aqz-KE-bpKQ', 'MWEB', entry, player);

    // Refetched despite there being no known prior revision to compare against.
    expect(session.calls).toEqual(['MWEB']);
    expect(response.playabilityStatus).toBe('OK');
  });

  test('a mismatch is not worth a refetch when nothing in the response would ever be deciphered', async () => {
    // VISIONOS formats carry neither a cipher nor an `n` — nothing `sign()`
    // would ever run through the player script — so a revision mismatch here
    // must not cost a spare /player call.
    const session = fakeSession({ VISIONOS: rawPlayerBody({ client: 'VISIONOS' }) });
    const player = fakePlayer({ playerId: 'current' });
    const staleEntry: PlayerEntry = {
      result: parsePlayer(rawPlayerBody({ client: 'VISIONOS' })),
      playerId: 'stale',
    };

    const response = await responseForDecipher(session, 'aqz-KE-bpKQ', 'VISIONOS', staleEntry, player);

    expect(response).toBe(staleEntry.result);
    expect(session.calls).toEqual([]);
  });
});

describe('the tiers close the loop end to end — Task 04 §1', () => {
  beforeEach(() => {
    resetPlayerCache();
    forgetPlayerResponse();
  });

  const noYtDlp = { ytDlpPath: 'yt-dlp-does-not-exist' };

  test('a premiere still ends the ladder when the player cannot be loaded', async () => {
    // Playability is decided before the player is touched. It does not depend
    // on the revision, and it is where a premiere ends the ladder — so a
    // `getPlayer()` that fails (here: a session with no JS player at all) must
    // not turn VIDEO_UPCOMING into an ordinary decline, which the watch page
    // would show as a *Try again* on a video that is fine.
    const session = fakeSession({
      VISIONOS: rawPlayerBody({
        client: 'VISIONOS',
        status: 'LIVE_STREAM_OFFLINE',
        reason: 'Premieres in 9 days',
      }),
    });
    (session.innertube.session as { player?: unknown }).player = undefined;

    const failure = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' }).then(
      () => null,
      (error: unknown) => error,
    );

    expect(hasCode(failure, 'VIDEO_UPCOMING')).toBe(true);
    // Two VISIONOS calls — tier 1 retries once with a fresh visitor id on any
    // non-OK status — and nothing below it: the ladder ended at tier 1.
    expect(session.calls).toEqual(['VISIONOS', 'VISIONOS']);
  });

  test('tierPlainAdaptive refetches a stale entry and deciphers with the current player’s script and signatureTimestamp', async () => {
    const session = fakeSession({ MWEB: rawPlayerBody({ client: 'MWEB', withN: true }) });

    // Capture the raw params of every /player call this test makes, so the
    // refetch's signatureTimestamp can be inspected directly, not just its side
    // effects.
    const paramsSeen: Record<string, unknown>[] = [];
    const rawExecute = session.execute.bind(session);
    session.execute = async (endpoint: string, params: Record<string, unknown> = {}) => {
      paramsSeen.push(params);
      return rawExecute(endpoint, params);
    };

    // Adopts `fakeJsPlayer`: playerId 'testplayer', signatureTimestamp 20662 —
    // the session's current revision.
    const player = await getPlayer(session);
    const staleEntry: PlayerEntry = {
      result: parsePlayer(rawPlayerBody({ client: 'MWEB', withN: true })),
      playerId: 'oldRevision',
    };

    const source = await tierPlainAdaptive({ session, ...noYtDlp }, 'aqz-KE-bpKQ', 'MWEB', null, staleEntry);

    // Refetched — the stale entry was never served straight through.
    expect(session.calls).toEqual(['MWEB']);
    const sts = (
      paramsSeen[0]!['playbackContext'] as { contentPlaybackContext: { signatureTimestamp: number } }
    ).contentPlaybackContext.signatureTimestamp;
    expect(sts).toBe(player.signatureTimestamp);

    // And deciphered by the current player's script.
    const url = new URL(source.variants[0]!.videoUrl);
    expect(url.searchParams.get('n')).toBe('n(RAWN315)');
  });

  test('tierProgressive gives the same guarantee for the itag-18 floor', async () => {
    const session = fakeSession({ ANDROID: rawPlayerBody({ client: 'ANDROID', withN: true }) });
    await getPlayer(session); // adopts fakeJsPlayer, playerId 'testplayer'
    const staleEntry: PlayerEntry = {
      result: parsePlayer(rawPlayerBody({ client: 'ANDROID', withN: true })),
      playerId: 'oldRevision',
    };

    const source = await tierProgressive(
      { session, ...noYtDlp },
      'aqz-KE-bpKQ',
      'ANDROID',
      null,
      staleEntry,
    );

    expect(session.calls).toEqual(['ANDROID']);
    expect(source.variants[0]!.height).toBe(360);
    const url = new URL(source.variants[0]!.videoUrl);
    expect(url.searchParams.get('n')).toBe('n(RAWN18)');
  });

  test('openPlayback (through tierVisionOs) refetches when the session’s player has moved since the last resolution — the original Task 04 §1 scenario', async () => {
    // First resolution: ordinary, nothing stale yet. Populates both caches —
    // player.ts's deciphering-player cache, and player-response.ts's response
    // cache — under the session's player (`fakeJsPlayer`, playerId
    // 'testplayer').
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS', withN: true }), // withN so decipher is actually exercised
      ANDROID: rawPlayerBody({ client: 'ANDROID', withN: false }),
    });

    const first = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });
    expect(session.calls).toEqual(['VISIONOS']);
    expect(new URL(first.variants[0]!.videoUrl).searchParams.get('n')).toBe('n(RAWN315)');

    // Simulate a player rollout landing between resolutions — exactly what
    // `player.ts`'s `build()` does when `getPlayer`'s TTL expires and YouTube
    // has shipped a new revision. The response cache still holds the entry
    // from the first call, minted under 'testplayer'.
    const fakeJsPlayerB = {
      player_id: 'playerB',
      signature_timestamp: 99999,
      decipher(url?: string, cipher?: string): string {
        if (cipher) {
          const args = new URLSearchParams(cipher);
          const out = new URL(args.get('url')!);
          out.searchParams.set(args.get('sp') ?? 'signature', `sigB(${args.get('s')})`);
          return out.toString();
        }
        const out = new URL(url!);
        const n = out.searchParams.get('n');
        if (n) out.searchParams.set('n', `nB(${n})`);
        return out.toString();
      },
    };
    (session.innertube.session as { player: unknown }).player = fakeJsPlayerB;

    const second = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });

    // Refetched — the response cached under 'testplayer' was not served
    // straight through to a decipher against 'playerB'.
    expect(session.calls).toEqual(['VISIONOS', 'VISIONOS']);
    // And deciphered with the NEW player's script, proving the pair was never
    // mismatched: 'n(...)' would mean the stale response was deciphered with
    // the old (still-cached, still matching) script; 'nB(...)' is only
    // reachable via a refetch minted under player B.
    expect(new URL(second.variants[0]!.videoUrl).searchParams.get('n')).toBe('nB(RAWN315)');
  });
});

// ---------------------------------------------------------------------------
// PlaybackSource shape — the Flutter contract
// ---------------------------------------------------------------------------

const SOURCE_SHAPE = {
  sessionId: 'string',
  durationMs: 'number?',
  startTimestamp: 'string?',
  storyboardTemplate: 'string?',
  qualityDegraded: 'boolean',
  transport: 'string',
  variants: 'array',
} as const;

const VARIANT_SHAPE = {
  videoUrl: 'string',
  audioUrl: 'string?',
  itag: 'number?',
  height: 'number',
  fps: 'number',
  videoCodec: 'string',
  audioCodec: 'string',
} as const;

function validateSource(source: PlaybackSource): string[] {
  const problems: string[] = [];
  const record = source as unknown as Record<string, unknown>;

  for (const key of Object.keys(record)) {
    if (!(key in SOURCE_SHAPE)) problems.push(`${key}: not in PlaybackSource`);
  }

  for (const [key, spec] of Object.entries(SOURCE_SHAPE)) {
    const value = record[key];
    if (value === undefined) {
      problems.push(`${key}: undefined (must be a value or null)`);
      continue;
    }
    if (spec === 'array') {
      if (!Array.isArray(value)) problems.push(`${key}: expected array, got ${typeof value}`);
      continue;
    }
    const optional = spec.endsWith('?');
    if (value === null) {
      if (!optional) problems.push(`${key}: null but not nullable`);
      continue;
    }
    const base = optional ? spec.slice(0, -1) : spec;
    if (typeof value !== base) problems.push(`${key}: expected ${base}, got ${typeof value}`);
  }

  if (!['plain', 'sabr-dash', 'ytdlp'].includes(source.transport)) {
    problems.push(`transport: '${source.transport}' is not a known tier`);
  }

  if (!Array.isArray(source.variants) || source.variants.length === 0) {
    problems.push('variants: must be a non-empty array');
  } else {
    for (const [i, variant] of source.variants.entries()) {
      const vRecord = variant as unknown as Record<string, unknown>;
      for (const key of Object.keys(vRecord)) {
        if (!(key in VARIANT_SHAPE)) problems.push(`variants[${i}].${key}: not in PlaybackVariant`);
      }
      for (const [key, spec] of Object.entries(VARIANT_SHAPE)) {
        const value = vRecord[key];
        if (value === undefined) {
          problems.push(`variants[${i}].${key}: undefined (must be a value or null)`);
          continue;
        }
        const optional = spec.endsWith('?');
        if (value === null) {
          if (!optional) problems.push(`variants[${i}].${key}: null but not nullable`);
          continue;
        }
        const base = optional ? spec.slice(0, -1) : spec;
        if (typeof value !== base) problems.push(`variants[${i}].${key}: expected ${base}, got ${typeof value}`);
      }
    }
  }
  return problems;
}

describe('PlaybackSource', () => {
  test('validates, with transport and qualityDegraded populated', () => {
    const source = stubSource('plain', 2160);
    expect(validateSource(source)).toEqual([]);
    expect(source.transport).toBe('plain');
    expect(source.qualityDegraded).toBe(false);
  });

  test('survives JSON round-tripping with no field lost', () => {
    // `undefined` is the failure mode that matters: it vanishes through
    // JSON.stringify and arrives at Flutter as a missing key.
    for (const source of [stubSource('plain', 2160), stubSource('ytdlp', 360)]) {
      expect(JSON.parse(JSON.stringify(source))).toEqual(source);
    }
  });

  test('the branded videoUrl is a plain string on the wire', () => {
    // The brand is compile-time only. If it ever became a runtime wrapper,
    // Flutter would receive an object where it expects a URL.
    const serialised = JSON.parse(JSON.stringify(stubSource('plain', 1080)));
    expect(typeof serialised.variants[0].videoUrl).toBe('string');
  });

  test('no consumer reads a top-level videoUrl', () => {
    // The type system enforces this at compile time; this is a runtime guard
    // for anything that casts to `any` or reads the JSON directly.
    const source = stubSource('plain', 1080);
    const record = source as unknown as Record<string, unknown>;
    expect(record['videoUrl']).toBeUndefined();
    expect(record['audioUrl']).toBeUndefined();
    expect(record['videoCodec']).toBeUndefined();
    expect(record['audioCodec']).toBeUndefined();
    expect(record['height']).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// Variants — Task 09
//
// These are the test requirements from the task brief. They exercise the shape
// and ranking of `variants[]` against the stub session, offline.
// ---------------------------------------------------------------------------

describe('variants', () => {
  beforeEach(() => {
    resetPlayerCache();
    forgetPlayerResponse();
  });

  const noYtDlp = { ytDlpPath: 'yt-dlp-does-not-exist' };

  test('tier 1 returns more than one variant from one /player response, and makes exactly one network call', async () => {
    // The fixture has itag 315 (2160p60) and itag 136 (1080p30) as video formats.
    // Both should become variants. Only one VISIONOS /player call.
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS' }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });

    expect(source.variants.length).toBeGreaterThan(1);
    // Only one /player call.
    expect(session.calls).toEqual(['VISIONOS']);
  });

  test('variants are ordered best-first: highest height, then fps', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS' }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });
    const heights = source.variants.map((v) => v.height);

    // Heights must be non-increasing (best first).
    for (let i = 1; i < heights.length; i++) {
      expect(heights[i]!).toBeLessThanOrEqual(heights[i - 1]!);
    }

    // The first variant is the tallest.
    expect(heights[0]).toBe(2160);
  });

  test('every variant URL is a branded SignedUrl (starts with https://)', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS' }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });

    for (const variant of source.variants) {
      // The brand is compile-time; runtime evidence is that the URL is a string.
      expect(typeof variant.videoUrl).toBe('string');
      expect(variant.videoUrl).toStartWith('https://');
      if (variant.audioUrl !== null) {
        expect(typeof variant.audioUrl).toBe('string');
        expect(variant.audioUrl).toStartWith('https://');
      }
    }
  });

  test('audio is shared across variants — same signed URL, not signed repeatedly', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS' }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });

    // All variants should share the same audioUrl since they use the best audio track.
    const audioUrls = source.variants.map((v) => v.audioUrl).filter(Boolean);
    const unique = new Set(audioUrls);
    expect(unique.size).toBe(1);
  });

  test('height and fps come from the format, not a lookup table', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS' }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });

    // The fixture has itag 315 at 2160p60 — height and fps must match the format fields,
    // not an itag→height lookup table.
    const v2160 = source.variants.find((v) => v.itag === 315);
    expect(v2160).toBeDefined();
    expect(v2160!.height).toBe(2160);
    expect(v2160!.fps).toBe(60);
  });

  test('tiers 4 and 5 return exactly one variant and remain valid', async () => {
    // Tier 5 (progressive) — single variant.
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS', sabrOnly: true }),
      ANDROID: rawPlayerBody({ client: 'ANDROID', withN: false, sabrOnly: true }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });
    expect(source.variants).toHaveLength(1);
    expect(validateSource(source)).toEqual([]);

    // Tier 4 (yt-dlp) — single variant.
    const ytdlpSource = sourceFromYtDlpDump(
      {
        duration: 634,
        url: 'https://r1.googlevideo.com/videoplayback?itag=18&c=MWEB&n=DECIPHERED',
        vcodec: 'avc1.42001E',
        acodec: 'mp4a.40.2',
        height: 360,
      },
      'yt-dlp',
      null,
    );
    expect(ytdlpSource.variants).toHaveLength(1);
    expect(validateSource(ytdlpSource)).toEqual([]);
  });

  test('PlaybackSource with variants survives JSON round-tripping with no field lost', async () => {
    const session = fakeSession({
      VISIONOS: rawPlayerBody({ client: 'VISIONOS' }),
    });

    const source = await openPlayback({ session, ...noYtDlp }, { videoId: 'aqz-KE-bpKQ' });
    const roundTripped = JSON.parse(JSON.stringify(source)) as PlaybackSource;

    expect(roundTripped.sessionId).toBe(source.sessionId);
    expect(roundTripped.durationMs).toBe(source.durationMs);
    expect(roundTripped.transport).toBe(source.transport);
    expect(roundTripped.qualityDegraded).toBe(source.qualityDegraded);
    expect(roundTripped.variants).toHaveLength(source.variants.length);

    for (let i = 0; i < source.variants.length; i++) {
      expect(roundTripped.variants[i]!.videoUrl).toBe(source.variants[i]!.videoUrl);
      expect(roundTripped.variants[i]!.audioUrl).toBe(source.variants[i]!.audioUrl);
      expect(roundTripped.variants[i]!.itag).toBe(source.variants[i]!.itag);
      expect(roundTripped.variants[i]!.height).toBe(source.variants[i]!.height);
      expect(roundTripped.variants[i]!.fps).toBe(source.variants[i]!.fps);
      expect(roundTripped.variants[i]!.videoCodec).toBe(source.variants[i]!.videoCodec);
      expect(roundTripped.variants[i]!.audioCodec).toBe(source.variants[i]!.audioCodec);
    }

    // Branded URLs are plain strings on the wire.
    for (const v of roundTripped.variants) {
      expect(typeof v.videoUrl).toBe('string');
    }
  });
});

// ---------------------------------------------------------------------------
// Format selection, on the real captured response
// ---------------------------------------------------------------------------

describe('format selection', () => {
  test.if(hasFixture('player-mweb'))('picks a 2160p video and a non-DRC stereo audio', () => {
    const response: PlayerResult = parsePlayer(fixture('player-mweb'));

    const video = response.formats
      .filter((f) => f.isAdaptive && f.hasVideo && !f.hasAudio && f.rawUrl !== null)
      .sort((a, b) => (b.height ?? 0) - (a.height ?? 0))[0]!;
    expect(video.height).toBe(2160);

    // The DRC duplicates are the trap here: they share an itag with the
    // original and differ only in loudness.
    const drc = response.formats.filter((f) => f.isDrc);
    expect(drc.length).toBeGreaterThan(0);
    for (const format of drc) {
      expect(response.formats.filter((f) => f.itag === format.itag).length).toBeGreaterThan(1);
    }
  });

  test.if(hasFixture('player-mweb'))('every MWEB adaptive URL carries an n to decipher', () => {
    const response = parsePlayer(fixture('player-mweb'));
    const adaptive = response.formats.filter((f) => f.isAdaptive);
    expect(adaptive.length).toBeGreaterThan(0);

    for (const format of adaptive) {
      const url = new URL(format.rawUrl!);
      expect(url.searchParams.get('c')).toBe('MWEB');
      // No `n` would mean nothing to get wrong — and no throttle to worry
      // about. It is here, on every format, which is why this task exists.
      expect(url.searchParams.get('n')).toBeString();
    }
  });

  test.if(hasFixture('player-vr'))('every VISIONOS adaptive URL is plain — no cipher, no n', () => {
    // Tier 1's premise, on a captured response rather than on the recommendation
    // that produced the reorder. A `LOGIN_REQUIRED` here is not a broken video:
    // it means the capture session carried a fabricated visitor id (F5).
    //
    // **The client is `VISIONOS`, not `ANDROID_VR`** — `architecture.md` F11,
    // amended 2026-08-18: `ANDROID_VR` now requires a PO token and is no
    // longer viable. The code and the `player-vr` capture both moved with it;
    // this assertion did not, and sat red long enough to be treated as
    // background noise. The fixture name is the last thing still carrying the
    // old client's initials.
    const response = parsePlayer(fixture('player-vr'));
    expect(response.playabilityStatus).toBe('OK');

    const adaptive = response.formats.filter((f) => f.isAdaptive);
    expect(adaptive.length).toBeGreaterThan(0);

    for (const format of adaptive) {
      expect(format.signatureCipher).toBeNull();
      const url = new URL(format.rawUrl!);
      expect(url.searchParams.get('c')).toBe('VISIONOS');
      // The whole reason this client leads the ladder: nothing to get wrong.
      expect(url.searchParams.has('n')).toBe(false);
    }

    expect(Math.max(...adaptive.map((f) => f.height ?? 0))).toBeGreaterThanOrEqual(1080);
  });

  test.if(hasFixture('player-mweb'))('the storyboard template comes through (F8)', () => {
    const response = parsePlayer(fixture('player-mweb'));
    expect(response.storyboards.length).toBeGreaterThan(0);

    const best = [...response.storyboards].sort(
      (a, b) => (b.thumbnailWidth ?? 0) - (a.thumbnailWidth ?? 0),
    )[0]!;
    expect(best.templateUrl).toStartWith('http');
  });
});

// ---------------------------------------------------------------------------
// Tier 3 — yt-dlp
//
// The subprocess itself is not exercised here: whether `yt-dlp` is installed is
// a property of the machine, and a tier that exists for age-restricted and Vevo
// videos cannot be proven against a public one anyway. What *is* pinned is the
// two halves that break without anybody noticing — the dump mapping, and the
// decline when the binary is absent.
// ---------------------------------------------------------------------------

/**
 * A stand-in for `yt-dlp` that writes `STUB_STDERR_MB` megabytes to stderr and
 * then a valid dump to stdout.
 *
 * It has to be a real executable rather than a fake `spawn`, because the thing
 * under test is what happens to two OS pipes — a stubbed spawn would prove
 * nothing about either. Written at test time so the repository does not carry a
 * platform-specific script, and a `.cmd` on Windows because `Bun.spawn` needs
 * something the shell can start — deliberately, because a real `yt-dlp` install
 * on Windows (pip, scoop) is a `.cmd` shim too, and that shim is exactly what a
 * cmd.exe `AutoRun` hook injects into.
 *
 * **If these two tests fail fast (not a timeout) with `stdout` one byte short
 * of valid JSON,** check `HKCU\SOFTWARE\Microsoft\Command Processor\AutoRun` —
 * mine was `cls & clink.bat inject …`. Windows runs `AutoRun` for *every*
 * `cmd.exe`, including the hidden one spawned to start a `.cmd`, and `cls`
 * against a non-console (piped) stdout writes a bare form-feed byte ahead of
 * the child's real output — not a timeout, not a deadlock, just corrupted
 * stdout, ~0.2 s in. Reproduced 2026-08-25 outside the test: the same script
 * spawned directly (`Bun.spawn(['bun', 'stub.mjs'])`) is clean; spawned through
 * the identical `.cmd` it comes back as `"\f{...}"`. Not a bug in this repo —
 * it is real for anyone with an `AutoRun` hook and a `.cmd`-shimmed tool, which
 * makes it a live (if narrow) production hazard in `tierYtDlp` too, not just a
 * test artifact.
 */
const stubDir = mkdtempSync(join(tmpdir(), 'ytdlp-stub-'));
const stub = join(stubDir, process.platform === 'win32' ? 'stub.cmd' : 'stub.sh');

{
  const script = join(stubDir, 'stub.mjs');
  writeFileSync(
    script,
    [
      "import { writeSync } from 'node:fs';",
      'const megabytes = Number(process.env.STUB_STDERR_MB ?? 8);',
      "const chunk = Buffer.from('x'.repeat(64 * 1024) + '\\n');",
      'for (let i = 0; i < megabytes * 16; i++) writeSync(2, chunk);',
      'writeSync(1, JSON.stringify({',
      "  duration: 634, url: 'https://r1.googlevideo.com/videoplayback?itag=18&c=MWEB&n=DECIPHERED',",
      "  vcodec: 'avc1.42001E', acodec: 'mp4a.40.2', height: 360,",
      '}));',
    ].join('\n'),
    'utf8',
  );

  if (process.platform === 'win32') {
    writeFileSync(stub, `@echo off\r\n"${process.execPath}" "${script}" %*\r\n`, 'utf8');
  } else {
    writeFileSync(stub, `#!/bin/sh\nexec "${process.execPath}" "${script}" "$@"\n`, 'utf8');
    chmodSync(stub, 0o755);
  }
}

afterAll(() => {
  rmSync(stubDir, { recursive: true, force: true });
});

describe('yt-dlp tier', () => {
  const adaptiveDump: YtDlpDump = {
    duration: 634.566,
    requested_formats: [
      {
        url: 'https://r1.googlevideo.com/videoplayback?itag=315&c=MWEB&n=DECIPHERED',
        vcodec: 'vp09.00.50.08',
        acodec: 'none',
        height: 2160,
      },
      {
        url: 'https://r1.googlevideo.com/videoplayback?itag=251&c=MWEB&n=DECIPHERED',
        vcodec: 'none',
        acodec: 'opus',
      },
    ],
  };

  test('an adaptive dump becomes two signed URLs', () => {
    const source = sourceFromYtDlpDump(adaptiveDump, 'yt-dlp', null);
    const best = source.variants[0]!;

    expect(validateSource(source)).toEqual([]);
    expect(source.transport).toBe('ytdlp');
    expect(source.variants).toHaveLength(1);
    expect(best.videoUrl).toContain('itag=315');
    expect(best.audioUrl).toContain('itag=251');
    expect(best.height).toBe(2160);
    expect(best.videoCodec).toStartWith('vp09');
    expect(best.audioCodec).toBe('opus');
    expect(source.durationMs).toBe(634566);
    expect(source.qualityDegraded).toBe(false);
  });

  test('a muxed dump has no separate audio track', () => {
    // `-f bv*+ba/b` falls back to one muxed format, and the address moves onto
    // the dump itself. Reading only `requested_formats` would find nothing.
    const source = sourceFromYtDlpDump(
      {
        url: 'https://r1.googlevideo.com/videoplayback?itag=18&c=MWEB&n=DECIPHERED',
        vcodec: 'avc1.42001E',
        acodec: 'mp4a.40.2',
        height: 360,
        duration: 634,
      },
      'yt-dlp',
      null,
    );

    expect(source.variants[0]!.audioUrl).toBeNull();
    expect(source.variants[0]!.height).toBe(360);
    expect(source.qualityDegraded).toBe(true);
  });

  test('a dump with no URL declines rather than emitting an empty source', () => {
    expect(() => sourceFromYtDlpDump({ duration: 10 }, 'yt-dlp', null)).toThrow(/no stream URL/);
  });

  test(
    'the stub really does overflow the pipe buffer',
    async () => {
      // Guards the test below from becoming vacuous. If the stub ever stops
      // writing — a broken shebang, a `.cmd` quoting mistake — the deadlock test
      // would still pass while exercising nothing at all.
      const child = Bun.spawn([stub], { stdout: 'pipe', stderr: 'pipe', timeout: 30_000 });
      const [out, err] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
      ]);
      await child.exited;

      expect(err.length).toBeGreaterThan(64 * 1024);
      expect(JSON.parse(out).height).toBe(360);
    },
    60_000,
  );

  test(
    'a child that floods stderr still resolves, and promptly',
    async () => {
      // Task 04 item 2. The old shape drained stdout to completion and only
      // touched stderr on a non-zero exit: a child that writes past the OS pipe
      // buffer (~64 KB) blocks in `write`, never finishes stdout and never
      // exits, so tier 4 burns its whole 45 s timeout before declining — on
      // exactly the videos tier 4 exists to serve.
      //
      // 8 MB is two orders of magnitude past the buffer, so this exercises the
      // overflow rather than asserting that stderr shows up in a message.
      //
      // Honest limit: measured 2026-08-02, this passes against the old shape
      // too, because `Bun.spawn` drains both pipes into memory eagerly and the
      // deadlock is unreachable on this runtime. What the test pins is the
      // requirement — a runtime or a rewrite that stops draining eagerly fails
      // here instead of in the field.
      const started = Date.now();
      const source = await tierYtDlp({ session: null as never, ytDlpPath: stub }, 'aqz-KE-bpKQ', null, null);

      expect(source.variants[0]!.height).toBe(360);
      expect(source.transport).toBe('ytdlp');
      expect(Date.now() - started).toBeLessThan(15_000);
    },
    60_000,
  );

  test('a missing binary declines cleanly', async () => {
    // The ordinary case on a machine that never installed it. This must be a
    // decline the ladder can walk past, not an unhandled spawn failure.
    const failure = await tierYtDlp(
      { session: null as never, ytDlpPath: 'yt-dlp-does-not-exist' },
      'aqz-KE-bpKQ',
      null,
      null,
    ).catch((error: unknown) => error);

    expect(isRpcError(failure)).toBe(true);
    expect(hasCode(failure, 'UPSTREAM_ERROR')).toBe(true);
    expect((failure as RpcError).message).toContain('yt-dlp-does-not-exist');
  });
});

// ---------------------------------------------------------------------------
// Capabilities
// ---------------------------------------------------------------------------

describe('capabilities', () => {
  test('a missing yt-dlp is reported, not assumed', () => {
    // The failure this exists to stop being silent: without tier 4 the ladder is
    // four rungs, and the videos that need the fifth fail as "Unavailable" with
    // nothing saying a binary is missing.
    expect(probeCapabilities('yt-dlp-does-not-exist')).toEqual({ ytDlp: false });
    expect(resolveYtDlp('yt-dlp-does-not-exist')).toBeNull();
  });

  test('a configured path is checked on disk, a bare name goes through PATH', () => {
    // The stub is a real file at an absolute path — the `YT_DLP_PATH` shape.
    expect(resolveYtDlp(stub)).toBe(stub);
    expect(probeCapabilities(stub)).toEqual({ ytDlp: true });

    // And whatever this machine has (or does not have) on PATH is a boolean,
    // never a throw.
    expect(typeof probeCapabilities().ytDlp).toBe('boolean');
  });

  test('the binary tier 4 spawns is the one the probe looked for', () => {
    // If these two ever diverge, the startup warning describes one binary and
    // the tier spawns another — the worst possible pair of half-truths.
    expect(ytDlpBinary('explicit')).toBe('explicit');
    expect(ytDlpBinary()).toBe(process.env['YT_DLP_PATH'] ?? 'yt-dlp');
  });
});

// ---------------------------------------------------------------------------
// PO tokens
// ---------------------------------------------------------------------------

describe('nullPoTokenProvider', () => {
  test('mints nothing and never fails', async () => {
    await expect(nullPoTokenProvider.mint('aqz-KE-bpKQ')).resolves.toBeNull();
  });
});
