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
  final uri = _webLink(text);
  if (uri == null) return null;

  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();

  final String? candidate;
  if (host == 'youtu.be') {
    candidate = segments.firstOrNull;
  } else if (_isYoutube(host)) {
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

final _playlistId = RegExp(r'^[A-Za-z0-9_-]{2,}$');

/// The id of the playlist a pasted `youtube.com/playlist?list=…` link points
/// at, or null when [text] is anything else.
///
/// The same "a link and nothing else" rule as [videoIdFromLink], and the same
/// hosts. Only the playlist's own address: a `watch?v=…&list=…` link is the
/// video. A mix (`RD…`) is not a playlist with a page, so its link is not one.
String? playlistIdFromLink(String text) {
  final uri = _webLink(text);
  if (uri == null || !_isYoutube(uri.host.toLowerCase())) return null;

  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
  if (segments.length != 1 || segments.single != 'playlist') return null;

  final id = uri.queryParameters['list'];
  if (id == null || !_playlistId.hasMatch(id) || id.startsWith('RD')) return null;
  return id;
}

bool _isYoutube(String host) => host == 'youtube.com' || host.endsWith('.youtube.com');

/// [text] as a web address, when it is one and nothing else.
Uri? _webLink(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;

  final uri = Uri.tryParse(trimmed.contains('://') ? trimmed : 'https://$trimmed');
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  return uri;
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
