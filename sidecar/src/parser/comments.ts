/* eslint-disable @typescript-eslint/no-explicit-any -- this file walks
 * `parse: false` JSON whose shape is not yet known, the same problem every
 * other file under `parser/` solves with `get`/`str`/`num`/`isObject`
 * (`tree.ts`). Those return `unknown`, not `any`, and property access on
 * `unknown` is a type error even after a truthy guard (TypeScript narrows a
 * checked `unknown` to the unhelpful `{}`, not to a shape) — `feed.ts` and
 * `video.ts` route every read through those helpers instead of ever holding
 * an untyped intermediate. This file was written directly against the raw
 * shape and never converted; that conversion is real cleanup work, tracked
 * separately, not a one-line fix bundled into an unrelated change.
 */
import { get, str } from './tree.ts';
import { EntityStore } from './entities.ts';
import type { Comment, CommentsResult, CommentText, Chip } from '../types.ts';
import { logger } from '../log.ts';

const log = logger('parser/comments');

function parseCommentText(contentObj: any): CommentText {
  if (!contentObj || typeof contentObj.content !== 'string') {
    return { content: '' };
  }
  const result: CommentText = { content: contentObj.content };
  
  if (Array.isArray(contentObj.styleRuns)) {
    result.styleRuns = contentObj.styleRuns.map((r: any) => ({
      startIndex: Number(r.startIndex) || 0,
      length: Number(r.length) || 0,
      weightLabel: r.weightLabel,
    }));
  }
  
  if (Array.isArray(contentObj.commandRuns)) {
    result.commandRuns = contentObj.commandRuns.map((r: any) => ({
      startIndex: Number(r.startIndex) || 0,
      length: Number(r.length) || 0,
      url: get(r, 'onTap', 'innertubeCommand', 'urlEndpoint', 'url') ?? undefined,
      videoId: get(r, 'onTap', 'innertubeCommand', 'watchEndpoint', 'videoId') ?? undefined,
      startTimeSeconds: get(r, 'onTap', 'innertubeCommand', 'watchEndpoint', 'startTimeSeconds') ?? undefined,
    }));
  }
  
  return result;
}

/**
 * `replyParams` / `deleteParams` — both live on the comment's
 * `engagementToolbarSurfaceEntityPayload`, keyed by `toolbarSurfaceKey`, not on
 * the `commentEntityPayload` the rest of this function reads. Verified live
 * 2026-09-18 against an authenticated session: `replyCommand` carries a
 * server-issued `createReplyParams` for `comment/create_comment_reply`, and
 * `menuCommand` carries a "Delete" item (own comments only) whose confirm
 * button holds a `comment/perform_comment_action` `action` blob. Both are
 * absent for an anonymous viewer — the surface carries `prepareAccountCommand`
 * instead, same as the top-level create box (`docs/tasks/27-comments.md`).
 */
function extractSurfaceCommands(
  store: EntityStore,
  surfaceKey: string | null | undefined,
): { replyParams: string | null; deleteParams: string | null } {
  const surface = store.get<any>(surfaceKey);
  if (!surface) return { replyParams: null, deleteParams: null };

  const replyParams = get(
    surface,
    'replyCommand', 'innertubeCommand', 'createCommentReplyDialogEndpoint', 'dialog',
    'commentReplyDialogRenderer', 'replyButton', 'buttonRenderer', 'serviceEndpoint',
    'createCommentReplyEndpoint', 'createReplyParams',
  );

  let deleteParams: string | null = null;
  const menuItems = get(
    surface, 'menuCommand', 'innertubeCommand', 'menuEndpoint', 'menu', 'menuRenderer', 'items',
  );
  if (Array.isArray(menuItems)) {
    for (const item of menuItems) {
      const label = get(item, 'menuNavigationItemRenderer', 'text', 'runs', '0', 'text');
      if (label !== 'Delete') continue;
      const action = get(
        item, 'menuNavigationItemRenderer', 'navigationEndpoint', 'confirmDialogEndpoint', 'content',
        'confirmDialogRenderer', 'confirmButton', 'buttonRenderer', 'serviceEndpoint',
        'performCommentActionEndpoint', 'action',
      );
      if (typeof action === 'string') deleteParams = action;
    }
  }

  return {
    replyParams: typeof replyParams === 'string' ? replyParams : null,
    deleteParams,
  };
}

/**
 * The token inside a `continuationItemRenderer`, in either of the two shapes
 * YouTube uses for it.
 *
 * A page of threads carries it as `continuationEndpoint.continuationCommand`;
 * a page of *replies* carries it as a button —
 * `button.buttonRenderer.command.continuationCommand`, the "Show more replies"
 * control. Measured 2026-09-18 on a thread advertising 962 replies: rill listed
 * 5 and offered no way to load the rest, because only the first shape was read
 * and the reply list's own pagination token is always the second.
 */
function continuationToken(renderer: unknown): string | null {
  return (
    str(get(renderer, 'continuationEndpoint', 'continuationCommand', 'token')) ??
    str(get(renderer, 'button', 'buttonRenderer', 'command', 'continuationCommand', 'token'))
  );
}

export function parseComments(root: any, context: string): CommentsResult {
  const store = new EntityStore(root);
  const items: Comment[] = [];
  let continuation: string | null = null;
  const chips: Chip[] = [];
  let commentCount: string | null = null;
  let createParams: string | null = null;

  /**
   * One thread, then — for a reply — every reply nested inside it, flattened
   * depth-first into the same list.
   *
   * YouTube's data nests a reply-to-a-reply in its parent's own
   * `replies.commentRepliesRenderer.subThreads` (`replyLevel` 2 inside a level-1
   * reply), while its UI shows them as one flat list. Only reading the top
   * level silently dropped every such reply: a thread advertising 2 replies
   * listed 1, with nothing thrown and nothing logged.
   *
   * Only a comment that is *itself* a reply (`replyLevel` >= 1) has its
   * children flattened. A top-level comment's inline children stay where they
   * were before, unlisted: flattening them would put replies among the
   * top-level comments of the main list.
   */
  const collectThread = (item: any): void => {
    const vm = get(item, 'commentThreadRenderer', 'commentViewModel', 'commentViewModel') as any;
    if (!vm) {
      log.warn(`${context}: commentThreadRenderer with no commentViewModel, skipping`);
      return;
    }

    const entity = store.get<any>(vm.commentKey);
    if (!entity) return; // already logged by EntityStore.get itself

    const props = entity.properties;
    const author = entity.author;
    if (!props || !author) {
      log.warn(`${context}: comment entity ${vm.commentKey} missing properties or author, skipping`);
      return;
    }

    let replyToken: string | null = null;
    let replyCount = 0;
    const subThreads = get(item, 'commentThreadRenderer', 'replies', 'commentRepliesRenderer', 'subThreads');
    const subs: any[] = Array.isArray(subThreads) ? subThreads : [];
    for (const sub of subs) {
      const t = continuationToken(sub?.continuationItemRenderer);
      if (t) replyToken = t;
    }
    if (entity.toolbar?.replyCount) {
      replyCount = parseInt(entity.toolbar.replyCount.replace(/\D/g, ''), 10) || 0;
    }

    const { replyParams, deleteParams } = extractSurfaceCommands(store, vm.toolbarSurfaceKey);

    items.push({
      id: props.commentId || '',
      authorName: author.displayName || '',
      authorAvatarUrl: author.avatarThumbnailUrl || '',
      authorChannelId: author.channelId || null,
      isUploader: !!author.isCreator,
      isVerified: !!author.isVerified,
      text: parseCommentText(props.content),
      likeCount: entity.toolbar?.likeCountNotliked || null,
      publishedText: props.publishedTime || null,
      replyCount: replyCount,
      isLiked: !!entity.toolbar?.isLiked,
      creatorHearted: !!entity.toolbar?.heartedTooltipA11y || !!entity.toolbar?.heartActiveTooltip,
      isPinned: !!props.pinnedText,
      repliesContinuation: replyToken,
      replyParams,
      deleteParams,
    });

    if (Number(props.replyLevel) >= 1) {
      for (const sub of subs) {
        if (sub?.commentThreadRenderer) collectThread(sub);
      }
    }
  };

  // Search for endpoints in onResponseReceivedEndpoints
  const endpoints = get(root, 'onResponseReceivedEndpoints');
  if (Array.isArray(endpoints)) {
    for (const ep of endpoints) {
      const actions = ep.reloadContinuationItemsCommand?.continuationItems || ep.appendContinuationItemsAction?.continuationItems;
      if (!Array.isArray(actions)) continue;

      for (const item of actions) {
        // Look for chips in header
        if (item.commentsHeaderRenderer) {
          const countRuns = get(item, 'commentsHeaderRenderer', 'countText', 'runs');
          if (Array.isArray(countRuns)) {
            commentCount = countRuns.map((r: any) => r.text ?? '').join('');
          }

          // The "Add a comment…" box's own submit endpoint. Present only for a
          // signed-in viewer — an anonymous one gets a `prepareAccountEndpoint`
          // (a sign-in prompt) in its place — and only on a page that carries
          // the header at all, so continuation pages leave it null.
          const created = str(
            get(
              item, 'commentsHeaderRenderer', 'createRenderer', 'commentSimpleboxRenderer', 'submitButton',
              'buttonRenderer', 'serviceEndpoint', 'createCommentEndpoint', 'createCommentParams',
            ),
          );
          if (created) createParams = created;

          const subMenuItems = get(item, 'commentsHeaderRenderer', 'sortMenu', 'sortFilterSubMenuRenderer', 'subMenuItems');
          if (Array.isArray(subMenuItems)) {
            for (const menu of subMenuItems) {
              const label = menu.title;
              const token = str(get(menu, 'serviceEndpoint', 'continuationCommand', 'token'));
              if (label && token) {
                chips.push({
                  label,
                  token,
                  selected: !!menu.selected,
                  scope: 'feed',
                });
              }
            }
          }
        }

        // Look for continuation token at bottom
        if (item.continuationItemRenderer) {
          const token = continuationToken(item.continuationItemRenderer);
          if (token) continuation = token;
        }

        // Look for comment thread
        if (item.commentThreadRenderer) collectThread(item);
      }
    }
  }

  return { items, continuation, chips: chips.length > 0 ? chips : undefined, commentCount, createParams };
}
