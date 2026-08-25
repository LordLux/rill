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
  /** Display string as YouTube formatted it ("22K views"), never parsed. */
  viewCountText: string | null;
  publishedText: string | null;
  /** "4K", "New", "Members only", … */
  badges: string[];
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
}

export interface Chip {
  label: string;
  token: string;
  selected: boolean;
  /** `chipCloudChipRenderer` is feed-scoped; `ChipsShelfView`/`chipViewModel` is shelf-scoped. */
  scope: 'feed' | 'shelf';
}

export interface FeedResult {
  chips: Chip[];
  items: FeedItem[];
  continuation: string | null;
}

// ---------------------------------------------------------------------------
// Video detail
// ---------------------------------------------------------------------------

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
  publishedText: string | null;
  likeText: string | null;
  isSubscribed: boolean;
  badges: string[];
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
  storyboards: Storyboard[];
  /** Client playback nonce, needed by `playback.report`. */
  cpn: string | null;
  playabilityStatus: string | null;
  playabilityReason: string | null;
  durationSeconds: number | null;
  isLive: boolean;
  /** A premiere or scheduled stream that has not started. Never playable yet. */
  isUpcoming: boolean;
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
// Playback
// ---------------------------------------------------------------------------

/**
 * Which rung of the resolution ladder served this source.
 *
 * Telemetry only. Flutter must not be able to tell the tiers apart — a video
 * that arrived over `ytdlp` opens exactly like one that arrived over `plain`.
 */
export type PlaybackTransport = 'plain' | 'sabr-dash' | 'ytdlp';

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
  /** Sprite-sheet template for hover previews (F8). */
  storyboardTemplate: string | null;
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
