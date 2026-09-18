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
    @Default(false) bool isLiked,
    @Default(false) bool creatorHearted,
    @Default(false) bool isPinned,
    String? repliesContinuation,
    String? replyParams,
    String? deleteParams,
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
