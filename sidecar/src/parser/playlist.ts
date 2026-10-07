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
import type { PlaylistHeader, PlaylistResult, VideoItem } from '../types.ts';
import { parseFeed } from './feed.ts';
import { countFromText, metadataRowTexts, text } from './text.ts';
import { asArray, get, str, type Json, isObject } from './tree.ts';

const log = logger('playlist');

/**
 * An `ERROR` alert is the whole answer ("The playlist does not exist."); any
 * other type rides along with a list that is still good, so it is only logged.
 */
function themedColor(value: Json): { light: number; dark: number } | null {
  if (!isObject(value)) return null;
  const light = value['lightTheme'];
  const dark = value['darkTheme'];
  if (typeof light !== 'number' || typeof dark !== 'number') return null;
  return { light, dark };
}

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
export function parsePlaylistHeader(raw: Json): { title: string | null; videoCount: number | null; header: PlaylistHeader | null } {
  // Title
  const title =
    str(get(raw, 'metadata', 'playlistMetadataRenderer', 'title')) ??
    str(get(raw, 'header', 'pageHeaderRenderer', 'pageTitle'));

  // Video count
  const stats = get(raw, 'sidebar', 'playlistSidebarRenderer', 'items', '0', 'playlistSidebarPrimaryInfoRenderer', 'stats', '0');
  const headerParts = metadataRowTexts(
    get(raw, 'header', 'pageHeaderRenderer', 'content', 'pageHeaderViewModel', 'metadata', 'contentMetadataViewModel'),
  ).flat();
  const videoCount =
    countFromText(stats) ?? countFromText(headerParts.find((part) => /^\d[\d,.\s]*videos?$/i.test(part)));

  // If there's no title, it's likely a continuation page with no header.
  if (!title) {
    return { title: null, videoCount: null, header: null };
  }

  // Thumbnail
  const thumbnailUrl =
    str(get(raw, 'microformat', 'microformatDataRenderer', 'thumbnail', 'thumbnails', '0', 'url')) ??
    str(get(raw, 'header', 'playlistHeaderRenderer', 'playlistHeaderBanner', 'heroPlaylistThumbnailRenderer', 'thumbnail', 'thumbnails', '0', 'url'));

  // Owner
  const ownerObj =
    get(raw, 'sidebar', 'playlistSidebarRenderer', 'items', '1', 'playlistSidebarSecondaryInfoRenderer', 'videoOwner', 'videoOwnerRenderer') ??
    get(raw, 'header', 'playlistHeaderRenderer', 'ownerText', 'runs', '0');
  const ownerName = text(get(ownerObj, 'title')) ?? str(get(ownerObj, 'text')) ?? null;
  const ownerChannelId = str(get(ownerObj, 'navigationEndpoint', 'browseEndpoint', 'browseId')) ?? null;
  const ownerAvatarUrl = str(get(ownerObj, 'thumbnail', 'thumbnails', '0', 'url')) ?? null;

  // View count
  const viewCountText =
    text(get(raw, 'sidebar', 'playlistSidebarRenderer', 'items', '0', 'playlistSidebarPrimaryInfoRenderer', 'stats', '1')) ??
    headerParts.find(p => /views?$/i.test(p)) ?? null;

  // Description
  const description = text(get(raw, 'sidebar', 'playlistSidebarRenderer', 'items', '0', 'playlistSidebarPrimaryInfoRenderer', 'description')) ?? null;

  // Visibility and ownership
  const oldDropdown = asArray(get(raw, 'sidebar', 'playlistSidebarRenderer', 'items', '0', 'playlistSidebarPrimaryInfoRenderer', 'privacyForm', 'dropdownFormFieldRenderer', 'entries'));
  const newDropdown = asArray(get(raw, 'header', 'pageHeaderRenderer', 'content', 'pageHeaderViewModel', 'actions', 'privacyForm', 'dropdownFormFieldRenderer', 'entries'));
  const dropdown = oldDropdown.length > 0 ? oldDropdown : newDropdown;
  const isOwnedByViewer = dropdown.length > 0;

  let visibility: 'public' | 'unlisted' | 'private' | null = null;
  if (isOwnedByViewer) {
    const selected = dropdown.find(e => get(e, 'privacyDropdownItemRenderer', 'isSelected') === true);
    const val = get(selected, 'privacyDropdownItemRenderer', 'int32Value');
    visibility = val === 0 ? 'private' : val === 1 ? 'public' : val === 2 ? 'unlisted' : null;
  } else {
    const unlisted = get(raw, 'microformat', 'microformatDataRenderer', 'unlisted') === true;
    const privacyStr = str(get(raw, 'header', 'playlistHeaderRenderer', 'privacy'));
    if (privacyStr === 'PRIVATE') visibility = 'private';
    else if (privacyStr === 'UNLISTED') visibility = 'unlisted';
    else visibility = unlisted ? 'unlisted' : 'public';
  }

  // Background color
  const colorData = get(raw, 'header', 'pageHeaderRenderer', 'content', 'pageHeaderViewModel', 'style', 'pageHeaderStyle', 'imageColorInfo', 'palette');
  const backgroundColor = themedColor(colorData);

  const header: PlaylistHeader = {
    thumbnailUrl,
    ownerName,
    ownerChannelId,
    ownerAvatarUrl,
    viewCountText,
    description,
    visibility,
    backgroundColor,
    isOwnedByViewer
  };

  return { title, videoCount, header };
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
