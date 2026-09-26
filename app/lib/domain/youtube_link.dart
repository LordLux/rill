import 'feed_item.dart';

final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// The id of the one video a pasted YouTube link points at, or null when [text]
/// is anything else — a search, a playlist, a channel, another site.
///
/// **A link and nothing else.** "watch this https://youtu.be/…" is a sentence,
/// and a sentence is a search. Accepted shapes: `watch?v=`, `/shorts/`, `/live/`,
/// `/embed/` and `/v/` on youtube.com and its `www.`, `m.` and `music.`
/// subdomains, and `youtu.be/`; with or without a scheme, and with any trailing
/// `?feature=share`, `&t=` or `&si=` ignored. Anything after the id in the path
/// is too.
///
/// A `watch?v=…&list=…` link is the video; the playlist is not opened.
String? videoIdFromLink(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;

  final uri = Uri.tryParse(trimmed.contains('://') ? trimmed : 'https://$trimmed');
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;

  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();

  final String? candidate;
  if (host == 'youtu.be') {
    candidate = segments.firstOrNull;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    candidate = switch (segments) {
      ['watch', ...] => uri.queryParameters['v'],
      ['shorts' || 'live' || 'embed' || 'v', final id, ...] => id,
      _ => null,
    };
  } else {
    candidate = null;
  }

  return candidate != null && _videoId.hasMatch(candidate) ? candidate : null;
}

/// What a tile would have supplied. `video.info` replaces every one of these a
/// moment later; this is only what the page shows meanwhile.
VideoItem placeholderVideoItem(String videoId) => VideoItem(
      kind: 'video',
      id: videoId,
      title: videoId,
      channelName: '',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: false,
      canAddToQueue: false,
    );
