/**
 * Premieres — a video that exists, is fine, and has not started.
 *
 * **These use inline payloads rather than fixtures, deliberately.** The corpus
 * rule is that fixtures are *captured* with `parse: false` (CLAUDE.md, and F2 on
 * why parsed objects make a useless corpus), and there is no premiere in it —
 * capturing one means a whole-corpus refresh against a live account with a
 * premiere in reach. Hand-writing a file into `fixtures/` to fill the gap would
 * quietly turn the corpus into a mixture of captured and invented responses,
 * which is worse than the gap: every later reader would have to know which is
 * which. So the shapes below are written here, minimal and labelled, and the
 * corpus stays honest.
 *
 * What that costs is real and worth stating: these pin the *rule* against the
 * shapes YouTube is documented and observed to use, not against a response
 * anyone captured. A layout that moves the field somewhere none of the three
 * branches look would pass here and fail in the app.
 */

import { describe, expect, test } from 'bun:test';
import { premiereStartMs } from '../src/parser/premiere.ts';
import { parsePlayer } from '../src/parser/player.ts';
import { mapClassicVideo } from '../src/parser/items.ts';
import { retryModeFor } from '../src/errors.ts';

/** 2026-08-22T15:00:00Z, the premiere in the bug report. */
const START_SECONDS = 1787670000;
const START_MS = START_SECONDS * 1000;

describe('premiereStartMs', () => {
  test('reads upcomingEventData.startTime, wherever it is buried', () => {
    expect(premiereStartMs({ upcomingEventData: { startTime: String(START_SECONDS) } })).toBe(
      START_MS,
    );
    // Nested arbitrarily deep — the tile shape differs per renderer generation.
    expect(
      premiereStartMs({
        contents: [{ richItemRenderer: { content: { videoRenderer: { upcomingEventData: { startTime: START_SECONDS } } } } }],
      }),
    ).toBe(START_MS);
  });

  test('reads the /player offline slate', () => {
    expect(
      premiereStartMs({
        playabilityStatus: {
          status: 'LIVE_STREAM_OFFLINE',
          liveStreamability: {
            liveStreamabilityRenderer: {
              offlineSlate: {
                liveStreamOfflineSlateRenderer: { scheduledStartTime: String(START_SECONDS) },
              },
            },
          },
        },
      }),
    ).toBe(START_MS);
  });

  test('reads the microformat ISO timestamp', () => {
    expect(
      premiereStartMs({
        microformat: {
          playerMicroformatRenderer: {
            liveBroadcastDetails: { startTimestamp: '2026-08-22T15:00:00Z' },
          },
        },
      }),
    ).toBe(Date.parse('2026-08-22T15:00:00Z'));
  });

  test('milliseconds are not multiplied a second time', () => {
    // Nothing observed sends these, and that is exactly why the guard is here: a
    // value already in milliseconds would otherwise become a date in the year
    // 58,000 and still look like a plausible number all the way to the UI.
    expect(premiereStartMs({ upcomingEventData: { startTime: START_MS } })).toBe(START_MS);
  });

  test('an ordinary payload has no premiere, and that is not a failure', () => {
    expect(premiereStartMs({ videoDetails: { videoId: 'abc', title: 'x' } })).toBeNull();
    expect(premiereStartMs(null)).toBeNull();
    expect(premiereStartMs([])).toBeNull();
  });
});

describe('parsePlayer on a premiere', () => {
  const response = {
    playabilityStatus: {
      status: 'LIVE_STREAM_OFFLINE',
      reason: 'Premieres in 9 days',
      liveStreamability: {
        liveStreamabilityRenderer: {
          offlineSlate: {
            liveStreamOfflineSlateRenderer: { scheduledStartTime: String(START_SECONDS) },
          },
        },
      },
    },
    videoDetails: { videoId: 'mYJshNOfv_w', isUpcoming: true, lengthSeconds: '0' },
  };

  test('is flagged upcoming and carries the start time', () => {
    const parsed = parsePlayer(response);
    expect(parsed.isUpcoming).toBe(true);
    expect(parsed.scheduledStartMs).toBe(START_MS);
    expect(parsed.playabilityReason).toBe('Premieres in 9 days');
  });

  test('LIVE_STREAM_OFFLINE alone is enough, without the isUpcoming flag', () => {
    // The two have never been observed apart, and a premiere that reads as an
    // ordinary dead video is the whole bug — so either one is taken as proof.
    const parsed = parsePlayer({
      ...response,
      videoDetails: { videoId: 'mYJshNOfv_w', lengthSeconds: '0' },
    });
    expect(parsed.isUpcoming).toBe(true);
  });

  test('an ordinary response is not upcoming', () => {
    const parsed = parsePlayer({
      playabilityStatus: { status: 'OK' },
      videoDetails: { videoId: 'aqz-KE-bpKQ', lengthSeconds: '634' },
    });
    expect(parsed.isUpcoming).toBe(false);
    expect(parsed.scheduledStartMs).toBeNull();
  });
});

describe('a premiere tile', () => {
  test('carries its start time so a card can offer a reminder without a /player call', () => {
    const item = mapClassicVideo({
      videoId: 'mYJshNOfv_w',
      title: { runs: [{ text: 'Ado - Utattemita Live Movie' }] },
      ownerText: { runs: [{ text: 'Ado' }] },
      upcomingEventData: { startTime: String(START_SECONDS), isReminderSet: false },
    });
    expect(item?.premiereAtMs).toBe(START_MS);
  });

  test('an ordinary tile has none', () => {
    const item = mapClassicVideo({
      videoId: 'aqz-KE-bpKQ',
      title: { runs: [{ text: 'Big Buck Bunny' }] },
      ownerText: { runs: [{ text: 'Blender' }] },
    });
    expect(item?.premiereAtMs).toBeNull();
  });
});

describe('VIDEO_UPCOMING', () => {
  test('is `no`, because retrying cannot beat a clock', () => {
    // Not `user` like STREAM_UNAVAILABLE: a *Try again* button on a premiere can
    // only fail for the next nine days, and the UI has a date and a reminder to
    // offer instead.
    expect(retryModeFor('VIDEO_UPCOMING')).toBe('no');
  });
});
