/**
 * Renderer → flat DTO mapping.
 *
 * Every mapper returns a fully populated item or `null`. `null` means the node
 * carried too little to be a usable tile (no id, or no title) — not that parsing
 * failed. A missing view count is never a reason to drop a video: optional
 * fields go to `null` and the item still ships.
 */

import type { ArtistPanel, ChannelItem, FeedItem, MixItem, PlaylistItem, VideoItem } from '../types.ts';
import { premiereStartMs } from './premiere.ts';
import {
  asArray,
  deepFind,
  get,
  isObject,
  str,
  type Json,
  type JsonObject,
} from './tree.ts';
import {
  bestImageUrl,
  channelIdFrom,
  countFromText,
  deepTileId,
  durationToSeconds,
  isPublishedText,
  isViewCountText,
  metadataRowTexts,
  scanBadges,
  scanOwnerBadges,
  scanTileActions,
  text,
  tileId,
} from './text.ts';

/** A Mix is a radio playlist. Its id always starts `RD`. */
function isMixId(id: string): boolean {
  return /^RD/.test(id);
}

// ---------------------------------------------------------------------------
// View-based: lockupViewModel
// ---------------------------------------------------------------------------

/**
 * `lockupViewModel` is one renderer for every tile type, discriminated by
 * `contentType`. When `contentType` is absent the tile is an ad shell — those
 * are stripped upstream, but the guard stays here so a stray one cannot ship as
 * a title-less video.
 */
export function mapLockup(node: JsonObject): FeedItem | null {
  const id = tileId(node) ?? deepTileId(node);
  if (!id) return null;

  const contentType = str(node['contentType']) ?? '';
  const metadata = get(node, 'metadata', 'lockupMetadataViewModel');
  const title = text(get(metadata, 'title'));

  // No lockupMetadataViewModel means an ad layout (feedAdMetadataViewModel) or a
  // shape we do not model. Either way there is no title to ship.
  if (!title) return null;

  const thumbnailUrl = bestImageUrl(node['contentImage']);
  const badges = scanBadges(node['contentImage']);
  const rows = metadataRowTexts(get(metadata, 'metadata', 'contentMetadataViewModel'));
  const flatRows = rows.flat();

  if (/PLAYLIST|PODCAST|ALBUM/i.test(contentType)) {
    const subtitle = flatRows[0] ?? null;
    const videoCount = flatRows.map(countFromText).find((n) => n !== null) ?? null;

    if (isMixId(id) || badges.labels.some((label) => /^mix$/i.test(label))) {
      return {
        kind: 'mix',
        id,
        title,
        subtitle,
        thumbnailUrl: thumbnailUrl ?? '',
        videoCount,
      } satisfies MixItem;
    }

    return {
      kind: 'playlist',
      id,
      title,
      thumbnailUrl: thumbnailUrl ?? '',
      videoCount,
      channelName: subtitle,
    } satisfies PlaylistItem;
  }

  if (/CHANNEL/i.test(contentType)) {
    const ownerBadges = scanOwnerBadges(node);
    return {
      kind: 'channel',
      id,
      name: title,
      avatarUrl: bestImageUrl(node['contentImage']) ?? '',
      subscriberText: flatRows.find((row) => /subscriber/i.test(row)) ?? null,
      isVerified: ownerBadges.isVerified,
      isArtistChannel: ownerBadges.isArtistChannel,
    } satisfies ChannelItem;
  }

  // Everything else is a video: LOCKUP_CONTENT_TYPE_VIDEO, and anything new that
  // carries a title and an id. Shipping it as a video beats dropping it.
  const channelRow = rows[0] ?? [];
  const detailRows = rows.slice(1).flat();
  const actions = scanTileActions(node);
  const ownerBadges = scanOwnerBadges(node);

  return {
    kind: 'video',
    id,
    title,
    channelName: channelRow[0] ?? '',
    channelId: channelIdFrom(metadata),
    channelAvatarUrl: bestImageUrl(get(metadata, 'image')),
    thumbnailUrl: thumbnailUrl ?? '',
    durationSeconds: badges.isLive ? null : badges.durationSeconds,
    isLive: badges.isLive || detailRows.some((row) => /watching now/i.test(row)),
    viewCountText: detailRows.find(isViewCountText) ?? null,
    publishedText: detailRows.find(isPublishedText) ?? null,
    descriptionSnippet: null,
    badges: badges.labels.filter((label) => label !== 'LIVE'),
    isShort: badges.isShort,
    isMusic: badges.hasMusicNote,
    isVerified: ownerBadges.isVerified,
    isArtistChannel: ownerBadges.isArtistChannel,
    premiereAtMs: premiereStartMs(node),
    canWatchLater: actions.canWatchLater,
    canAddToQueue: actions.canAddToQueue,
  } satisfies VideoItem;
}

// ---------------------------------------------------------------------------
// Classic: videoRenderer and friends
// ---------------------------------------------------------------------------

export function mapClassicVideo(node: JsonObject): VideoItem | null {
  const id = tileId(node) ?? deepTileId(node);
  if (!id) return null;

  const title = text(node['title']) ?? text(node['headline']);
  if (!title) return null;

  const byline = node['longBylineText'] ?? node['ownerText'] ?? node['shortBylineText'];
  const badges = scanBadges(node);
  const actions = scanTileActions(node);
  const ownerBadges = scanOwnerBadges(node);

  const lengthSeconds =
    durationToSeconds(node['lengthText']) ??
    badges.durationSeconds ??
    (typeof node['lengthSeconds'] === 'string' ? Number(node['lengthSeconds']) : null);

  const viewCountText = text(node['viewCountText']) ?? text(node['shortViewCountText']);

  // Classic tiles signal live three ways: a LIVE badge, a LIVE-styled time
  // overlay (both caught by scanBadges), or a "watching now" view count.
  const isLive = badges.isLive || (viewCountText !== null && /watching/i.test(viewCountText));

  return {
    kind: 'video',
    id,
    title,
    channelName: text(byline) ?? '',
    channelId: channelIdFrom(byline) ?? channelIdFrom(node['channelThumbnailSupportedRenderers']),
    channelAvatarUrl:
      bestImageUrl(node['channelThumbnailSupportedRenderers']) ?? bestImageUrl(node['avatar']),
    thumbnailUrl: bestImageUrl(node['thumbnail']) ?? '',
    durationSeconds: isLive ? null : (Number.isFinite(lengthSeconds) ? lengthSeconds : null),
    isLive,
    viewCountText,
    publishedText: text(node['publishedTimeText']),
    descriptionSnippet:
      text(get(asArray(node['detailedMetadataSnippets'])[0], 'snippetText')) ??
      text(node['descriptionSnippet']) ??
      null,
    badges: badges.labels.filter((label) => label !== 'LIVE'),
    isShort: badges.isShort,
    isMusic: badges.hasMusicNote,
    isVerified: ownerBadges.isVerified,
    isArtistChannel: ownerBadges.isArtistChannel,
    premiereAtMs: premiereStartMs(node),
    canWatchLater: actions.canWatchLater,
    canAddToQueue: actions.canAddToQueue,
  } satisfies VideoItem;
}

// ---------------------------------------------------------------------------
// Classic: playlistRenderer / radioRenderer / channelRenderer
// ---------------------------------------------------------------------------

export function mapClassicPlaylist(node: JsonObject): MixItem | PlaylistItem | null {
  const id =
    str(node['playlistId']) ?? str(node['playlist_id']) ?? (tileId(node) ?? deepTileId(node));
  if (!id) return null;

  const title = text(node['title']);
  if (!title) return null;

  const thumbnailUrl = bestImageUrl(node['thumbnail'] ?? node['thumbnails']) ?? '';
  const videoCount =
    countFromText(node['videoCountText']) ??
    countFromText(node['videoCountShortText']) ??
    countFromText(node['videoCount']);

  if (isMixId(id)) {
    return {
      kind: 'mix',
      id,
      title,
      subtitle: text(node['secondaryTitle']) ?? text(node['longBylineText']) ?? null,
      thumbnailUrl,
      videoCount,
    } satisfies MixItem;
  }

  return {
    kind: 'playlist',
    id,
    title,
    thumbnailUrl,
    videoCount,
    channelName: text(node['longBylineText'] ?? node['shortBylineText'] ?? node['ownerText']),
  } satisfies PlaylistItem;
}

export function mapClassicChannel(node: JsonObject): ChannelItem | null {
  const id = str(node['channelId']) ?? channelIdFrom(node);
  if (!id) return null;

  const name = text(node['title']) ?? text(node['displayName']);
  if (!name) return null;

  const ownerBadges = scanOwnerBadges(node);

  return {
    kind: 'channel',
    id,
    name,
    avatarUrl: bestImageUrl(node['thumbnail']) ?? '',
    subscriberText: subscriberishText(node),
    isVerified: ownerBadges.isVerified,
    isArtistChannel: ownerBadges.isArtistChannel,
  } satisfies ChannelItem;
}

/**
 * `channelRenderer`'s subscriber count, from whichever field actually holds it.
 *
 * `videoCountText`, despite the name, is where a search channel result puts
 * "21.2M subscribers" — measured 2026-08-27. `subscriberCountText` is *not* a
 * fallback for it; on that same node it held `"@mkbhd"`, the handle. Trusting
 * field-name order the way `mapClassicVideo`'s byline does would have shipped
 * a handle as a subscriber count, silently — nothing throws, the string is
 * just wrong. So this checks shape instead of name: a handle starts with `@`
 * and is skipped rather than trusted.
 */
function subscriberishText(node: JsonObject): string | null {
  for (const value of [node['videoCountText'], node['subscriberCountText']]) {
    const candidate = text(value);
    if (candidate && !candidate.startsWith('@')) return candidate;
  }
  return null;
}

// ---------------------------------------------------------------------------
// officialCardViewModel — the artist panel (Task 21 §3)
// ---------------------------------------------------------------------------

/**
 * `officialCardViewModel` → `ArtistPanel`. Live-confirmed the top item of a
 * search-results `itemSectionRenderer` for an artist-name query, and absent
 * for an ordinary creator query — its presence is itself the "is an official
 * artist channel" fact, so unlike every other mapper here this one has no
 * badge check of its own to gate on.
 *
 * `subscriptionEntities` resolves `isSubscribed`: this view-model does **not**
 * carry the current subscription state inline. `subscribeButtonContent` and
 * `unsubscribeButtonContent` both ship, each with its own hardcoded
 * `subscribeState.subscribed` (`false` and `true` respectively) describing
 * what clicking *that* variant would produce — not which variant is active.
 * The real answer is the response's `frameworkUpdates.entityBatchUpdate`
 * entity store, looked up by `stateEntityStoreKey`; `parseFeed` resolves that
 * map once per response and threads it down here.
 */
export function mapArtistPanel(
  node: JsonObject,
  subscriptionEntities: ReadonlyMap<string, boolean>,
): ArtistPanel | null {
  const header = get(node, 'header', 'pageHeaderViewModel');
  if (!isObject(header)) return null;

  const channelId = channelIdFrom(header);
  if (!channelId) return null;

  const name = text(get(header, 'title', 'dynamicTextViewModel', 'text'));
  if (!name) return null;

  const avatarUrl = bestImageUrl(get(header, 'image')) ?? '';
  const rows = metadataRowTexts(get(header, 'metadata', 'contentMetadataViewModel')).flat();
  const handle = rows.find((row) => row.startsWith('@')) ?? null;
  const subscriberText = rows.find((row) => /subscriber/i.test(row)) ?? null;
  const videoCountText = rows.find((row) => /video/i.test(row)) ?? null;
  const description = text(get(header, 'description', 'descriptionPreviewViewModel', 'description'));

  const subscribeVm = deepFind(header, (candidate) => typeof candidate['stateEntityStoreKey'] === 'string');
  const stateKey = subscribeVm ? str(subscribeVm['stateEntityStoreKey']) : null;
  const isSubscribed = stateKey !== null ? (subscriptionEntities.get(stateKey) ?? false) : false;

  // The panel's "Mix" action, found by its `RD…` playlist id rather than by
  // button title — `buttonViewModel.title` is the localised label ("Mix" is
  // English-only), and the id shape is the same structural check `isMixId`
  // uses everywhere else in this file.
  const mixHolder = deepFind(get(header, 'actions'), (candidate) => {
    const playlistId = candidate['playlistId'];
    return typeof playlistId === 'string' && isMixId(playlistId);
  });
  const mixPlaylistId = mixHolder ? str(mixHolder['playlistId']) : null;

  return {
    channelId,
    name,
    handle,
    avatarUrl,
    subscriberText,
    videoCountText,
    description,
    isSubscribed,
    mixPlaylistId,
  } satisfies ArtistPanel;
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/**
 * Map one recognised item renderer. `renderer` is the normalised vocabulary name
 * (`lockup`, `gridvideo`, …) and `node` its payload.
 */
export function mapItem(renderer: string, node: Json): FeedItem | null {
  if (!isObject(node)) return null;

  switch (renderer) {
    case 'lockup':
      return mapLockup(node);

    case 'video':
    case 'gridvideo':
    case 'compactvideo':
    case 'playlistvideo':
    case 'videowithcontext':
    case 'playlistpanelvideo':
    case 'endscreenvideo':
      return mapClassicVideo(node);

    case 'playlist':
    case 'gridplaylist':
    case 'compactplaylist':
    case 'endscreenplaylist':
    case 'radio':
    case 'gridradio':
    case 'compactradio':
      return mapClassicPlaylist(node);

    case 'channel':
    case 'gridchannel':
    case 'compactchannel':
      return mapClassicChannel(node);

    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Chips
// ---------------------------------------------------------------------------

/**
 * Chips carry their replay handle two different ways, and `scope` is what tells
 * the caller which it is:
 *
 *   feed  (chipCloudChipRenderer) → a continuation token, replayed via /browse
 *                                   with `continuation`
 *   shelf (chipViewModel)         → `browseEndpoint.params`, replayed via
 *                                   /browse with `browseId` + `params`
 *
 * Both are opaque strings Flutter hands straight back, so they share one field
 * rather than widening the DTO with a second one.
 *
 * The selected chip ("All") on the home feed carries neither — it *is* the
 * default feed. An empty token means "no filter", not "extraction failed".
 */
export function mapChip(
  node: JsonObject,
  scope: 'feed' | 'shelf',
): { label: string; token: string; selected: boolean; scope: 'feed' | 'shelf' } | null {
  const label = text(node['text']) ?? text(node['label']) ?? text(node['chipText']);
  if (!label) return null;

  const tokenHolder = deepFind(node, (candidate) => typeof candidate['token'] === 'string');
  const paramsHolder = deepFind(
    node,
    (candidate) => typeof get(candidate, 'browseEndpoint', 'params') === 'string',
  );

  const token =
    (tokenHolder ? str(tokenHolder['token']) : null) ??
    (paramsHolder ? str(get(paramsHolder, 'browseEndpoint', 'params')) : null) ??
    '';

  const selected =
    node['selected'] === true ||
    node['isSelected'] === true ||
    node['is_selected'] === true ||
    str(node['style']) === 'STYLE_SELECTED' ||
    asArray(get(node, 'style')).some((entry) => str(entry) === 'STYLE_SELECTED');

  return { label, token, selected, scope };
}
