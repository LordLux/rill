/**
 * `VideoItem.isPromoted` — a tile YouTube itself marks as promoted.
 *
 * The shape is the one measured 2026-11-13 on the watch page's related list: a
 * `lockupViewModel` whose metadata carries a `badgeViewModel` with `badgeStyle:
 * BADGE_PROMOTED`, an id that is not a video id, and none of the save/queue actions.
 * Renderer names and styles only; ids and titles are invented.
 */

import { describe, expect, test } from 'bun:test';
import { parseFeed } from '../src/parser/feed.ts';
import { scanBadges } from '../src/parser/text.ts';

const PROMOTED = { badgeViewModel: { badgeStyle: 'BADGE_PROMOTED', badgeText: 'Promoted' } };

function lockup(id: string, badges: unknown[]) {
  return {
    lockupViewModel: {
      contentId: id,
      contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
      contentImage: {
        thumbnailViewModel: {
          image: { sources: [{ url: `https://i.example.test/${id}.jpg`, width: 720 }] },
          overlays: [{ thumbnailBadgeViewModel: { text: '3:21', badgeStyle: 'THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT' } }],
        },
      },
      metadata: {
        lockupMetadataViewModel: {
          title: { content: `Synthetic title ${id}` },
          metadata: {
            contentMetadataViewModel: {
              metadataRows: [
                { metadataParts: [{ text: { content: 'Synthetic Channel' } }] },
                { metadataParts: [{ text: { content: '3w ago' } }], badges },
              ],
            },
          },
        },
      },
    },
  };
}

const wrap = (tiles: unknown[]) => ({ contents: { richGridRenderer: { contents: tiles } } });
const rich = (content: unknown) => ({ richItemRenderer: { content } });

describe('scanBadges: promoted', () => {
  test('BADGE_PROMOTED sets the flag and adds no pill, whatever the label says', () => {
    for (const badgeText of ['Promoted', 'Sponsorizzato', '']) {
      const scan = scanBadges({ b: { badgeViewModel: { badgeStyle: 'BADGE_PROMOTED', badgeText } } });
      expect(scan.isPromoted).toBe(true);
      expect(scan.labels).toEqual([]);
    }
  });

  test('other badgeViewModels, and a tile with none, are not promoted', () => {
    expect(scanBadges({ b: { badgeViewModel: { badgeStyle: 'BADGE_DEFAULT', iconName: 'STAR_SHOOTING' } } }).isPromoted).toBe(false);
    expect(scanBadges({ b: { badgeViewModel: { badgeStyle: 'BADGE_MEMBERS_ONLY' } } }).isPromoted).toBe(false);
    expect(scanBadges({}).isPromoted).toBe(false);
  });

  test('a label saying "promoted" without the style is not enough — the style is the token', () => {
    expect(scanBadges({ b: { thumbnailBadgeViewModel: { text: 'Promoted' } } }).isPromoted).toBe(false);
  });
});

describe('a tile carrying the marker', () => {
  test('is flagged on every surface that shares the tile parser, and the others are not', () => {
    for (const context of ['home', 'search', 'subscriptions', 'video.related']) {
      const { items } = parseFeed(wrap([rich(lockup('adtile', [PROMOTED])), rich(lockup('plain', []))]), context);
      expect(items).toHaveLength(2);
      expect(items[0]).toMatchObject({ kind: 'video', id: 'adtile', isPromoted: true, badges: [] });
      expect(items[1]).toMatchObject({ kind: 'video', id: 'plain', isPromoted: false });
    }
  });

  test('inside a shelf it is flagged too', () => {
    const shelf = {
      richSectionRenderer: {
        content: { richShelfRenderer: { title: { runs: [{ text: 'Synthetic shelf' }] }, contents: [rich(lockup('adtile', [PROMOTED]))] } },
      },
    };
    const { shelves } = parseFeed(wrap([shelf]), 'home', undefined, { shelves: true });
    expect(shelves[0]?.items[0]).toMatchObject({ kind: 'video', isPromoted: true });
  });
});
