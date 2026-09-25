import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/now_playing_track.dart';
import 'playback_controller.dart';
import 'video_info.dart';

/// Which chapter of [videoId] is playing, rebuilding only when it changes.
///
/// From `positionStream`, never a property read (hard invariant 9), and mapped
/// through `distinct` here rather than in the widgets: the stream ticks several
/// times a second, and a chapter boundary is a few times an hour. Null for a
/// video with fewer than two chapters, which is not a segmentation.
///
/// Seeks need nothing special — the next position event lands in the right
/// chapter, and the index simply jumps.
final _chapterIndexProvider = StreamProvider.autoDispose.family<int?, String>((ref, videoId) async* {
  final chapters = ref.watch(videoInfoProvider(videoId).select((info) => info.value?.chapters));
  if (chapters == null || chapters.length < 2) {
    yield null;
    return;
  }
  final engine = ref.watch(playbackEngineProvider);
  var last = chapterIndexAt(chapters, engine.position);
  yield last;
  await for (final position in engine.positionStream) {
    final index = chapterIndexAt(chapters, position);
    if (index == last) continue;
    last = index;
    yield index;
  }
});

/// What is playing right now — title, artist, album, cover, backdrop.
///
/// **The one resolver every now-playing surface reads**: the audio-only layout,
/// its backdrop and the Windows media flyout. See [resolveNowPlaying] for the
/// rules; this only feeds it.
final nowPlayingTrackProvider = Provider<NowPlayingTrack?>((ref) {
  final item = ref.watch(playbackProvider.select((p) => p.item));
  if (item == null) return null;
  // Loads after the stream does; until then the tile's own title stands in, and
  // this re-resolves when the credits and chapters arrive.
  final detail = ref.watch(videoInfoProvider(item.id)).value;
  final chapterIndex = ref.watch(_chapterIndexProvider(item.id)).value;

  final channelName = detail?.channelName ?? item.channelName;
  final isMusicVideo =
      item.isMusic || item.isArtistChannel || (detail?.isArtistChannel ?? false) || isTopicChannel(channelName);

  return resolveNowPlaying(
    videoTitle: detail?.title ?? item.title,
    channelName: channelName,
    isMusicVideo: isMusicVideo,
    music: detail?.music ?? const [],
    chapters: detail?.chapters ?? const [],
    chapterIndex: chapterIndex,
  );
});

/// The best still there is for what is playing, or null.
///
/// The song's cover when a credit is believed for this moment
/// ([NowPlayingTrack.coverUrl]), else the video's poster
/// (`PlaybackSource.posterUrl`), else the tile's thumbnail — best first. The
/// tile's is last because it is whatever the surface that listed the video
/// happened to ship, which on the watch page's related rail is 480x360, and
/// there is no bigger one to ask for (`architecture.md` F40).
///
/// `isCover` says which kind it found, because they are different shapes: a
/// cover is square, and everything after it is a still from the video, 16:9.
typedef NowPlayingArt = ({String url, bool isCover});

final nowPlayingArtProvider = Provider<NowPlayingArt?>((ref) {
  final item = ref.watch(playbackProvider.select((p) => p.item));
  if (item == null) return null;
  final poster = ref.watch(playbackProvider.select((p) => p.source?.posterUrl));
  final cover = ref.watch(nowPlayingTrackProvider.select((t) => t?.coverUrl));
  if (cover != null && cover.isNotEmpty) return (url: cover, isCover: true);
  for (final url in [poster, item.thumbnailUrl]) {
    if (url != null && url.isNotEmpty) return (url: url, isCover: false);
  }
  return null;
});

/// The image behind the audio-only layout, which is blurred to nothing.
///
/// The current chapter's frame when the chapters are songs — it changes with the
/// song, which is the point, and its 336x188 is invisible under the blur where
/// it would be a smear as a cover. Otherwise the poster, then the tile's
/// thumbnail, as before.
final nowPlayingBackdropProvider = Provider<String?>((ref) {
  final chapterFrame = ref.watch(nowPlayingTrackProvider.select((t) => t?.backdropUrl));
  if (chapterFrame != null && chapterFrame.isNotEmpty) return chapterFrame;
  final poster = ref.watch(playbackProvider.select((p) => p.source?.posterUrl));
  return poster ?? ref.watch(playbackProvider.select((p) => p.item?.thumbnailUrl));
});
