import 'package:freezed_annotation/freezed_annotation.dart';
import 'feed_item.dart';

part 'comment.freezed.dart';
part 'comment.g.dart';

@freezed
abstract class CommentTextRun with _$CommentTextRun {
  const CommentTextRun._();
  const factory CommentTextRun({
    required int startIndex,
    required int length,
  }) = _CommentTextRun;

  factory CommentTextRun.fromJson(Map<String, Object?> json) => _$CommentTextRunFromJson(json);
}

@freezed
abstract class CommentStyleRun with _$CommentStyleRun {
  const CommentStyleRun._();
  const factory CommentStyleRun({
    required int startIndex,
    required int length,
    String? weightLabel,
  }) = _CommentStyleRun;

  factory CommentStyleRun.fromJson(Map<String, Object?> json) => _$CommentStyleRunFromJson(json);
}

@freezed
abstract class CommentCommandRun with _$CommentCommandRun {
  const CommentCommandRun._();
  const factory CommentCommandRun({
    required int startIndex,
    required int length,
    String? url,
    String? videoId,
    int? startTimeSeconds,
  }) = _CommentCommandRun;

  factory CommentCommandRun.fromJson(Map<String, Object?> json) => _$CommentCommandRunFromJson(json);
}

@freezed
abstract class CommentText with _$CommentText {
  const CommentText._();
  const factory CommentText({
    required String content,
    List<CommentStyleRun>? styleRuns,
    List<CommentCommandRun>? commandRuns,
  }) = _CommentText;

  factory CommentText.fromJson(Map<String, Object?> json) => _$CommentTextFromJson(json);
}

@freezed
abstract class Comment with _$Comment {
  const Comment._();
  const factory Comment({
    required String id,
    required String authorName,
    required String authorAvatarUrl,
    String? authorChannelId,
    @Default(false) bool isUploader,
    @Default(false) bool isVerified,
    required CommentText text,
    String? likeCount,
    String? publishedText,
    required int replyCount,

    /// This viewer's vote — `'like'`, `'dislike'` or `'none'`, and `'none'`
    /// whenever anonymous.
    ///
    /// One field rather than two booleans, matching the wire: all three come
    /// off `engagementToolbarStateEntityPayload.likeState`, and two booleans
    /// would admit liked-and-disliked, which YouTube cannot produce. Same
    /// reasoning and same values as `VideoDetail.myRating`, so the app has one
    /// rating model and not two.
    ///
    /// Defaulting to `'none'` is safe but load-bearing: it is also what a
    /// *missing* key produces, which is how the rename from `isLiked` went
    /// unnoticed here until `contract_test.dart` grew a `Comment` group.
    @Default('none') String myRating,
    @Default(false) bool creatorHearted,
    @Default(false) bool isPinned,
    String? repliesContinuation,
    String? replyParams,
    String? deleteParams,

    /// The four vote transitions, each an opaque blob the *server* supplies for
    /// `action.rateComment`. The client sends whichever one matches the
    /// transition it wants; nothing is built here.
    ///
    /// **Non-null is not permission to vote** — all four are present on
    /// anonymous pages too. Gate on the session, never on these.
    String? likeParams,
    String? unlikeParams,
    String? dislikeParams,
    String? undislikeParams,
  }) = _Comment;

  factory Comment.fromJson(Map<String, Object?> json) => _$CommentFromJson(json);
}

@freezed
abstract class CommentsResult with _$CommentsResult {
  const CommentsResult._();
  const factory CommentsResult({
    @Default([]) List<Comment> items,
    String? continuation,
    List<Chip>? chips,
    String? commentCount,
    String? createParams,
  }) = _CommentsResult;

  factory CommentsResult.fromJson(Map<String, Object?> json) => _$CommentsResultFromJson(json);
}
