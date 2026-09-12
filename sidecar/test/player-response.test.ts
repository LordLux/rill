/**
 * The shared `/player` cache — and specifically what including the playlist id
 * in its key did and did not change (Task 26).
 *
 * The cache exists so that `video.info` and `playback.open` racing on the same
 * video open cost one round trip, not two. Task 26 added the playlist id to the
 * key because `client:videoId` was serving one entry for two genuinely
 * different responses — a `/player` asked with a `playlistId` carries `list=`
 * in its `videostatsWatchtimeUrl` and one asked without does not. The risk in
 * that change is not the new behaviour; it is quietly breaking the old one, so
 * the sharing property is pinned first and hardest.
 */

import { beforeEach, describe, expect, test } from 'bun:test';

import {
  forgetPlayerResponse,
  getPlayerResponse,
} from '../src/innertube/player-response.ts';
import type { Session } from '../src/innertube/session.ts';

interface Call {
  endpoint: string;
  params: Record<string, unknown>;
}

/** A `/player` body with just enough for `parsePlayer` to return something. */
function playerBody(watchtimeUrl: string): unknown {
  return {
    playabilityStatus: { status: 'OK' },
    videoDetails: { videoId: 'aqz-KE-bpKQ', lengthSeconds: '635' },
    streamingData: { adaptiveFormats: [] },
    playbackTracking: {
      videostatsWatchtimeUrl: { baseUrl: watchtimeUrl },
      videostatsPlaybackUrl: { baseUrl: 'https://s.youtube.com/api/stats/playback' },
    },
  };
}

function stubSession(): { session: Session; calls: Call[] } {
  const calls: Call[] = [];
  const session = {
    hasCookie: true,
    visitorId: 'v'.repeat(558),
    innertube: {
      session: { player: { signature_timestamp: 20662 }, context: { client: {} } },
    } as unknown as Session['innertube'],
    async execute(endpoint: string, params: Record<string, unknown> = {}) {
      calls.push({ endpoint, params });
      const list = params['playlistId'];
      // The real difference the key is about: `list=` is present only when the
      // request named a playlist.
      return playerBody(
        list
          ? `https://s.youtube.com/api/stats/watchtime?list=${String(list)}&docid=x`
          : 'https://s.youtube.com/api/stats/watchtime?docid=x',
      );
    },
  } as unknown as Session;
  return { session, calls };
}

const VIDEO = 'aqz-KE-bpKQ';

beforeEach(() => {
  forgetPlayerResponse();
});

describe('the no-playlist path is unchanged', () => {
  test('two sequential calls share one fetch', async () => {
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB');
    await getPlayerResponse(session, VIDEO, 'WEB');
    expect(calls).toHaveLength(1);
  });

  test('concurrent callers share one in-flight request', async () => {
    // `video.info` and `playback.open` on the same open — the common case the
    // cache was built for, and the one a key change could silently break.
    const { session, calls } = stubSession();
    await Promise.all([
      getPlayerResponse(session, VIDEO, 'WEB'),
      getPlayerResponse(session, VIDEO, 'WEB'),
      getPlayerResponse(session, VIDEO, 'WEB'),
    ]);
    expect(calls).toHaveLength(1);
  });

  test('sends no playlistId at all', async () => {
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB');
    expect(calls[0]!.params).not.toHaveProperty('playlistId');
  });

  test('an explicit null playlistId is the same entry, not a second one', async () => {
    // `playback.report` passes `session.playlistId`, which is `null` for a
    // standalone watch. If null keyed differently from absent, every ordinary
    // watch would pay for a second `/player` round trip.
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB');
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: null });
    expect(calls).toHaveLength(1);
  });

  test('different clients are still different entries', async () => {
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB');
    await getPlayerResponse(session, VIDEO, 'VISIONOS');
    expect(calls).toHaveLength(2);
  });
});

describe('a playlist context is its own entry', () => {
  test('with and without a playlist are two fetches, not one shared answer', async () => {
    // The bug the key change fixes: whichever landed first used to decide what
    // both callers got.
    const { session, calls } = stubSession();
    const plain = await getPlayerResponse(session, VIDEO, 'WEB');
    const inMix = await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDxyz' });

    expect(calls).toHaveLength(2);
    expect(plain.videostatsWatchtimeUrl).not.toContain('list=');
    expect(inMix.videostatsWatchtimeUrl).toContain('list=RDxyz');
  });

  test('and in the other order too', async () => {
    // Ordering must not matter. With one shared key it decided everything.
    const { session } = stubSession();
    const inMix = await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDxyz' });
    const plain = await getPlayerResponse(session, VIDEO, 'WEB');

    expect(inMix.videostatsWatchtimeUrl).toContain('list=RDxyz');
    expect(plain.videostatsWatchtimeUrl).not.toContain('list=');
  });

  test('the same playlist twice still shares one fetch', async () => {
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDxyz' });
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDxyz' });
    expect(calls).toHaveLength(1);
  });

  test('two different playlists are two entries', async () => {
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDone' });
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDtwo' });
    expect(calls).toHaveLength(2);
  });

  test('the request actually carries the playlist id', async () => {
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDxyz' });
    expect(calls[0]!.params).toMatchObject({ playlistId: 'RDxyz' });
  });
});

describe('forgetting a video', () => {
  test('drops the playlist-scoped entries too', async () => {
    // Otherwise a mix's reporting response outlives the video that was
    // explicitly forgotten — the one thing the function exists to prevent,
    // one key along.
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB');
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDxyz' });
    expect(calls).toHaveLength(2);

    forgetPlayerResponse(VIDEO);

    await getPlayerResponse(session, VIDEO, 'WEB');
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDxyz' });
    expect(calls).toHaveLength(4);
  });

  test('leaves another video alone', async () => {
    const { session, calls } = stubSession();
    await getPlayerResponse(session, VIDEO, 'WEB', { playlistId: 'RDxyz' });
    await getPlayerResponse(session, 'otherVideoId', 'WEB', { playlistId: 'RDxyz' });
    forgetPlayerResponse(VIDEO);
    await getPlayerResponse(session, 'otherVideoId', 'WEB', { playlistId: 'RDxyz' });
    expect(calls).toHaveLength(2);
  });
});
