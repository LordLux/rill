#!/usr/bin/env bun
import { spawnSync } from 'node:child_process';
import { readdir, readFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseFeed } from './parser/feed.ts';
import { parseVideoDetail } from './parser/video.ts';
import type { ArtistPanel, Chip, FeedItem, VideoDetail } from './types.ts';
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
  // Free text from an arbitrary uploader — the same reasoning as `title`, and
  // a pre-existing gap: this field shipped without an exporter branch, so it
  // was passing every real snippet straight into the corpus until the first
  // re-export after it landed exercised the auditor for the first time.
  if (sanitised.descriptionSnippet) sanitised.descriptionSnippet = `Sanitised Snippet ${n}`;
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

/**
 * The artist panel (Task 21 §3), sanitised the same way an item is:
 * `channelId`/`mixPlaylistId` are ids (reuses the item shapes so
 * `corpus.test.ts` needs no bespoke pattern for either), `name`/`avatarUrl`/
 * `subscriberText`/`description` reuse the shapes those fields already have
 * on other DTOs, and `handle`/`videoCountText` are the two genuinely new
 * string fields this panel introduces.
 */
function sanitiseArtistPanel(panel: ArtistPanel): ArtistPanel {
  return {
    ...panel,
    channelId: 'chan_001',
    name: 'Sanitised Channel 1',
    handle: panel.handle === null ? null : '@sanitised_handle_1',
    avatarUrl: 'https://fake.url/avatar1.jpg',
    backdropUrl: panel.backdropUrl === null ? null : 'https://fake.url/backdrop1.jpg',
    subscriberText: panel.subscriberText === null ? null : 'Sanitised Subscribers 1',
    videoCountText: panel.videoCountText === null ? null : 'Sanitised Videos 1',
    description: panel.description === null ? null : 'Sanitised Description 1',
    mixPlaylistId: panel.mixPlaylistId === null ? null : 'mix_001',
    // The shelf holds real videos, so it goes through the same per-item
    // sanitiser the surrounding results do. `backgroundColor` and
    // `baseBackgroundColor` ride the spread untouched on purpose: they are
    // YouTube's own palette for a public channel, identify nobody, and
    // replacing them would cost the corpus the one field a colour
    // regression could ever be caught by.
    shelfItems: panel.shelfItems.map(sanitiseItem),
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
      artistPanel: parsed.artistPanel ? sanitiseArtistPanel(parsed.artistPanel) : null,
    };

    await writeFile(join(CORPUS, file), JSON.stringify(result, null, 2), 'utf8');
    log.info(`exported sanitised ${file}`);
    
    // Also export VideoDetail for watch responses
    if (file === 'watch.json') {
      const { parseVideoDetail } = await import('./parser/video.ts');
      // For testing, we mock the player response if parseVideoDetail needs it, but watch.json has it in the tree
      const detail = parseVideoDetail(raw);
      if (detail) {
        // Sanitize detail
        const sanitisedDetail = {
          ...detail,
          id: 'vid_001',
          title: 'Sanitised Title 1',
          channelName: 'Sanitised Channel 1',
          channelId: 'chan_001',
          channelAvatarUrl: 'https://fake.url/avatar1.jpg',
          related: detail.related.map(sanitiseItem),
          relatedContinuation: sanitiseContinuation(detail.relatedContinuation, fileIndex),
        };
        await writeFile(join(CORPUS, 'video-detail.json'), JSON.stringify(sanitisedDetail, null, 2), 'utf8');
        log.info(`exported sanitised video-detail.json`);
      }
    }
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

  audit();
}

/**
 * Run the auditor the export exists to satisfy, and fail if it fails.
 *
 * `corpus.test.ts` is a closed world: every string in `corpus/` must match the
 * synthetic shape its field is supposed to have, so a DTO field added without a
 * matching branch above ships real data and turns the suite red. That is the
 * design working — but only if someone runs it. On 2026-09-04 this export ran
 * after the last `bun run check` of a session, and the session was reported
 * green while the auditor was red. The export had broken the suite that
 * validates it, and the failure surfaced in a file nobody had touched.
 *
 * So the export runs it itself, rather than trusting the next person to. It is
 * spawned here rather than only chained in `package.json` because the direct
 * invocation — `bun run src/export-contract-corpus.ts` — is the one that
 * actually gets typed, and a script-level `&&` does nothing for it.
 */
function audit(): void {
  log.info('running the corpus auditor over what was just exported…');
  const result = spawnSync('bun', ['test', 'test/corpus.test.ts'], {
    cwd: join(ROOT, 'sidecar'),
    stdio: ['ignore', 'inherit', 'inherit'],
  });

  if (result.error) {
    // Not fatal by itself, but it must not read as a pass: the corpus is
    // written and unverified, which is exactly the state this guards against.
    log.error(
      `could not run the corpus auditor (${result.error.message}). ` +
        'The corpus is exported but UNVERIFIED — run `bun test test/corpus.test.ts`.',
    );
    process.exit(1);
  }

  if (result.status !== 0) {
    log.error(
      'the corpus auditor is RED against the corpus just exported. A new DTO field ' +
        'almost certainly needs a branch in this file and a shape in SANITISED_SHAPE — ' +
        'until then `corpus/` may contain real capture data. Do not commit it.',
    );
    process.exit(result.status ?? 1);
  }

  log.info('corpus auditor green');
}

main().catch((error: unknown) => {
  // `.catch(console.error)` printed the error and exited 0, so a failed export
  // was indistinguishable from a successful one to anything downstream.
  log.error(`export failed: ${error instanceof Error ? error.stack : String(error)}`);
  process.exit(1);
});
