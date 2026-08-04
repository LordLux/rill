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
    @Default([]) List<String> badges,
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
