/**
 * Text, thumbnail and number extraction.
 *
 * YouTube expresses the same string four different ways depending on the
 * renderer generation:
 *
 *   { runs: [{ text: 'a' }, { text: 'b' }] }   classic, segmented
 *   { simpleText: 'ab' }                        classic, plain
 *   { content: 'ab' }                           view-based
 *   'ab'                                        occasionally just the string
 *
 * Every reader below accepts all four and returns `string | null`.
 */

import { asArray, deepFind, get, isObject, num, str, walk, type Json, type JsonObject } from './tree.ts';

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/** Flatten any of YouTube's text shapes into a plain string, or null. */
export function text(value: unknown): string | null {
  if (typeof value === 'string') return str(value);
  if (!isObject(value)) return null;

  const runs = value['runs'];
  if (Array.isArray(runs)) {
    const joined = runs
      .map((run) => (isObject(run) ? (typeof run['text'] === 'string' ? run['text'] : '') : ''))
      .join('');
    const trimmed = str(joined);
    if (trimmed) return trimmed;
  }

  return (
    str(value['simpleText']) ??
    str(value['content']) ??
    str(value['text']) ??
    str(value['label']) ??
    str(get(value, 'accessibility', 'accessibilityData', 'label'))
  );
}

/**
 * A channel id reachable from `node` — `browseEndpoint.browseId` shaped like a
 * channel. View-based tiles hang it off `commandRuns`, classic ones off
 * `navigationEndpoint`; searching by shape covers both and whatever comes next.
 */
export function channelIdFrom(node: Json): string | null {
  const endpoint = deepFind(node, (candidate) => {
    const browseId = get(candidate, 'browseEndpoint', 'browseId');
    return typeof browseId === 'string' && /^UC[\w-]{20,}$/.test(browseId);
  });
  return endpoint ? str(get(endpoint, 'browseEndpoint', 'browseId')) : null;
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

interface ImageSource {
  url: string;
  width: number;
}

/**
 * Best image URL under `node`, preferring the widest source.
 *
 * Handles `thumbnail.thumbnails[]` (classic) and `image.sources[]` (view-based),
 * at any depth, so callers can hand over a whole tile subtree.
 */
export function bestImageUrl(node: Json): string | null {
  const sources: ImageSource[] = [];

  walk(node, (candidate) => {
    for (const key of ['thumbnails', 'sources'] as const) {
      const list = candidate[key];
      if (!Array.isArray(list)) continue;
      for (const entry of list) {
        if (!isObject(entry)) continue;
        const url = str(entry['url']);
        if (!url) continue;
        // Channel avatars (`yt3.ggpht.com`) arrive protocol-relative — `//host/…`
        // — where video thumbnails do not. Measured on a search channel result
        // 2026-08-27: rejecting these left every `ChannelItem.avatarUrl` empty.
        if (/^\/\//.test(url)) sources.push({ url: `https:${url}`, width: num(entry['width']) ?? 0 });
        else if (/^https?:\/\//.test(url)) sources.push({ url, width: num(entry['width']) ?? 0 });
      }
    }
    return true;
  });

  if (sources.length === 0) return null;
  // Zero-width entries are unlabelled originals; keep them only if nothing else exists.
  const widest = sources.reduce((best, current) => (current.width > best.width ? current : best));
  return widest.url;
}

// ---------------------------------------------------------------------------
// Durations and counts
// ---------------------------------------------------------------------------

/** "10:02" → 602, "1:02:03" → 3723, "0:15" → 15. Anything else → null. */
export function durationToSeconds(value: unknown): number | null {
  const raw = text(value);
  if (!raw) return null;
  if (!/^\d{1,3}(:[0-5]\d){1,2}$/.test(raw)) return null;

  return raw
    .split(':')
    .map(Number)
    .reduce((total, part) => total * 60 + part, 0);
}

/** True when a badge/overlay string is a duration rather than a label. */
export function looksLikeDuration(value: string): boolean {
  return /^\d{1,3}(:[0-5]\d){1,2}$/.test(value);
}

/** "1,234 videos" → 1234, "50 videos" → 50, "Mix" → null. */
export function countFromText(value: unknown): number | null {
  const raw = text(value);
  if (!raw) return null;
  const match = /(\d[\d,.\s]*)/.exec(raw);
  if (!match?.[1]) return null;
  const digits = match[1].replace(/[^\d]/g, '');
  if (digits === '') return null;
  const parsed = Number(digits);
  return Number.isFinite(parsed) ? parsed : null;
}

/** Classifies a metadata string as a view count. "22K views", "1.2M watching". */
export function isViewCountText(value: string): boolean {
  return /\b(view|views|watching|waiting)\b/i.test(value);
}

/** Classifies a metadata string as a publish date. "1 hour ago", "Streamed 2 days ago". */
export function isPublishedText(value: string): boolean {
  return /\bago\b/i.test(value) || /^(streamed|premiered|scheduled|live)\b/i.test(value);
}

// ---------------------------------------------------------------------------
// Badges
// ---------------------------------------------------------------------------

/**
 * **A fact with a DTO field of its own does not also travel as a label.**
 *
 * That is the whole convention, and it is why `labels` below excludes live and
 * Shorts. Both used to be pushed into `labels` and then filtered back out by
 * each mapper individually — redundant, and with a hole in it: a fourth mapper
 * that forgot the filter would ship `badges: ["LIVE"]` beside `isLive: true`
 * and nothing would say so. The filter is gone; the flags are the only route.
 */
export interface BadgeScan {
  /** Non-duration, non-live, non-Shorts, non-members labels: "4K", "New", "Upcoming". */
  labels: string[];
  durationSeconds: number | null;
  /** Ships as `VideoItem.isLive`. Never as a `"LIVE"` entry in `badges[]`. */
  isLive: boolean;
  /** Ships as `VideoItem.isShort` (Task 21 §1). Never as `"SHORTS"` in `badges[]`. */
  isShort: boolean;
  /**
   * The `♪` YouTube draws on a music video's duration badge — `imageName:
   * "MUSIC"` on the badge's own icon, not its text. Only ever seen on
   * `thumbnailBadgeViewModel` (view-based) in the corpus; classic tiles carry
   * no equivalent icon field, so this stays false for them.
   */
  hasMusicNote: boolean;
  /**
   * Members-only content — ships as `VideoItem.isMembersOnly`, never as a
   * `"Members only"` entry in `badges[]`.
   *
   * **Keyed on `style`, never on the label**, and that is the whole point:
   * `label` is localised (this account browses `tz=Europe.Rome`) while
   * `BADGE_STYLE_TYPE_MEMBERS_ONLY` is not — the same trap the verified badge
   * documents in `protocol.md`. Measured live 2026-09-09 on the watch page for
   * `rAWLNJoE5_Y`:
   *
   * ```json
   * {"metadataBadgeRenderer": {
   *    "icon": {"iconType": "SPONSORSHIP_STAR"},
   *    "style": "BADGE_STYLE_TYPE_MEMBERS_ONLY",
   *    "label": "Members only"}}
   * ```
   *
   * The icon is read as a second route because a view-based tile carries an
   * icon where it may carry no style — the same asymmetry `hasMusicNote`
   * already deals with. Only the classic shape above is confirmed live.
   */
  isMembersOnly: boolean;
}

const LIVE_LABEL = /^(live|live now|in diretta)$/i;
const SHORTS_LABEL = /^shorts$/i;

/** `thumbnailBadgeViewModel.icon.sources[].clientResource.imageName === 'MUSIC'`. */
function badgeHasMusicIcon(badge: JsonObject): boolean {
  const sources = asArray(get(badge, 'icon', 'sources'));
  return sources.some((source) => str(get(source, 'clientResource', 'imageName')) === 'MUSIC');
}

/**
 * YouTube's own membership glyph, on a badge that may carry no `style`.
 *
 * Checked in both spellings a badge icon uses: `icon.iconType` (classic) and
 * `icon.sources[].clientResource.imageName` (view-based).
 */
function badgeHasMembersIcon(badge: JsonObject): boolean {
  if (str(get(badge, 'icon', 'iconType')) === MEMBERS_ICON) return true;
  const sources = asArray(get(badge, 'icon', 'sources'));
  return sources.some((source) => str(get(source, 'clientResource', 'imageName')) === MEMBERS_ICON);
}

const MEMBERS_STYLE = /MEMBERS_ONLY/i;
const MEMBERS_ICON = 'SPONSORSHIP_STAR';

/**
 * Sweep every badge-ish node in a tile and split it into duration, live/Shorts
 * flags, the music-note icon and display labels. Covers `thumbnailBadgeViewModel`
 * (view-based), `metadataBadgeRenderer` (classic) and
 * `thumbnailOverlayTimeStatusRenderer`.
 */
export function scanBadges(node: Json): BadgeScan {
  const labels: string[] = [];
  let durationSeconds: number | null = null;
  let isLive = false;
  let isShort = false;
  let isMembersOnly = false;

  /**
   * `membersIcon` is the badge's own `SPONSORSHIP_STAR`, decided by the caller.
   *
   * It is a *parameter* rather than something the sweep sets afterwards, and
   * that is what keeps this locale-independent. Deciding it out here and
   * striking the label later meant the label had already been pushed, so it had
   * to be removed by matching `/members only|solo membri/` — which covered two
   * languages and would have drawn a green pill *and* a grey "Réservé aux
   * membres" pill for everyone else. Now neither shape ever pushes it, and no
   * pattern over localised text exists to be incomplete.
   */
  const consider = (value: string | null, style: string | null, membersIcon = false): void => {
    // **Members first, and before the empty-value guard.** A members badge can
    // be an icon with no text at all on a view-based tile, and returning early
    // on a null label would drop the one signal it carries.
    if (membersIcon || (style !== null && MEMBERS_STYLE.test(style))) {
      isMembersOnly = true;
      return;
    }
    if (!value) return;
    if (looksLikeDuration(value)) {
      durationSeconds ??= durationToSeconds(value);
      return;
    }
    if (LIVE_LABEL.test(value) || (style !== null && /LIVE/i.test(style))) {
      isLive = true;
      return;
    }
    if (SHORTS_LABEL.test(value) || (style !== null && /SHORTS/i.test(style))) {
      isShort = true;
      return;
    }
    if (!labels.includes(value)) labels.push(value);
  };

  let hasMusicNote = false;

  walk(node, (candidate) => {
    const badge = candidate['thumbnailBadgeViewModel'];
    if (isObject(badge)) {
      consider(text(badge['text']), str(badge['badgeStyle']), badgeHasMembersIcon(badge));
      if (badgeHasMusicIcon(badge)) hasMusicNote = true;
    }

    const metadataBadge = candidate['metadataBadgeRenderer'];
    if (isObject(metadataBadge)) {
      consider(
        text(metadataBadge['label']),
        str(metadataBadge['style']),
        badgeHasMembersIcon(metadataBadge),
      );
    }

    const timeStatus = candidate['thumbnailOverlayTimeStatusRenderer'];
    if (isObject(timeStatus)) {
      consider(text(timeStatus['text']), str(timeStatus['style']));
    }

    return true;
  });

  return { labels, durationSeconds, isLive, isShort, hasMusicNote, isMembersOnly };
}

const VERIFIED_STYLE = 'BADGE_STYLE_TYPE_VERIFIED';
const VERIFIED_ARTIST_STYLE = 'BADGE_STYLE_TYPE_VERIFIED_ARTIST';

export interface OwnerBadgeScan {
  isVerified: boolean;
  isArtistChannel: boolean;
}

/**
 * The channel-level verified checkmark and "Official Artist Channel" badge
 * (Task 21 §2). Both are `metadataBadgeRenderer`, under `ownerBadges` on a
 * classic video/channel tile — but keyed on `style` rather than that wrapper
 * key, since `officialCardViewModel`'s title carries the same badge under a
 * different shape entirely, and `style` is the one thing constant across
 * both generations.
 *
 * Not folded into `scanBadges`: that function's `metadataBadgeRenderer`
 * branch reads `label`, which an owner badge never sets (only `tooltip`/
 * `accessibilityData.label` — both localised, and deliberately not read
 * here). Sharing one walk would mean every owner-badge node also passing
 * through `consider()` with a null label, which is harmless but couples two
 * unrelated extraction rules for no reason.
 */
export function scanOwnerBadges(node: Json): OwnerBadgeScan {
  let isVerified = false;
  let isArtistChannel = false;

  walk(node, (candidate) => {
    const badge = candidate['metadataBadgeRenderer'];
    if (isObject(badge)) {
      const style = str(badge['style']);
      if (style === VERIFIED_STYLE) isVerified = true;
      else if (style === VERIFIED_ARTIST_STYLE) isArtistChannel = true;
    }
    return true;
  });

  return { isVerified, isArtistChannel };
}

/**
 * Whether the tile offers Watch Later / Add to queue.
 *
 * View-based tiles express this as `playlistEditEndpoint { playlistId: 'WL' }`
 * and `addToPlaylistCommand { listType: …QUEUE }` inside the hover overlay;
 * classic tiles use `thumbnailOverlayToggleButtonRenderer` with the same
 * endpoints underneath. Matching on the endpoints covers both.
 */
export function scanTileActions(node: Json): { canWatchLater: boolean; canAddToQueue: boolean } {
  let canWatchLater = false;
  let canAddToQueue = false;

  walk(node, (candidate) => {
    const playlistEdit = candidate['playlistEditEndpoint'];
    if (isObject(playlistEdit) && str(playlistEdit['playlistId']) === 'WL') {
      canWatchLater = true;
    }

    const addToPlaylist = candidate['addToPlaylistCommand'];
    if (isObject(addToPlaylist)) {
      const listType = str(addToPlaylist['listType']) ?? '';
      if (/QUEUE/i.test(listType)) canAddToQueue = true;
      if (/WATCH_LATER/i.test(listType)) canWatchLater = true;
    }

    const iconName = str(candidate['iconName']);
    if (iconName === 'WATCH_LATER') canWatchLater = true;
    if (iconName !== null && /ADD_TO_QUEUE/i.test(iconName)) canAddToQueue = true;

    return true;
  });

  return { canWatchLater, canAddToQueue };
}

/**
 * Every id-ish field a tile might carry, tried in contract order:
 * `content_id`, `video_id`, `videoId`. Never key on a single field name.
 */
export function tileId(node: Json): string | null {
  if (!isObject(node)) return null;
  for (const key of ['content_id', 'contentId', 'video_id', 'videoId', 'playlist_id', 'playlistId']) {
    const value = str(node[key]);
    if (value) return value;
  }
  return null;
}

/** Same order, but searching the whole subtree — for renderers that bury the id. */
export function deepTileId(node: Json): string | null {
  for (const key of ['content_id', 'contentId', 'video_id', 'videoId']) {
    const holder = deepFind(node, (candidate) => str(candidate[key]) !== null);
    if (holder) {
      const value = str(holder[key]);
      if (value) return value;
    }
  }
  return null;
}

/** Flatten `contentMetadataViewModel.metadataRows[].metadataParts[].text` to strings. */
export function metadataRowTexts(contentMetadata: Json): string[][] {
  const rows = asArray(get(contentMetadata, 'metadataRows'));
  return rows.map((row) =>
    asArray(get(row, 'metadataParts'))
      .map((part) => text(get(part, 'text')))
      .filter((value): value is string => value !== null),
  );
}
