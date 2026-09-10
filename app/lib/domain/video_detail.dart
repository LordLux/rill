import 'package:freezed_annotation/freezed_annotation.dart';

import 'feed_item.dart';

part 'video_detail.freezed.dart';
part 'video_detail.g.dart';

/// `video.info`'s result — `protocol.md` §3.3, mirroring the sidecar's
/// `VideoDetail` field for field.
///
/// Dumb by design (hard invariant 6): the sidecar walked the renderer tree and
/// emitted this flat shape, and nothing here interprets anything. `related`
/// holds the same [FeedItem]s the feed does, which is what lets the watch page
/// reuse `MediaTile` rather than growing a second tile widget.
///
/// `durationSeconds` is nullable and means two different things: `null` with
/// `isLive` is a live stream that has no final duration, and `null` without it
/// is a `/player` response the sidecar could not get — the watch page shows the
/// player's own duration in both cases, so neither is a dead end.
@freezed
abstract class VideoDetail with _$VideoDetail {
  const VideoDetail._();

  const factory VideoDetail({
    required String id,
    required String title,
    String? description,
    required String channelName,
    String? channelId,
    String? channelAvatarUrl,
    String? subscriberText,
    int? durationSeconds,
    required bool isLive,
    String? viewCountText,
    String? publishedText,
    String? likeText,
    required bool isSubscribed,
    @Default(false) bool isVerified,
    @Default(false) bool isArtistChannel,
    @Default(<String>[]) List<String> badges,
    /// Members-only content. Same badge and same rule as
    /// `FeedItem.video.isMembersOnly`, read off the watch page.
    ///
    /// This is what the members slate is drawn from — it is structural, where
    /// the `playback.open` failure's message is localised prose.
    @Default(false) bool isMembersOnly,
    /// When a premiere starts, unix ms. The watch page's slate reads this;
    /// `playback.open`'s `VIDEO_UPCOMING` says only *that* it is a premiere.
    int? premiereAtMs,
    @Default(<FeedItem>[]) List<FeedItem> related,
    String? relatedContinuation,
  }) = _VideoDetail;

  factory VideoDetail.fromJson(Map<String, Object?> json) => _$VideoDetailFromJson(json);

  /// The line under the title: view count and age, whichever of them exists.
  String? get metaLine {
    final parts = [viewCountText, publishedText].whereType<String>();
    return parts.isEmpty ? null : parts.join(' • ');
  }
}
