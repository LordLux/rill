import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/comment.dart';
import 'rpc/client.dart';

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
}

final commentsSourceProvider = Provider<CommentsSource>((ref) => const RpcCommentsSource());
