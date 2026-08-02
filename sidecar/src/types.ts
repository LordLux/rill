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
  /** Template URL with `$L`/`$N`/`$M` placeholders still in place. */
  templateUrl: string;
  thumbnailWidth: number | null;
  thumbnailHeight: number | null;
  thumbnailCount: number | null;
  columns: number | null;
  rows: number | null;
  intervalMs: number | null;
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
 * What `playback.open` returns. Identical in Phase 1 and Phase 2, so the SABR
 * bridge lands as a transport swap and not a protocol revision.
 */
export interface PlaybackSource {
  sessionId: string;
  /** Phase 2: `http://127.0.0.1:PORT/s/…/manifest.mpd`. */
  videoUrl: SignedUrl;
  /** null for a progressive (muxed) stream, and in Phase 2 for DASH. */
  audioUrl: SignedUrl | null;
  /** null when live — a live stream has no final duration. */
  durationMs: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  height: number | null;
  /** Sprite-sheet template for hover previews (F8). */
  storyboardTemplate: string | null;
  /** Drives a badge in the UI, never a dead end. */
  qualityDegraded: boolean;
  transport: PlaybackTransport;
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
