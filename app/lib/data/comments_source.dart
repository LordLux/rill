import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/comment.dart';
import 'rpc/client.dart';

/// The longest comment YouTube will take, **measured 2026-09-21** rather than
/// read from documentation: `comment/create_comment` accepts 10,000 characters
/// and refuses 10,001 with an HTTP 4xx. It appears in no response — the create
/// box ships no `maxCharacterLimit` — so both sides write it down, and the
/// sidecar's `COMMENT_MAX_LENGTH` is the one that actually guards the wire.
const kCommentMaxLength = 10000;

/// One page of comments on its way: the id to `$cancel` it by, and its answer.
///
/// A cancelled request's [response] never completes — the transport's contract
/// (`RpcClient.callCancelable`) — so a caller must move on by its own signal,
/// never by waiting for it.
typedef CommentsPageRequest = ({int id, Future<CommentsResult> response});

/// Where comment pages come from: the sidecar in the app, a fake in a test.
///
/// `RpcClient` is a singleton with no seam, which is why the widgets that page
/// comments — the section and each thread's replies — had no test of their own.
/// They ask this instead, and the one rule that lives in their state, *a
/// superseded page must never be merged in*, can be tested without a sidecar.
abstract class CommentsSource {
  /// The page [continuation] names — a page of threads, a re-sorted list, or one
  /// thread's replies; they are all `video.comments {continuation}`.
  CommentsPageRequest page(String continuation);

  /// Releases the sidecar from a request nobody wants any more. Best-effort: a
  /// response already on the wire still arrives, which is what the caller's
  /// generation guard is for.
  void cancel(int id);

  // --- Writes ---------------------------------------------------------------
  //
  // The same seam, for the same reason. These went straight to
  // `RpcClient.instance` until 2026-09-21, so every rule that lives around them
  // — the guard that stops a posted comment landing in another video's list,
  // the optimistic vote and its revert — had no test at all (`todo.md` 39.5).
  // Voting made that worse rather than better: it was a fourth action on the
  // untestable path, and the one whose failure is *least* visible, because a
  // vote that silently does not stick looks exactly like a vote that did.

  /// Posts a top-level comment and answers the created one, which carries a
  /// real id and its own delete and reply tokens. Null when the response held
  /// no comment — the caller then stands in a local one.
  Future<Comment?> post(String createParams, String text);

  /// Replies to a comment. Answers nothing: `action.replyToComment` still
  /// returns `{}` (`todo.md` 39.2), so the caller stands in a local reply.
  Future<void> reply(String replyParams, String text);

  Future<void> delete(String deleteParams);

  /// Votes, by sending one of the comment's four server-supplied blobs
  /// verbatim. The *caller* picks which, because it holds the rating the
  /// viewer is looking at.
  Future<void> rate(String params);
}

class RpcCommentsSource implements CommentsSource {
  const RpcCommentsSource();

  @override
  CommentsPageRequest page(String continuation) {
    final request = RpcClient.instance.callCancelable('video.comments', {'continuation': continuation});
    return (id: request.id, response: request.response.then((raw) => CommentsResult.fromJson(raw)));
  }

  @override
  void cancel(int id) => RpcClient.instance.cancel(id);

  @override
  Future<Comment?> post(String createParams, String text) async {
    final response = await RpcClient.instance.call('action.postComment', {
      'createParams': createParams,
      'commentText': text,
    });
    final created = response is Map ? response['comment'] : null;
    return created is Map ? Comment.fromJson(Map<String, Object?>.from(created)) : null;
  }

  @override
  Future<void> reply(String replyParams, String text) =>
      RpcClient.instance.call('action.replyToComment', {'replyParams': replyParams, 'commentText': text});

  @override
  Future<void> delete(String deleteParams) =>
      RpcClient.instance.call('action.deleteComment', {'deleteParams': deleteParams});

  @override
  Future<void> rate(String params) => RpcClient.instance.call('action.rateComment', {'params': params});
}

final commentsSourceProvider = Provider<CommentsSource>((ref) => const RpcCommentsSource());
