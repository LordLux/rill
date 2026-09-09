/**
 * Members-only, from badge to error code — offline.
 *
 * Every shape here is copied from a live response captured 2026-09-09 against
 * `rAWLNJoE5_Y`, a real members-only video (`scratch/members-*.ts`). The corpus
 * has no members-only tile, so these are hand-built from what was measured
 * rather than skipped for want of a fixture.
 */

import { describe, expect, test } from 'bun:test';
import { scanBadges } from '../src/parser/text.ts';
import { parsePlayer } from '../src/parser/player.ts';
import { openPlayback } from '../src/playback/resolve.ts';
import { isRpcError } from '../src/errors.ts';
import type { Session } from '../src/innertube/session.ts';

/** Verbatim from the watch page for `rAWLNJoE5_Y`. */
const CLASSIC_BADGE = {
  metadataBadgeRenderer: {
    icon: { iconType: 'SPONSORSHIP_STAR' },
    style: 'BADGE_STYLE_TYPE_MEMBERS_ONLY',
    label: 'Members only',
  },
};

describe('scanBadges', () => {
  test('flags members-only from the style', () => {
    const scan = scanBadges({ badges: [CLASSIC_BADGE] });
    expect(scan.isMembersOnly).toBe(true);
  });

  test('and keeps the label out of badges[]', () => {
    // The rule `isLive` and `isShort` already follow. Without it the tile draws
    // a green members pill *and* a grey "Members only" pill next to it.
    const scan = scanBadges({ badges: [CLASSIC_BADGE] });
    expect(scan.labels).not.toContain('Members only');
    expect(scan.labels).toEqual([]);
  });

  test('the style alone is enough — no label needed', () => {
    // A view-based badge can be an icon with no text. Returning early on a null
    // label would drop the only signal it carries.
    const scan = scanBadges({
      badges: [{ metadataBadgeRenderer: { style: 'BADGE_STYLE_TYPE_MEMBERS_ONLY' } }],
    });
    expect(scan.isMembersOnly).toBe(true);
  });

  test('the icon alone is enough, and the label is still struck', () => {
    // The shape with no style. `consider` cannot drop the label in this case —
    // it has already been pushed by the time the icon is seen — so the sweep
    // strikes it afterwards.
    const scan = scanBadges({
      badges: [{ metadataBadgeRenderer: { icon: { iconType: 'SPONSORSHIP_STAR' }, label: 'Members only' } }],
    });
    expect(scan.isMembersOnly).toBe(true);
    expect(scan.labels).toEqual([]);
  });

  test('the label is struck in a language the code has never seen', () => {
    // The reason detection reads `style` and `icon` and never text: an earlier
    // version stripped the label with `/members only|solo membri/`, which drew
    // a green pill *and* a grey "Réservé aux membres" pill for every locale
    // outside that pattern. Nothing here matches words, so nothing here has a
    // list of languages to be incomplete.
    for (const label of ['Réservé aux membres', 'Nur für Mitglieder', 'メンバー限定']) {
      const scan = scanBadges({
        badges: [
          {
            metadataBadgeRenderer: {
              icon: { iconType: 'SPONSORSHIP_STAR' },
              style: 'BADGE_STYLE_TYPE_MEMBERS_ONLY',
              label,
            },
          },
        ],
      });
      expect(scan.isMembersOnly).toBe(true);
      expect(scan.labels).toEqual([]);
    }
  });

  test('and struck from an icon-only badge in a foreign language too', () => {
    // The shape with no style token, where the icon is the only signal — the
    // case the old regex was there for.
    const scan = scanBadges({
      badges: [
        {
          metadataBadgeRenderer: {
            icon: { iconType: 'SPONSORSHIP_STAR' },
            label: 'Réservé aux membres',
          },
        },
      ],
    });
    expect(scan.isMembersOnly).toBe(true);
    expect(scan.labels).toEqual([]);
  });

  test('an ordinary badge is untouched', () => {
    const scan = scanBadges({
      badges: [{ metadataBadgeRenderer: { style: 'BADGE_STYLE_TYPE_SIMPLE', label: '4K' } }],
    });
    expect(scan.isMembersOnly).toBe(false);
    expect(scan.labels).toEqual(['4K']);
  });

  test('a members badge does not swallow the other badges on the same tile', () => {
    const scan = scanBadges({
      badges: [CLASSIC_BADGE, { metadataBadgeRenderer: { label: 'New' } }],
    });
    expect(scan.isMembersOnly).toBe(true);
    expect(scan.labels).toEqual(['New']);
  });

  test('the duration badge still parses beside it', () => {
    const scan = scanBadges({
      badges: [CLASSIC_BADGE],
      overlay: { thumbnailOverlayTimeStatusRenderer: { text: { simpleText: '34:32' } } },
    });
    expect(scan.isMembersOnly).toBe(true);
    expect(scan.durationSeconds).toBe(34 * 60 + 32);
  });

  test('nothing members-ish is false, not undefined', () => {
    expect(scanBadges({}).isMembersOnly).toBe(false);
  });
});

describe('parsePlayer', () => {
  /** The whole of `playabilityStatus` on VISIONOS — measured; there is no more. */
  const refusal = (reason: string) => ({
    playabilityStatus: { status: 'UNPLAYABLE', reason, playableInEmbed: true },
    videoDetails: { videoId: 'rAWLNJoE5_Y' },
  });

  test('classifies the VISIONOS/MWEB wording', () => {
    const result = parsePlayer(
      refusal(
        'Join this channel from your computer or mobile app to get access to ' +
          'members-only content like this video.',
      ),
    );
    expect(result.isMembersOnly).toBe(true);
  });

  test('classifies the WEB/ANDROID wording too', () => {
    const result = parsePlayer(
      refusal(
        'Join this channel to get access to members-only content like this video, ' +
          'and other exclusive perks.',
      ),
    );
    expect(result.isMembersOnly).toBe(true);
  });

  test('an unrelated refusal is not members-only', () => {
    // The property that makes a localised-string match tolerable here: it can
    // only ever refine an already-failed response, never invent a refusal.
    expect(parsePlayer(refusal('This video is private.')).isMembersOnly).toBe(false);
    expect(parsePlayer(refusal('The page needs to be reloaded.')).isMembersOnly).toBe(false);
  });

  test('reads the messages[] fallback when there is no reason', () => {
    // `parsePlayer` takes `reason ?? messages[0]`, and only the first half had
    // coverage. Some clients answer with `messages` instead, so the fallback is
    // reachable rather than defensive.
    const result = parsePlayer({
      playabilityStatus: {
        status: 'UNPLAYABLE',
        messages: ['Join this channel to get access to members-only content.'],
      },
      videoDetails: { videoId: 'rAWLNJoE5_Y' },
    });
    expect(result.isMembersOnly).toBe(true);
  });

  test('a refusal with neither reason nor messages is not members-only', () => {
    const result = parsePlayer({
      playabilityStatus: { status: 'UNPLAYABLE' },
      videoDetails: { videoId: 'x' },
    });
    expect(result.isMembersOnly).toBe(false);
  });

  test('a members-only refusal ends the ladder — it is not a decline', async () => {
    // **The bug that reached a user.** `assertPlayable` threw
    // `VIDEO_MEMBERS_ONLY`, `protocol.md` said it ended the ladder, and the
    // ladder's rethrow named `VIDEO_UPCOMING` alone — so it was collected as an
    // ordinary decline, every remaining tier was tried, and the watch page got
    // `STREAM_UNAVAILABLE` ("This video would not open") with a *Try again*
    // button on a video nothing is wrong with.
    //
    // Asserted through `openPlayback` rather than `assertPlayable`, because the
    // throw was never the broken half — what was broken is what the loop around
    // it did with the throw.
    const refusal = {
      playabilityStatus: {
        status: 'UNPLAYABLE',
        reason:
          'Join this channel from your computer or mobile app to get access to ' +
          'members-only content like this video.',
      },
      videoDetails: { videoId: '0BVmuG4Kjhk' },
    };

    let calls = 0;
    const session = {
      innertube: { session: { player: { signature_timestamp: 20702 } } },
      hasCookie: false,
      visitorId: 'x'.repeat(560),
      async execute() {
        calls += 1;
        return refusal;
      },
    } as unknown as Session;

    let thrown: unknown;
    try {
      await openPlayback({ session }, { videoId: '0BVmuG4Kjhk' });
    } catch (error) {
      thrown = error;
    }

    expect(isRpcError(thrown)).toBe(true);
    const rpcError = thrown as { code: string; retry: string | null; message: string };
    expect(rpcError.code).toBe('VIDEO_MEMBERS_ONLY');
    // `no`, not `user` — the whole point. A retry cannot buy a membership.
    expect(rpcError.retry).toBe('no');
    expect(rpcError.message).not.toContain('every resolution tier declined');

    // Tier 1 mints a fresh visitor id and retries once on any non-OK response
    // (F5), so two `/player` calls is expected. What must not happen is the
    // ladder walking on to MWEB, yt-dlp and the progressive floor.
    expect(calls).toBeLessThanOrEqual(2);
  });

  test('a healthy response is not members-only', () => {
    const ok = parsePlayer({
      playabilityStatus: { status: 'OK' },
      videoDetails: { videoId: 'aqz-KE-bpKQ', lengthSeconds: '634' },
    });
    expect(ok.isMembersOnly).toBe(false);
  });
});
