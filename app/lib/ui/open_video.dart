import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/feed_item.dart';
import 'player_shell.dart';
import 'queue_controller.dart';

/// What a tile tap means, per kind (task §6).
///
/// One function rather than a handler per surface, because the feed, the related
/// rail and the queue panel all draw the same tiles and must all behave the
/// same. Anything that cannot be watched is inert: no navigation, no error, no
/// dead route.
void openFromTile(WidgetRef ref, FeedItem item) {
  final video = watchTargetFor(item);
  if (video == null) return;
  openWatch(ref, video);
}

/// Add to the queue from a tile, for the kinds that can be queued.
void queueFromTile(WidgetRef ref, FeedItem item) {
  final video = watchTargetFor(item);
  if (video == null) return;
  ref.read(queueProvider.notifier).addToQueue(video);
}

/// The video a tile opens, or null if the tile is not watchable.
///
/// - `video` is itself.
/// - `mix` opens its **seed** video, which is as far as this task goes:
///   `mix.start` is a later task, and §6 says opening the first video is enough.
/// - `playlist` is explicitly out of scope and stays inert.
/// - `channel` and anything unknown have nothing to play.
VideoItem? watchTargetFor(FeedItem item) {
  return item.map(
    video: (v) => v,
    mix: (m) {
      final seed = mixSeedVideoId(m);
      if (seed == null) return null;
      return VideoItem(
        kind: 'video',
        id: seed,
        title: m.title,
        channelName: m.subtitle ?? '',
        thumbnailUrl: m.thumbnailUrl,
        isLive: false,
        canWatchLater: false,
        canAddToQueue: false,
      );
    },
    playlist: (_) => null,
    channel: (_) => null,
    unknown: (_) => null,
  );
}

/// The video a mix starts from, derived rather than carried.
///
/// **`MixItem` cannot represent this.** The DTO holds the `RD…` playlist id, a
/// title, a subtitle, a thumbnail and a count — nothing that is a video id. That
/// is a genuine gap in the shared contract, and widening it unilaterally is
/// exactly what this task's stop conditions forbid, so this derives what it can
/// instead and gives up honestly when it cannot:
///
///  1. **The thumbnail.** A mix tile's artwork is one of its videos, and the URL
///     is `…/vi/<videoId>/…`. This is the general case — it holds for curated
///     `RDCLAK…` and `RDMM…` mixes too, where the id is not in the playlist id
///     at all.
///  2. **The playlist id.** An auto-generated radio is literally `RD` + the seed
///     video id, so an 11-character remainder is that id.
///
/// Returns null when neither applies, and the tile stays inert rather than
/// navigating to a video that does not exist.
String? mixSeedVideoId(MixItem mix) {
  final fromThumbnail = RegExp(r'/vi(?:_webp)?/([A-Za-z0-9_-]{11})/').firstMatch(mix.thumbnailUrl);
  if (fromThumbnail != null) return fromThumbnail.group(1);

  if (mix.id.startsWith('RD')) {
    final remainder = mix.id.substring(2);
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(remainder)) return remainder;
  }
  return null;
}
