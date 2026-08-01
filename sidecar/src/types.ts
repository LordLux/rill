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
 * A `SignedUrl` is constructible only by the decipher path (`markSigned`, which
 * lives in the decipher module and is deliberately not exported from here). The
 * parser cannot produce one — it only ever sees what YouTube sent, so its output
 * carries `rawUrl` / `signatureCipher`, both explicitly *un*signed. An unsigned
 * `n` throttles to ~50 KB/s and presents as a bad network connection.
 */
export type SignedUrl = string & { readonly __signed: unique symbol };

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
  /** True when every format lacks both a URL and a cipher — the SABR-only case. */
  sabrOnly: boolean;
  serverAbrStreamingUrl: string | null;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

export type AuthState = 'authenticated' | 'degraded' | 'anonymous';

export interface AuthVerification {
  state: AuthState;
  tileCount: number;
}
