import { get, type WalkNode } from './tree.ts';
import { EntityStore } from './entities.ts';
import type { Comment, CommentsResult, CommentText, CommentStyleRun, CommentCommandRun, Chip } from '../types.ts';
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

export function parseComments(root: any, context: string): CommentsResult {
  const store = new EntityStore(root);
  const items: Comment[] = [];
  let continuation: string | null = null;
  const chips: Chip[] = [];
  let commentCount: string | null = null;

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

          const subMenuItems = get(item, 'commentsHeaderRenderer', 'sortMenu', 'sortFilterSubMenuRenderer', 'subMenuItems');
          if (Array.isArray(subMenuItems)) {
            for (const menu of subMenuItems) {
              const label = menu.title;
              const token = get(menu, 'serviceEndpoint', 'continuationCommand', 'token');
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
          const token = get(item, 'continuationItemRenderer', 'continuationEndpoint', 'continuationCommand', 'token');
          if (token) continuation = token;
        }

        // Look for comment thread
        if (item.commentThreadRenderer) {
          const vm = get(item, 'commentThreadRenderer', 'commentViewModel', 'commentViewModel');
          if (!vm) continue;
          
          const entity = store.get<any>(vm.commentKey);
          if (!entity) continue;
          
          const props = entity.properties;
          const author = entity.author;
          if (!props || !author) continue;

          // Find reply continuation
          let replyToken: string | null = null;
          let replyCount = 0;
          const repliesRenderer = get(item, 'commentThreadRenderer', 'replies', 'commentRepliesRenderer');
          if (repliesRenderer && Array.isArray(repliesRenderer.subThreads)) {
            for (const sub of repliesRenderer.subThreads) {
              const t = get(sub, 'continuationItemRenderer', 'continuationEndpoint', 'continuationCommand', 'token');
              if (t) replyToken = t;
            }
          }
          if (entity.toolbar?.replyCount) {
            replyCount = parseInt(entity.toolbar.replyCount.replace(/\D/g, ''), 10) || 0;
          }

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
          });
        }
        
        // Inline replies from appendContinuationItemsAction might just be commentViewModel?
        // Wait, replies inside `appendContinuationItemsAction` are wrapped in `commentRenderer`? No, they are `commentViewModel`s?
        // In my check, they were wrapped in `commentThreadRenderer` even for replies? No, let's verify.
      }
    }
  }

  return { items, continuation, chips: chips.length > 0 ? chips : undefined, commentCount };
}
