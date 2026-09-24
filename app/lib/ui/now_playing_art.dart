import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'playback_controller.dart';
import 'video_info.dart';

/// The best still there is for what is playing, or null.
///
/// The song's cover when YouTube credits one (`VideoDetail.music`), else the
/// video's poster (`PlaybackSource.posterUrl`), else the tile's thumbnail —
/// best first. The tile's is last because it is whatever the surface that
/// listed the video happened to ship, which on the watch page's related rail is
/// 480x360, and there is no bigger one to ask for (`architecture.md` F40).
///
/// **One resolver, read by everything that shows artwork for the current
/// track** — the audio-only layout and the Windows media flyout — so the two
/// cannot pick different images for the same song.
///
/// `isCover` says which kind it found, because they are different shapes: a
/// cover is square, and everything after it is a still from the video, 16:9.
typedef NowPlayingArt = ({String url, bool isCover});

final nowPlayingArtProvider = Provider<NowPlayingArt?>((ref) {
  final item = ref.watch(playbackProvider.select((p) => p.item));
  if (item == null) return null;
  final poster = ref.watch(playbackProvider.select((p) => p.source?.posterUrl));
  // Loads after the stream does; until then the poster or thumbnail stands in,
  // and this re-resolves when the credits arrive.
  final cover = ref
      .watch(videoInfoProvider(item.id))
      .value
      ?.music
      .firstOrNull
      ?.coverUrl;
  if (cover != null && cover.isNotEmpty) return (url: cover, isCover: true);
  for (final url in [poster, item.thumbnailUrl]) {
    if (url != null && url.isNotEmpty) return (url: url, isCover: false);
  }
  return null;
});
