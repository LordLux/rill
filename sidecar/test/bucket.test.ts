/**
 * The poisoned-bucket retry (F20) — **retired, and this file now guards the
 * retirement rather than the mechanism.**
 *
 * The history, because it is the reason for the shape of this file. About 27%
 * of resolve sessions were minted into a YouTube experiment bucket
 * (`fexp=51946838`) whose URLs refuse ffmpeg's request shape for the life of
 * the session, and re-minting the session escaped it — measured 26.7% → 3.3%
 * over four rounds. That worked only because the rollout was partial and a
 * fresh mint could randomly draw an *unflagged* bucket. The rollout reached
 * 100% (`architecture.md` F5, F20), unflagged buckets stopped existing, and the
 * escape rate went to zero. `MAX_REMINTS` was set to 0 in `c53fb54` and the
 * behavioural blocks below were skipped in the same commit.
 *
 * They are kept, skipped, because they are the executable record of what was
 * measured. **`describe('the retirement')` at the bottom is live**, and it is
 * the part that matters: it fails if anyone re-wires `playback.open` to the
 * re-mint wrapper. That is not hypothetical — Task 22 did exactly that on
 * 2026-09-09, reading a leftover `remintResolveSession` argument (an excess
 * property left behind when `663edb1` unwired the call site by accident) as
 * evidence the wiring was broken, and restored a mechanism the docs record as
 * retired. Nothing failed, because nothing was watching. Now something is.
 *
 * One invariant outlives the mechanism and is asserted below: if anything here
 * ever re-mints a session again, it replaces the **resolve** session only.
 * `browseSessionPromise` carries the user's cookies, and dropping it to fix a
 * stream URL signs them out silently (F7).
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

  // The companion test — that the *server* re-mints the resolve promise and
  // leaves the browse one alone — is gone with `remintResolveSession()` itself.
  // Its invariant is restated in `server.ts` where the function used to be, and
  // the retirement block below asserts nothing has re-introduced a caller.
});

describe('the retirement', () => {
  // Live, unlike everything above. Read the file header first.

  test('the cap is zero — re-minting escapes nothing at 100% rollout', () => {
    // The table this number used to be chosen from, kept because it is what a
    // future partial rollout would make relevant again:
    // 0 → 26.7%, 1 → 7.1%, 2 → 1.9%, 3 → 0.5%. Those residuals assume
    // unflagged buckets exist to be drawn. They do not (F20, amended
    // 2026-08-18), which is why the answer is 0 and not 2.
    expect(MAX_REMINTS).toBe(0);
  });

  test('`playback.open` resolves through the bare ladder, not the re-mint wrapper', async () => {
    // The guard that would have caught Task 22. Source-level and blunt on
    // purpose: the alternative is asserting on a dynamic import inside a 400-line
    // `if`/`else` chain, and this failure needs to be legible to whoever trips
    // it rather than clever.
    const server = await Bun.file('src/rpc/server.ts').text();
    const code = server
      .split('\n')
      .filter((line) => !line.trimStart().startsWith('//') && !line.trimStart().startsWith('*'))
      .join('\n');

    // Booleans, not `toContain` on the source: a failing `toContain` prints the
    // entire 900-line file, which buries the one sentence that explains it.
    const mentions = (name: string) => code.includes(name);

    expect({
      revivedTheWrapper: mentions('openPlaybackPastBucket'),
      revivedTheRemint: mentions('remintResolveSession'),
      importsTheBareLadder: mentions("import('../playback/resolve.ts')"),
    }).toEqual({
      revivedTheWrapper: false,
      revivedTheRemint: false,
      importsTheBareLadder: true,
    });
  });

  test('the flag list survives, because YouTube can retire or fork it', () => {
    expect(Array.isArray(POISONED_FEXP_FLAGS)).toBe(true);
    expect(POISONED_FEXP_FLAGS).toContain('51946838');
  });
});
