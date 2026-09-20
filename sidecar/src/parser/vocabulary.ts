/**
 * Renderer vocabulary — first captured 2026-08-01, extended since (the newer
 * entries carry their own dates). CLAUDE.md's "Renderer vocabulary" table
 * summarises which of these carries what; this file is the authority.
 *
 * Both generations ship simultaneously, so every entry is stored in a normalised
 * form that collapses the two spellings of the same node:
 *
 *   lockupViewModel   (raw, parse:false)   ─┐
 *   LockupView        (youtubei.js typed)  ─┴─► 'lockup'
 *
 * We only ever consume `parse: false` responses, so the raw spelling is what
 * matters — but normalising costs nothing and means a stray parsed tree degrades
 * to the same behaviour instead of silently yielding zero items.
 *
 * Anything not in these tables is unknown: the parser skips it, logs the type
 * once, and carries on with its siblings (hard invariant 4).
 */

/** `lockupViewModel` → `lockup`, `LockupView` → `lockup`, `videoRenderer` → `video`. */
export function normaliseRendererName(name: string): string {
  return name.replace(/(ViewModel|Renderer|View|Model)$/, '').toLowerCase();
}

export type RendererRole =
  | 'item'
  | 'strip'
  | 'chip-feed'
  | 'chip-shelf'
  | 'continuation'
  | 'container'
  | 'ignore'
  | 'artist-panel';

/** Leaf renderers that map to exactly one `FeedItem`. */
const ITEMS = [
  // View-based — one renderer, discriminated by `contentType`.
  'lockup',
  // Classic video tiles.
  'video',
  'gridvideo',
  'compactvideo',
  'playlistvideo',
  'videowithcontext',
  'playlistpanelvideo',
  'endscreenvideo',
  // Classic playlist tiles.
  'playlist',
  'gridplaylist',
  'compactplaylist',
  'endscreenplaylist',
  // Classic mix / radio tiles.
  'radio',
  'gridradio',
  'compactradio',
  // Classic channel tiles.
  'channel',
  'gridchannel',
  'compactchannel',
];

/**
 * Recognised, deliberately dropped.
 *
 * Shorts *shelves* are stripped. A Short that arrives as an ordinary video
 * tile is not — it is classified instead (`VideoItem.isShort`, Task 21). Ads
 * are stripped for the same reason the app exists at all — and an in-feed ad nests a real `lockupViewModel` inside
 * `adSlotRenderer`, so the whole subtree has to go, not just the wrapper.
 */
const STRIPPED = [
  // Shorts.
  'shortslockup',
  'reelitem',
  'reelshelf',
  'richshelfshorts',
  // Ads.
  'adslot',
  'infeedadlayout',
  'displayad',
  'promotedvideo',
  'promotedsparklestext',
  'promotedsparkleswebsite',
  'searchpyv',
  'inlinesurvey',
  'videodisplayfulllayout',
  'videodisplaybuttongrouplayout',
  'feedadmetadata',
  // A masthead-style promoted video, first seen 2026-08-28: wraps a real
  // `videoRenderer` in `content`, same shape problem as `adSlotRenderer` — the
  // whole subtree has to go, or the paid placement inside it surfaces as an
  // ordinary organic tile.
  'brandvideosingleton',
];

/** Traversed, never emitted. */
const CONTAINERS = [
  'twocolumnbrowseresults',
  'twocolumnsearchresults',
  'twocolumnwatchnextresults',
  'singlecolumnbrowseresults',
  'tab',
  'tabbedsearchresults',
  'sectionlist',
  'itemsection',
  'richgrid',
  'richsection',
  'richshelf',
  'richitem',
  'shelf',
  'grid',
  'horizontallist',
  'verticallist',
  'expandedshelfcontents',
  'playlistvideolist',
  // **Matches nothing today, and is kept deliberately — Task 26, 2026-09-12.**
  // The watch page's mix/playlist panel is now a *bare object* at
  // `twoColumnWatchNextResults.playlist.playlist` with no renderer wrapper, so
  // `playlistPanelRenderer` occurs zero times in a real response — verified for
  // both a mix (`RD…`) and an ordinary `PL…` playlist. `parser/mix.ts` reaches
  // the bare object by path instead, which is the actual fix.
  //
  // Removing this line is not the neutral tidy-up it looks like. An unknown
  // container is *pruned*, not descended (`handleRenderer`'s `default` returns
  // false), so if YouTube ever ships the wrapped form again — and the wrapper
  // is what every other client library still expects — the whole panel subtree
  // would be dropped and every mix entry silently lost. One dead line is the
  // cheaper side of that trade.
  'playlistpanel',
  'brandvideoshelf',
  'watchnextsecondaryresults',
  'secondarysearchcontainer',
  'universalwatchcard',
  'chipcloud',
  'chipsshelf',
  'chipbar',
  'feedfilterchipbar',
  // Carries eight shelf chips alongside its video shelf; skipping it lost all of
  // them on the home continuation.
  'chipsshelfwithvideoshelf',
  // The related-video filter bar on a watch page. This is the type named in F2 —
  // youtubei.js throws `Type mismatch, got RelatedChipCloud` on it, which is
  // precisely why we walk the raw tree instead.
  'relatedchipcloud',
  // Search's Shorts shelf today, but a generic grid container — descend and let
  // the strip rules decide, rather than assuming its contents stay Shorts.
  'gridshelf',
  // Continuation envelopes.
  'appendcontinuationitems',
  'reloadcontinuationitems',
];

/**
 * Known non-content subtrees. Skipped wholesale so their inner text, ids and
 * thumbnails cannot be mistaken for feed items. Tiles we map are never descended
 * into, so excluding menus here does not cost us their hover actions.
 */
const IGNORED = [
  'sponsorshipschannelupsell',
  // Chrome that sits between tiles. These appear on every capture, so warning
  // about them would bury the one line that actually means YouTube changed
  // something.
  'button',
  'togglebutton',
  'defaultbutton',
  'toggledbutton',
  'sectionheader',
  'shelfheader',
  'richmetadatarow',
  'richmetadata',
  'message',
  'backstageimage',
  'itemsectionheader',
  'browsefeedactions',
  'searchbox',
  'searchheader',
  // Sort/filter menus. Real affordances, but not chip-bar chips — they do not
  // carry a continuation token or browse params, so they cannot fill a Chip.
  'searchsubmenu',
  'sortfiltersubmenu',
  // A dismissible "Looking for something different?" card. Its one chip is a
  // feedback endpoint and a duplicate of a filter-bar chip we already emit.
  'feednudge',
  // Watch-page metadata. parseVideoDetail reads these by path; when parseFeed
  // sweeps a watch response for related tiles they are not items.
  'videoprimaryinfo',
  'videosecondaryinfo',
  'compositevideoprimaryinfo',
  'videoowner',
  'commentsheader',
  'commentsentrypointheader',
  // Community posts: real feed content we deliberately do not render, the same
  // way Shorts are stripped. Known-unsupported, not a surprise.
  'post',
  'backstagepost',
  'backstagepostthread',
  'sharedpost',
  // "View all posts" — a navigation button attached to a post shelf, first
  // seen 2026-08-28 on an artist channel's search results. Not a tile itself;
  // same reasoning as the post renderers above it.
  'buttoncard',
  // A home shelf of YouTube Playables (mini-games, `/playables/…`,
  // `WEB_PAGE_TYPE_MINI_APP`), first seen 2026-09-14 — 48 cards across the
  // home fixtures. Not an ad, so not stripped; content this app does not play,
  // so ignored like the post renderers above.
  'minigamecard',
  'menu',
  'multipagemenu',
  'multipagemenusection',
  'menuserviceitem',
  'menuserviceitemdownload',
  'menunavigationitem',
  'notificationmultiaction',
  'notificationaction',
  'notificationtext',
  'hotkeydialog',
  'hotkeydialogsection',
  'hotkeydialogsectionoption',
  'unifiedsharepanel',
  'sheet',
  'dialog',
  'dialogheader',
  'voicesearchdialog',
  'desktoptopbar',
  'topbarlogo',
  'topbarmenubutton',
  'notificationtopbarbutton',
  'fusionsearchbox',
  'hint',
  'bubblehint',
  'ghostgrid',
  'downloadlistitem',
  'feedtabbedheader',
  'guide',
  'guidesection',
  'guideentry',
];

const ROLES = new Map<string, RendererRole>();
for (const name of ITEMS) ROLES.set(name, 'item');
for (const name of STRIPPED) ROLES.set(name, 'strip');
for (const name of CONTAINERS) ROLES.set(name, 'container');
for (const name of IGNORED) ROLES.set(name, 'ignore');
ROLES.set('chipcloudchip', 'chip-feed');
ROLES.set('chip', 'chip-shelf');
ROLES.set('continuationitem', 'continuation');
// The artist-search panel (Task 21 §3) — `officialCardViewModel`, live-
// confirmed absent for an ordinary creator query. Mapped whole, not
// descended into: its embedded video/mix shelf *is* modelled now (Task 23),
// but by `mapArtistPanel` reaching into it, not by the walker — descending
// would splice those tiles into the surrounding search results too.
ROLES.set('officialcard', 'artist-panel');

/** Role of a renderer key, or null when we have never seen it before. */
export function roleOf(rendererName: string): RendererRole | null {
  return ROLES.get(normaliseRendererName(rendererName)) ?? null;
}

/**
 * Does this object key look like a renderer at all?
 *
 * Guards the dispatch so an ordinary field called `video` or `channel` cannot be
 * mistaken for a renderer of the same normalised name.
 */
export function isRendererKey(key: string): boolean {
  return /(Renderer|ViewModel|Model)$/.test(key);
}
