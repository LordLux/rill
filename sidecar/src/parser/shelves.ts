/**
 * Home shelves (`todo.md` 111): what a titled row is, what is in it, and which
 * category it belongs to.
 *
 * `parseFeed` flattened every shelf into the grid until now, which hid the members
 * shelf and let one channel crowd the page (`architecture.md` F61). With shelves
 * asked for, a shelf container collects its own tiles instead, and this file turns
 * what it collected into a {@link Shelf}.
 *
 * **The category is structure, never the title.** The title is localised — the
 * same trap as the members label — so it is only ever carried through for display.
 * What decides is what the tiles *are*: all Shorts, all posts, all members-only.
 * Anything else, including a shelf of mixed tiles, is `other`, deliberately: a
 * shelf with no rule yet is shown or hidden by the user's "other" setting rather
 * than guessed into a category.
 */

import type { PostItem, Shelf, ShelfCategory, ShelfItem, VideoItem } from '../types.ts';
import { bestImageUrl, channelIdFrom, text } from './text.ts';
import { get, isObject, str, type Json } from './tree.ts';

/** Container renderers (normalised) that are a titled row rather than the grid. */
export const SHELF_RENDERERS: ReadonlySet<string> = new Set(['richshelf', 'brandvideoshelf', 'shelf']);

/**
 * A shelf's header text: its own `title`/`headline`, else the headline of the
 * `sectionHeaderViewModel` a `brandVideoShelfRenderer` carries. Null when it has
 * neither — never a guess from the tiles.
 */
export function shelfTitle(payload: Json): string | null {
  if (!isObject(payload)) return null;
  const direct = text(payload['title']) ?? text(payload['headline']);
  if (direct) return direct;
  for (const key of ['header', 'headerViewModel']) {
    const header = payload[key];
    if (!isObject(header)) continue;
    const inner = header['sectionHeaderViewModel'] ?? header['shelfHeaderRenderer'] ?? header;
    const found = text(get(inner, 'headline')) ?? text(get(inner, 'title'));
    if (found) return found;
  }
  return null;
}

/**
 * `shortsLockupViewModel` → a `VideoItem` with `isShort: true`, so the app's own
 * Short tile and the "open as a video" path already apply. It has no channel, no
 * duration and no badges of its own — `channelName` is `''` and the rest `null` /
 * `false`, which is what a missing value is on this DTO.
 *
 * The id comes from the tile's own `reelWatchEndpoint`, never from `entityId`
 * (a store key whose spelling is not a contract).
 */
export function mapShortsLockup(node: Json): VideoItem | null {
  if (!isObject(node)) return null;
  const id = str(get(node, 'onTap', 'innertubeCommand', 'reelWatchEndpoint', 'videoId'));
  if (!id) return null;
  const title = text(get(node, 'overlayMetadata', 'primaryText')) ?? text(node['accessibilityText']);
  if (!title) return null;
  return {
    kind: 'video',
    id,
    title,
    channelName: '',
    channelId: null,
    channelAvatarUrl: null,
    thumbnailUrl: bestImageUrl(get(node, 'thumbnailViewModel')) ?? bestImageUrl(get(node, 'onTap')) ?? '',
    durationSeconds: null,
    isLive: false,
    isStation: false,
    viewCountText: text(get(node, 'overlayMetadata', 'secondaryText')),
    publishedText: null,
    descriptionSnippet: null,
    badges: [],
    isShort: true,
    isMusic: false,
    isMembersOnly: false,
    isVerified: false,
    isArtistChannel: false,
    premiereAtMs: null,
    canWatchLater: false,
    canAddToQueue: false,
  };
}

/** `postRenderer` → a {@link PostItem}, or null when it carries no post id. */
export function mapPost(node: Json): PostItem | null {
  if (!isObject(node)) return null;
  const id = str(node['postId']);
  if (!id) return null;
  const author = node['authorText'];
  // The link on the timestamp is the post's own permalink; a relative path is the
  // only shape seen, so anything else is not carried rather than guessed at.
  const path = str(get(node, 'publishedTimeText', 'runs', '0', 'navigationEndpoint', 'commandMetadata', 'webCommandMetadata', 'url'));
  return {
    kind: 'post',
    id,
    authorName: text(author) ?? '',
    authorChannelId: channelIdFrom(author) ?? str(get(node, 'authorEndpoint', 'browseEndpoint', 'browseId')),
    authorAvatarUrl: bestImageUrl(node['authorThumbnail']),
    text: text(node['contentText']),
    imageUrl: bestImageUrl(get(node, 'backstageAttachment', 'backstageImageRenderer', 'image')),
    publishedText: text(node['publishedTimeText']),
    likeCountText: text(node['voteCount']),
    postUrl: path !== null && path.startsWith('/') ? `https://www.youtube.com${path}` : null,
  };
}

/** What a shelf's tiles say it is. Pure structure; see the file comment. */
export function categorise(items: readonly ShelfItem[]): ShelfCategory {
  if (items.length === 0) return 'other';
  if (items.every((item) => item.kind === 'post')) return 'posts';
  if (items.every((item) => item.kind === 'video' && item.isShort)) return 'shorts';
  if (items.every((item) => item.kind === 'video' && item.isMembersOnly)) return 'members';
  return 'other';
}

/** A finished shelf, or null for one with nothing mappable in it (a row of nothing is not shown). */
export function buildShelf(title: string | null, index: number, items: ShelfItem[]): Shelf | null {
  if (items.length === 0) return null;
  return { category: categorise(items), title, index, items };
}
