import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../data/playback/engine.dart';
import '../data/rpc/client.dart';
import '../domain/feed_item.dart';
import '../domain/playback_source.dart';
import 'queue_controller.dart';

/// The engine, as a provider so tests can put a fake in its place.
///
/// Overridden in `main.dart` with the real [MediaKitEngine]; the default throws
/// rather than constructing one, because a `Player()` built inside a widget test
/// would try to load libmpv and take the suite down with it.
final playbackEngineProvider = Provider<PlaybackEngine>((ref) {
  throw UnimplementedError(
    'playbackEngineProvider must be overridden — with MediaKitEngine in the app, '
    'with a fake in tests.',
  );
});

class PlaybackState {
  const PlaybackState({
    this.item,
    this.source,
    this.sessionId,
    this.isLoading = false,
    this.error,
    this.errorRetry,
    this.reportError,
  });

  /// What is loaded, or loading. Null when nothing has ever played.
  final VideoItem? item;
  final PlaybackSource? source;
  final String? sessionId;
  final bool isLoading;

  final String? error;

  /// From `protocol.md` §4. `STREAM_UNAVAILABLE` is `user`: show the error with
  /// a retry affordance, never loop silently — the ladder's floor is a very good
  /// bet and not a promise (F9), so "Unavailable" is a state a user can retry
  /// out of rather than a verdict on the video.
  final RpcRetryMode? errorRetry;

  /// The last `playback.report` failure, if reporting has stopped working.
  ///
  /// Surfaced rather than swallowed. If watch events stop landing the recommender
  /// stops training and the homepage drifts from the real one, and the failure
  /// mode this project keeps getting bitten by is the one nothing says out loud.
  final String? reportError;

  bool get hasVideo => source?.best != null;
  bool get canRetry => error != null && errorRetry != RpcRetryMode.no;

  PlaybackState copyWith({
    VideoItem? item,
    Object? source = _unchanged,
    Object? sessionId = _unchanged,
    bool? isLoading,
    Object? error = _unchanged,
    Object? errorRetry = _unchanged,
    Object? reportError = _unchanged,
  }) {
    return PlaybackState(
      item: item ?? this.item,
      source: identical(source, _unchanged) ? this.source : source as PlaybackSource?,
      sessionId: identical(sessionId, _unchanged) ? this.sessionId : sessionId as String?,
      isLoading: isLoading ?? this.isLoading,
      error: identical(error, _unchanged) ? this.error : error as String?,
      errorRetry: identical(errorRetry, _unchanged) ? this.errorRetry : errorRetry as RpcRetryMode?,
      reportError:
          identical(reportError, _unchanged) ? this.reportError : reportError as String?,
    );
  }
}

/// `copyWith` sentinel — hard invariant 10. `value ?? this.value` cannot clear a
/// field, so `error: null` on a fresh open would silently keep the old error and
/// the retry button would outlive the failure that produced it.
const Object _unchanged = Object();

/// Opens what the queue points at, keeps the engine fed, and reports the watch.
///
/// It listens to the queue rather than being called by the UI, so every path
/// that can start a video — a feed tile, a related tile, the queue panel,
/// autoplay at the end of a video — goes through one place.
class PlaybackController extends Notifier<PlaybackState> {
  /// The `playback.report` cadence. §3.5 asks for every 10–30 s plus state
  /// changes; a single ping at completion is a weak training signal.
  ///
  /// Mutable only so a test need not spend 15 real seconds proving the cadence
  /// exists. Nothing in the app writes to it.
  @visibleForTesting
  static Duration reportInterval = const Duration(seconds: 15);

  PlaybackEngine get _engine => ref.read(playbackEngineProvider);

  int _generation = 0;
  Timer? _reportTimer;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  String? _preloadedVideoId;
  bool? _lastReportedPlaying;

  /// A report can be on the wire when the container goes away — at app exit, or
  /// between tests. Assigning to `state` on a disposed `Notifier` throws, and it
  /// throws from inside a `catch`-less async gap, so it lands as an unhandled
  /// zone error with a stack trace pointing at a timer rather than at anything a
  /// reader would recognise.
  bool _disposed = false;

  @override
  PlaybackState build() {
    final engine = ref.read(playbackEngineProvider);

    _subscriptions.addAll([
      // Autoplay. A media that reaches its end reports as ended, closes its
      // session, and hands over to the queue — which stops when it runs out.
      engine.completedStream.listen((completed) {
        if (completed) unawaited(_onCompleted());
      }),
      // A state change is half of what §3.5 means by cadence. Filtered, because
      // media_kit emits `playing` again on things that are not transitions.
      engine.playingStream.listen((playing) {
        if (_lastReportedPlaying == playing) return;
        _lastReportedPlaying = playing;
        unawaited(_report(playing ? 'playing' : 'paused'));
      }),
    ]);

    // One place decides what plays. Every caller moves the queue's cursor.
    //
    // Keyed on the cursor *and* the id, because neither alone is enough: the
    // index alone reopens the current video when an earlier entry is removed and
    // everything shifts down, and the id alone never fires when the next item is
    // the same video twice in a row. So both, and then a check for whether this
    // is already the video playing healthily.
    ref.listen(queueProvider.select((q) => (q.currentIndex, q.current?.id)), (_, _) {
      final item = ref.read(queueProvider).current;
      if (item == null) return;
      if (item.id == state.item?.id && state.sessionId != null && state.error == null) return;
      unawaited(open(item));
    });

    // Preload the item after the current one so the transition is instant
    // (§3.6: `preload: true` resolves and caches without opening a session).
    ref.listen(queueProvider.select((q) => q.next), (previous, next) {
      if (next != null) unawaited(_preload(next.id));
    });

    ref.onDispose(() {
      _disposed = true;
      _reportTimer?.cancel();
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
    });

    return const PlaybackState();
  }

  /// Resolve and play one video.
  ///
  /// Guarded by a generation counter for the same reason the feed is: two taps
  /// in quick succession put two `playback.open` calls on the wire, and the
  /// slower one must not open its video over the newer one's.
  Future<void> open(VideoItem item) async {
    final generation = ++_generation;

    _endSession(reportState: 'paused');

    state = state.copyWith(
      item: item,
      source: null,
      sessionId: null,
      isLoading: true,
      error: null,
      errorRetry: null,
      reportError: null,
    );

    try {
      final response = await RpcClient.instance.call('playback.open', {'videoId': item.id});
      if (generation != _generation || _disposed) return;

      final source = PlaybackSource.fromJson(response as Map<String, dynamic>);
      final variant = source.best;
      if (variant == null) {
        // An empty ladder is the same dead end as `STREAM_UNAVAILABLE` and gets
        // the same affordance: the user may try again.
        _fail('No playable stream for this video.', RpcRetryMode.user);
        return;
      }

      await _engine.open(variant);
      if (generation != _generation || _disposed) return;

      state = state.copyWith(source: source, sessionId: source.sessionId, isLoading: false);
      _lastReportedPlaying = true;

      // Immediately, not on the first tick: this is the report that registers
      // the view at all, and a 15 s wait would lose every short watch.
      unawaited(_report('playing'));
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(reportInterval, (_) => unawaited(_report(null)));
    } on RpcException catch (e) {
      if (generation != _generation || _disposed) return;
      _fail(e.message, e.retry);
    } catch (e) {
      if (generation != _generation || _disposed) return;
      // Not an envelope — a bug on this side. `user` is the honest reading:
      // nothing will fix itself, but letting the user try again costs nothing.
      _fail(e.toString(), RpcRetryMode.user);
    }
  }

  void _fail(String message, RpcRetryMode retry) {
    if (_disposed) return;
    state = state.copyWith(
      isLoading: false,
      source: null,
      sessionId: null,
      error: message,
      errorRetry: retry,
    );
  }

  /// The user answering a `retry: "user"` error (§4).
  Future<void> retry() async {
    final item = state.item;
    if (item == null) return;
    await open(item);
  }

  Future<void> _preload(String videoId) async {
    if (_preloadedVideoId == videoId) return;
    _preloadedVideoId = videoId;
    try {
      await RpcClient.instance.call('playback.open', {'videoId': videoId, 'preload': true});
    } on Object catch (e) {
      // A preload that fails costs the transition its instantness and nothing
      // else — the real open runs the whole ladder again.
      stderr.writeln('preload $videoId failed: $e');
    }
  }

  Future<void> _onCompleted() async {
    _endSession(reportState: 'ended');
    // Autoplay, or stop. `advance` answers false at the end of the queue, and
    // pulling from related or a mix is explicitly a later task.
    ref.read(queueProvider.notifier).advance();
  }

  /// Final report and `playback.close` for whatever session is open.
  ///
  /// Synchronous up to the point where everything it needs is captured — the
  /// session id and the position it ended at — and asynchronous after. Opening
  /// the next video must not wait on two round trips to YouTube, and the final
  /// report must not read a position the *next* video has already reset to zero,
  /// which is what awaiting it later would have produced.
  void _endSession({required String reportState}) {
    final sessionId = state.sessionId;
    _reportTimer?.cancel();
    _reportTimer = null;
    if (sessionId == null) return;

    final positionMs = _engine.position.inMilliseconds;
    if (state.sessionId == sessionId) {
      state = state.copyWith(sessionId: null);
    }

    unawaited(() async {
      await _report(reportState, sessionId: sessionId, positionMs: positionMs);
      try {
        await RpcClient.instance.call('playback.close', {'sessionId': sessionId});
      } on Object catch (e) {
        stderr.writeln('playback.close failed: $e');
      }
    }());
  }

  /// One report. A null `reportState` means "whatever the engine is doing".
  ///
  /// Position comes from the engine's cached stream value — never a property
  /// read (hard invariant 9, F15).
  Future<void> _report(String? reportState, {String? sessionId, int? positionMs}) async {
    final id = sessionId ?? state.sessionId;
    if (id == null) return;

    final engine = _engine;
    final resolved = reportState ?? (engine.playing ? 'playing' : 'paused');

    try {
      await RpcClient.instance.call('playback.report', {
        'sessionId': id,
        'positionMs': positionMs ?? engine.position.inMilliseconds,
        'state': resolved,
      });
      if (!_disposed && state.reportError != null) state = state.copyWith(reportError: null);
    } on Object catch (e) {
      // Never retried here: the next tick is one interval away and carries a
      // superset of this report's segment. Recorded, so a client that has
      // silently stopped contributing to its own recommendations can say so.
      stderr.writeln('playback.report failed: $e');
      if (!_disposed) state = state.copyWith(reportError: e.toString());
    }
  }

  Future<void> togglePlayPause() => _engine.playOrPause();
  Future<void> seek(Duration to) => _engine.seek(to);

  /// Stop and forget the current video — the mini-player's close button.
  Future<void> stop() async {
    _generation++;
    _endSession(reportState: 'paused');
    await _engine.stop();
    ref.read(queueProvider.notifier).clear();
    state = const PlaybackState();
  }
}

final playbackProvider =
    NotifierProvider<PlaybackController, PlaybackState>(PlaybackController.new);
