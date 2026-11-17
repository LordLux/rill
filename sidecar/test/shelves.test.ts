/**
 * Home shelves (`todo.md` 111) — offline, hand-built from the shapes measured in
 * `architecture.md` F61 and F62. Renderer names and field paths only; every id,
 * title and name here is invented.
 *
 * The rule most worth pinning is the one a localised UI breaks silently: a shelf's
 * category is decided from what its tiles *are*, never from its title.
 */

import { describe, expect, test } from 'bun:test';
import { parseFeed } from '../src/parser/feed.ts';

function lockup(id: string, opts: { members?: boolean } = {}) {
  return {
    lockupViewModel: {
      contentId: id,
      contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
      contentImage: {
        thumbnailViewModel: {
          image: { sources: [{ url: `https://i.example.test/${id}.jpg`, width: 720 }] },
          overlays: [{ thumbnailBadgeViewModel: { text: '12:34', badgeStyle: 'THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT' } }],
        },
      },
      metadata: {
        lockupMetadataViewModel: {
          title: { content: `Synthetic title ${id}` },
          metadata: {
            contentMetadataViewModel: {
              metadataRows: [
                { metadataParts: [{ text: { content: 'Synthetic Channel' } }] },
                {
                  metadataParts: [{ text: { content: '3w ago' } }],
                  badges: opts.members
                    ? [{ badgeViewModel: { badgeStyle: 'BADGE_MEMBERS_ONLY', iconName: 'SPONSORSHIP_STAR' } }]
                    : [],
                },
              ],
            },
          },
        },
      },
    },
  };
}

function short(id: string) {
  return {
    shortsLockupViewModel: {
      entityId: `shorts-shelf-item-${id}`,
      accessibilityText: `Synthetic short ${id}, 1.2M views - play Short`,
      onTap: { innertubeCommand: { reelWatchEndpoint: { videoId: id } } },
      overlayMetadata: { primaryText: { content: `Synthetic short ${id}` }, secondaryText: { content: '1.2M views' } },
      thumbnailViewModel: {
        thumbnailViewModel: { image: { sources: [{ url: `https://i.example.test/${id}.jpg`, width: 405, height: 720 }] } },
      },
    },
  };
}

function post(id: string | null) {
  return {
    postRenderer: {
      ...(id ? { postId: id } : {}),
      authorText: {
        runs: [
          {
            text: 'Synthetic Author',
            navigationEndpoint: { browseEndpoint: { browseId: 'UCsynthetic0000000000000' } },
          },
        ],
      },
      authorThumbnail: { thumbnails: [{ url: 'https://i.example.test/a.jpg', width: 48, height: 48 }] },
      contentText: { runs: [{ text: 'Synthetic ' }, { text: 'post text' }] },
      backstageAttachment: {
        backstageImageRenderer: { image: { thumbnails: [{ url: 'https://i.example.test/p.jpg', width: 640, height: 360 }] } },
      },
      publishedTimeText: {
        runs: [
          {
            text: '2 days ago',
            navigationEndpoint: { commandMetadata: { webCommandMetadata: { url: `/post/${id ?? 'none'}` } } },
          },
        ],
      },
      voteCount: { simpleText: '4.2K' },
    },
  };
}

const item = (content: unknown) => ({ richItemRenderer: { content } });
const gridItem = (id: string) => ({ richItemRenderer: { content: lockup(id) } });
const section = (inner: unknown) => ({ richSectionRenderer: { content: inner } });

function richShelf(title: string, tiles: unknown[]) {
  return section({ richShelfRenderer: { title: { runs: [{ text: title }] }, contents: tiles.map(item) } });
}

function brandShelf(title: string, tiles: unknown[]) {
  // Direct children, no `richItemRenderer` wrapper — as measured (F61 §2).
  return section({
    brandVideoShelfRenderer: {
      title: { runs: [{ text: title }] },
      contents: tiles,
      header: { sectionHeaderViewModel: { headline: { content: 'Ignored header' } } },
    },
  });
}

function page(contents: unknown[]) {
  return {
    contents: { twoColumnBrowseResultsRenderer: { tabs: [{ tabRenderer: { content: { richGridRenderer: { contents } } } }] } },
  };
}

describe('shelves', () => {
  test('a members shelf is a shelf of its own and its tiles leave the grid', () => {
    const raw = page([
      gridItem('g1'),
      brandShelf('Get more from memberships', [lockup('m1', { members: true }), lockup('m2', { members: true })]),
      gridItem('g2'),
    ]);
    const result = parseFeed(raw, 'test', undefined, { shelves: true });
    expect(result.items.map((i) => i.kind === 'video' && i.id)).toEqual(['g1', 'g2']);
    expect(result.shelves).toHaveLength(1);
    expect(result.shelves[0]).toMatchObject({ category: 'members', title: 'Get more from memberships', index: 1 });
    expect(result.shelves[0]!.items.map((i) => i.kind === 'video' && i.id)).toEqual(['m1', 'm2']);
  });

  test('the category is structure, never the title', () => {
    // The title says "Shorts" and "Members" and neither is true; the title is a
    // language the code has never seen and everything is true.
    const raw = page([
      richShelf('Shorts', [lockup('a1'), lockup('a2')]),
      brandShelf('Members', [lockup('b1'), lockup('b2')]),
      richShelf('ショート', [short('s1'), short('s2')]),
      brandShelf('メンバー限定', [lockup('c1', { members: true })]),
      richShelf('Beiträge', [post('Ugx1'), post('Ugx2')]),
    ]);
    const { shelves } = parseFeed(raw, 'test', undefined, { shelves: true });
    expect(shelves.map((s) => s.category)).toEqual(['other', 'other', 'shorts', 'members', 'posts']);
  });

  test('a Short becomes a video flagged isShort, with its id from its own endpoint', () => {
    const raw = page([richShelf('Shorts', [short('abcdefghijk')])]);
    const [shelf] = parseFeed(raw, 'test', undefined, { shelves: true }).shelves;
    expect(shelf!.items[0]).toMatchObject({
      kind: 'video',
      id: 'abcdefghijk',
      title: 'Synthetic short abcdefghijk',
      viewCountText: '1.2M views',
      thumbnailUrl: 'https://i.example.test/abcdefghijk.jpg',
      isShort: true,
      durationSeconds: null,
    });
  });

  test('a post becomes a post item, with its link taken from the timestamp', () => {
    const raw = page([richShelf('Latest posts', [post('Ugx1')])]);
    const [shelf] = parseFeed(raw, 'test', undefined, { shelves: true }).shelves;
    expect(shelf!.items[0]).toEqual({
      kind: 'post',
      id: 'Ugx1',
      authorName: 'Synthetic Author',
      authorChannelId: 'UCsynthetic0000000000000',
      authorAvatarUrl: 'https://i.example.test/a.jpg',
      text: 'Synthetic post text',
      imageUrl: 'https://i.example.test/p.jpg',
      publishedText: '2 days ago',
      likeCountText: '4.2K',
      postUrl: 'https://www.youtube.com/post/Ugx1',
    });
  });

  test('a mixed shelf is other, and keeps everything it had', () => {
    const raw = page([richShelf('Mixed', [lockup('v1'), short('s1')])]);
    const [shelf] = parseFeed(raw, 'test', undefined, { shelves: true }).shelves;
    expect(shelf!.category).toBe('other');
    expect(shelf!.items).toHaveLength(2);
  });

  test('a tile that cannot be mapped is skipped, and a shelf of nothing is not a shelf', () => {
    const raw = page([
      richShelf('Posts', [post(null), post('Ugx1')]),
      richShelf('Empty', [post(null)]),
      richShelf('Unknown tiles', [{ someFutureTileViewModel: { x: 1 } }]),
      gridItem('g1'),
    ]);
    const result = parseFeed(raw, 'test', undefined, { shelves: true });
    expect(result.shelves.map((s) => s.items.length)).toEqual([1]);
    expect(result.items).toHaveLength(1);
  });

  test('index counts the grid tiles before the shelf, and shelves keep page order', () => {
    const raw = page([
      richShelf('One', [short('s1')]),
      gridItem('g1'),
      gridItem('g2'),
      richShelf('Two', [post('Ugx1')]),
      richShelf('Three', [short('s2')]),
      gridItem('g3'),
    ]);
    const { shelves } = parseFeed(raw, 'test', undefined, { shelves: true });
    expect(shelves.map((s) => [s.title, s.index])).toEqual([
      ['One', 0],
      ['Two', 2],
      ['Three', 2],
    ]);
  });

  test('a title falls back to the shelf header, and is null when there is none', () => {
    const raw = page([
      section({
        brandVideoShelfRenderer: {
          contents: [lockup('v1')],
          header: { sectionHeaderViewModel: { headline: { content: 'From the header' } } },
        },
      }),
      section({ richShelfRenderer: { contents: [item(lockup('v2'))] } }),
    ]);
    const { shelves } = parseFeed(raw, 'test', undefined, { shelves: true });
    expect(shelves.map((s) => s.title)).toEqual(['From the header', null]);
  });

  test('a Short or a post outside a shelf is dropped, as ever', () => {
    const raw = page([item(short('s1')), item(post('Ugx1')), gridItem('g1')]);
    const result = parseFeed(raw, 'test', undefined, { shelves: true });
    expect(result.shelves).toEqual([]);
    expect(result.items).toHaveLength(1);
  });

  describe('without shelves asked for — every other surface', () => {
    const raw = page([
      gridItem('g1'),
      brandShelf('Curated', [lockup('b1'), lockup('b2')]),
      richShelf('Shorts', [short('s1')]),
      richShelf('Posts', [post('Ugx1')]),
    ]);

    test('the shelf container is an ordinary container: its tiles join the grid', () => {
      const result = parseFeed(raw, 'test');
      expect(result.items.map((i) => i.kind === 'video' && i.id)).toEqual(['g1', 'b1', 'b2']);
      expect(result.shelves).toEqual([]);
    });

    test('a Shorts shelf stays stripped and posts stay ignored', () => {
      const result = parseFeed(raw, 'test');
      expect(result.items.some((i) => i.kind === 'video' && i.isShort)).toBe(false);
      expect(JSON.stringify(result)).not.toContain('Ugx1');
    });
  });
});
