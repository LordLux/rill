/**
 * The names-only feed shape dump (Task 37 §1) — offline, synthetic.
 *
 * The property that matters is a negative one: nothing identifying reaches the
 * file. Every title, id, url and channel name below is invented and distinctive,
 * so a leak is a plain `not.toContain`.
 */

import { describe, expect, test } from 'bun:test';
import { parseFeed } from '../src/parser/feed.ts';
import { FeedShapeRecorder } from '../src/parser/feed-shape.ts';

const SECRET_CHANNEL_ID = 'UCsyntheticchannelid0000';

function lockup(
  id: string,
  title: string,
  options: { views?: string; members?: boolean; channelName?: string } = {},
) {
  const overlays: unknown[] = [
    { thumbnailBadgeViewModel: { text: '12:34', badgeStyle: 'THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT' } },
  ];
  if (options.members) {
    overlays.push({
      thumbnailBadgeViewModel: {
        text: 'Members only',
        badgeStyle: 'THUMBNAIL_OVERLAY_BADGE_STYLE_MEMBERS_ONLY',
        icon: { sources: [{ clientResource: { imageName: 'SPONSORSHIP_STAR' } }] },
      },
    });
  }
  const detail = [{ text: { content: '3 weeks ago' } }];
  if (options.views) detail.unshift({ text: { content: options.views } });
  return {
    richItemRenderer: {
      content: {
        lockupViewModel: {
          contentId: id,
          contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
          contentImage: {
            thumbnailViewModel: {
              image: { sources: [{ url: `https://i.ytimg.com/vi/${id}/hq720.jpg`, width: 720 }] },
              overlays,
            },
          },
          metadata: {
            lockupMetadataViewModel: {
              title: { content: title },
              metadata: {
                contentMetadataViewModel: {
                  metadataRows: [
                    {
                      metadataParts: [
                        {
                          text: {
                            content: options.channelName ?? 'Synthetic Channel Name',
                            commandRuns: [
                              { onTap: { innertubeCommand: { browseEndpoint: { browseId: SECRET_CHANNEL_ID } } } },
                            ],
                          },
                        },
                      ],
                    },
                    { metadataParts: detail },
                  ],
                },
              },
            },
          },
        },
      },
    },
  };
}

function page() {
  return {
    contents: {
      twoColumnBrowseResultsRenderer: {
        tabs: [
          {
            tabRenderer: {
              content: {
                richGridRenderer: {
                  contents: [
                    lockup('gridvideo0001', 'Secret grid title one', { views: '1.2M views' }),
                    {
                      richSectionRenderer: {
                        content: {
                          richShelfRenderer: {
                            title: { runs: [{ text: 'Synthetic shelf heading' }] },
                            contents: [
                              lockup('shelfvideo01', 'Secret shelf title one', { members: true }),
                              lockup('shelfvideo02', 'Secret shelf title two'),
                            ],
                          },
                        },
                      },
                    },
                    { adSlotRenderer: { content: { richItemRenderer: {} } } },
                    { someBrandNewRenderer: { payload: 1 } },
                    lockup('gridvideo0002', 'Secret grid title two', { views: '5K views' }),
                  ],
                },
              },
            },
          },
        ],
      },
    },
  };
}

describe('feed shape dump', () => {
  const recorder = new FeedShapeRecorder('first');
  const raw = page();
  const result = parseFeed(raw, 'test', recorder);
  const dump = recorder.render(result);

  test('flags a tile whose id is not a video id, by shape and never by value', () => {
    // 'gridvideo0002' is 13 characters, which is not a video id's 11: told apart from an
    // ordinary tile without the id itself ever reaching the file.
    expect(dump).toMatch(/tile#\d+ {2}mapped:video .*flags=.*idodd/);
    expect(dump).not.toContain('gridvideo0002');
  });

  test('names the shelf, its header text, and which tiles sit in it', () => {
    expect(dump).toMatch(/richShelfRenderer {2}S\d+ {2}title="Synthetic shelf heading"/);
    expect(dump).toMatch(/lockupViewModel {2}tile#2 {2}mapped:video {2}views=no .*in=S\d+/);
    expect(dump).toMatch(/lockupViewModel {2}tile#1 {2}mapped:video {2}views=yes .*in=grid/);
  });

  test('reports the badge a members tile carries: renderer, style, icon, label', () => {
    expect(dump).toContain(
      'badge  thumbnailBadgeViewModel  style=THUMBNAIL_OVERLAY_BADGE_STYLE_MEMBERS_ONLY  icon=SPONSORSHIP_STAR  label="Members only"',
    );
    expect(dump).toContain('flags=members');
  });

  test('records the parser verdict for stripped and unknown nodes', () => {
    expect(dump).toContain('adSlotRenderer  strip');
    expect(dump).toContain('someBrandNewRenderer  unknown');
  });

  test('counts a channel across shelves without naming it', () => {
    expect(dump).toMatch(/== by channel[\s\S]*ch1 {2}total=4 {2}.*in richShelfRenderer "Synthetic shelf heading"/);
  });

  test('nothing identifying is in the file', () => {
    for (const leak of [
      'Secret grid title',
      'Secret shelf title',
      'Synthetic Channel Name',
      SECRET_CHANNEL_ID,
      'gridvideo000',
      'shelfvideo0',
      'ytimg',
      'http',
      'hq720',
    ]) {
      expect(dump).not.toContain(leak);
    }
  });

  test('watching the walk does not change what it returns', () => {
    const plain = parseFeed(page(), 'test');
    expect(result.items).toEqual(plain.items);
    expect(result.chips).toEqual(plain.chips);
    expect(result.continuation).toEqual(plain.continuation);
  });

  test('a payload it cannot read costs nothing', () => {
    const unreadable = new FeedShapeRecorder('x');
    expect(() =>
      unreadable.renderer({ key: 'weirdRenderer', name: 'weird', role: 'item', payload: null, item: null }),
    ).not.toThrow();
  });
});
