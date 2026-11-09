import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/session/session_snapshot.dart';
import '../domain/feed_item.dart';
import 'pages/playlist.dart' show openPlaylistPage, playlistRouteName;
import 'pages/search_results.dart' show openSearchIn, searchRouteName;
import 'playback_controller.dart';
import 'player_shell.dart';
import 'queue_controller.dart';

/// Picking up where the viewer left off (`docs/architecture.md` §2.17).
///
/// Two triggers. **After an update, always:** the updater restarts the app itself, the one restart the viewer did not
/// choose. **After a manual close, only with the setting on** (off by default): a fresh app is what most people expect
/// from a launch.
///
/// The app ends with `TerminateProcess`, so there is no exit to write from. The snapshot is written as things change
/// (debounced, plus a slow tick for the position), and what a crash leaves is the last one.

const String _restorePrefsKey = 'restore_session';

final sessionStoreProvider = Provider<SessionStore>((ref) => const PrefsSessionStore());

/// The setting: reopen the queue and the page after a manual close. Off by default.
class RestoreSessionController extends Notifier<bool> {
  RestoreSessionController({this.initial = false});

  final bool initial;

  @override
  bool build() => initial;

  Future<void> setEnabled(bool value) async {
    if (state == value) return;
    state = value;
    final writer = ref.read(sessionWriterProvider);
    if (value) {
      writer.enable();
    } else {
      // Nothing is kept for a viewer who turned it off.
      await writer.disable();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_restorePrefsKey, value);
  }
}

final restoreSessionProvider = NotifierProvider<RestoreSessionController, bool>(RestoreSessionController.new);

Future<bool> readRestoreSession() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_restorePrefsKey) ?? false;
}

typedef SessionRead = T Function<T>(ProviderListenable<T> provider);

/// The session as it is now, in the two stored parts, or null when there is nothing to come back to.
({String queue, String state})? captureSession(SessionRead read, {required DateTime now}) {
  final queue = read(queueProvider);
  final index = queue.currentIndex;
  final current = queue.current;
  if (queue.isEmpty || index == null || current == null) return null;

  final playback = read(playbackProvider);
  // Where the video is only if it is the one loaded and playable: a video still opening is at its start, and a
  // live stream or one that has ended has no place to come back to.
  final loaded = playback.item?.id == current.id && !playback.isLoading && playback.source != null;
  final live = playback.source != null && playback.source!.durationMs == null;
  final position = loaded && !live && !queue.playedOut ? read(playbackProvider.notifier).currentPosition : Duration.zero;

  final mix = queue.mix;
  final stored = SnapshotQueue.windowed(
    [for (final entry in queue.entries) _toSnapshot(entry.item)],
    index,
    mix == null
        ? null
        : SnapshotMix(
            playlistId: mix.playlistId,
            title: mix.title,
            isPlaylist: mix.isPlaylist,
            exhausted: mix.exhausted,
            continuation: mix.continuation,
            totalCount: mix.totalCount,
          ),
  );

  final route = read(currentRouteProvider);
  final argument = read(currentRouteArgumentProvider);
  final page = switch (route) {
    watchRouteName => const SnapshotPage(SnapshotPageKind.watch),
    playlistRouteName when argument is String => SnapshotPage(SnapshotPageKind.playlist, argument),
    searchRouteName when argument is String => SnapshotPage(SnapshotPageKind.search, argument),
    _ => SnapshotPage.home,
  };

  final state = SnapshotState(
    positionMs: position.inMilliseconds,
    page: page,
    savedAtMs: now.millisecondsSinceEpoch,
    volume: read(playbackEngineProvider).volume,
    preferredHeight: read(playbackProvider.notifier).preferredHeight,
  );
  return (queue: stored.encode(), state: state.encode());
}

SnapshotVideo _toSnapshot(VideoItem item) => SnapshotVideo(
      id: item.id,
      title: item.title,
      channelName: item.channelName,
      thumbnailUrl: item.thumbnailUrl,
      channelId: item.channelId,
      durationSeconds: item.durationSeconds,
      isLive: item.isLive,
      isStation: item.isStation,
      isVerified: item.isVerified,
      isArtistChannel: item.isArtistChannel,
    );

VideoItem _fromSnapshot(SnapshotVideo video) => VideoItem(
      kind: 'video',
      id: video.id,
      title: video.title,
      channelName: video.channelName,
      channelId: video.channelId,
      thumbnailUrl: video.thumbnailUrl,
      durationSeconds: video.durationSeconds,
      isLive: video.isLive,
      isStation: video.isStation,
      isVerified: video.isVerified,
      isArtistChannel: video.isArtistChannel,
      canWatchLater: true,
      canAddToQueue: true,
    );

/// Writes the session as it changes, while it is enabled.
class SessionWriter {
  SessionWriter({
    required this._read,
    required this._store,
    DateTime Function()? now,
    this.debounce = const Duration(seconds: 1),
    this.tick = const Duration(seconds: 5),
  }) : _now = now ?? DateTime.now;

  final SessionRead _read;
  final SessionStore _store;
  final DateTime Function() _now;
  final Duration debounce;
  final Duration tick;

  bool _enabled = false;
  bool get enabled => _enabled;
  Timer? _debounceTimer;
  Timer? _ticker;
  String? _lastQueue;
  String? _lastState;
  bool _disposed = false;

  /// Writes are one at a time, in order: a queue part and a state part from two captures must not interleave.
  Future<void> _chain = Future<void>.value();

  /// Starts writing. Not before a restore has been applied, or what it is about to read would be overwritten.
  void enable() {
    if (_enabled || _disposed) return;
    _enabled = true;
    _ticker = Timer.periodic(tick, (_) => unawaited(flush()));
    unawaited(flush());
  }

  /// Stops writing and removes what was written.
  Future<void> disable() async {
    _enabled = false;
    _debounceTimer?.cancel();
    _ticker?.cancel();
    _ticker = null;
    _lastQueue = null;
    _lastState = null;
    await _enqueue(() => _store.clear());
  }

  /// Something the snapshot holds may have changed.
  void changed() {
    if (!_enabled || _disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(flush()));
  }

  /// Captures and writes what differs from what was last written. With nothing to come back to, removes it.
  Future<void> flush({bool force = false}) {
    if (!force && (!_enabled || _disposed)) return Future<void>.value();
    return _enqueue(() async {
      final parts = captureSession(_read, now: _now());
      if (parts == null) {
        if (_lastQueue != null || _lastState != null) await _store.clear();
        _lastQueue = null;
        _lastState = null;
        return;
      }
      if (parts.queue != _lastQueue) {
        await _store.writeQueue(parts.queue);
        _lastQueue = parts.queue;
      }
      if (parts.state != _lastState) {
        await _store.writeState(parts.state);
        _lastState = parts.state;
      }
    });
  }

  /// The updater is about to start the installer: write the session now, whatever the setting, and leave the
  /// marker that tells the next start it follows an update. Awaited before the app exits, because nothing runs
  /// after that.
  Future<void> prepareForUpdate() async {
    await flush(force: true);
    await _enqueue(() => _store.setUpdateMarker(true));
  }

  /// The installer did not start: nothing follows, so nothing is left behind for a viewer who has the setting off.
  Future<void> cancelUpdate() async {
    await _enqueue(() => _store.setUpdateMarker(false));
    if (!_enabled) await _enqueue(() => _store.clear());
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _chain.then((_) => action()).catchError((Object error) {
      stderr.writeln('rill session: write failed: $error');
    });
    _chain = next;
    return next;
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _ticker?.cancel();
  }
}

final sessionWriterProvider = Provider<SessionWriter>((ref) {
  final writer = SessionWriter(read: ref.read, store: ref.watch(sessionStoreProvider));
  // The writer only acts while enabled, so listening costs a no-op for a viewer who has the setting off.
  ref.listen(queueProvider, (_, _) => writer.changed());
  ref.listen(currentRouteProvider, (_, _) => writer.changed());
  ref.listen(currentRouteArgumentProvider, (_, _) => writer.changed());
  ref.listen(playbackProvider.select((p) => p.item?.id), (_, _) => writer.changed());
  ref.onDispose(writer.dispose);
  return writer;
});

/// The start: read what the last session left, remove it, and put it back if this start is meant to.
///
/// **Applied once.** The stored copy is removed before anything is applied, so a snapshot that crashes the app on
/// the way back in is not read again, and the writer starts only after the apply, so it cannot put the same rows
/// back before they are known to be good.
///
/// [firstFrame] and [openPage] are what a test replaces: the frame after which a navigator exists, and the push of
/// the page the viewer was on.
Future<void> restoreSessionOnStart(
  ProviderContainer container, {
  Future<void> Function()? firstFrame,
  void Function(SnapshotPage page)? openPage,
}) async {
  final store = container.read(sessionStoreProvider);
  final writer = container.read(sessionWriterProvider);
  final enabled = container.read(restoreSessionProvider);

  var afterUpdate = false;
  String? queue;
  String? state;
  try {
    afterUpdate = await store.takeUpdateMarker();
    queue = await store.readQueue();
    state = await store.readState();
    await store.clear();
  } on Object catch (error) {
    stderr.writeln('rill session: could not read the last session: $error');
  }

  if ((afterUpdate || enabled) && (queue != null || state != null)) {
    final snapshot = SessionSnapshot.read(queue: queue, state: state, now: DateTime.now());
    if (snapshot == null) {
      stderr.writeln('rill session: the last session was unreadable or too old, ignored');
    } else {
      stderr.writeln('rill session: restoring ${snapshot.queue.videos.length} videos${afterUpdate ? ' after an update' : ''}');
      try {
        await _apply(
          container,
          snapshot,
          firstFrame: firstFrame ?? () => WidgetsBinding.instance.endOfFrame,
          openPage: openPage ?? (page) => _openPage(container, page),
        );
      } on Object catch (error) {
        stderr.writeln('rill session: restore failed: $error');
      }
    }
  }

  if (enabled) writer.enable();
}

Future<void> _apply(
  ProviderContainer container,
  SessionSnapshot snapshot, {
  required Future<void> Function() firstFrame,
  required void Function(SnapshotPage page) openPage,
}) async {
  // The viewer got there first (a link opened at launch, a click before the store answered): theirs wins.
  if (!container.read(queueProvider).isEmpty || container.read(playbackProvider).item != null) return;

  final items = [for (final video in snapshot.queue.videos) _fromSnapshot(video)];
  final current = items[snapshot.queue.currentIndex];
  final playback = container.read(playbackProvider.notifier);
  playback.restorePreferredHeight(snapshot.state.preferredHeight);
  final volume = snapshot.state.volume;
  if (volume != null) {
    unawaited(playback.setVolume(volume).catchError((Object error) => stderr.writeln('rill session: volume not restored: $error')));
  }
  playback.restoreNext(videoId: current.id, position: Duration(milliseconds: snapshot.state.positionMs));

  final mix = snapshot.queue.mix;
  container.read(queueProvider.notifier).restoreFrom(
        items,
        currentIndex: snapshot.queue.currentIndex,
        mix: mix == null
            ? null
            : MixQueue(
                playlistId: mix.playlistId,
                title: mix.title,
                isPlaylist: mix.isPlaylist,
                exhausted: mix.exhausted,
                continuation: mix.continuation,
                totalCount: mix.totalCount,
              ),
      );

  // The navigator exists after the first frame.
  await firstFrame();
  openPage(snapshot.state.page);
}

void _openPage(ProviderContainer container, SnapshotPage page) {
  switch (page.kind) {
    case SnapshotPageKind.watch:
      showWatchPageIn(container);
    case SnapshotPageKind.playlist:
      openPlaylistPage(page.argument!);
    case SnapshotPageKind.search:
      openSearchIn(container, page.argument!);
    case SnapshotPageKind.home:
      break;
  }
}
