/**
 * `MixItem.seedVideoId` / `startParams` — reading the video a mix tile
 * advertises off the tile's own click target (2026-09-14).
 *
 * Synthetic tiles in the two real shapes: a view-based lockup keeps the click
 * target under `rendererContext.commandContext.onTap.innertubeCommand`, a
 * classic radio tile under `navigationEndpoint`.
 */

import { describe, expect, test } from 'bun:test';

import { parseFeed } from '../src/parser/feed.ts';

function lockupMix(options: { id: string; endpoint?: Record<string, unknown> | null; nested?: Record<string, unknown> }) {
  return {
    contents: [
      {
        lockupViewModel: {
          contentId: options.id,
          contentType: 'LOCKUP_CONTENT_TYPE_PLAYLIST',
          contentImage: {
            collectionThumbnailViewModel: {
              primaryThumbnail: {
                thumbnailViewModel: {
                  image: { sources: [{ url: 'https://i.ytimg.com/vi/thumbVideo1/hq.jpg', width: 480 }] },
                },
              },
            },
          },
          metadata: {
            lockupMetadataViewModel: {
              title: { content: 'Mix - Some Song' },
              ...(options.nested ?? {}),
            },
          },
          rendererContext: {
            commandContext: {
              onTap: {
                innertubeCommand: options.endpoint === null ? {} : { watchEndpoint: options.endpoint },
              },
            },
          },
        },
      },
    ],
  };
}

const mixOf = (raw: unknown) => {
  const item = parseFeed(raw as never, 'test').items.find((i) => i.kind === 'mix');
  if (!item || item.kind !== 'mix') throw new Error('no mix parsed');
  return item;
};

describe('a view-based mix tile', () => {
  test('carries the advertised video and its params', () => {
    const mix = mixOf(
      lockupMix({ id: 'RDadvertised', endpoint: { videoId: 'advertised1', playlistId: 'RDadvertised', params: 'OALAAQE%3D' } }),
    );
    expect(mix.seedVideoId).toBe('advertised1');
    expect(mix.startParams).toBe('OALAAQE%3D');
  });

  test('reads the click target, not the RD suffix — RDMM and RDGMEM have none', () => {
    const mix = mixOf(
      lockupMix({ id: 'RDGMEMgenreMixId', endpoint: { videoId: 'genreSong01', playlistId: 'RDGMEMgenreMixId', params: 'p' } }),
    );
    expect(mix.seedVideoId).toBe('genreSong01');
  });

  test('a click target for a different playlist does not lend its seed', () => {
    const mix = mixOf(
      lockupMix({
        id: 'RDmine',
        endpoint: null,
        nested: { menu: { watchEndpoint: { videoId: 'notMine0001', playlistId: 'RDsomeoneElse', params: 'x' } } },
      }),
    );
    expect(mix.seedVideoId).toBeNull();
    expect(mix.startParams).toBeNull();
  });

  test('no click target: null, and the tile still ships', () => {
    const mix = mixOf(lockupMix({ id: 'RDnoEndpoint', endpoint: null }));
    expect(mix.id).toBe('RDnoEndpoint');
    expect(mix.seedVideoId).toBeNull();
    expect(mix.startParams).toBeNull();
  });

  test('a seed with no params is still a seed', () => {
    const mix = mixOf(lockupMix({ id: 'RDx', endpoint: { videoId: 'seedOnly001', playlistId: 'RDx' } }));
    expect(mix.seedVideoId).toBe('seedOnly001');
    expect(mix.startParams).toBeNull();
  });
});

describe('a classic radio tile', () => {
  test('reads navigationEndpoint', () => {
    const mix = mixOf({
      contents: [
        {
          compactRadioRenderer: {
            playlistId: 'RDclassic01',
            title: { simpleText: 'Mix - Classic' },
            thumbnail: { thumbnails: [{ url: 'https://i.ytimg.com/vi/classicSeed/hq.jpg', width: 336 }] },
            navigationEndpoint: {
              watchEndpoint: { videoId: 'classicSeed', playlistId: 'RDclassic01', params: 'OALAAQE%3D' },
            },
          },
        },
      ],
    });
    expect(mix.seedVideoId).toBe('classicSeed');
    expect(mix.startParams).toBe('OALAAQE%3D');
  });
});
