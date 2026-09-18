/**
 * `action.postComment` / `action.replyToComment` / `action.deleteComment` —
 * `protocol.md` §3.4.
 *
 * Deliberately deferred by Task 27 §5 ("read-only in this task"); built once
 * asked, against shapes verified live 2026-09-18 rather than against
 * youtubei.js's reference implementation, per the standing "community
 * references are hypotheses" rule (`CLAUDE.md`). Two things that reference
 * implementation gets wrong or leaves unclear, worth recording because they
 * are not obvious from the endpoint names alone:
 *
 * - **A reply is not `comment/create_comment` with a different `params`.**
 *   It is a distinct endpoint, `comment/create_comment_reply`, taking
 *   `createReplyParams` rather than `createCommentParams`. youtubei.js's
 *   `CommentView.reply()` obscures this — it just calls whatever endpoint the
 *   dialog names — so the two are easy to assume are the same request until
 *   the raw `apiUrl` is actually read off a live response.
 * - **Delete is not its own endpoint.** It reuses `comment/perform_comment_action`
 *   — the same one a comment like/dislike goes over — differentiated only by
 *   which pre-built, opaque `action` blob is sent. youtubei.js has no typed
 *   method for this at all (GitHub issue #744 on `LuanRT/YouTube.js`: "Can't
 *   edit, delete or report a comment", still open), so there was no reference
 *   to compare against; this is verified purely against a real request/response.
 *
 * All three take a server-issued opaque token — `CommentsResult.createParams`,
 * `Comment.replyParams`, `Comment.deleteParams` (`types.ts`) — handed back
 * verbatim, the same contract as a feed `continuation` or a playlist
 * `removeToken`.
 *
 * **They are deterministic, not session-minted — measured 2026-09-18.** The
 * comment-box token was byte-identical across three separate sessions, and the
 * reply token is just the video id and the parent comment id in a protobuf.
 * An earlier note here called them "short-lived"; that was an inference from a
 * single `404 NOT_FOUND` on a reply sent ~15 minutes after its token was read,
 * and it does not survive the data: `NOT_FOUND` names an *entity*, and the
 * parent comment that request targeted could no longer be found in any later
 * listing. Treat a 404 on a reply or a delete as "that comment is gone", not
 * "the token expired".
 *
 * Neither the reply nor the delete response matches `assertSucceeded`'s bare
 * top-level `status` field, so each is checked against its own confirmed
 * shape: post's and reply's is `{actionResult: {status}}` at the top level;
 * delete's is nested one level deeper, under
 * `actions[0].removeCommentAction.actionResult.status`.
 *
 * **A 200 with `STATUS_SUCCEEDED` is not proof the comment is visible.** The
 * create response also carries a separate `runAttestationCommand` — YouTube
 * asking a real browser to run BotGuard afterwards — which this process cannot
 * honour and which the write does not wait for. Whether skipping it makes a
 * comment likelier to be silently dropped by spam filtering is *not*
 * established here; the 2022 reports this was researched against
 * (`LuanRT/YouTube.js#224`) describe successful posts that never appeared, and
 * that is all that is known.
 */

import { RpcError, messageOf } from '../errors.ts';
import { logger } from '../log.ts';
import type { Session } from '../innertube/session.ts';
import { parseComments } from '../parser/comments.ts';
import { get, str } from '../parser/tree.ts';
import type { Comment } from '../types.ts';
import { requireCookie } from './shared.ts';

const log = logger('action');

/**
 * The comment a successful `comment/create_comment` created, as an ordinary
 * `Comment` — or `null` if the response did not carry one in the shape this
 * expects.
 *
 * The response wraps the new thread in `actions[].createCommentAction` and
 * ships its entities in the usual `frameworkUpdates`, so it is fed through
 * `parseComments` by dressing it as the one-item page that function already
 * reads, rather than by a second parser that would drift from the first. That
 * is also what makes the result carry the real `id`, and the `deleteParams` /
 * `replyParams` YouTube issues for the author's own comment — so a client can
 * offer delete and reply on it immediately, instead of inventing a local
 * stand-in that has neither.
 */
function createdComment(response: unknown): Comment | null {
  const actions = get(response, 'actions');
  if (!Array.isArray(actions)) return null;

  for (const action of actions) {
    const thread = get(action, 'createCommentAction', 'contents', 'commentThreadRenderer');
    if (!thread) continue;
    const parsed = parseComments(
      {
        frameworkUpdates: get(response, 'frameworkUpdates'),
        onResponseReceivedEndpoints: [
          { appendContinuationItemsAction: { continuationItems: [{ commentThreadRenderer: thread }] } },
        ],
      },
      'action.postComment',
    );
    return parsed.items[0] ?? null;
  }
  return null;
}

export async function postComment(
  session: Session,
  createParams: string,
  commentText: string,
): Promise<{ comment: Comment | null }> {
  requireCookie(session, 'action.postComment');

  let response: unknown;
  try {
    response = await session.execute('/comment/create_comment', {
      createCommentParams: createParams,
      commentText,
    });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `action.postComment: ${messageOf(error)}`);
  }

  const status = str(get(response, 'actionResult', 'status'));
  if (status !== null && status !== 'STATUS_SUCCEEDED') {
    throw new RpcError('UPSTREAM_ERROR', `action.postComment: YouTube answered ${status}`);
  }

  const comment = createdComment(response);
  if (!comment) log.warn('action.postComment: posted, but the response carried no comment to parse');
  log.info('posted a comment');
  return { comment };
}

export async function replyToComment(
  session: Session,
  replyParams: string,
  commentText: string,
): Promise<Record<string, never>> {
  requireCookie(session, 'action.replyToComment');

  let response: unknown;
  try {
    response = await session.execute('/comment/create_comment_reply', {
      createReplyParams: replyParams,
      commentText,
    });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `action.replyToComment: ${messageOf(error)}`);
  }

  const status = str(get(response, 'actionResult', 'status'));
  if (status !== null && status !== 'STATUS_SUCCEEDED') {
    throw new RpcError('UPSTREAM_ERROR', `action.replyToComment: YouTube answered ${status}`);
  }
  log.info('posted a reply');
  return {};
}

export async function deleteComment(
  session: Session,
  deleteParams: string,
): Promise<Record<string, never>> {
  requireCookie(session, 'action.deleteComment');

  let response: unknown;
  try {
    response = await session.execute('/comment/perform_comment_action', { action: deleteParams });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `action.deleteComment: ${messageOf(error)}`);
  }

  const status = str(get(response, 'actions', '0', 'removeCommentAction', 'actionResult', 'status'));
  if (status !== null && status !== 'STATUS_SUCCEEDED') {
    throw new RpcError('UPSTREAM_ERROR', `action.deleteComment: YouTube answered ${status}`);
  }
  log.info('deleted a comment');
  return {};
}
