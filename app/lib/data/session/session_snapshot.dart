import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What the app keeps of a session so the next start can put the viewer back (`docs/architecture.md` §2.17).
///
/// **Ids, titles and numbers, and nothing that was resolved:** no cookie, no stream URL (`playback.open` resolves
/// again), no response. A queue row needs a title and a thumbnail to read as itself before anything is fetched, so
/// those travel; they are public display strings, not account state.
///
/// Two parts, stored apart. The queue is large and changes rarely; the position changes every few seconds. One
/// blob would rewrite a playlist of hundreds of rows for every tick of the clock.

/// A snapshot older than this is ignored, whatever else is in it.
const Duration sessionSnapshotMaxAge = Duration(days: 7);

/// More rows than this are cut to a window around the playing one, and a list that was cut stops there
/// (its continuation would no longer follow the rows that are kept).
const int sessionSnapshotMaxEntries = 500;

class SnapshotVideo {
  const SnapshotVideo({
    required this.id,
    required this.title,
    required this.channelName,
    required this.thumbnailUrl,
    this.channelId,
    this.durationSeconds,
    this.isLive = false,
    this.isStation = false,
    this.isVerified = false,
    this.isArtistChannel = false,
  });

  final String id;
  final String title;
  final String channelName;
  final String thumbnailUrl;
  final String? channelId;
  final int? durationSeconds;
  final bool isLive;
  final bool isStation;
  final bool isVerified;
  final bool isArtistChannel;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'channelName': channelName,
        'thumbnailUrl': thumbnailUrl,
        'channelId': channelId,
        'durationSeconds': durationSeconds,
        'isLive': isLive,
        'isStation': isStation,
        'isVerified': isVerified,
        'isArtistChannel': isArtistChannel,
      };

  /// Null for anything that is not a video with an id: the row is dropped, not the snapshot.
  static SnapshotVideo? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return SnapshotVideo(
      id: id,
      title: raw['title'] is String ? raw['title'] as String : '',
      channelName: raw['channelName'] is String ? raw['channelName'] as String : '',
      thumbnailUrl: raw['thumbnailUrl'] is String ? raw['thumbnailUrl'] as String : '',
      channelId: raw['channelId'] is String ? raw['channelId'] as String : null,
      durationSeconds: raw['durationSeconds'] is int ? raw['durationSeconds'] as int : null,
      isLive: raw['isLive'] == true,
      isStation: raw['isStation'] == true,
      isVerified: raw['isVerified'] == true,
      isArtistChannel: raw['isArtistChannel'] == true,
    );
  }
}

/// The mix or playlist the queue was playing.
class SnapshotMix {
  const SnapshotMix({
    required this.playlistId,
    this.title,
    this.isPlaylist = false,
    this.exhausted = false,
    this.continuation,
    this.totalCount,
  });

  final String playlistId;
  final String? title;
  final bool isPlaylist;
  final bool exhausted;

  /// The next page's token. Opaque and server-issued; one that has expired costs the next page, which the queue
  /// reports the way any failed page is reported, and what is loaded plays on.
  final String? continuation;
  final int? totalCount;

  Map<String, Object?> toJson() => {
        'playlistId': playlistId,
        'title': title,
        'isPlaylist': isPlaylist,
        'exhausted': exhausted,
        'continuation': continuation,
        'totalCount': totalCount,
      };

  static SnapshotMix? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['playlistId'];
    if (id is! String || id.isEmpty) return null;
    return SnapshotMix(
      playlistId: id,
      title: raw['title'] is String ? raw['title'] as String : null,
      isPlaylist: raw['isPlaylist'] == true,
      exhausted: raw['exhausted'] == true,
      continuation: raw['continuation'] is String ? raw['continuation'] as String : null,
      totalCount: raw['totalCount'] is int ? raw['totalCount'] as int : null,
    );
  }
}

/// The queue and the list behind it.
class SnapshotQueue {
  const SnapshotQueue({required this.videos, required this.currentIndex, this.mix});

  final List<SnapshotVideo> videos;
  final int currentIndex;
  final SnapshotMix? mix;

  String encode() => jsonEncode({
        'v': SessionSnapshot.format,
        'videos': [for (final video in videos) video.toJson()],
        'current': currentIndex,
        'mix': mix?.toJson(),
      });

  /// A window of at most [sessionSnapshotMaxEntries] rows around the playing one.
  factory SnapshotQueue.windowed(List<SnapshotVideo> all, int currentIndex, SnapshotMix? mix) {
    if (all.length <= sessionSnapshotMaxEntries) return SnapshotQueue(videos: all, currentIndex: currentIndex, mix: mix);
    final start = (currentIndex - 50).clamp(0, all.length - sessionSnapshotMaxEntries);
    final end = start + sessionSnapshotMaxEntries;
    final cutTail = end < all.length;
    final cut = mix == null || !cutTail
        ? mix
        : SnapshotMix(
            playlistId: mix.playlistId,
            title: mix.title,
            isPlaylist: mix.isPlaylist,
            exhausted: true,
            totalCount: mix.totalCount,
          );
    return SnapshotQueue(videos: all.sublist(start, end), currentIndex: currentIndex - start, mix: cut);
  }

  /// Null for anything unreadable, or a queue with no playable current row.
  static SnapshotQueue? tryDecode(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != SessionSnapshot.format) return null;
      final rows = json['videos'];
      final current = json['current'];
      if (rows is! List || current is! int) return null;
      // A dropped row shifts every index after it, so the playing one is tracked by identity, not by number.
      final videos = <SnapshotVideo>[];
      var index = -1;
      for (var i = 0; i < rows.length; i++) {
        final video = SnapshotVideo.tryFromJson(rows[i]);
        if (video == null) continue;
        if (i == current) index = videos.length;
        videos.add(video);
      }
      if (index < 0) return null;
      return SnapshotQueue(videos: videos, currentIndex: index, mix: SnapshotMix.tryFromJson(json['mix']));
    } on Object {
      return null;
    }
  }
}

/// Where the viewer was.
enum SnapshotPageKind { home, watch, playlist, search }

class SnapshotPage {
  const SnapshotPage(this.kind, [this.argument]);

  static const SnapshotPage home = SnapshotPage(SnapshotPageKind.home);

  final SnapshotPageKind kind;

  /// The playlist id or the search text; null for the others.
  final String? argument;

  @override
  bool operator ==(Object other) => other is SnapshotPage && other.kind == kind && other.argument == argument;

  @override
  int get hashCode => Object.hash(kind, argument);
}

/// The part that changes while a video plays.
class SnapshotState {
  const SnapshotState({
    required this.positionMs,
    required this.page,
    required this.savedAtMs,
    this.volume,
    this.preferredHeight,
  });

  final int positionMs;
  final SnapshotPage page;
  final int savedAtMs;

  /// mpv's 0–100.
  final double? volume;
  final int? preferredHeight;

  String encode() => jsonEncode({
        'v': SessionSnapshot.format,
        'positionMs': positionMs,
        'page': page.kind.name,
        'pageArgument': page.argument,
        'savedAtMs': savedAtMs,
        'volume': volume,
        'preferredHeight': preferredHeight,
      });

  static SnapshotState? tryDecode(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != SessionSnapshot.format) return null;
      final saved = json['savedAtMs'];
      final position = json['positionMs'];
      if (saved is! int || position is! int) return null;
      final kind = SnapshotPageKind.values.where((k) => k.name == json['page']).firstOrNull ?? SnapshotPageKind.home;
      final argument = json['pageArgument'] is String ? json['pageArgument'] as String : null;
      // A page that needs its argument and has none is the home page.
      final page = (kind == SnapshotPageKind.playlist || kind == SnapshotPageKind.search) && (argument == null || argument.isEmpty)
          ? SnapshotPage.home
          : SnapshotPage(kind, argument);
      final volume = json['volume'];
      final height = json['preferredHeight'];
      return SnapshotState(
        positionMs: position < 0 ? 0 : position,
        page: page,
        savedAtMs: saved,
        volume: volume is num ? volume.toDouble().clamp(0.0, 100.0) : null,
        preferredHeight: height is int && height > 0 ? height : null,
      );
    } on Object {
      return null;
    }
  }
}

/// Both parts, read back.
class SessionSnapshot {
  const SessionSnapshot({required this.queue, required this.state});

  /// Bumped when the shape changes, so an old file is ignored rather than half understood.
  static const int format = 1;

  final SnapshotQueue queue;
  final SnapshotState state;

  /// Null when either part is missing or unreadable, or when the snapshot is older than [sessionSnapshotMaxAge].
  static SessionSnapshot? read({required String? queue, required String? state, required DateTime now}) {
    final q = SnapshotQueue.tryDecode(queue);
    final s = SnapshotState.tryDecode(state);
    if (q == null || s == null) return null;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(s.savedAtMs));
    if (age > sessionSnapshotMaxAge) return null;
    // A clock set back would make a snapshot look newer than it is; it is still readable.
    return SessionSnapshot(queue: q, state: s);
  }
}

/// Where the two parts and the update marker live.
abstract class SessionStore {
  Future<String?> readQueue();
  Future<String?> readState();
  Future<void> writeQueue(String value);
  Future<void> writeState(String value);

  /// Removes both parts. Idempotent.
  Future<void> clear();

  /// Left by the updater just before it starts the installer, so the start that follows is told apart from a
  /// launch (the installer's arguments come from the old version, `rill.iss`).
  Future<void> setUpdateMarker(bool value);

  /// Reads the marker and clears it in one step: it applies to one start.
  Future<bool> takeUpdateMarker();
}

class PrefsSessionStore implements SessionStore {
  const PrefsSessionStore();

  static const String queueKey = 'session_queue';
  static const String stateKey = 'session_state';
  static const String markerKey = 'session_restore_after_update';

  @override
  Future<String?> readQueue() async => (await SharedPreferences.getInstance()).getString(queueKey);

  @override
  Future<String?> readState() async => (await SharedPreferences.getInstance()).getString(stateKey);

  @override
  Future<void> writeQueue(String value) async => (await SharedPreferences.getInstance()).setString(queueKey, value);

  @override
  Future<void> writeState(String value) async => (await SharedPreferences.getInstance()).setString(stateKey, value);

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(queueKey);
    await prefs.remove(stateKey);
  }

  @override
  Future<void> setUpdateMarker(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value) {
      await prefs.setBool(markerKey, true);
    } else {
      await prefs.remove(markerKey);
    }
  }

  @override
  Future<bool> takeUpdateMarker() async {
    final prefs = await SharedPreferences.getInstance();
    final marked = prefs.getBool(markerKey) ?? false;
    if (marked) await prefs.remove(markerKey);
    return marked;
  }
}
