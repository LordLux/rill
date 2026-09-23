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
/// `VideoDetail.myRating` — `docs/protocol.md` §3.3. A closed set rather than
/// two independent booleans: `isLiked`/`isDisliked` both `true` at once is a
/// state YouTube cannot produce, so the type should not admit it either. The
/// enum's own names match the wire strings the sidecar sends (`'like'` /
/// `'dislike'` / `'none'`), so json_serializable needs no converter.
enum VideoRating { like, dislike, none }

/// A song YouTube credits on a watch page — `protocol.md` §3.3.
///
/// Nested rather than four fields on [VideoDetail], because the four are
/// jointly present or jointly absent: flat ones would encode a constraint the
/// type cannot express.
///
/// `coverUrl` arrives **already sized** by the sidecar; the client appends
/// nothing to it (§3.7's rule).
@freezed
abstract class MusicTrack with _$MusicTrack {
  const factory MusicTrack({
    @Default('') String title,
    String? artist,
    String? album,
    String? coverUrl,
  }) = _MusicTrack;

  factory MusicTrack.fromJson(Map<String, Object?> json) => _$MusicTrackFromJson(json);
}

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

    /// The exact view count as a number, when the exact number is knowable.
    ///
    /// Derived from [viewCountText] — the string the tooltip shows — so the
    /// short form and the exact one always agree. `null` means it is genuinely
    /// not recoverable, such as a layout that only gave a rounded string like
    /// "1.8M views", and the caller should show [viewCountText] unchanged
    /// rather than shortening something already short.
    int? viewCount,
    String? publishedText,

    /// The exact upload date ("Dec 6, 2009"), for a tooltip on
    /// [publishedText]'s relative one ("14 years ago") — the sidecar carries
    /// both as siblings off the same renderer, not as alternatives. Null when
    /// the layout carries no exact date at all.
    String? publishedDateText,
    String? likeText,
    required VideoRating myRating,
    required bool isSubscribed,
    @Default(false) bool isVerified,
    @Default(false) bool isArtistChannel,
    @Default(<String>[]) List<String> badges,

    /// Songs credited on this video, in YouTube's order.
    ///
    /// **Empty is the ordinary answer**, not a gap — most videos carry no
    /// attribution, so every path has to work without it.
    @Default(<MusicTrack>[]) List<MusicTrack> music,
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
    String? commentsContinuation,
  }) = _VideoDetail;

  factory VideoDetail.fromJson(Map<String, Object?> json) => _$VideoDetailFromJson(json);

  /// The line under the title: view count and age, whichever of them exists.
  String? get metaLine {
    final parts = [viewCountText, publishedText].whereType<String>();
    return parts.isEmpty ? null : parts.join(' • ');
  }
}
