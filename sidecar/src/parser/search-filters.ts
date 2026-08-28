/**
 * Search filters → the `params` token `/search` expects (`protocol.md` §3.3).
 *
 * A filter is not a chip (Task 20 §3): a chip is a token the server hands back in
 * a response; a filter is a token the client asks for, built from a closed set
 * the sidecar owns. `search.query` accepts a small structured `filters` object
 * and this module is the only place that turns it into the opaque `sp` string
 * InnerTube actually reads — the same shape `capture.ts` already relies on for
 * `EgIQAw%3D%3D` (type=playlist), now generalised and verified across the other
 * dimensions.
 *
 * **Measured against the live `/search` endpoint on 2026-08-27, not guessed.**
 * Each single-dimension token decodes to a small protobuf entry:
 *
 *   uploadDate  →  12 02 08 <n>   (field 2, a length-2 submessage: field 1 = n)
 *   type        →  12 02 10 <n>  (field 2, a length-2 submessage: field 2 = n)
 *   duration    →  12 02 18 <n>  (field 2, a length-2 submessage: field 3 = n)
 *   sortBy      →  08 <n>        (top-level field 1, a bare varint)
 *
 * Combining dimensions is raw concatenation of these byte sequences, re-encoded
 * as one base64url string — confirmed live rather than assumed: protobuf merges
 * repeated entries of the same embedded-message field as if the submessages were
 * merged, so `type=playlist` + `sortBy=viewCount` concatenated bytes decoded on
 * the server exactly as `type=playlist, sorted by view count` (result count and
 * ordering both shifted from the unfiltered and the type-only responses).
 *
 * `duration`'s values are deliberately non-sequential — short=1, long=2,
 * medium=3 — because that is what the server actually does with them, confirmed
 * by the resolved videos' own `durationSeconds` (short: 66–186s, long:
 * 1466–12202s, medium: 254–1170s). Trusting UI presentation order here would
 * have swapped medium and long silently.
 *
 * `sortBy` ships only `viewCount` (field-1 value 3). The other three UI options
 * — relevance (the default, sent as no token at all), upload date and rating —
 * could not be told apart from relevance by result order in repeated live
 * probes against values 1, 2 and 4: none produced a monotonically-recent or
 * otherwise distinguishable ordering, most likely because a search response
 * interleaves an unsorted shelf (e.g. a live-news card) ahead of the sorted
 * list, which defeats eyeballing order as a verification method. Shipping a
 * guessed label on a sort dropdown is exactly the kind of silent-wrong this
 * project's parser tests exist to catch elsewhere; `viewCount` is the one value
 * whose effect is unambiguous (the top results are consistently the
 * highest-view videos in the set), so it is the only one shipped. See the
 * Task 20 report for how this was checked and the follow-up this leaves open.
 */

export interface SearchFilters {
  uploadDate?: 'hour' | 'today' | 'week' | 'month' | 'year';
  type?: 'video' | 'channel' | 'playlist' | 'movie';
  duration?: 'short' | 'medium' | 'long';
  /** The only verified sort value — see the module comment. */
  sortBy?: 'viewCount';
}

const UPLOAD_DATE_VALUES: Record<NonNullable<SearchFilters['uploadDate']>, number> = {
  hour: 1,
  today: 2,
  week: 3,
  month: 4,
  year: 5,
};

const TYPE_VALUES: Record<NonNullable<SearchFilters['type']>, number> = {
  video: 1,
  channel: 2,
  playlist: 3,
  movie: 4,
};

// Not 1=short,2=medium,3=long — see the module comment; this is measured.
const DURATION_VALUES: Record<NonNullable<SearchFilters['duration']>, number> = {
  short: 1,
  long: 2,
  medium: 3,
};

const SORT_BY_VALUES: Record<NonNullable<SearchFilters['sortBy']>, number> = {
  viewCount: 3,
};

/** One `field 2` submessage entry: tag byte, length 2, then `[innerTag, value]`. */
function submessageEntry(innerTag: number, value: number): number[] {
  return [0x12, 0x02, innerTag, value];
}

/**
 * `filters` → the `params` string for `/search`, or `null` for an unfiltered
 * search (no field is ever omitted-but-present; an empty object is the same as
 * no filters at all).
 */
export function buildSearchParams(filters: SearchFilters | null | undefined): string | null {
  if (!filters) return null;

  const bytes: number[] = [];
  // Sort is a bare top-level field, not part of the field-2 submessage — kept
  // first for no protocol reason, only readability; concatenation order does
  // not matter to the decoder (verified live).
  if (filters.sortBy) bytes.push(0x08, SORT_BY_VALUES[filters.sortBy]);
  if (filters.uploadDate) bytes.push(...submessageEntry(0x08, UPLOAD_DATE_VALUES[filters.uploadDate]));
  if (filters.type) bytes.push(...submessageEntry(0x10, TYPE_VALUES[filters.type]));
  if (filters.duration) bytes.push(...submessageEntry(0x18, DURATION_VALUES[filters.duration]));

  if (bytes.length === 0) return null;
  return Buffer.from(bytes).toString('base64url');
}
