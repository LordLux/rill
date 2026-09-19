#!/usr/bin/env bun
/**
 * Fixtures in *known* viewer states — `bun run capture:viewer-state <before|after>`.
 *
 * **The hole this closes.** Every other fixture is captured with the account in
 * whatever state it happens to be in, so a reader of that state can be wrong in
 * a way no test can see: `creatorHearted` was true for every comment ever
 * exported, `isLiked` for none, and `PlaylistMembership.containsVideo` was false
 * for every playlist of every video. All three passed, because the fixtures held
 * no liked comment, no hearted comment and no video that was in Watch Later to
 * disagree with them. A capture whose state is *claimed* has the same problem one
 * step removed, so this one **checks the claim against the raw response and
 * writes nothing if it does not hold** — the state is proven at capture time, not
 * assumed. (The checks read raw JSON by their own small paths, not through the
 * parsers the fixtures exist to test; a check that reuses the code under test
 * proves nothing.)
 *
 * **The recipe.** Three targets, by environment variable:
 *
 *   YT_VIEWER_VIDEO          a public video the account has not rated, whose
 *                            channel it does not subscribe to, and that is not in
 *                            Watch Later. Default `aqz-KE-bpKQ` (Big Buck Bunny).
 *   YT_VIEWER_COMMENT_VIDEO  a video the account **owns**, with at least one
 *                            comment by the account itself. Hearting is creator-
 *                            only, and hearting your own comment on your own video
 *                            touches nobody else — which is why it is the target.
 *   YT_VIEWER_DISLIKED_VIDEO optional: a video the account has disliked.
 *
 *   1. Put the account in the BEFORE state:
 *        - the video unrated (no like, no dislike);
 *        - its channel not subscribed;
 *        - the video not in Watch Later;
 *        - the own comment neither liked nor hearted.
 *      `bun run capture:viewer-state before`
 *   2. Put the account in the AFTER state:
 *        - like the video;
 *        - subscribe to its channel;
 *        - add the video to Watch Later;
 *        - like the own comment and heart it.
 *      `bun run capture:viewer-state after`
 *   3. Undo step 2, so the account is where it started. (Liking and hearting are
 *      an on/off pair, and the own comment is a comment you wrote.)
 *
 * The rill app does the video, subscribe and Watch Later steps itself; liking
 * and hearting a comment are done on youtube.com. Each run retries for `--wait`
 * seconds (default 60) because a write takes a few seconds to show in a read.
 *
 * Output: `fixtures/viewer-state/` — kept across `bun run capture`, which
 * otherwise replaces `fixtures/` wholesale — plus a `manifest.json` recording the
 * ids and the raw facts each phase was verified against. `export-contract-corpus`
 * turns the pair into sanitised corpus files, and the contract tests assert the
 * states in both.
 */

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { logger } from './log.ts';
import { createSession, type Session } from './innertube/session.ts';
import { parseComments } from './parser/comments.ts';
import { parseVideoDetail } from './parser/video.ts';
import { deepCollect, deepFind, get, isObject, str } from './parser/tree.ts';

const log = logger('capture-viewer-state');

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'fixtures', 'viewer-state');

type Phase = 'before' | 'after';

// ---------------------------------------------------------------------------
// Raw facts — read by paths of their own, never through the parsers under test
// ---------------------------------------------------------------------------

/** First string value of `key` anywhere under `node`, depth first. */
function firstString(node: unknown, key: string): string | null {
  if (Array.isArray(node)) {
    for (const child of node) {
      const found = firstString(child, key);
      if (found !== null) return found;
    }
    return null;
  }
  if (isObject(node)) {
    if (typeof node[key] === 'string') return node[key];
    for (const child of Object.values(node)) {
      const found = firstString(child, key);
      if (found !== null) return found;
    }
  }
  return null;
}

/** The main like button's status: `LIKE` / `DISLIKE` / `INDIFFERENT`. */
function rawLikeStatus(watch: unknown): string | null {
  const primary = deepFind(watch, (node) => isObject(node['videoPrimaryInfoRenderer']));
  return primary ? firstString(primary['videoPrimaryInfoRenderer'], 'likeStatus') : null;
}

/**
 * The owner's subscribe button, as YouTube states it — `null` unless two
 * independent statements of it agree.
 *
 * `subscribeButtonRenderer.subscribed` is present in both states.
 * `videoOwnerRenderer.subscriptionButton` is *not* (measured 2026-09-20: it only
 * exists once subscribed, which is the first path this used and why the "before"
 * capture found nothing). The `subscriptionStateEntity` in the entity store is
 * the second statement, and a page that has one must agree with the button.
 */
function rawSubscribed(watch: unknown): boolean | null {
  const secondary = deepFind(watch, (node) => isObject(node['videoSecondaryInfoRenderer']));
  const button = get(secondary, 'videoSecondaryInfoRenderer', 'subscribeButton', 'subscribeButtonRenderer', 'subscribed');
  if (typeof button !== 'boolean') return null;

  const mutations = get(watch, 'frameworkUpdates', 'entityBatchUpdate', 'mutations');
  for (const mutation of Array.isArray(mutations) ? mutations : []) {
    const entity = get(mutation, 'payload', 'subscriptionStateEntity', 'subscribed');
    if (typeof entity === 'boolean' && entity !== button) return null;
  }
  return button;
}

/** Watch Later's row in the save dialog: `ALL` / `NONE`. */
function rawWatchLater(membership: unknown): string | null {
  const rows = deepCollect(membership, (node) => isObject(node['playlistAddToOptionRenderer']));
  for (const row of rows) {
    const option = row['playlistAddToOptionRenderer'];
    if (str(get(option, 'playlistId')) === 'WL') return str(get(option, 'containsSelectedVideos'));
  }
  return null;
}

interface CommentState {
  likeState: string | null;
  heartState: string | null;
}

/** `commentId → its {likeState, heartState}`, from the entity store — the only place either lives. */
function rawCommentStates(page: unknown): Map<string, CommentState> {
  const byKey = new Map<string, Record<string, unknown>>();
  const mutations = get(page, 'frameworkUpdates', 'entityBatchUpdate', 'mutations');
  for (const mutation of Array.isArray(mutations) ? mutations : []) {
    const payload = get(mutation, 'payload');
    if (!isObject(payload)) continue;
    for (const entity of Object.values(payload)) {
      if (isObject(entity) && typeof entity['key'] === 'string') byKey.set(entity['key'], entity);
    }
  }

  const states = new Map<string, CommentState>();
  const endpoints = get(page, 'onResponseReceivedEndpoints');
  for (const endpoint of Array.isArray(endpoints) ? endpoints : []) {
    const items =
      get(endpoint, 'reloadContinuationItemsCommand', 'continuationItems') ??
      get(endpoint, 'appendContinuationItemsAction', 'continuationItems');
    for (const item of Array.isArray(items) ? items : []) {
      const vm = get(item, 'commentThreadRenderer', 'commentViewModel', 'commentViewModel');
      if (!isObject(vm)) continue;
      const comment = byKey.get(str(vm['commentKey']) ?? '');
      const state = byKey.get(str(vm['toolbarStateKey']) ?? '');
      const id = str(get(comment, 'properties', 'commentId'));
      if (id && state) {
        states.set(id, { likeState: str(state['likeState']), heartState: str(state['heartState']) });
      }
    }
  }
  return states;
}

const isLiked = (s: CommentState | undefined) => s?.likeState === 'TOOLBAR_LIKE_STATE_LIKED';
const isHearted = (s: CommentState | undefined) => s?.heartState?.startsWith('TOOLBAR_HEART_STATE_HEARTED') ?? false;

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

interface Snapshot {
  watch: unknown;
  membership: unknown;
  comments: unknown | null;
  commentId: string | null;
  anonymousComments: unknown | null;
  disliked: unknown | null;
  facts: Record<string, unknown>;
}

async function commentsPage(session: Session, videoId: string): Promise<unknown | null> {
  const detail = parseVideoDetail(await session.execute('/next', { videoId }), 'viewer-state');
  if (!detail.commentsContinuation) return null;
  return session.execute('/next', { continuation: detail.commentsContinuation });
}

async function snapshot(
  session: Session,
  anonymous: Session,
  phase: Phase,
  video: string,
  commentVideo: string | null,
  dislikedVideo: string | null,
  knownCommentId: string | null,
): Promise<Snapshot> {
  const watch = await session.execute('/next', { videoId: video });
  const membership = await session.execute('/playlist/get_add_to_playlist', { videoIds: [video] });

  let comments: unknown | null = null;
  let commentId = knownCommentId;
  let anonymousComments: unknown | null = null;
  let own: CommentState | undefined;
  let publicView: CommentState | undefined;

  if (commentVideo) {
    comments = await commentsPage(session, commentVideo);
    if (comments && !commentId) {
      // The account's own comment: the only kind that carries a delete action.
      commentId = parseComments(comments, 'viewer-state').items.find((c) => c.deleteParams !== null)?.id ?? null;
    }
    if (comments && commentId) own = rawCommentStates(comments).get(commentId);
    if (phase === 'after') {
      anonymousComments = await commentsPage(anonymous, commentVideo);
      if (anonymousComments && commentId) publicView = rawCommentStates(anonymousComments).get(commentId);
    }
  }

  const disliked = phase === 'after' && dislikedVideo ? await session.execute('/next', { videoId: dislikedVideo }) : null;

  return {
    watch,
    membership,
    comments,
    commentId,
    anonymousComments,
    disliked,
    facts: {
      likeStatus: rawLikeStatus(watch),
      subscribed: rawSubscribed(watch),
      watchLater: rawWatchLater(membership),
      ...(commentVideo ? { commentLikeState: own?.likeState ?? null, commentHeartState: own?.heartState ?? null } : {}),
      ...(phase === 'after' && commentVideo
        ? { publicLikeState: publicView?.likeState ?? null, publicHeartState: publicView?.heartState ?? null }
        : {}),
      ...(disliked ? { dislikedLikeStatus: rawLikeStatus(disliked) } : {}),
    },
  };
}

/** What is wrong with the account's state for `phase` — empty means it is as claimed. */
function problems(phase: Phase, snap: Snapshot, withComments: boolean): string[] {
  const f = snap.facts;
  const out: string[] = [];
  const want =
    phase === 'before'
      ? { likeStatus: 'INDIFFERENT', subscribed: false, watchLater: 'NONE', liked: false, hearted: false }
      : { likeStatus: 'LIKE', subscribed: true, watchLater: 'ALL', liked: true, hearted: true };

  if (f['likeStatus'] !== want.likeStatus) out.push(`video rating is ${String(f['likeStatus'])}, want ${want.likeStatus}`);
  if (f['subscribed'] !== want.subscribed) out.push(`channel subscribed is ${String(f['subscribed'])}, want ${want.subscribed}`);
  if (f['watchLater'] !== want.watchLater) out.push(`Watch Later contains it is ${String(f['watchLater'])}, want ${want.watchLater}`);

  if (withComments) {
    if (!snap.comments) out.push('the comment video has no comments page (are comments on?)');
    else if (!snap.commentId) out.push('the account has no comment of its own on the comment video');
    else if (f['commentLikeState'] === null || f['commentHeartState'] === null) out.push('the own comment is not on the first page');
    else {
      const own = { likeState: f['commentLikeState'] as string, heartState: f['commentHeartState'] as string };
      if (isLiked(own) !== want.liked) out.push(`own comment liked is ${isLiked(own)}, want ${want.liked}`);
      if (isHearted(own) !== want.hearted) out.push(`own comment hearted is ${isHearted(own)}, want ${want.hearted}`);
    }
    if (phase === 'after') {
      // What everyone else sees of it: hearted (the plain HEARTED value, not the creator's EDITABLE one), and not liked by *them*.
      const pub = { likeState: f['publicLikeState'] as string | null, heartState: f['publicHeartState'] as string | null };
      if (pub.heartState === null) out.push('the own comment is not on the anonymous first page');
      else {
        if (!isHearted(pub)) out.push(`anonymous view: comment hearted is false, want true (${pub.heartState})`);
        if (isLiked(pub)) out.push('anonymous view: comment reads as liked by the viewer');
      }
    }
  }
  if (phase === 'after' && f['dislikedLikeStatus'] !== undefined && f['dislikedLikeStatus'] !== 'DISLIKE') {
    out.push(`the disliked video's rating is ${String(f['dislikedLikeStatus'])}, want DISLIKE`);
  }
  return out;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function main(): Promise<void> {
  const phase = process.argv[2];
  if (phase !== 'before' && phase !== 'after') {
    log.error('usage: bun run capture:viewer-state <before|after> [--wait <seconds>]');
    process.exit(2);
  }
  const waitFlag = process.argv.indexOf('--wait');
  const waitSeconds = waitFlag > 0 ? Number(process.argv[waitFlag + 1]) : 60;

  const cookie = process.env.YT_COOKIE;
  if (!cookie) {
    log.error('YT_COOKIE is not set — a viewer state needs a viewer');
    process.exit(2);
  }
  const video = process.env.YT_VIEWER_VIDEO ?? 'aqz-KE-bpKQ';
  const commentVideo = process.env.YT_VIEWER_COMMENT_VIDEO ?? null;
  const dislikedVideo = process.env.YT_VIEWER_DISLIKED_VIDEO ?? null;
  if (!commentVideo) log.warn('YT_VIEWER_COMMENT_VIDEO is not set — the comment half is skipped');

  const session = await createSession({ clientType: 'WEB', cookie });
  const anonymous = await createSession({ clientType: 'WEB' });

  let manifest: Record<string, unknown> = {};
  try {
    manifest = JSON.parse(await readFile(join(OUT, 'manifest.json'), 'utf8')) as Record<string, unknown>;
  } catch {
    // first run
  }
  const knownCommentId = typeof manifest['commentId'] === 'string' ? manifest['commentId'] : null;

  const deadline = Date.now() + waitSeconds * 1000;
  for (;;) {
    const snap = await snapshot(session, anonymous, phase, video, commentVideo, dislikedVideo, knownCommentId);
    const wrong = problems(phase, snap, commentVideo !== null);
    if (wrong.length === 0) {
      await mkdir(OUT, { recursive: true });
      const write = (name: string, body: unknown) => writeFile(join(OUT, name), JSON.stringify(body), 'utf8');
      await write(`watch-${phase}.json`, snap.watch);
      await write(`membership-${phase}.json`, snap.membership);
      if (snap.comments) await write(`comments-${phase}.json`, snap.comments);
      if (snap.anonymousComments) await write('comments-after-anonymous.json', snap.anonymousComments);
      if (snap.disliked) await write('watch-disliked.json', snap.disliked);

      const detail = parseVideoDetail(snap.watch, 'viewer-state');
      const phases = (manifest['phases'] as Record<string, unknown> | undefined) ?? {};
      phases[phase] = { capturedAt: new Date().toISOString(), facts: snap.facts };
      await writeFile(
        join(OUT, 'manifest.json'),
        JSON.stringify(
          {
            ...manifest,
            video,
            channelId: detail.channelId,
            commentVideo,
            commentId: snap.commentId,
            dislikedVideo,
            phases,
          },
          null,
          2,
        ),
        'utf8',
      );
      log.info(`captured the "${phase}" state to fixtures/viewer-state/ — verified: ${JSON.stringify(snap.facts)}`);
      return;
    }
    if (Date.now() >= deadline) {
      log.error(`the account is not in the "${phase}" state, so nothing was written:\n  - ${wrong.join('\n  - ')}`);
      process.exit(1);
    }
    log.warn(`not yet in the "${phase}" state (${wrong.length} to go); retrying in 5 s — ${wrong.join('; ')}`);
    await sleep(5000);
  }
}

await main();
