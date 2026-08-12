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
  /** Sidebar / up-next tiles, already flattened to the same DTOs as any feed. */
  related: FeedItem[];
  relatedContinuation: string | null;
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
