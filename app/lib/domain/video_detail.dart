import 'feed_item.dart';
import 'caption_track.dart';

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
class VideoDetail {
  final String id;
  final String title;
  final String? description;
  final String channelName;
  final String? channelId;
  final String? channelAvatarUrl;
  final String? subscriberText;
  final int? durationSeconds;
  final bool isLive;
  final String? viewCountText;
  final String? publishedText;
  final String? likeText;
  final bool isSubscribed;
  final List<String> badges;
  /// When a premiere starts, unix ms. The watch page's slate reads this;
  /// `playback.open`'s `VIDEO_UPCOMING` says only *that* it is a premiere.
  final int? premiereAtMs;
  final List<FeedItem> related;
  final String? relatedContinuation;
  final List<CaptionTrack> captionTracks;

  const VideoDetail({
    required this.id,
    required this.title,
    this.description,
    required this.channelName,
    this.channelId,
    this.channelAvatarUrl,
    this.subscriberText,
    this.durationSeconds,
    required this.isLive,
    this.viewCountText,
    this.publishedText,
    this.likeText,
    required this.isSubscribed,
    this.badges = const [],
    this.premiereAtMs,
    this.related = const [],
    this.relatedContinuation,
    this.captionTracks = const [],
  });

  factory VideoDetail.fromJson(Map<String, dynamic> json) {
    return VideoDetail(
      id: json['id'] as String,
      title: json['title'] as String,
      description: json['description'] as String?,
      channelName: json['channelName'] as String,
      channelId: json['channelId'] as String?,
      channelAvatarUrl: json['channelAvatarUrl'] as String?,
      subscriberText: json['subscriberText'] as String?,
      durationSeconds: json['durationSeconds'] as int?,
      isLive: json['isLive'] as bool,
      viewCountText: json['viewCountText'] as String?,
      publishedText: json['publishedText'] as String?,
      likeText: json['likeText'] as String?,
      isSubscribed: json['isSubscribed'] as bool,
      badges: (json['badges'] as List<dynamic>?)?.map((e) => e as String).toList() ?? const [],
      premiereAtMs: json['premiereAtMs'] as int?,
      related: (json['related'] as List<dynamic>?)?.map((e) => FeedItem.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
      relatedContinuation: json['relatedContinuation'] as String?,
      captionTracks: (json['captionTracks'] as List<dynamic>?)?.map((e) => CaptionTrack.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
    );
  }

  /// The line under the title: view count and age, whichever of them exists.
  String? get metaLine {
    final parts = [viewCountText, publishedText].whereType<String>();
    return parts.isEmpty ? null : parts.join(' • ');
  }

  VideoDetail copyWith({
    String? id,
    String? title,
    String? description,
    String? channelName,
    String? channelId,
    String? channelAvatarUrl,
    String? subscriberText,
    int? durationSeconds,
    bool? isLive,
    String? viewCountText,
    String? publishedText,
    String? likeText,
    bool? isSubscribed,
    List<String>? badges,
    int? premiereAtMs,
    List<FeedItem>? related,
    String? relatedContinuation,
    List<CaptionTrack>? captionTracks,
  }) {
    return VideoDetail(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      channelName: channelName ?? this.channelName,
      channelId: channelId ?? this.channelId,
      channelAvatarUrl: channelAvatarUrl ?? this.channelAvatarUrl,
      subscriberText: subscriberText ?? this.subscriberText,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      isLive: isLive ?? this.isLive,
      viewCountText: viewCountText ?? this.viewCountText,
      publishedText: publishedText ?? this.publishedText,
      likeText: likeText ?? this.likeText,
      isSubscribed: isSubscribed ?? this.isSubscribed,
      badges: badges ?? this.badges,
      premiereAtMs: premiereAtMs ?? this.premiereAtMs,
      related: related ?? this.related,
      relatedContinuation: relatedContinuation ?? this.relatedContinuation,
      captionTracks: captionTracks ?? this.captionTracks,
    );
  }
}
