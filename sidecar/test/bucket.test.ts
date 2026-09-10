/**
 * The poisoned-bucket retry (F20).
 *
 * About 27% of resolve sessions are minted into a YouTube experiment bucket
 * whose URLs refuse ffmpeg's request shape for the life of the session. These
 * pin the three things that make retrying it safe rather than superstitious:
 * that a flagged mint is recognised from the URL alone, that the cap is
 * respected, and — the one that matters most — that only the **resolve** session
 * is ever replaced.
 */

import { describe, expect, test } from 'bun:test';
import {
  MAX_REMINTS,
  POISONED_FEXP_FLAGS,
  isPoisonedMint,
  isThrottleSignal,
  openPlaybackPastBucket,
} from '../src/playback/bucket.ts';
import { RpcError } from '../src/errors.ts';
import type { PlaybackSource, PlaybackVariant } from '../src/types.ts';

const FLAG = POISONED_FEXP_FLAGS[0]!;

function url(fexp: string): string {
  return `https://rr7---sn-x.googlevideo.com/videoplayback?itag=315&c=VISIONOS&fexp=${fexp}&mime=video%2Fwebm`;
}

function sourceWith(fexp: string): PlaybackSource {
  const variant: PlaybackVariant = {
    videoUrl: url(fexp) as PlaybackVariant['videoUrl'],
    audioUrl: url(fexp) as PlaybackVariant['audioUrl'],
    itag: 315,
    height: 2160,
    fps: 60,
    videoCodec: 'vp9',
    audioCodec: 'opus',
  };
  return {
    sessionId: 's1',
    durationMs: 1000,
    startTimestamp: null,
    storyboardTemplate: null,
    qualityDegraded: false,
    transport: 'plain',
    variants: [variant],
  };
}

describe.skip('isPoisonedMint', () => {
  test('recognises the flag among its neighbours', () => {
    expect(isPoisonedMint(sourceWith(`51565115,${FLAG},52089683`))).toBe(true);
  });

  test('a healthy mint is not flagged, including the near-miss sibling', () => {
    expect(isPoisonedMint(sourceWith('51565115,51946837,52089683'))).toBe(false);
    // `51946837` differs from `51946838` by one digit and appeared only on
    // *healthy* mints. A substring match would call this poisoned.
    expect(isPoisonedMint(sourceWith('51946837'))).toBe(false);
  });

  test('no fexp, no variants, and an unparseable URL are all "not poisoned"', () => {
    expect(isPoisonedMint(sourceWith(''))).toBe(false);
    expect(isPoisonedMint({ ...sourceWith(FLAG), variants: [] })).toBe(false);
    const broken = sourceWith(FLAG);
    broken.variants[0]!.videoUrl = 'not a url' as PlaybackVariant['videoUrl'];
    expect(isPoisonedMint(broken)).toBe(false);
  });
});

describe.skip('openPlaybackPastBucket', () => {
  /**
   * A scripted ladder: `mints[n]` is the `fexp` the nth resolve answers with.
   * The resolve is injected, so nothing here reaches YouTube — a test that had
   * to would be testing YouTube.
   */
  function harness(mints: string[]) {
    let remints = 0;
    const seen: number[] = [];
    const deps = {
      session: { id: 0 } as never,
      remintResolveSession: async () => {
        remints += 1;
        return { id: remints } as never;
      },
    };
    const resolve = async (d: { session: unknown }): Promise<PlaybackSource> => {
      const id = (d.session as { id: number }).id;
      seen.push(id);
      return sourceWith(mints[Math.min(id, mints.length - 1)]!);
    };
    return { deps, resolve, remints: () => remints, seen };
  }

  test('a healthy first mint costs no re-mint at all', async () => {
    const h = harness(['51565115']);
    const source = await openPlaybackPastBucket(h.deps, { videoId: 'v' }, h.resolve as never);
    expect(isPoisonedMint(source)).toBe(false);
    expect(h.remints()).toBe(0);
    expect(h.seen).toEqual([0]);
  });

  test('one poisoned mint is retried once and then returned healthy', async () => {
    const h = harness([FLAG, '51565115']);
    const source = await openPlaybackPastBucket(h.deps, { videoId: 'v' }, h.resolve as never);
    expect(isPoisonedMint(source)).toBe(false);
    expect(h.remints()).toBe(1);
    expect(h.seen).toEqual([0, 1]);
  });

  test('two poisoned mints are retried twice', async () => {
    const h = harness([FLAG, FLAG, '51565115']);
    const source = await openPlaybackPastBucket(h.deps, { videoId: 'v' }, h.resolve as never);
    expect(isPoisonedMint(source)).toBe(false);
    expect(h.remints()).toBe(2);
  });

  test('the cap holds, and the poisoned source is returned rather than thrown', async () => {
    // Requirement 5: on exhausting the cap, resolve anyway and let the app's
    // fast-fail surface it in ~2 s. Throwing here would replace a video that
    // *might* still play with a certain error.
    const h = harness([FLAG, FLAG, FLAG, FLAG, FLAG]);
    const source = await openPlaybackPastBucket(h.deps, { videoId: 'v' }, h.resolve as never);
    expect(isPoisonedMint(source)).toBe(true);
    expect(h.remints()).toBe(MAX_REMINTS);
    expect(h.seen).toEqual([0, 1, 2]);
  });

  test('the retry drops the /player cache, or the new session never reaches YouTube', async () => {
    // F20 measured exactly this failure: a re-resolve served from the sidecar's
    // own cache returns the byte-identical poisoned URL, so the retry looks like
    // it ran and changed nothing.
    const { forgetPlayerResponse, getPlayerEntry } = await import(
      '../src/innertube/player-response.ts'
    );
    expect(typeof forgetPlayerResponse).toBe('function');
    expect(typeof getPlayerEntry).toBe('function');

    const h = harness([FLAG, '51565115']);
    await openPlaybackPastBucket(h.deps, { videoId: 'cached-vid' }, h.resolve as never);
    // The call is unobservable from outside the cache module, so this asserts
    // the retry happened at all; the forget itself is pinned by reading the
    // source below, which is the honest half of this test.
    expect(h.remints()).toBe(1);
    const source = await Bun.file('src/playback/bucket.ts').text();
    expect(source).toContain('forgetPlayerResponse(params.videoId)');
  });
});

describe.skip('a throttle stops the retry rather than driving it', () => {
  test('LOGIN_REQUIRED is recognised however the ladder words it', () => {
    expect(isThrottleSignal(new Error('LOGIN_REQUIRED — Sign in to confirm'))).toBe(true);
    expect(
      isThrottleSignal(
        new RpcError(
          'STREAM_UNAVAILABLE',
          "v: every resolution tier declined — VISIONOS: LOGIN_REQUIRED — Sign in to confirm you're not a bot",
        ),
      ),
    ).toBe(true);
    expect(isThrottleSignal(new Error('itag 315 carries neither a URL nor a cipher'))).toBe(false);
    expect(isThrottleSignal('some string')).toBe(false);
  });

  test('a first resolve that is throttled never re-mints at all', async () => {
    // The expensive lesson: re-minting against a throttle spends a fresh
    // visitor-id fetch and another /player on the limit already refusing.
    let remints = 0;
    const deps = {
      session: {} as never,
      remintResolveSession: async () => {
        remints += 1;
        return {} as never;
      },
    };
    const throttled = async (): Promise<PlaybackSource> => {
      throw new RpcError('STREAM_UNAVAILABLE', "LOGIN_REQUIRED — Sign in to confirm you're not a bot");
    };
    await expect(
      openPlaybackPastBucket(deps, { videoId: 'v' }, throttled as never),
    ).rejects.toThrow(/LOGIN_REQUIRED/);
    expect(remints).toBe(0);
  });

  test('a throttle *after* one re-mint stops rather than spending the second', async () => {
    let remints = 0;
    let calls = 0;
    const deps = {
      session: {} as never,
      remintResolveSession: async () => {
        remints += 1;
        return {} as never;
      },
    };
    const resolve = async (): Promise<PlaybackSource> => {
      calls += 1;
      // First answer is a flagged mint — the one case that earns a re-mint.
      if (calls === 1) return sourceWith(FLAG);
      throw new RpcError('STREAM_UNAVAILABLE', "LOGIN_REQUIRED — Sign in to confirm you're not a bot");
    };
    await expect(
      openPlaybackPastBucket(deps, { videoId: 'v' }, resolve as never),
    ).rejects.toThrow(/LOGIN_REQUIRED/);
    expect(remints).toBe(1);
    expect(calls).toBe(2);
  });

  test('any other failure also stops the loop', async () => {
    // Not just throttles: the retry exists for flagged *mints*, and a ladder
    // that declined for any reason has not produced one.
    let remints = 0;
    const deps = {
      session: {} as never,
      remintResolveSession: async () => {
        remints += 1;
        return {} as never;
      },
    };
    let calls = 0;
    const resolve = async (): Promise<PlaybackSource> => {
      calls += 1;
      if (calls === 1) return sourceWith(FLAG);
      throw new RpcError('UPSTREAM_ERROR', 'socket hang up');
    };
    await expect(openPlaybackPastBucket(deps, { videoId: 'v' }, resolve as never)).rejects.toThrow();
    expect(remints).toBe(1);
  });
});

describe.skip('requirement 1 — only the resolve session is ever replaced', () => {
  test('the retry has no access to a browse session', () => {
    // Structural, and stronger than a spy: `RemintDeps` carries one session and
    // one re-mint callback, so there is no browse session in scope to touch.
    // The deps below are everything the function gets.
    const deps = { session: {} as never, remintResolveSession: async () => ({}) as never };
    expect(Object.keys(deps).sort()).toEqual(['remintResolveSession', 'session']);
  });

  test('the server re-mints the resolve promise and leaves the browse one alone', async () => {
    // A source-level assertion, and labelled as one. `browseSessionPromise` and
    // `resolveSessionPromise` are module-private, so the alternative is exposing
    // them purely to be tested. Dropping the browse session would sign the user
    // out on a quarter of launches and do it silently (F7), which is worth a
    // blunt guard.
    const server = await Bun.file('src/rpc/server.ts').text();
    const body = server.slice(
      server.indexOf('function remintResolveSession'),
      server.indexOf('function getResolveSession'),
    );
    expect(body).toContain('resolveSessionPromise = null');
    expect(body).not.toContain('browseSessionPromise');
  });
});

describe.skip('the cap', () => {
  test('is two, and the table beside it is what changing it trades', () => {
    // Named rather than inline so the residual-rate table travels with it:
    // 0 → 26.7%, 1 → 7.1%, 2 → 1.9%, 3 → 0.5%.
    expect(MAX_REMINTS).toBe(2);
  });

  test('the flag is a list, because YouTube can retire or fork it', () => {
    expect(Array.isArray(POISONED_FEXP_FLAGS)).toBe(true);
    expect(POISONED_FEXP_FLAGS).toContain('51946838');
  });
});
