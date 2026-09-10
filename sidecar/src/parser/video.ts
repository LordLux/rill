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
import { premiereStartMs } from './premiere.ts';
import { bestImageUrl, channelIdFrom, durationToSeconds, scanOwnerBadges, text } from './text.ts';
import { deepCollect, deepFind, get, isObject, num, str, type Json, type JsonObject } from './tree.ts';

function findRenderer(root: Json, key: string): Json {
  const holder = deepFind(root, (node) => isObject(node[key]));
  return holder ? holder[key] : null;
}

/** Owner block: `videoOwnerRenderer` (classic) or any node carrying a channel id + title. */
function findOwner(secondary: Json): Json {
  return findRenderer(secondary, 'videoOwnerRenderer') ?? secondary;
}

/**
 * The channel this video belongs to — or `null` when it does not belong to one.
 *
 * A deep scan for the first `UC…` browseId is wrong here, and wrong silently.
 * A **collaboration** upload replaces the owner's channel link with a
 * `showDialogCommand` listing the collaborators, and the first `UC…` id inside
 * that dialog is the first *collaborator*. Deep-scanning returned it as if it
 * were the video's channel: no error, no empty field, just the wrong channel —
 * which a "go to channel" or a subscribe action would then act on.
 *
 * So the endpoint is read structurally, and the rule is deliberately narrow:
 *
 *  1. The owner's own `navigationEndpoint.browseEndpoint` — the classic shape.
 *  2. An owner whose `navigationEndpoint` is something *other* than a browse is
 *     a dialog, not a channel: answer `null`. There genuinely is no single
 *     channel to name, and `null` says that where a plausible-looking id lies.
 *  3. Only an owner with no endpoint at all falls back to the deep scan, which
 *     is what covers layouts that bury the link somewhere new.
 *
 * Structural rather than matching the dialog's headline, because that headline
 * is localised — this account browses with `tz=Europe.Rome`, and "Collaborators"
 * is not what it would say.
 */
function ownerChannelId(owner: Json): string | null {
  const endpoint = get(owner, 'navigationEndpoint');
  if (isObject(endpoint)) {
    const browseId = str(get(endpoint, 'browseEndpoint', 'browseId'));
    return browseId !== null && /^UC[\w-]{20,}$/.test(browseId) ? browseId : null;
  }
  return channelIdFrom(owner);
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

  const ownerBadges = scanOwnerBadges(owner);

  // Every `metadataBadgeRenderer` on the page, split into the members-only flag
  // and the display labels — the same split `scanBadges` makes for a tile, and
  // for the same reason: `style` is stable across locales where `label` is not,
  // and a fact with a DTO field of its own must not also travel as a label.
  const badgeNodes = deepCollect(body, (node) => isObject(node['metadataBadgeRenderer'])).map(
    (node) => node['metadataBadgeRenderer'] as JsonObject,
  );

  const isMembersOnly = badgeNodes.some(
    (badge) =>
      /MEMBERS_ONLY/i.test(str(badge['style']) ?? '') ||
      str(get(badge, 'icon', 'iconType')) === 'SPONSORSHIP_STAR',
  );

  const badges = badgeNodes
    .filter((badge) => !/MEMBERS_ONLY/i.test(str(badge['style']) ?? ''))
    .map((badge) => text(badge['label']))
    .filter((label): label is string => label !== null);

  return {
    id,
    title,
    description,
    // `attributedTitle` is the view-based owner byline, and on a collaboration
    // upload it is the only one: "jazziiRed and 3 more", where a classic page
    // would carry `title.runs`. Without it the watch page drew a blank channel.
    channelName:
      text(get(owner, 'title')) ??
      text(get(owner, 'attributedTitle')) ??
      str(get(details, 'author')) ??
      '',
    channelId: ownerChannelId(owner) ?? str(get(details, 'channelId')),
    // `avatarStack` is the collaboration shape — four circular avatars where a
    // single-owner page has one `thumbnail`. The first is the one YouTube shows
    // in front, and `bestImageUrl` keeps the first of equally-sized sources.
    channelAvatarUrl:
      bestImageUrl(get(owner, 'thumbnail')) ?? bestImageUrl(get(owner, 'avatarStack')),
    subscriberText: text(get(owner, 'subscriberCountText')),
    durationSeconds: isLive ? null : lengthSeconds,
    isLive,
    viewCountText,
    publishedText:
      text(get(primary, 'relativeDateText')) ?? text(get(primary, 'dateText')),
    likeText,
    isSubscribed: hasSubscribedButton(body),
    isVerified: ownerBadges.isVerified,
    isArtistChannel: ownerBadges.isArtistChannel,
    badges: [...new Set(badges)],
    isMembersOnly,
    // Deep-searched for the same reason the tiles are: the watch page hangs this
    // off a different renderer depending on generation, and no premiere is in
    // the fixture corpus to pin a path against. Null here is ordinary —
    // `video.info` falls back to the `/player` half, which is the reliable one.
    premiereAtMs: premiereStartMs(body),
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
