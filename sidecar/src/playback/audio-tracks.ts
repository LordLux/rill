/**
 * Audio tracks: which one plays by default, the list the client chooses from, and what each
 * row is called — Task 39, `protocol.md` §3.5, `architecture.md` F65.
 */

import type { AudioTrack, PlayerAudioTrack, PlayerFormat } from '../types.ts';

/**
 * Where a format's track ranks: the original first, then the track YouTube flags as its
 * default, then everything else (which the caller orders as it always has).
 *
 * **Structural, never the name.** `acont=original` is the original whatever language the
 * request asked in. Anonymously YouTube's default *was* the original on every video and every
 * `hl` measured, including an `hl` matching an available dub, but nothing promises it, and a
 * signed-in viewer's setting is exactly the kind of thing that could move it.
 */
export function trackRank(format: PlayerFormat): number {
  const track = format.audioTrack;
  if (track === null) return 2;
  if (track.content === 'original') return 0;
  return track.isDefault ? 1 : 2;
}

/**
 * Wordings YouTube puts on the original's name, by language, measured 2026-11-22 under eight
 * `hl` values (F65). Each is a pattern for the whole remainder, so a name only loses a wording
 * that is all there is at that end of it.
 */
const ORIGINAL_WORDINGS: RegExp[] = [
  /\s*\(Original\)$/, // de: "Englisch (US) (Original)"
  /\s+original$/, // en, es, fr: "English (US) original", "Inglés (US) original", "Anglais (US) original"
  /\s*（オリジナル）$/, // "英語 (US)（オリジナル）"
  /\s*:\s*أصلي$/, // "الإنجليزية (US): أصلي"
  /^मूल भाषा\s+/, // "मूल भाषा अंग्रेज़ी (US)"
  /^মূল ভাষা\s+/, // "মূল ভাষা ইংরেজি (US)"
];

/**
 * The name a row shows: YouTube's, with its own "original" wording removed when the track is
 * the original, because the client draws an *Original* badge from `isOriginal` and the row
 * would otherwise say it twice.
 *
 * **The one place a display name is matched, and it decides nothing.** Which track plays and
 * which is marked original are read from `xtags`; this only changes the text. A wording not in
 * [ORIGINAL_WORDINGS] leaves the name as YouTube sent it, so the worst case is "original" said
 * twice, never a wrong track — the same trade `parser/player.ts`'s members-only reason makes.
 */
export function trackDisplayName(track: PlayerAudioTrack): string {
  const name = track.displayName?.trim() || track.language || track.id;
  if (track.content !== 'original') return name;
  for (const wording of ORIGINAL_WORDINGS) {
    const stripped = name.replace(wording, '').trim();
    if (stripped !== name && stripped.length > 0) return stripped;
  }
  return name;
}

export function toAudioTrack(track: PlayerAudioTrack): AudioTrack {
  return {
    id: track.id,
    displayName: trackDisplayName(track),
    isOriginal: track.content === 'original',
    isDubbed: track.content === 'dubbed',
    isAutoDubbed: track.content === 'dubbed-auto',
  };
}

/**
 * Every track the formats name, once each: the original first, then by name.
 *
 * `[]` when fewer than two: one track is nothing to choose from, and a single-track video's
 * formats name none at all.
 */
export function listAudioTracks(formats: PlayerFormat[]): AudioTrack[] {
  const byId = new Map<string, PlayerAudioTrack>();
  for (const format of formats) {
    const track = format.audioTrack;
    if (track !== null && !byId.has(track.id)) byId.set(track.id, track);
  }
  if (byId.size < 2) return [];
  return [...byId.values()]
    .map(toAudioTrack)
    .sort((a, b) => Number(b.isOriginal) - Number(a.isOriginal) || a.displayName.localeCompare(b.displayName));
}

export interface AudioChoice<F> {
  /** The format to play. */
  format: F;
  tracks: AudioTrack[];
  /** The track [format] carries; null exactly when [tracks] is empty. */
  audioTrackId: string | null;
}

/**
 * The format to play from [ranked] (best first), and the list it is one of.
 *
 * [requested] wins when one of [ranked] carries it; otherwise it is ignored and the best
 * format plays (`protocol.md` §3.5: `audioTrackId` is always the truth, so an id the video does
 * not have is not an error, it is simply not what plays).
 */
export function chooseAudio(ranked: PlayerFormat[], requested: string | null | undefined): AudioChoice<PlayerFormat> | null {
  const best = ranked[0];
  if (best === undefined) return null;
  const format = (requested ? ranked.find((f) => f.audioTrack?.id === requested) : undefined) ?? best;
  const tracks = listAudioTracks(ranked);
  const playing = format.audioTrack?.id ?? null;
  if (tracks.length === 0 || playing === null) return { format, tracks: [], audioTrackId: null };
  return { format, tracks, audioTrackId: playing };
}
