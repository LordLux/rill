/**
 * The flat DTO contract — the real boundary between the sidecar and Flutter.
 *
 * Renderer trees never leave the sidecar (hard invariant 6). Everything below is
 * flat, fully populated, and free of renderer fragments. Every optional field is
 * a value or `null`; never `undefined`, never omitted.
 *
 * These shapes mirror `CLAUDE.md` exactly. Changing them unilaterally breaks the
 * Flutter half of the app — treat them as a versioned contract, not as a
 * convenience.
 */

// ---------------------------------------------------------------------------
// Feed items
// ---------------------------------------------------------------------------

export type FeedItem = VideoItem | MixItem | PlaylistItem | ChannelItem;

export interface VideoItem {
  kind: 'video';
  id: string;
  title: string;
  channelName: string;
  channelId: string | null;
  channelAvatarUrl: string | null;
  thumbnailUrl: string;
  /** null when live — a live stream has no final duration. */
  durationSeconds: number | null;
  isLive: boolean;
  /**
   * A 24/7 radio/music station (architecture.md F22) — functionally live
   * (continuous, no fixed duration, a "N watching" count), but YouTube ships
   * its own `"STATION"` label rather than `"LIVE"`. Always `true` alongside
   * {@link isLive}, never instead of it: the duration/sort behaviour a live
   * tile needs still applies here, this only tells Flutter which pill text
   * to draw. Observed as a live, mid-session rollout rather than a fixed
   * per-client split — F22's second half — so this is read from the label
   * alone, never from which client answered.
   */
  isStation: boolean;
  /** Display string as YouTube formatted it ("22K views"), never parsed. */
  viewCountText: string | null;
  publishedText: string | null;
  descriptionSnippet: string | null;
  /** "4K", "New", "Members only", … */
  badges: string[];
  /**
   * A Short, classified rather than stripped (Task 21 §1). Covers the plain
   * `videoRenderer`/`lockupViewModel` shape carrying a `SHORTS`-styled
   * duration overlay — the shape that reaches search interleaved with
   * ordinary videos. The dedicated Shorts shelf (`reelShelfRenderer` /
   * `shortsLockupViewModel`) is a structurally different renderer with no
   * `content_id` and no title path this mapper reads; it stays stripped and
   * never reaches this type.
   */
  isShort: boolean;
  /**
   * The `♪` on YouTube's own duration badge — `thumbnailBadgeViewModel`'s
   * icon, not its text. Distinct from [isArtistChannel]: this is per-video,
   * that is per-channel, and they can disagree (an artist channel can upload
   * a non-music video).
   */
  isMusic: boolean;
  /**
   * Members-only content — the channel's paid tier, not a public video.
   *
   * From `BADGE_STYLE_TYPE_MEMBERS_ONLY` (or the `SPONSORSHIP_STAR` icon), so
   * it is read from a token YouTube does not localise. It is deliberately kept
   * out of `badges[]`: one fact, one route, the rule {@link isShort} and
   * {@link isLive} already follow.
   *
   * **It says nothing about whether *this* account can watch it.** YouTube puts
   * members-only videos in a subscriber's feed whether or not they are a
   * member, and the resolve path is anonymous besides — so a tile carrying this
   * is a tile whose playback may well answer `VIDEO_MEMBERS_ONLY`.
   */
  isMembersOnly: boolean;
  /** The uploading channel's verified checkmark. Never true alongside {@link isArtistChannel} — YouTube ships one badge per channel. */
  isVerified: boolean;
  /** The uploading channel's "Official Artist Channel" badge. */
  isArtistChannel: boolean;
  /**
   * When a premiere or scheduled stream starts, unix ms — null for everything
   * that has already happened, which is nearly every tile.
   *
   * Carried on the tile so a card can offer a reminder without a `/player` call
   * per item: a feed of upcoming videos would otherwise cost one round trip each
   * to discover something the feed response already said.
   */
  premiereAtMs: number | null;
  canWatchLater: boolean;
  canAddToQueue: boolean;
}

export interface MixItem {
  kind: 'mix';
  /** RD… playlist id. */
  id: string;
  title: string;
  subtitle: string | null;
  thumbnailUrl: string;
  videoCount: number | null;
  /**
   * The video this tile advertises — the song in its title ("Mix - <song>")
   * and thumbnail — read off the tile's own click target
   * (`watchEndpoint.videoId`). Null when the tile carries no click target.
   *
   * **Carried so a mix always opens on the song it advertised.** Without it
   * YouTube picks the opener, and signed in it often picks a different song,
   * sometimes one not in the mix at all; youtube.com does the same. That is a
   * user clicking one song and hearing another, and the same tile opening
   * differently on different days. `mix.start` sends this as the seed and the
   * sidecar enforces that it plays first — see `protocol.md` §3.3.
   *
   * Read from the click target, not derived from the `RD<id>` suffix: an
   * auto-radio's suffix happens to equal it, but `RDMM…` and `RDGMEM…` mixes
   * have no suffix while their tiles still name the video.
   */
  seedVideoId: string | null;
  /**
   * The tile's click-target `params`, handed back verbatim to `mix.start`.
   * Opaque — nothing outside the sidecar reads it, like a `continuation`.
   *
   * It is what makes a signed-in `/next` honour the seed: measured 2026-09-14,
   * the advertised video opened first 114/114 with it and 86/90 without. It is
   * currently one constant on every tile, and is carried from the tile rather
   * than hardcoded so a change to it arrives with the response.
   */
  startParams: string | null;
}

export interface PlaylistItem {
  kind: 'playlist';
  id: string;
  title: string;
  thumbnailUrl: string;
  videoCount: number | null;
  channelName: string | null;
}

export interface ChannelItem {
  kind: 'channel';
  id: string;
  name: string;
  avatarUrl: string;
  subscriberText: string | null;
  descriptionSnippet: string | null;
  /** Same badge as {@link VideoItem.isVerified}, read off the channel's own tile. */
  isVerified: boolean;
  /** Same badge as {@link VideoItem.isArtistChannel}, read off the channel's own tile. */
  isArtistChannel: boolean;
}

export interface Chip {
  label: string;
  token: string;
  selected: boolean;
  /** `chipCloudChipRenderer` is feed-scoped; `ChipsShelfView`/`chipViewModel` is shelf-scoped. */
  scope: 'feed' | 'shelf';
}

/**
 * The "official artist channel" panel a search for an artist's name returns
 * above the ordinary results (Task 21 §3) — `officialCardViewModel`, live-
 * confirmed **absent** for an ordinary creator search, so its presence is
 * itself the artist-channel signal.
 *
 * A separate field on `search.query`'s result rather than a new `FeedItem`
 * kind, per the task's own preference: `FeedItem` is a sealed union every
 * grid switches over, and a panel is not a grid item — widening the union
 * would make every surface responsible for skipping it.
 */
/**
 * A colour YouTube supplies for both themes, as ARGB ints (`0xAARRGGBB`).
 *
 * Carried verbatim rather than resolved here: which one applies is a client
 * question, and the sidecar has no idea what theme Flutter is painting.
 */
export interface ThemedColor {
  light: number;
  dark: number;
}

export interface ArtistPanel {
  channelId: string;
  name: string;
  /** "@Ado1024". */
  handle: string | null;
  avatarUrl: string;
  /** "9.51M subscribers". */
  subscriberText: string | null;
  /** "739 videos". */
  videoCountText: string | null;
  description: string | null;
  isSubscribed: boolean;
  /**
   * The `RD…` id behind the panel's own "Mix" action, or null if the panel
   * carried none. Carried because reconstructing it later costs a `/next`
   * round trip the panel response already answers for free — the same
   * reasoning as `VideoItem.premiereAtMs`.
   */
  mixPlaylistId: string | null;
  /**
   * The panel's own tint, straight off `officialCardViewModel` — YouTube
   * already derives it from the artist's imagery server-side, so the client
   * has no reason to sample the avatar itself. `backgroundColor` is the card
   * fill; `baseBackgroundColor` is the much darker page wash behind it.
   * Null when the payload omits them.
   */
  backgroundColor: ThemedColor | null;
  baseBackgroundColor: ThemedColor | null;
  /**
   * The wide artwork strip behind the header — `cinematicContainerViewModel`'s
   * `backgroundImageConfig`, a genuinely different image from `avatarUrl`
   * (measured: a 600x176 banner, against the avatar's square). It is what
   * bleeds off the top-right corner of YouTube's own panel; a blurred copy of
   * the avatar is not the same picture and does not look like one.
   */
  backdropUrl: string | null;
  /**
   * The panel's embedded "top videos" shelf — a `horizontalShelfViewModel` of
   * ordinary `lockupViewModel` tiles, so these are the same flat `FeedItem`
   * DTOs every grid already renders (a leading `MixItem`, then `VideoItem`s).
   *
   * Extracted **here** rather than by letting the walker descend into the
   * panel: descending would also splice these tiles into the surrounding
   * search results, where YouTube does not show them and where they would
   * read as duplicates of the artist's own videos further down.
   */
  shelfItems: FeedItem[];
}

export interface FeedResult {
  chips: Chip[];
  items: FeedItem[];
  continuation: string | null;
  /**
   * Populated only when the response carried an `officialCardViewModel` —
   * in practice, only ever on a `search.query` response. `null` everywhere
   * else. Kept on the shared parser return type rather than a bespoke one
   * because `parseFeed` is one function for every surface; callers that have
   * no use for it (`feed.home`, `feed.subscriptions`) simply don't forward
   * it onto the wire — see `rpc/server.ts`.
   */
  artistPanel: ArtistPanel | null;
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

/**
 * `search.query`'s filter parameter (`protocol.md` §3.3, Task 20 §3).
 *
 * Not a chip: a chip is a token the server hands back in a response, a filter
 * is a token the client asks for from a closed set the sidecar owns. This
 * struct is the wire shape; `parser/search-filters.ts` is what turns it into
 * the opaque `params` string `/search` actually reads, and carries the
 * measurements behind each value.
 */
export type { SearchFilters } from './parser/search-filters.ts';

/** `search.suggest`'s result — a flat, ranked list of query strings. */
export interface SearchSuggestResult {
  suggestions: string[];
}

// ---------------------------------------------------------------------------
// Video detail
// ---------------------------------------------------------------------------

/**
 * A song YouTube attributes to a video — its "Music in this video" credit.
 *
 * A nested DTO rather than four fields on {@link VideoDetail}, because the
 * four are jointly present or jointly absent: flat ones would encode a
 * constraint the type cannot express and invite
 * `musicArtist != null && musicAlbum != null` checks at every call site. Same
 * shape and same reason as {@link ArtistPanel}.
 */
export interface MusicTrack {
  /** The song. Never empty — a card without one is dropped. */
  title: string;
  /**
   * The performing artist, as the card states it.
   *
   * The card's primary artist, which can be narrower than the credits dialog's
   * — see `parser/music.ts` for why the narrower structural one is preferred.
   */
  artist: string | null;
  album: string | null;
  /** Square cover art, already sized by the sidecar. */
  coverUrl: string | null;
}

export interface VideoDetail {
  id: string;
  title: string;
  description: string | null;
  channelName: string;
  channelId: string | null;
  channelAvatarUrl: string | null;
  subscriberText: string | null;
  /** null when live. */
  durationSeconds: number | null;
  isLive: boolean;
  viewCountText: string | null;
  /**
   * The exact view count as a number, for a client that shows its own short
   * form ("4.6M views") with the exact one on hover.
   *
   * **Derived from {@link viewCountText}, the same string the tooltip shows**,
   * so the short form and the exact one cannot disagree. The parse refuses
   * anything already rounded rather than guessing: `"1.8M views"` yields
   * `null`, never 18. See `parser/text.ts`'s `exactCountFromText`.
   *
   * `videoViewCountRenderer.originalViewCount` is a fallback only, and **its
   * `"0"` means "not filled in"** — measured 2026-09-13, it was `"0"` on 18 of
   * 24 watch pages that had real counts, and the number on the other 6.
   *
   * `null` means the exact number is not recoverable, and the client should
   * show {@link viewCountText} unchanged.
   */
  viewCount: number | null;
  publishedText: string | null;
  /**
   * The exact upload date ("Dec 6, 2009"), for a tooltip on {@link
   * publishedText}'s relative one ("14 years ago") — YouTube ships both as
   * siblings on the same renderer, not as alternatives; `publishedText`
   * already prefers the relative one when present, and this is the exact one
   * regardless of which way that preference went. Null when the layout
   * carries no exact date at all.
   */
  publishedDateText: string | null;
  likeText: string | null;
  /**
   * Task 25 §3: a like button needs to know it is already liked before the
   * first render, or the first click toggles the wrong way. A closed set
   * rather than two independent booleans — `isLiked`/`isDisliked` can both be
   * `true` at once with nothing to stop it, a state YouTube itself cannot
   * produce, so the type should not admit it either.
   *
   * Read from `likeButtonRenderer.likeStatus` (classic) or the view-based
   * button's own inline `likeStatusEntity.likeStatus` — `parser/video.ts` has
   * both. **The view-based path is unverified against a live capture**: it is
   * built from a community library's typed accessor for this exact renderer
   * (`LikeButtonView`, read as documentation only — hard invariant 1), not
   * from a fixture in this repo. If it turns out wrong, the failure is silent
   * — `'none'` looks identical to "really not rated" — so this is the first
   * thing to check against a real watch page.
   */
  myRating: 'like' | 'dislike' | 'none';
  isSubscribed: boolean;
  /** The uploading channel's verified checkmark. Same badge as {@link VideoItem.isVerified}. */
  isVerified: boolean;
  /** Whether the channel holds an Official Artist Channel badge. Same badge as {@link VideoItem.isArtistChannel}. */
  isArtistChannel: boolean;
  badges: string[];
  /**
   * Songs attributed to this video, in the order YouTube lists them.
   *
   * **Empty is the ordinary answer**, not a failure — most videos carry no
   * attribution. A list rather than a nullable single because `cards[]` is an
   * array and the panel header is templated ("1 song"); widening later would
   * break this, the freezed model, `protocol.md` and `contract-docs.test.ts`
   * at once.
   */
  music: MusicTrack[];
  /**
   * Members-only content. Same badge and same rule as
   * {@link VideoItem.isMembersOnly}, read off the watch page.
   *
   * This is what the watch page's members slate is drawn from, rather than the
   * `playback.open` failure: it is structural (`BADGE_STYLE_TYPE_MEMBERS_ONLY`)
   * where the failure's `reason` is localised prose, and it arrives on a call
   * the page already makes.
   */
  isMembersOnly: boolean;
  /**
   * When a premiere starts, unix ms — null for anything already published.
   *
   * The watch page's source of truth for the premiere slate. `playback.open`
   * answers `VIDEO_UPCOMING` with YouTube's own prose ("Premieres in 9 days"),
   * which is enough to say *that* it is a premiere but not enough to render a
   * date; this is the machine-readable half, and it arrives on a call the watch
   * page already makes.
   */
  premiereAtMs: number | null;
  /** Sidebar / up-next tiles, already flattened to the same DTOs as any feed. */
  related: FeedItem[];
  relatedContinuation: string | null;
  /**
   * The continuation token for the first page of comments, read from the watch
   * page's own `comment-item-section`.
   *
   * Null when comments are disabled, unavailable (e.g. made for kids), or when
   * the video is age-restricted and the session is anonymous. A missing section
   * in a successfully parsed page is the only signal YouTube sends for "disabled",
   * so this being null *is* that signal.
   */
  commentsContinuation: string | null;
}

/**
 * **Captions are deliberately not on `VideoDetail`.** They were, briefly, and
 * `watch.test.ts` caught what it cost: the `VISIONOS` → `MWEB` fallback
 * (`protocol.md` §3.8) is a second `/player` round trip, and putting it here put
 * it on the video-open path — breaking §3.3's "opening a video costs **one**
 * `/player` call" for the ~29% of videos whose primary caption list is empty.
 *
 * `captions.list` is the single source of truth instead. The watch page calls it
 * alongside `video.info` rather than after it, so the fallback runs concurrently
 * with the open rather than inside it, and the CC control appears when it
 * answers. Nothing about playback waits for captions.
 */

// ---------------------------------------------------------------------------
// Captions
// ---------------------------------------------------------------------------

/**
 * One caption track, as the client picks between them (`protocol.md` §3.8).
 *
 * **There is no URL here, and that is the point.** A `timedtext` address is
 * signed — `sparams`, `signature`, `expire` — and the sidecar is what fetches
 * it. `id` is an opaque handle the client hands back to `captions.get`. Same
 * reasoning as hard invariant 2 applied to a different endpoint: nothing outside
 * this process holds a URL whose signing it does not own.
 */
/**
 * How a caption track is styled, as the picker badges it.
 *
 * Deliberately a small closed set rather than a bag of flags: the badge has room
 * for one word, so the question the sidecar has to answer is "which word", and
 * answering it here keeps the precedence rule in one place instead of in the
 * widget. `'plain'` earns no badge.
 */
export type CaptionStyling = 'plain' | 'styled' | 'karaoke';

/**
 * Task 19's caption style, drag offset and document geometry.
 *
 * Defined in `captions/style.ts` — where the reasons live — and re-exported here
 * because they are part of the Flutter contract and this file is where that
 * contract reads as a whole.
 */
export type {
  CaptionEdgeStyle,
  CaptionLayout,
  CaptionOffset,
  CaptionStyle,
} from './captions/style.ts';
import type { CaptionLayout } from './captions/style.ts';


export interface CaptionTrack {
  /**
   * YouTube's `vssId` — the stable key, and the only field that distinguishes
   * the manual and auto-generated tracks of one language (".en" vs "a.en").
   */
  id: string;
  /** As YouTube reports it: "en", "de-DE", "es-419". Not normalised. */
  languageCode: string;
  /** YouTube's own display name: "English", "English (auto-generated)". */
  label: string;
  /** `kind: "asr"`. Word-level at the source, grouped into lines before it ships. */
  isAutoGenerated: boolean;
  /**
   * YouTube's own sub-name for the track, or `''`.
   *
   * How a channel tells apart two tracks in one language — "Commentary",
   * "Forced", "Director's cut". Empty on every track measured so far, which is
   * the ordinary case; when it is not empty, `label` alone shows two identical
   * rows.
   */
  trackName: string;
  /**
   * What kind of styling the track carries, or `null` for **not known yet**,
   * which is the usual answer.
   *
   * Two things about it are counter-intuitive and both were measured 2026-08-19.
   *
   * **It cannot be answered from the track list.** The list rides on a cached
   * `/player`; the styling lives in the *document*, one `timedtext` GET per
   * track. `captions.list` is on the video-open path (`protocol.md` §3.8 keeps it
   * there deliberately), so it never fetches — the caller opts in with
   * `includeStyled`, which is what the caption menu does.
   *
   * **It is `pens`, not "any of the three arrays".** The obvious predicate is
   * wrong: *every* auto-generated track has `wsWinStyles` and `wpWinPositions`
   * populated, because its rolling window is expressed with them. Measured on
   * `dQw4w9WgXcQ`, all six tracks — `pens` was 0 on every one, and the two window
   * arrays were 1 each on the ASR track alone. So the loose predicate badges the
   * most ordinary tracks in the app and nothing else.
   *
   * `'karaoke'` is the narrower answer and wins where both apply: a karaoke
   * track is styled too, so the badge would be true of everything if the more
   * specific one did not take precedence. It is detected by a `pPenId` on a
   * `seg` rather than by the pens themselves — that is the one thing only a
   * karaoke track does, and it is what drives the per-run highlight.
   */
  styled: CaptionStyling | null;
  /** Whether the track uses non-default positions or overlapping cues. */
  positional: boolean | null;
  /** YouTube offers machine translations of it. Translations are out of scope. */
  isTranslatable: boolean;
}

/** `captions.list`'s result. An empty array means no CC control, after the fallback. */
export interface CaptionListResult {
  tracks: CaptionTrack[];
}

/**
 * `captions.get`'s result — one track as a subtitle document.
 *
 * `format` is `'ass'` and is sent anyway, because the client hands the body
 * straight to libmpv and a silent format change is the kind that renders as
 * nothing at all. Every source format converts to ASS in the sidecar
 * (`architecture.md` §2.9); Flutter draws no captions.
 */
export interface CaptionTrackContent {
  trackId: string;
  languageCode: string;
  format: 'ass';
  /** A complete ASS document, UTF-8, ready for `sub-add`. */
  content: string;
  /** Lines in the document. Telemetry — the client renders nothing from it. */
  cueCount: number;
  /**
   * The geometry this document was written with — Task 19.
   *
   * The client needs it to put an invisible hit rectangle over a caption whose
   * real rectangle nothing publishes: libass composites into the video texture
   * and mpv exposes only the plain text. Eight numbers per *track*, not per cue,
   * and sent rather than duplicated as constants in Flutter, because two copies
   * of a layout constant are two things that have to agree and eventually will
   * not. `architecture.md` §2.9.
   */
  layout: CaptionLayout;
  styled: CaptionStyling | null;
  positional: boolean | null;
}



// ---------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------

/**
 * Hard invariant 2: never let an undeciphered URL cross the RPC boundary.
 *
 * The brand and its constructor live in `innertube/signed-url.ts`, which is the
 * only module allowed to mint one; it is re-exported here because
 * `PlaybackSource` below is part of the Flutter contract and should read as a
 * whole. The parser cannot produce one — it only ever sees what YouTube sent, so
 * its output carries `rawUrl` / `signatureCipher`, both explicitly *un*signed.
 * An unsigned `n` throttles to ~50 KB/s and presents as a bad network
 * connection.
 */
import type { SignedUrl } from './innertube/signed-url.ts';

export type { SignedUrl };

export interface PlayerFormat {
  itag: number;
  mimeType: string | null;
  codecs: string | null;
  bitrate: number | null;
  width: number | null;
  height: number | null;
  fps: number | null;
  audioQuality: string | null;
  audioSampleRate: number | null;
  audioChannels: number | null;
  /**
   * A dynamic-range-compressed duplicate of another itag. YouTube ships these
   * alongside the originals under the same itag number; picking one by accident
   * changes the mix the user hears with no other symptom.
   */
  isDrc: boolean;
  contentLength: number | null;
  approxDurationMs: number | null;
  hasVideo: boolean;
  hasAudio: boolean;
  /** Adaptive (video-only / audio-only) vs progressive (muxed). */
  isAdaptive: boolean;
  /**
   * The URL exactly as YouTube sent it — NOT deciphered, NOT safe to hand to a
   * player. Named `rawUrl` so nothing can mistake it for a `SignedUrl`.
   */
  rawUrl: string | null;
  /** Present instead of `rawUrl` when the format is signature-protected. */
  signatureCipher: string | null;
}

export interface Storyboard {
  /** The `$L` value, and this level's index in the spec — they are the same. */
  level: number;
  /**
   * The sheet URL with `$L` and `$N` resolved and `sigh` appended. `$M` — the sheet index — is
   * deliberately left in, because it is per-sheet rather than per-level; use `sheetUrl`.
   */
  templateUrl: string;
  thumbnailWidth: number | null;
  thumbnailHeight: number | null;
  /** Frames in this level **across every sheet**, not per sheet. */
  thumbnailCount: number | null;
  columns: number | null;
  rows: number | null;
  /**
   * Video time one frame represents. `0` on level 0, where YouTube spreads a fixed count across
   * the whole runtime instead — `selectSheet` divides that out; nothing else should treat a
   * `0` as an interval.
   */
  intervalMs: number | null;
}

/**
 * One fetchable sprite sheet — `video.storyboard`'s result and the only storyboard shape that
 * crosses the RPC boundary (`protocol.md` §3.7). Every placeholder is already substituted, so
 * Flutter constructs no URLs. Exactly one sheet, by construction.
 */
export interface StoryboardSpec {
  /** Fully substituted and signed. One GET, one image. */
  url: string;
  /** Grid of the sheet at `url`. */
  columns: number;
  rows: number;
  /** Frames present, row-major from the top left. Never more than `columns * rows`. */
  frameCount: number;
  frameWidth: number;
  frameHeight: number;
  /**
   * Video time one frame represents, always positive and resolved. **Not a playback cadence** —
   * level 0 puts ~6 s behind every frame.
   */
  intervalMs: number;
  /** The `$L` level this came from. Telemetry — the client picks nothing. */
  level: number;
}

/** `video.storyboard`'s result. `null` for a video YouTube ships no sheets for. */
export interface StoryboardResult {
  storyboard: StoryboardSpec | null;
}

export interface PlayerResult {
  videoId: string | null;
  formats: PlayerFormat[];
  hlsManifestUrl: string | null;
  dashManifestUrl: string | null;
  storyboards: Storyboard[];
  /** The widest still the response lists — see {@link PlaybackSource.posterUrl}. */
  posterUrl: string | null;
  /** Client playback nonce, needed by `playback.report`. */
  cpn: string | null;
  playabilityStatus: string | null;
  playabilityReason: string | null;
  durationSeconds: number | null;
  isLive: boolean;
  startTimestamp: string | null;
  /** A premiere or scheduled stream that has not started. Never playable yet. */
  isUpcoming: boolean;
  /**
   * The refusal was "join this channel". Ends the ladder, like {@link isUpcoming}.
   *
   * Classified from `playabilityStatus.reason`, which is localised — the only
   * signal this response carries. See the note in `parser/player.ts`; the
   * structural answer is {@link VideoDetail.isMembersOnly}.
   */
  isMembersOnly: boolean;
  /** When it starts, unix ms. Null even when [isUpcoming] — see the parser. */
  scheduledStartMs: number | null;
  /**
   * True when the *adaptive* ladder lacks both a URL and a cipher — the
   * SABR-only case. Defined over adaptive formats only; see
   * `playback/sabr-detect.ts` for why that distinction is load-bearing.
   */
  sabrOnly: boolean;
  serverAbrStreamingUrl: string | null;
  /**
   * `playbackTracking.videostatsPlaybackUrl` — the ping that registers a view.
   *
   * Read from whichever client fetched this response, and only ever *used* from
   * the `WEB` one: these URLs carry an `ei`/`of`/`vm` minted for the request that
   * produced them, so sending a resolution client's URL over the authenticated
   * session is the cross-client bridging A5 rejects. See `playback/report.ts`.
   */
  videostatsPlaybackUrl: string | null;
  /** `playbackTracking.videostatsWatchtimeUrl` — the recurring progress ping. */
  videostatsWatchtimeUrl: string | null;
}

// ---------------------------------------------------------------------------
// Comments (Task 27)
// ---------------------------------------------------------------------------

export interface CommentTextRun {
  startIndex: number;
  length: number;
}

export interface CommentStyleRun extends CommentTextRun {
  weightLabel?: string;
}

export interface CommentCommandRun extends CommentTextRun {
  url?: string;
  videoId?: string;
  startTimeSeconds?: number;
}

export interface CommentText {
  content: string;
  styleRuns?: CommentStyleRun[];
  commandRuns?: CommentCommandRun[];
}

export interface Comment {
  id: string;
  authorName: string;
  authorAvatarUrl: string;
  authorChannelId: string | null;
  isUploader: boolean;
  isVerified: boolean;
  text: CommentText;
  /**
   * The count as this viewer sees it — a comment they liked carries the count
   * *with* their like in it. A display string ("737", "4.8M"), not parsed.
   */
  likeCount: string | null;
  publishedText: string | null;
  replyCount: number;
  /** Structural nesting level: 0 for top-level, 1 for direct replies, 2+ for nested. */
  depth: number;
  /**
   * This viewer's vote on the comment — `'none'` when anonymous, always.
   *
   * A closed set rather than `isLiked`/`isDisliked`, for the reason {@link
   * VideoDetail.myRating} gives: two booleans admit both-true, a state YouTube
   * cannot produce, so the type should not admit it either. It is also the
   * shape the wire has — all three come off one field,
   * `engagementToolbarStateEntityPayload.likeState`
   * (`TOOLBAR_LIKE_STATE_LIKED` / `_DISLIKED` / `_INDIFFERENT`).
   *
   * `'dislike'` was unobserved until 2026-09-21 and is now held by
   * `fixtures/viewer-state/comments-disliked.json`
   * (`capture:viewer-state dislike`). Before that fixture existed a reader
   * that never returned `'dislike'` would have looked exactly like a comment
   * nobody had voted on — F35's rule, that a viewer-state field is untested
   * until a fixture holds the state.
   *
   * Written out rather than aliased, and deliberately the same three values as
   * {@link VideoDetail.myRating}, so a client has one rating model and not two.
   */
  myRating: 'like' | 'dislike' | 'none';
  /**
   * The video's creator hearted this comment. Public: the same in an anonymous
   * and a signed-in view. Read from the state entity, never inferred from a
   * tooltip — `parser/comments.ts` has what that cost.
   */
  creatorHearted: boolean;
  isPinned: boolean;
  repliesContinuation: string | null;
  /**
   * Opaque token for `action.replyToComment`. `null` when the viewer cannot
   * reply — not signed in, same rule as the top-level create box carrying a
   * `prepareAccountCommand` instead of a real endpoint. Verified live
   * 2026-09-18: the real request is `comment/create_comment_reply`, a
   * distinct endpoint from top-level posting, not a variant of it.
   */
  replyParams: string | null;
  /**
   * Opaque token for `action.deleteComment`. `null` unless the viewer is this
   * comment's own author — the field simply doesn't exist in the response
   * otherwise, there is no separate "am I the author" flag to read instead.
   * Verified live 2026-09-18: delete reuses `comment/perform_comment_action`,
   * the same endpoint a comment like/dislike goes over, differentiated only
   * by which pre-built opaque `action` blob is sent.
   */
  deleteParams: string | null;
  /**
   * The four vote transitions, each a **server-supplied** opaque blob for
   * `action.rateComment` — `comment/perform_comment_action` again, exactly as
   * `deleteParams` above predicted. The client sends whichever one matches the
   * transition it wants rather than building anything, so there is no token
   * shape here to get wrong: measured 2026-09-20, all four present on 20 of 20
   * comments of a signed-in page.
   *
   * **A non-null value is not permission to vote.** All four are present on an
   * anonymous capture too, so a button enabled because the token exists is the
   * `heartActiveTooltip` mistake again (F33). Gate on the session, not on these.
   *
   * `null` only when the surface entity is missing entirely.
   */
  likeParams: string | null;
  unlikeParams: string | null;
  dislikeParams: string | null;
  undislikeParams: string | null;
}

export interface CommentsResult {
  items: Comment[];
  continuation: string | null;
  chips?: Chip[];
  commentCount: string | null;
  /**
   * Opaque token for `action.postComment` — the "Add a comment…" box's own
   * submit endpoint, off the same header that carries the sort chips.
   *
   * `null` when the viewer cannot comment: an anonymous session is handed a
   * sign-in prompt in that slot instead of an endpoint. Also `null` on every
   * page but the first (a continuation carries no header), so a client keeps
   * the last non-null one rather than overwriting it — the same rule it already
   * follows for `chips` and `commentCount`.
   */
  createParams: string | null;
}

// ---------------------------------------------------------------------------
// Lists
// ---------------------------------------------------------------------------

/**
 * What every non-feed list method answers with (`protocol.md` §3.3).
 *
 * `FeedResult` minus the chip bar: `video.related`, `playlist.get` and
 * `search.query` have no filter strip of their own, and shipping an empty
 * `chips: []` would invite a caller to render one.
 */
export interface ItemListResult {
  items: FeedItem[];
  continuation: string | null;
}

// ---------------------------------------------------------------------------
// Mixes (Task 26)
// ---------------------------------------------------------------------------

/**
 * `mix.start` — a mix opened, with the window YouTube leads with.
 *
 * **No `continuation`, and that is measured rather than omitted** (2026-09-12):
 * a mix `/next` response carries no continuation token anywhere. Extension goes
 * through `mix.extend`, which re-anchors. `mix/service.ts` has the full shape.
 */
export interface MixStartResult {
  playlistId: string;
  /** "My Mix", "Mix - <video title>", "Chroma: Today's Dance Hits". Null if absent. */
  title: string | null;
  items: FeedItem[];
}

/**
 * `mix.extend` — the radio's next stretch, or the end of it.
 *
 * **`exhausted` is a field rather than an empty `items[]`** because the two
 * ends a mix can reach are genuinely different upstream behaviours — the
 * anchor being the last item the server has, versus the server no longer
 * placing the anchor in this sequence at all and answering with a re-seeded
 * window. Both mean "stop asking", and a client that had to infer that from
 * `items.length === 0` could not tell either of them from a transient empty
 * answer. The sidecar logs which of the two fired.
 */
export interface MixExtendResult {
  items: FeedItem[];
  exhausted: boolean;
}

// ---------------------------------------------------------------------------
// Playlists — the save-to-playlist dialog (Task 25 §5)
// ---------------------------------------------------------------------------

/** A closed set rather than the raw `PUBLIC`/`UNLISTED`/`PRIVATE` InnerTube sends — the DTO rule the rest of this file holds to. */
export type PlaylistPrivacy = 'public' | 'unlisted' | 'private';

/**
 * One row of `playlist.forVideo`'s answer: one of the user's playlists (Watch
 * Later included, at its fixed id `'WL'`), and whether the video asked about
 * is already in it.
 */
export interface PlaylistMembership {
  id: string;
  title: string;
  /** `null` when the response carried no recognised privacy value — never guessed. */
  privacy: PlaylistPrivacy | null;
  containsVideo: boolean;
  /**
   * Hand this back verbatim to `action.removeFromPlaylist` to un-check this
   * row. Opaque — nothing outside the sidecar parses it, the same rule a feed
   * `continuation` token already follows. Present only when
   * {@link containsVideo} is true; there is nothing to remove otherwise.
   */
  removeToken: string | null;
}

export interface PlaylistMembershipResult {
  playlists: PlaylistMembership[];
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

/**
 * Which rung of the resolution ladder served this source.
 *
 * Telemetry only. Flutter must not be able to tell the tiers apart — a video
 * that arrived over `ytdlp` opens exactly like one that arrived over `plain`.
 */
export type PlaybackTransport = 'plain' | 'hls' | 'dash' | 'sabr-dash' | 'ytdlp';

/**
 * One playable video + audio pair within a `PlaybackSource`.
 *
 * Ranked best-first by the sidecar (height → fps → codec preference). The
 * client picks one and may step down on sustained frame drops (F16). Every
 * entry is playable — a format that cannot be signed is silently omitted.
 */
export interface PlaybackVariant {
  videoUrl: SignedUrl;
  /** null for a progressive (muxed) stream, and in Phase 2 for DASH. */
  audioUrl: SignedUrl | null;
  itag: number | null;
  /** From the format itself, never from an itag→height lookup table. */
  height: number;
  /** From the format itself. */
  fps: number;
  videoCodec: string;
  audioCodec: string;
}

/**
 * What `playback.open` returns. Identical in Phase 1 and Phase 2, so the SABR
 * bridge lands as a transport swap and not a protocol revision.
 *
 * `variants` is ranked best-first. The client picks one and may switch without
 * reopening — all variants come from a single `/player` response (§3.5).
 */
/**
 * What the player is doing, as `playback.report` carries it (`protocol.md` §3.5).
 *
 * A closed set rather than a free string. The report path is load-bearing — if
 * watch events stop landing the recommender stops training — and the failure
 * mode of a free string is a typo that reports forever into nothing while every
 * call returns success.
 */
export type PlaybackReportState = 'playing' | 'paused' | 'buffering' | 'ended';

export const PLAYBACK_REPORT_STATES: readonly PlaybackReportState[] = [
  'playing',
  'paused',
  'buffering',
  'ended',
];

export interface PlaybackSource {
  sessionId: string;
  /** null when live — a live stream has no final duration. */
  durationMs: number | null;
  startTimestamp: string | null;
  /** Sprite-sheet template for hover previews (F8). */
  storyboardTemplate: string | null;
  /**
   * The widest still YouTube lists for this video, or null.
   *
   * For any surface that shows artwork instead of a picture — audio-only, the
   * premiere slate — because **the tile's own `thumbnailUrl` is not good
   * enough and cannot be upgraded by the client**: 1280x720 is YouTube's
   * ceiling, `maxresdefault` is byte-identical to `hq720`, and the watch
   * page's related rail ships 480x360 (F40). This comes off the `/player`
   * response the resolve already fetched, so it costs no extra request.
   *
   * Null is ordinary — fall back to the tile's `thumbnailUrl`.
   */
  posterUrl: string | null;
  /** Drives a badge in the UI, never a dead end. */
  qualityDegraded: boolean;
  transport: PlaybackTransport;
  /**
   * Ranked best-first: highest height → highest fps → codec preference.
   * Every entry is a playable pair. Tiers 3–5 may return a single-entry array.
   */
  variants: PlaybackVariant[];
}

// ---------------------------------------------------------------------------
// Capabilities
// ---------------------------------------------------------------------------

/**
 * Optional pieces of the machine, reported in the `event.ready` handshake
 * (`protocol.md` §2).
 *
 * These are not preferences — they are things that are installed or are not, and
 * the app has no way to find out on its own. A capability that is missing
 * removes a rung from the resolution ladder without removing anything the user
 * can see, which is the kind of degradation this project keeps having to make
 * loud on purpose.
 */
export interface Capabilities {
  /**
   * `yt-dlp` is on PATH or at `YT_DLP_PATH`. False means ladder tier 4 is gone
   * and age-restricted, Vevo and similar videos resolve to "Unavailable" with
   * nothing in the UI explaining why.
   */
  ytDlp: boolean;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

export type AuthState = 'authenticated' | 'degraded' | 'anonymous';

export interface AuthVerification {
  state: AuthState;
  tileCount: number;
}

/**
 * `auth.status` — protocol.md §3.1, widened by Task 22 §7.
 *
 * §3.1 specified `{state, accountName?}`. The top bar needs a picture as well
 * as a name, and a handle is what tells two accounts with the same display name
 * apart, so all three ship. They are **values or `null`**, never omitted — the
 * DTO rule in `CLAUDE.md`, applied here because the alternative is a client
 * that cannot distinguish "no name" from "an older sidecar".
 *
 * `state` is measured, never inferred from cookie presence (hard invariant 5).
 * The account fields are `null` for any state but `authenticated`.
 */
export interface AuthStatus {
  state: AuthState;
  accountName: string | null;
  accountHandle: string | null;
  accountAvatarUrl: string | null;
}

