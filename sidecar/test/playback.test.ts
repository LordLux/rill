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

import { describe, expect, test } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { hasCode, isRpcError, RpcError } from '../src/errors.ts';
import type { Player } from '../src/innertube/player.ts';
import { adoptExternallyDeciphered, sign } from '../src/innertube/signed-url.ts';
import { parsePlayer } from '../src/parser/index.ts';
import {
  descendLadder,
  sourceFromYtDlpDump,
  tierYtDlp,
  type Tier,
  type YtDlpDump,
} from '../src/playback/resolve.ts';
import { isSabrOnly, isSabrOnlyAdaptive } from '../src/playback/sabr-detect.ts';
import { nullPoTokenProvider } from '../src/playback/po-token.ts';
import type { PlaybackSource, PlayerResult } from '../src/types.ts';

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

const MWEB_URL =
  'https://r1.googlevideo.com/videoplayback?expire=1&itag=315&c=MWEB&n=RAWNVALUE&mime=video%2Fwebm';
const VR_URL = 'https://r1.googlevideo.com/videoplayback?expire=1&itag=315&c=ANDROID_VR';

// ---------------------------------------------------------------------------
// sabr-detect — the Phase 2 tripwire
// ---------------------------------------------------------------------------

describe('isSabrOnly', () => {
  test.if(hasFixture('player-mweb'))('MWEB is false — Phase 1 still has a plain path', () => {
    const response = parsePlayer(fixture('player-mweb'));
    expect(response.playabilityStatus).toBe('OK');

    // If this ever flips, MWEB has gone the way of WEB and the SABR → DASH
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
  test('MWEB output carries a deciphered n', async () => {
    const signed = await sign(MWEB_URL, fakePlayer());
    const url = new URL(signed);

    expect(url.searchParams.get('n')).toBe('n(RAWNVALUE)');
    // Presence alone proves nothing — the raw URL had an `n` too. What matters
    // is that the value changed.
    expect(url.searchParams.get('n')).not.toBe('RAWNVALUE');
  });

  test('ANDROID_VR is accepted without one', async () => {
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
    await expect(sign(MWEB_URL, brokenPlayer)).rejects.toThrow(/no-op/);
  });

  test("the player script's own refusal is caught", async () => {
    const givesUp = fakePlayer({ decipherN: async () => 'enhanced_except_abc123' });
    await expect(sign(MWEB_URL, givesUp)).rejects.toThrow(/rejected n=/);
  });

  test('a signatureCipher is unwrapped, deciphered and reassembled', async () => {
    const inner = 'https://r1.googlevideo.com/videoplayback?itag=251&c=MWEB&n=RAWN';
    const cipher = new URLSearchParams({ s: 'SIGVALUE', sp: 'sig', url: inner }).toString();

    const url = new URL(await sign(cipher, fakePlayer()));
    expect(url.searchParams.get('sig')).toBe('sig(SIGVALUE)');
    expect(url.searchParams.get('n')).toBe('n(RAWN)');
  });

  test('a no-op signature transform is refused too', async () => {
    const inner = 'https://r1.googlevideo.com/videoplayback?itag=251&c=ANDROID_VR';
    const cipher = new URLSearchParams({ s: 'SIGVALUE', sp: 'sig', url: inner }).toString();
    await expect(sign(cipher, brokenPlayer)).rejects.toThrow(/no-op/);
  });

  test('a PO token is applied inside the constructor, not bolted on after', async () => {
    // Appending `pot=` to a finished SignedUrl would mean mutating a value the
    // type says is already final.
    const signed = await sign(MWEB_URL, fakePlayer(), { poToken: 'TOKEN' });
    expect(new URL(signed).searchParams.get('pot')).toBe('TOKEN');

    const without = await sign(MWEB_URL, fakePlayer());
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
    const adopted = adoptExternallyDeciphered(MWEB_URL, 'yt-dlp');
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
function stubSource(transport: PlaybackSource['transport'], height: number): PlaybackSource {
  return {
    sessionId: 'test',
    // A legitimate constructor rather than a cast — nothing outside
    // `signed-url.ts` should be minting these, tests included.
    videoUrl: adoptExternallyDeciphered(MWEB_URL, 'test'),
    audioUrl: null,
    durationMs: 1000,
    videoCodec: 'vp9',
    audioCodec: null,
    height,
    storyboardTemplate: null,
    qualityDegraded: height < 720,
    transport,
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
    expect(source.height).toBe(2160);
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
// PlaybackSource shape — the Flutter contract
// ---------------------------------------------------------------------------

const SOURCE_SHAPE = {
  sessionId: 'string',
  videoUrl: 'string',
  audioUrl: 'string?',
  durationMs: 'number?',
  videoCodec: 'string?',
  audioCodec: 'string?',
  height: 'number?',
  storyboardTemplate: 'string?',
  qualityDegraded: 'boolean',
  transport: 'string',
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
    expect(typeof serialised.videoUrl).toBe('string');
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

    expect(validateSource(source)).toEqual([]);
    expect(source.transport).toBe('ytdlp');
    expect(source.videoUrl).toContain('itag=315');
    expect(source.audioUrl).toContain('itag=251');
    expect(source.height).toBe(2160);
    expect(source.videoCodec).toStartWith('vp09');
    expect(source.audioCodec).toBe('opus');
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

    expect(source.audioUrl).toBeNull();
    expect(source.height).toBe(360);
    expect(source.qualityDegraded).toBe(true);
  });

  test('a dump with no URL declines rather than emitting an empty source', () => {
    expect(() => sourceFromYtDlpDump({ duration: 10 }, 'yt-dlp', null)).toThrow(/no stream URL/);
  });

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
// PO tokens
// ---------------------------------------------------------------------------

describe('nullPoTokenProvider', () => {
  test('mints nothing and never fails', async () => {
    await expect(nullPoTokenProvider.mint('aqz-KE-bpKQ')).resolves.toBeNull();
  });
});
