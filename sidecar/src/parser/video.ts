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
import { parseChapters } from './chapters.ts';
import { parseFeed } from './feed.ts';
import { parseMusicTracks } from './music.ts';
import { premiereStartMs } from './premiere.ts';
import {
  bestImageUrl,
  channelIdFrom,
  durationToSeconds,
  exactCountFromText,
  scanOwnerBadges,
  text,
} from './text.ts';
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

  // **The text first, because it is the number on screen.** The tooltip shows
  // `viewCountText` verbatim, so deriving the short form from the same string
  // makes the two agree by construction rather than by coincidence.
  //
  // `originalViewCount` is only a fallback, and **`"0"` there means "not filled
  // in", not zero** — measured 2026-09-13 across 24 watch pages: 18 carried
  // `"0"` beside a real count ("0" next to "67,867 views"), 6 carried the actual
  // number. The first version of this read that field first, trusting a single
  // measurement that happened to land on one of the six, and `0 ?? fallback`
  // never falls back — so most videos showed "0 views". A genuinely unwatched
  // video is still right: its text reads "0 views" and parses to 0 above.
  const originalViewCount = num(
    str(get(primary, 'viewCount', 'videoViewCountRenderer', 'originalViewCount')),
  );
  const viewCount =
    exactCountFromText(viewCountText) ??
    (originalViewCount !== null && originalViewCount > 0 ? originalViewCount : null);

  // `isLiveContent` dropped deliberately — it is a permanent "this is/was
  // live-form content" tag, not a current-status signal, and stays `true`
  // forever once a broadcast has ever gone live. See `player.ts`'s
  // `parsePlayer` for the measurement (`0QnMv0bRyk0`, ended June 2024, still
  // `isLiveContent: true` in 2026) that caught it there; `/next`'s own
  // `videoDetails` is sparser and did not carry the field for that video, but
  // nothing rules out a layout where it does.
  const isLive =
    get(details, 'isLive') === true ||
    isObject(get(primary, 'viewCount', 'videoViewCountRenderer', 'isLive'));

  // A `/next` response carries no duration — `lengthSeconds` lives on the
  // `/player` response, and `videoPrimaryInfoRenderer` has no length text. Null
  // here is expected, not a gap: `playback.open` returns `durationMs`, and
  // `video.info` composes the two.
  const lengthSeconds =
    num(get(details, 'lengthSeconds')) ?? durationToSeconds(get(primary, 'lengthText'));

  const likeText = findLikeText(body);
  const myRating = findMyRating(body);

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
    viewCount,
    publishedText:
      text(get(primary, 'relativeDateText')) ?? text(get(primary, 'dateText')),
    // The exact date, kept as a field of its own rather than folded into the
    // `??` above: `relativeDateText` ("14 years ago") and `dateText` ("Dec 6,
    // 2009") are siblings on the same renderer when both are present, not
    // alternatives — `publishedText` prefers the relative one for the
    // headline, and this is the exact one for a tooltip on it. Null exactly
    // when the layout carries no exact date at all, same as `publishedText`
    // falling back to it only when the relative one is missing.
    publishedDateText: text(get(primary, 'dateText')),
    likeText,
    myRating,
    isSubscribed: hasSubscribedButton(body),
    isVerified: ownerBadges.isVerified,
    isArtistChannel: ownerBadges.isArtistChannel,
    badges: [...new Set(badges)],
    // Off `engagementPanels`, which nothing else in this parser reads — see
    // `parser/music.ts`. Empty for most videos, and that is an answer.
    music: parseMusicTracks(body),
    // Where a song starts — the credits above carry no timestamps. See
    // `parser/chapters.ts`.
    chapters: parseChapters(body, description),
    isMembersOnly,
    // Deep-searched for the same reason the tiles are: the watch page hangs this
    // off a different renderer depending on generation, and no premiere is in
    // the fixture corpus to pin a path against. Null here is ordinary —
    // `video.info` falls back to the `/player` half, which is the reliable one.
    premiereAtMs: premiereStartMs(body),
    related: related.items as FeedItem[],
    relatedContinuation: related.continuation,
    commentsContinuation: findCommentsContinuation(body),
  };
}

/**
 * The continuation token for the first page of comments, read from the watch
 * page's own `comment-item-section`. Null when comments are disabled.
 */
function findCommentsContinuation(body: Json): string | null {
  const sections = get(body, 'contents', 'twoColumnWatchNextResults', 'results', 'results', 'contents');
  if (Array.isArray(sections)) {
    for (const section of sections) {
      if (
        isObject(section['itemSectionRenderer']) &&
        str(get(section, 'itemSectionRenderer', 'sectionIdentifier')) === 'comment-item-section'
      ) {
        const contents = get(section, 'itemSectionRenderer', 'contents');
        if (Array.isArray(contents)) {
          for (const item of contents) {
            const token = str(
              get(item, 'continuationItemRenderer', 'continuationEndpoint', 'continuationCommand', 'token'),
            );
            if (token) return token;
          }
        }
      }
    }
  }
  return null;
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

/**
 * The raw `likeStatus` value off the watch page's like/dislike button —
 * `'LIKE' | 'DISLIKE' | 'INDIFFERENT'`, or `null` if neither shape was found.
 *
 * Two generations, read structurally rather than by a fixed path, the same
 * discipline `findOwner`/`findLikeText` already use above:
 *
 *  - **Classic**: `likeButtonRenderer.likeStatus` sits directly on the
 *    renderer, next to `target.videoId` — the same field name and enum
 *    `action.like`/`dislike`/`removeRating` send as `status`
 *    (`actions/interaction.ts`). Long-stable shape.
 *  - **View-based**: `likeButtonViewModel`'s own payload carries
 *    `likeStatusEntity.{key, likeStatus}` *inline* — unlike the search artist
 *    panel's subscribe button (`protocol.md` §3.3), which carries no
 *    current-state boolean of its own and has to be resolved through
 *    `frameworkUpdates.entityBatchUpdate`. This button is not that case: its
 *    own subtree already says which way it is toggled.
 *
 * Both come from a community library's typed renderer classes
 * (`LikeButton`, `LikeButtonView`), read as documentation of the raw shape
 * only (hard invariant 1) — **neither is confirmed against a fixture in this
 * repo.** If `myRating` reads wrong on a real account, this is where to look
 * first, and the view-based path is the more likely place it is wrong: it is
 * newer and has rotated shape before (F22, the STATION badge, on an unrelated
 * renderer).
 */
function likeStatusFrom(body: Json): string | null {
  const classic = deepFind(body, (node) => isObject(node['likeButtonRenderer']));
  if (classic) {
    const status = str(get(classic, 'likeButtonRenderer', 'likeStatus'));
    if (status) return status;
  }

  const viewBased = deepFind(body, (node) => isObject(node['likeStatusEntity']));
  if (viewBased) {
    const status = str(get(viewBased, 'likeStatusEntity', 'likeStatus'));
    if (status) return status;
  }

  return null;
}

/**
 * `'INDIFFERENT'` and "shape not found" both mean the same thing to a caller —
 * no rating — so both collapse to `'none'` rather than the DTO carrying a
 * third `null` state nothing could ever act on differently. See
 * {@link likeStatusFrom} for which case is which; this function does not
 * distinguish them on purpose.
 */
function findMyRating(body: Json): 'like' | 'dislike' | 'none' {
  const status = likeStatusFrom(body);
  if (status === 'LIKE') return 'like';
  if (status === 'DISLIKE') return 'dislike';
  return 'none';
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
