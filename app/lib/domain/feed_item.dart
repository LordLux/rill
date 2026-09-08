import 'package:freezed_annotation/freezed_annotation.dart';

part 'feed_item.freezed.dart';
part 'feed_item.g.dart';

@Freezed(unionKey: 'kind', fallbackUnion: 'unknown')
sealed class FeedItem with _$FeedItem {

  @FreezedUnionValue('video')
  const factory FeedItem.video({
    required String kind,
    required String id,
    required String title,
    required String channelName,
    String? channelId,
    String? channelAvatarUrl,
    required String thumbnailUrl,
    int? durationSeconds,
    required bool isLive,
    String? viewCountText,
    String? publishedText,
    String? descriptionSnippet,
    @Default([]) List<String> badges,
    /// A Short, classified rather than stripped (Task 21 §1) — the ordinary
    /// videoRenderer/lockupViewModel shape carrying a SHORTS-styled duration
    /// overlay. The dedicated Shorts shelf is a different renderer entirely
    /// and never reaches this DTO.
    @Default(false) bool isShort,
    /// The ♪ on YouTube's own duration badge, per video — distinct from
    /// [isArtistChannel], which is per channel and can disagree with this.
    @Default(false) bool isMusic,
    /// The uploading channel's verified checkmark.
    @Default(false) bool isVerified,
    /// The uploading channel's "Official Artist Channel" badge.
    @Default(false) bool isArtistChannel,
    /// When a premiere starts, unix ms — null for everything already published.
    ///
    /// Carried on the tile so a card can offer a reminder without a `/player`
    /// call per item.
    int? premiereAtMs,
    required bool canWatchLater,
    required bool canAddToQueue,
  }) = VideoItem;

  @FreezedUnionValue('mix')
  const factory FeedItem.mix({
    required String kind,
    required String id,
    required String title,
    String? subtitle,
    required String thumbnailUrl,
    int? videoCount,
  }) = MixItem;

  @FreezedUnionValue('playlist')
  const factory FeedItem.playlist({
    required String kind,
    required String id,
    required String title,
    required String thumbnailUrl,
    int? videoCount,
    String? channelName,
  }) = PlaylistItem;

  @FreezedUnionValue('channel')
  const factory FeedItem.channel({
    required String kind,
    required String id,
    required String name,
    required String avatarUrl,
    String? subscriberText,
    String? descriptionSnippet,
    @Default(false) bool isVerified,
    @Default(false) bool isArtistChannel,
  }) = ChannelItem;

  @FreezedUnionValue('unknown')
  const factory FeedItem.unknown({
    @Default('unknown') String kind,
  }) = UnknownItem;

  factory FeedItem.fromJson(Map<String, Object?> json) => _$FeedItemFromJson(json);
}

@freezed
abstract class Chip with _$Chip {
  const Chip._();
  const factory Chip({
    required String label,
    required String token,
    required bool selected,
    required String scope,
  }) = _Chip;

  factory Chip.fromJson(Map<String, Object?> json) => _$ChipFromJson(json);
}
