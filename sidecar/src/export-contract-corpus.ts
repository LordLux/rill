#!/usr/bin/env bun
import { readdir, readFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseFeed } from './parser/feed.ts';
import { parseVideoDetail } from './parser/video.ts';
import type { Chip, FeedItem, VideoDetail } from './types.ts';
import { logger } from './log.ts';

const log = logger('corpus');

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');
const FIXTURES = join(ROOT, 'sidecar/fixtures');
const CORPUS = join(ROOT, 'corpus');

/**
 * Chips carry two things that must not reach a committed corpus.
 *
 * The token is base64 protobuf with the session's context baked in — the same
 * long blob repeats across every chip of a response, which is what gives it
 * away as per-session rather than per-chip. The label is a taste profile:
 * "Japanese Music", "Music Arrangements" are derived from watch history.
 *
 * `scope` and `selected` are contract fields and pass through untouched, as
 * does the "All" chip's identity — the app keys its unfiltered state off that
 * label, so genericising it would erase the selection semantics the corpus
 * exists to pin down. An empty token is that same "no filter" signal rather
 * than session data, so it also survives as-is.
 */
function sanitiseChip() {
  let category = 0;
  return (chip: Chip): Chip => {
    const isAllChip = chip.label === 'All';
    if (!isAllChip) category += 1;
    const suffix = isAllChip ? 'ALL' : String(category);
    return {
      ...chip,
      label: isAllChip ? 'All' : `Category ${category}`,
      token: chip.token ? `CHIP_TOKEN_${suffix}` : chip.token,
    };
  };
}

/**
 * Placeholders are indexed by item position.
 *
 * An unindexed corpus cannot fail the bug worth catching: a mapper that
 * assigned every item the same title passes against 24 items that all read
 * "Sanitised Title". Indexing also pins field-to-item alignment, so a mapper
 * that pairs item 3's title with item 4's channel shows up as a mismatch.
 */
function sanitiseItem(item: FeedItem, index: number): FeedItem {
  const n = index + 1;
  const seq = String(n).padStart(3, '0');
  const sanitised = { ...item } as Record<string, unknown>;

  // Ids are replaced outright, never truncated. A `F_` prefix plus 8 of a video
  // id's 11 characters leaves a search space small enough to brute force, and
  // the surviving prefix combined with the tile's visible metadata identifies
  // the video anyway. `UC`-prefixed channel ids are worse — 8 characters of a
  // channel id is close to the whole distinguishing part.
  if (sanitised.id) sanitised.id = `${ID_PREFIX[String(sanitised.kind)] ?? 'item'}_${seq}`;
  if (sanitised.channelId) sanitised.channelId = `chan_${seq}`;

  if (sanitised.title) sanitised.title = `Sanitised Title ${n}`;
  if (sanitised.channelName) sanitised.channelName = `Sanitised Channel ${n}`;
  // ChannelItem carries the channel's own name here rather than in
  // `channelName`. Branch added before a re-export that includes channel tiles
  // ships real names without anyone noticing.
  if (sanitised.name) sanitised.name = `Sanitised Channel ${n}`;
  // A mix subtitle is a track/artist list — "Daft Punk, Todd Terje, and more" —
  // which is the same taste profile the chip labels leak.
  if (sanitised.subtitle) sanitised.subtitle = `Sanitised Subtitle ${n}`;
  // Public, but not the point of the corpus — same call as `title`. First hit
  // 2026-08-27: no fixture had ever produced a `ChannelItem` before the search
  // filter fix that let real ones through.
  if (sanitised.subscriberText) sanitised.subscriberText = `Sanitised Subscribers ${n}`;

  if (sanitised.thumbnailUrl) sanitised.thumbnailUrl = `https://fake.url/img${n}.jpg`;
  if (sanitised.avatarUrl) sanitised.avatarUrl = `https://fake.url/avatar${n}.jpg`;
  if (sanitised.channelAvatarUrl) sanitised.channelAvatarUrl = `https://fake.url/avatar${n}.jpg`;
  return sanitised as unknown as FeedItem;
}

const ID_PREFIX: Record<string, string> = {
  video: 'vid',
  mix: 'mix',
  playlist: 'list',
  channel: 'chan',
};

/**
 * Continuations are the same base64 session protobuf as the chip tokens, up to
 * 5.6 KB of it, and none of it is contract data.
 *
 * A contract test asserting continuation shape should assert "non-empty
 * string"; if one ever needs a realistic length, pad this filler rather than
 * keeping a real token. Session protobuf does not belong in a public repo to
 * preserve a shape nothing asserts yet.
 */
function sanitiseContinuation(continuation: string | null, index: number): string | null {
  return continuation === null ? null : `CONTINUATION_TOKEN_${index + 1}`;
}

/**
 * A `VideoDetail`, sanitised, so the Flutter contract test has one to check.
 *
 * `VideoDetail` was the one DTO the corpus did not cover, and it is the one
 * where being uncovered costs most: it is the payload the watch page is built
 * out of, and a field added here and not mirrored in `app/lib/domain` is dropped
 * by `fromJson` in silence — nothing throws, the field is simply absent.
 *
 * `related` keeps the same per-item sanitisation the feeds get, so the tiles a
 * watch page ships are audited by exactly the rule that audits a home feed
 * rather than by a second copy of it.
 */
function sanitiseVideoDetail(detail: VideoDetail): VideoDetail {
  return {
    ...detail,
    id: 'vid_001',
    title: 'Sanitised Title 1',
    // A description is free text from an arbitrary uploader — links, handles,
    // and on a personalised page sometimes the viewer's own locale formatting.
    // Replaced wholesale rather than truncated.
    description: 'Sanitised Description 1',
    channelName: 'Sanitised Channel 1',
    channelId: 'chan_001',
    channelAvatarUrl: 'https://fake.url/avatar1.jpg',
    subscriberText: detail.subscriberText === null ? null : 'Sanitised Subscribers 1',
    likeText: detail.likeText === null ? null : 'Sanitised Likes 1',
    related: detail.related.map(sanitiseItem),
    relatedContinuation: sanitiseContinuation(detail.relatedContinuation, 0),
  };
}

async function main() {
  await mkdir(CORPUS, { recursive: true });
  const files = (await readdir(FIXTURES)).filter(
    (file) => file.endsWith('.json') && !file.startsWith('player-') && file !== 'manifest.json',
  );

  for (const [fileIndex, file] of files.entries()) {
    const name = file.replace(/\.json$/, '');
    const raw = JSON.parse(await readFile(join(FIXTURES, file), 'utf8'));
    const parsed = parseFeed(raw, name);

    const result = {
      ...parsed,
      chips: parsed.chips.map(sanitiseChip()),
      items: parsed.items.map(sanitiseItem),
      continuation: sanitiseContinuation(parsed.continuation, fileIndex),
    };

    await writeFile(join(CORPUS, file), JSON.stringify(result, null, 2), 'utf8');
    log.info(`exported sanitised ${file}`);
  }

  // The watch fixture twice: once as the sidebar feed above, once as the
  // `VideoDetail` the watch page actually renders. Same capture, two DTOs, and
  // the second one had no corpus coverage at all until now.
  const watch = join(FIXTURES, 'watch.json');
  if (files.includes('watch.json')) {
    const detail = parseVideoDetail(JSON.parse(await readFile(watch, 'utf8')), 'video-detail');
    await writeFile(
      join(CORPUS, 'video-detail.json'),
      JSON.stringify(sanitiseVideoDetail(detail), null, 2),
      'utf8',
    );
    log.info('exported sanitised video-detail.json');
  }
}

main().catch(console.error);
