/**
 * `playlist.get` — a playlist's videos, a page at a time (Task 34).
 *
 * A playlist is a finite list that pages with a real continuation, read from
 * `/browse VL<id>`. It is **not** a mix (`mix/service.ts`): nothing here
 * re-anchors, and the end is a null continuation. `architecture.md` F54.
 */

import { RpcError } from '../errors.ts';
import type { Session } from '../innertube/session.ts';
import { logger } from '../log.ts';
import type { PlaylistResult, VideoItem } from '../types.ts';
import { parseFeed } from './feed.ts';
import { countFromText, metadataRowTexts, text } from './text.ts';
import { asArray, get, str, type Json } from './tree.ts';

const log = logger('playlist');

/**
 * An `ERROR` alert is the whole answer ("The playlist does not exist."); any
 * other type rides along with a list that is still good, so it is only logged.
 */
function refusalFrom(raw: Json, playlistId: string): string | null {
  for (const alert of asArray(get(raw, 'alerts'))) {
    // "Unavailable videos are hidden" comes as `alertWithButtonRenderer`.
    const renderer = get(alert, 'alertRenderer') ?? get(alert, 'alertWithButtonRenderer');
    const message = text(get(renderer, 'text'));
    if (!message) continue;
    if (str(get(renderer, 'type')) === 'ERROR') return message;
    log.warn(`playlist ${playlistId} returned alert: ${message}`);
  }
  return null;
}

/**
 * The playlist's own name and length, from the first page's header.
 *
 * `videoCount` counts every entry, unavailable ones included, so it can be
 * larger than the number of items the pages add up to.
 */
export function parsePlaylistHeader(raw: Json): { title: string | null; videoCount: number | null } {
  const title =
    str(get(raw, 'metadata', 'playlistMetadataRenderer', 'title')) ??
    str(get(raw, 'header', 'pageHeaderRenderer', 'pageTitle'));

  // The sidebar's first stat is the count on its own. The page header only has
  // it as one part among several, found by its (hl=en) wording.
  const stats = get(raw, 'sidebar', 'playlistSidebarRenderer', 'items', '0', 'playlistSidebarPrimaryInfoRenderer', 'stats', '0');
  const headerParts = metadataRowTexts(
    get(raw, 'header', 'pageHeaderRenderer', 'content', 'pageHeaderViewModel', 'metadata', 'contentMetadataViewModel'),
  ).flat();
  const videoCount =
    countFromText(stats) ?? countFromText(headerParts.find((part) => /^\d[\d,.\s]*videos?$/i.test(part)));

  return { title, videoCount };
}

export async function getPlaylist(
  session: Session,
  params: { playlistId: string; continuation: string | null },
): Promise<PlaylistResult> {
  const { playlistId, continuation } = params;

  // The client sends the id as tiles carry it; `/browse` wants it `VL`-prefixed.
  const browseId = playlistId.startsWith('VL') ? playlistId : `VL${playlistId}`;

  const raw = (continuation
    ? await session.execute('/browse', { continuation })
    : await session.execute('/browse', { browseId })) as Json;

  const refusal = refusalFrom(raw, playlistId);
  if (refusal) throw new RpcError('UPSTREAM_ERROR', refusal);

  const feed = parseFeed(raw, 'playlist');
  const items = feed.items.filter((item): item is VideoItem => item.kind === 'video');
  if (items.length !== feed.items.length) {
    log.debug(`playlist.get dropped ${feed.items.length - items.length} non-video items`);
  }

  // Measured 2026-10-06: a continuation page repeats `metadata` and `sidebar`,
  // so the header is there too — but nothing promises it, hence nullable.
  return { ...parsePlaylistHeader(raw), items, continuation: feed.continuation };
}
