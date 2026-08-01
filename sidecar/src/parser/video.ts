/**
 * `parseVideoDetail` — raw `/next` (watch page) response → `VideoDetail`.
 *
 * The watch page is the most A/B-tested surface YouTube has: the same fields
 * move between `videoPrimaryInfoRenderer`, `videoSecondaryInfoRenderer`,
 * engagement panels and, on newer layouts, view models with none of those names.
 * So this reads by shape wherever a fixed path would be brittle, and falls back
 * to `videoDetails` from an accompanying player response when present.
 *
 * Related tiles reuse `parseFeed` — the sidebar is a feed like any other, and
 * having one item mapper is the point of the DTO contract.
 */

import type { FeedItem, VideoDetail } from '../types.ts';
import { parseFeed } from './feed.ts';
import { bestImageUrl, channelIdFrom, durationToSeconds, text } from './text.ts';
import { deepCollect, deepFind, get, isObject, num, str, type Json } from './tree.ts';

function findRenderer(root: Json, key: string): Json {
  const holder = deepFind(root, (node) => isObject(node[key]));
  return holder ? holder[key] : null;
}

/** Owner block: `videoOwnerRenderer` (classic) or any node carrying a channel id + title. */
function findOwner(secondary: Json): Json {
  return findRenderer(secondary, 'videoOwnerRenderer') ?? secondary;
}

export function parseVideoDetail(raw: Json, context = 'video'): VideoDetail {
  const body = isObject(raw) && isObject(raw['data']) ? raw['data'] : raw;

  const primary = findRenderer(body, 'videoPrimaryInfoRenderer');
  const secondary = findRenderer(body, 'videoSecondaryInfoRenderer');
  const details = get(body, 'videoDetails');
  const owner = findOwner(secondary);

  // Related tiles live under secondaryResults; on layouts where they do not,
  // parseFeed over the whole body still finds them and drops the rest.
  const relatedRoot =
    get(body, 'contents', 'twoColumnWatchNextResults', 'secondaryResults') ??
    get(body, 'contents', 'twoColumnWatchNextResults') ??
    body;
  const related = parseFeed(relatedRoot, `${context}.related`);

  const id =
    str(get(details, 'videoId')) ??
    str(get(body, 'currentVideoEndpoint', 'watchEndpoint', 'videoId')) ??
    '';

  const title = text(get(primary, 'title')) ?? str(get(details, 'title')) ?? '';

  const description =
    text(get(secondary, 'attributedDescription')) ??
    text(get(secondary, 'description')) ??
    str(get(details, 'shortDescription'));

  const viewCountText =
    text(get(primary, 'viewCount', 'videoViewCountRenderer', 'viewCount')) ??
    text(get(primary, 'viewCount', 'videoViewCountRenderer', 'shortViewCount'));

  const isLive =
    get(details, 'isLive') === true ||
    get(details, 'isLiveContent') === true ||
    isObject(get(primary, 'viewCount', 'videoViewCountRenderer', 'isLive'));

  // A `/next` response carries no duration — `lengthSeconds` lives on the
  // `/player` response, and `videoPrimaryInfoRenderer` has no length text. Null
  // here is expected, not a gap: `playback.open` returns `durationMs`, and
  // `video.info` composes the two.
  const lengthSeconds =
    num(get(details, 'lengthSeconds')) ?? durationToSeconds(get(primary, 'lengthText'));

  const likeText = findLikeText(body);

  const badges = deepCollect(body, (node) => isObject(node['metadataBadgeRenderer']))
    .map((node) => text(get(node, 'metadataBadgeRenderer', 'label')))
    .filter((label): label is string => label !== null);

  return {
    id,
    title,
    description,
    channelName: text(get(owner, 'title')) ?? str(get(details, 'author')) ?? '',
    channelId: channelIdFrom(owner) ?? str(get(details, 'channelId')),
    channelAvatarUrl: bestImageUrl(get(owner, 'thumbnail')),
    subscriberText: text(get(owner, 'subscriberCountText')),
    durationSeconds: isLive ? null : lengthSeconds,
    isLive,
    viewCountText,
    publishedText:
      text(get(primary, 'relativeDateText')) ?? text(get(primary, 'dateText')),
    likeText,
    isSubscribed: hasSubscribedButton(body),
    badges: [...new Set(badges)],
    related: related.items as FeedItem[],
    relatedContinuation: related.continuation,
  };
}

/**
 * The like count, as a display string.
 *
 * View-based watch pages nest it five levels deep
 * (`likeButtonViewModel → toggleButtonViewModel → defaultButtonViewModel →
 * buttonViewModel`), where the count is the button's `title` next to
 * `iconName: 'LIKE'`. Classic pages put it on a `toggleButtonRenderer`'s
 * `defaultText`. Matching on the icon finds both without hardcoding either path.
 */
function findLikeText(body: Json): string | null {
  const viewModel = deepFind(
    body,
    (node) => str(node['iconName']) === 'LIKE' && str(node['title']) !== null,
  );
  if (viewModel) return str(viewModel['title']);

  const classic = deepFind(
    body,
    (node) =>
      isObject(node['defaultText']) && /LIKE/i.test(str(get(node, 'defaultIcon', 'iconType')) ?? ''),
  );
  return classic ? text(classic['defaultText']) : null;
}

function hasSubscribedButton(body: Json): boolean {
  const button = deepFind(
    body,
    (node) => isObject(node['subscribeButtonRenderer']) || typeof node['subscribed'] === 'boolean',
  );
  if (!button) return false;
  return (
    get(button, 'subscribeButtonRenderer', 'subscribed') === true || button['subscribed'] === true
  );
}
