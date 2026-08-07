/**
 * The playback session registry — what `sessionId` means in Phase 1.
 *
 * `protocol.md` §5 specifies a real registry (TTL, keepalive, a hard cap of 3,
 * LRU eviction) and marks it Phase 2, because that is where a session owns
 * server-side state that leaks if a Flutter crash orphans it. Phase 1 has no
 * such state: `playback.open` returns signed URLs and holds nothing open.
 *
 * But `playback.report` takes a `sessionId` and nothing else (§3.5), so
 * something has to remember which video that is — and, more importantly, hold
 * the **CPN**, which must be one value for the whole watch or YouTube sees a
 * string of one-ping views instead of a session. That is all this is: the
 * smallest thing that makes `playback.report` addressable.
 *
 * It is deliberately not §5's registry, and the cap here is a leak guard rather
 * than a concurrency limit — evicting a session the user is still watching would
 * stop their history landing, which is the exact failure this whole path exists
 * to prevent.
 */

import { logger } from '../log.ts';

const log = logger('playback-session');

/** Comfortably above what one player plus a preloaded queue can hold open. */
const MAX_SESSIONS = 16;

export interface PlaybackSessionState {
  readonly sessionId: string;
  readonly videoId: string;
  /**
   * The client playback nonce, minted here and used for every ping of this
   * session.
   *
   * **Ours, not a resolution client's.** F6 measured reporting working from the
   * authenticated `WEB` session with its own CPN, and A5 rejects bridging the
   * resolution client's across — so this is generated locally and never leaves
   * the reporting path.
   */
  readonly cpn: string;
  /** Whether the view-registering `videostatsPlaybackUrl` ping has gone out. */
  playbackPinged: boolean;
  /** Where the last report left off, in seconds — the `st` of the next one. */
  lastPositionSeconds: number;
  openedAt: number;
}

const sessions = new Map<string, PlaybackSessionState>();

/**
 * A client playback nonce.
 *
 * 16 characters from YouTube's own alphabet. The value is opaque to the server —
 * what matters is that it is stable across a watch and not reused between them,
 * which is why it is minted per session rather than per report.
 */
const CPN_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

export function generateCpn(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let out = '';
  for (const byte of bytes) out += CPN_ALPHABET[byte & 63];
  return out;
}

export function openPlaybackSession(sessionId: string, videoId: string): PlaybackSessionState {
  const state: PlaybackSessionState = {
    sessionId,
    videoId,
    cpn: generateCpn(),
    playbackPinged: false,
    lastPositionSeconds: 0,
    openedAt: Date.now(),
  };
  sessions.set(sessionId, state);

  // Insertion order, oldest first. Anything this old has been superseded many
  // videos ago; a session still being watched is never the oldest of sixteen.
  while (sessions.size > MAX_SESSIONS) {
    const oldest = sessions.keys().next();
    if (oldest.done) break;
    log.debug(`evicting playback session ${oldest.value} — registry full`);
    sessions.delete(oldest.value);
  }

  return state;
}

export function getPlaybackSession(sessionId: string): PlaybackSessionState | null {
  return sessions.get(sessionId) ?? null;
}

export function closePlaybackSession(sessionId: string): boolean {
  return sessions.delete(sessionId);
}

/** Test seam. */
export function resetPlaybackSessions(): void {
  sessions.clear();
}
