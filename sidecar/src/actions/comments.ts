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


/**
 * YouTube's comment length limit, **measured 2026-09-21** rather than taken
 * from documentation: 10,000 characters is accepted and 10,001 is refused
 * outright by `comment/create_comment` with an HTTP 4xx.
 *
 * It is not in the response anywhere — the create box ships no
 * `maxCharacterLimit` or equivalent — so the only way to know it is to ask, and
 * the only way to keep knowing it is to write it down.
 *
 * Checked here rather than only in the client because the client is not the
 * only caller of the RPC, and because a refusal that names the limit is worth
 * more than a bare 400 from the edge. The client checks too, so a viewer is
 * stopped while typing instead of after pressing send.
 */
export const COMMENT_MAX_LENGTH = 10000;

/** Refuses a comment YouTube will refuse anyway, with a message that says why. */
function requireLength(text: string, method: string): void {
  if (text.length <= COMMENT_MAX_LENGTH) return;
  throw new RpcError(
    'BAD_REQUEST',
    `${method}: a comment is at most ${COMMENT_MAX_LENGTH} characters; this one is ${text.length}`,
  );
}

export async function postComment(
  session: Session,
  createParams: string,
  commentText: string,
): Promise<{ comment: Comment | null }> {
  requireCookie(session, 'action.postComment');
  requireLength(commentText, 'action.postComment');

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
  requireLength(commentText, 'action.replyToComment');

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

/**
 * `action.rateComment` — like, unlike, dislike or undislike a comment.
 *
 * **The caller sends a blob, not an intent.** `params` is one of the four
 * server-supplied tokens on {@link Comment} (`likeParams`, `unlikeParams`,
 * `dislikeParams`, `undislikeParams`), handed back verbatim. This function
 * deliberately does not take a target rating and pick the token itself: that
 * would mean holding a second copy of the state machine here, out of step with
 * whatever the client is actually showing, and the endpoint has no notion of
 * "set rating to X" to translate into anyway.
 *
 * It reuses `comment/perform_comment_action` — the same endpoint as delete,
 * differentiated only by which blob is sent, exactly as that function's own
 * note predicted. So there is no new request shape here to get wrong, which is
 * the whole reason this was cheap: the `target` shape for a *video*'s
 * like/dislike came from a reference implementation and produced 400s until it
 * was corrected against a real response (`CLAUDE.md`). These blobs come off the
 * response itself.
 *
 * Measured 2026-09-20: all four are present on 20 of 20 comments of a signed-in
 * page — **and on an anonymous one too**, so their presence is not evidence the
 * viewer may vote. `requireCookie` is what actually enforces that, here as
 * everywhere else.
 */
export async function rateComment(
  session: Session,
  params: string,
): Promise<Record<string, never>> {
  requireCookie(session, 'action.rateComment');

  let response: unknown;
  try {
    response = await session.execute('/comment/perform_comment_action', { action: params });
  } catch (error) {
    throw new RpcError('UPSTREAM_ERROR', `action.rateComment: ${messageOf(error)}`);
  }

  // `actionResults` — **plural**, and a sibling of `actions` rather than nested
  // inside one: `[{status: 'STATUS_SUCCEEDED', feedback: 'FEEDBACK_LIKE'}]`.
  // Measured 2026-09-21 off a real vote; `actions` comes back empty.
  //
  // The first version of this read `actions[0].updateCommentVoteAction
  // .actionResult.status`, inferred from the `updateCommentVoteAction` that
  // appears in the *surface entity's* `clientActions` — a plausible shape that
  // is not this endpoint's. It matched nothing, so `status` was always `null`
  // and every vote, including a rejected one, was reported as a success. That
  // is the "community references are hypotheses" rule biting on a shape I
  // inferred from a neighbouring field rather than read off the response.
  const status = str(get(response, 'actionResults', '0', 'status'));
  if (status !== null && status !== 'STATUS_SUCCEEDED') {
    throw new RpcError('UPSTREAM_ERROR', `action.rateComment: YouTube answered ${status}`);
  }
  log.info('rated a comment');
  return {};
}
