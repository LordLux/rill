/**
 * The ordering `subscriptions.channels` is assumed to arrive in, and the check
 * that says so out loud when it does not.
 *
 * `FEchannels` has no sort parameter (protocol.md §3.3). The app's A–Z
 * scrubber — `alphabet_index.dart`, `AllSubscriptionsPage` — depends on the
 * server's *default* order already being `#`, then A–Z, which was confirmed
 * empirically and is specified nowhere. If that default ever changes, every
 * letter jump lands on the wrong row and nothing throws: the list still
 * renders, the scrubber still scrolls, it just points at the wrong place.
 *
 * So the assumption gets checked where it is made. This is not a parser: it
 * changes no item and drops none. It exists to turn a silent wrong answer into
 * a line on stderr.
 */

import type { FeedItem } from '../types.ts';

/**
 * The `#`/A–Z bucket for a channel name. Must agree with `letterBucketOf` in
 * `app/lib/ui/widgets/alphabet_index.dart` — anything not A–Z, the empty name
 * included, buckets to `#` and sorts first.
 */
export function channelBucket(name: string): string {
  if (name.length === 0) return '#';
  const c = name[0]!.toUpperCase();
  return c >= 'A' && c <= 'Z' ? c : '#';
}

export interface ChannelOrderViolation {
  index: number;
  previousBucket: string;
  bucket: string;
}

/**
 * The first place the order goes backwards, or `null` when the whole list is
 * non-decreasing by bucket.
 *
 * Deliberately bucket-wise rather than a full string comparison: within a
 * letter YouTube's collation is its own business (case, diacritics, leading
 * "The"), and asserting on it would fail on ordering the scrubber does not
 * care about. The scrubber only ever asks "where does `M` start", so `M`
 * appearing after `N` is the only failure worth being loud about.
 */
export function firstChannelOrderViolation(items: readonly FeedItem[]): ChannelOrderViolation | null {
  let previousBucket = '';
  let index = 0;

  for (const item of items) {
    if (item.kind !== 'channel') continue;
    const bucket = channelBucket(item.name);
    if (bucket < previousBucket) return { index, previousBucket, bucket };
    previousBucket = bucket;
    index += 1;
  }

  return null;
}
