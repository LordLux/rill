import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../data/playback/engine.dart';
import '../data/rpc/client.dart';
import '../domain/feed_item.dart';
import '../domain/playback_source.dart';
import 'audio_mode_controller.dart';
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

/// Where the video is, while the engine cannot say.
///
/// **One object, not two nullable fields** (architecture §2.7): holding only the
/// position collapses the scrubber's range to 1 ms and pins the thumb to the far
/// right until the real duration arrives.
@immutable
class PlaybackHold {
  const PlaybackHold({required this.position, required this.duration});

  final Duration position;

  /// The same video's duration, which a switch does not change — so this is the
  /// value from before the reopen, held until the engine reports it again.
  final Duration duration;

  /// The user scrubbed or pressed a seek key while the hold is up. The duration
  /// is unaffected: it is the same video.
  PlaybackHold at(Duration position) =>
      PlaybackHold(position: position, duration: duration);

  @override
  bool operator ==(Object other) =>
      other is PlaybackHold && other.position == position && other.duration == duration;

  @override
  int get hashCode => Object.hash(position, duration);

  @override
  String toString() => 'PlaybackHold($position of $duration)';
}

class PlaybackState {
  const PlaybackState({
    this.item,
    this.source,
    this.variant,
    this.sessionId,
    this.isLoading = false,
    this.isSwitchingQuality = false,
    this.hold,
    this.error,
    this.errorCode,
    this.errorRetry,
    this.reportError,
  });

  /// What is loaded, or loading. Null when nothing has ever played.
  final VideoItem? item;
  final PlaybackSource? source;

  /// The rung of `variants[]` currently open — what the quality menu ticks.
  ///
  /// Not `source.best`: that is always `variants[0]`, and the whole point of
  /// this task is that the client stopped being obliged to take it.
  final PlaybackVariant? variant;

  final String? sessionId;
  final bool isLoading;

  /// A quality change in flight. Distinct from [isLoading] because it must not
  /// draw the "opening a video" spinner over a video that is already playing.
  final bool isSwitchingQuality;

  /// Where the video is while the engine cannot say — see [PlaybackHold].
  ///
  /// Everything that displays a position prefers this while set, and so does
  /// `playback.report`, or a switch posts 0:00 to the account's history.
  ///
  /// **Not a freeze**: a seek during the hold moves it (see [seek]). Null
  /// whenever the engine's own values are trustworthy, which is nearly always.
  final PlaybackHold? hold;

  final String? error;

  /// The envelope's code, kept alongside its message.
  ///
  /// The message is for a human; this is what the UI switches on. Added for
  /// `VIDEO_UPCOMING`, which needs a different screen entirely rather than a
  /// differently-worded failure — see [isUpcoming].
  final String? errorCode;

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

  /// A premiere: the video is fine, it has not started.
  ///
  /// Not an error state the user can act on by retrying — `retry` is `no` — so
  /// the watch page shows the scheduled time and a reminder rather than
  /// "This video would not open" over a *Try again* that cannot work yet.
  bool get isUpcoming => errorCode == 'VIDEO_UPCOMING';

  /// Members-only: the video is fine, it is behind the channel's paid tier.
  ///
  /// Same shape as [isUpcoming] and for the same reason — `retry` is `no`,
  /// because retrying cannot buy a membership, so the page owes the user an
  /// explanation rather than a *Try again*.
  bool get isMembersOnly => errorCode == 'VIDEO_MEMBERS_ONLY';

  /// YouTube is throttling this connection — `RATE_LIMITED`, `retry: user`.
  ///
  /// The video is not the problem, so the failure screen must not say it is.
  /// A retry is still offered: the limit lifts after minutes, and the user is
  /// the one who knows when to try again.
  bool get isRateLimited => errorCode == 'RATE_LIMITED';

  /// The ladder the quality menu lists. Empty when nothing is open.
  List<PlaybackVariant> get variants => source?.variants ?? const [];

  PlaybackState copyWith({
    Object? item = _unchanged,
    Object? source = _unchanged,
    Object? variant = _unchanged,
    Object? sessionId = _unchanged,
    bool? isLoading,
    bool? isSwitchingQuality,
    Object? hold = _unchanged,
    Object? error = _unchanged,
    Object? errorCode = _unchanged,
    Object? errorRetry = _unchanged,
    Object? reportError = _unchanged,
  }) {
    return PlaybackState(
      // Sentinel like every other nullable field here — hard invariant 10. It
      // was the one exception, so `copyWith(item: null)` was a no-op that read
      // like a clear.
      item: identical(item, _unchanged) ? this.item : item as VideoItem?,
      source: identical(source, _unchanged) ? this.source : source as PlaybackSource?,
      variant: identical(variant, _unchanged) ? this.variant : variant as PlaybackVariant?,
      sessionId: identical(sessionId, _unchanged) ? this.sessionId : sessionId as String?,
      isLoading: isLoading ?? this.isLoading,
      isSwitchingQuality: isSwitchingQuality ?? this.isSwitchingQuality,
      // Sentinel, not `??` — hard invariant 10. This field's whole job is to be
      // *cleared* when the switch finishes, and `??` cannot clear anything.
      hold: identical(hold, _unchanged) ? this.hold : hold as PlaybackHold?,
      error: identical(error, _unchanged) ? this.error : error as String?,
      errorCode: identical(errorCode, _unchanged) ? this.errorCode : errorCode as String?,
      errorRetry: identical(errorRetry, _unchanged) ? this.errorRetry : errorRetry as RpcRetryMode?,
      reportError:
          identical(reportError, _unchanged) ? this.reportError : reportError as String?,
    );
  }
}

/// The rung to open, given whatever height the user last chose.
///
/// `variants` arrives ranked best-first (§3.5), so the first entry at or under
/// the preference is the best one that honours it. When nothing is low enough —
/// a 360p preference against a ladder that starts at 720p — the **smallest** rung
/// wins: taking the top would be the furthest possible answer from what was
/// asked for. Null preference means `variants[0]`, which is what every video did
/// before this task and remains the default.
@visibleForTesting
PlaybackVariant? variantFor(List<PlaybackVariant> variants, int? preferredHeight) {
  if (variants.isEmpty) return null;
  if (preferredHeight == null) return variants.first;
  for (final variant in variants) {
    if (variant.height <= preferredHeight) return variant;
  }
  return variants.last;
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

  /// The height the user last chose, remembered **for the session** (§3 of the
  /// task). Persisting it is explicitly a later decision, so this is a field and
  /// not a `SharedPreferences` key.
  ///
  /// Null means "whatever the sidecar ranked first", which is what every video
  /// has done until now.
  int? _preferredHeight;

  /// The volume to come back to when unmuting. Null until something is muted.
  double? _volumeBeforeMute;

  @visibleForTesting
  int? get preferredHeight => _preferredHeight;

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

    ref.listen(audioModeProvider, (previous, next) {
      if (previous != next && state.source != null && state.variant != null) {
        // Toggle the video track on/off without reopening the media. This keeps
        // the demuxer, the cache and the position intact — no seek, no duration
        // wait, no picture wait — so the transition is instant in both
        // directions instead of the 6+ second cold reopen switchQuality caused.
        unawaited(_engine.setVideoTrack(!next));
      }
    });

    // One place decides what plays. Every caller moves the queue's cursor.
    //
    // Keyed on the queue's `version`, which increments *only* when the playhead
    // logically moves to a new track (e.g. advance, playNow). This prevents
    // queue reshuffles or clear operations from accidentally restarting the
    // current video.
    ref.listen(queueProvider.select((q) => q.version), (_, _) {
      final item = ref.read(queueProvider).current;
      if (item == null) {
        _endSession(reportState: 'ended');
        _engine.pause();
        state = const PlaybackState();
        return;
      }
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
    // A pending resume belongs to one video. Dropped the moment a different one
    // opens — otherwise an open superseded before it resolved (a quick tap on
    // something else during an undo) returns at its generation check without
    // consuming it, and the *next* video seeks to that position.
    if (_resumeAt?.videoId != item.id) _resumeAt = null;

    _endSession(reportState: 'paused');

    state = state.copyWith(
      item: item,
      source: null,
      variant: null,
      sessionId: null,
      isLoading: true,
      isSwitchingQuality: false,
      hold: null,
      error: null,
      errorCode: null,
      errorRetry: null,
      reportError: null,
    );

    try {
      // The mix this watch belongs to, if any. It does not change resolution —
      // the sidecar keeps it off the ladder for exactly that reason — it is
      // recorded on the playback session so `playback.report` can put `list=`
      // on the watchtime ping. Without it a mix watch trains the recommender
      // as a standalone watch, which is the signal F6 exists to protect.
      final playlistId = ref.read(queueProvider).mix?.playlistId;
      final response = await RpcClient.instance.call('playback.open', {
        'videoId': item.id,
        'playlistId': ?playlistId,
      });
      if (generation != _generation || _disposed) return;

      final source = PlaybackSource.fromJson(response as Map<String, dynamic>);
      // "The client starts at its preferred variant" (§3.5). Until this task
      // that sentence had no implementation and every video opened `variants[0]`.
      final variant = variantFor(source.variants, _preferredHeight);
      if (variant == null) {
        // An empty ladder is the same dead end as `STREAM_UNAVAILABLE` and gets
        // the same affordance: the user may try again.
        await _failOpen('No playable stream for this video.', RpcRetryMode.user);
        return;
      }
      
      await _engine.open(variant, isLive: source.durationMs == null);
      if (generation != _generation || _disposed) return;

      // Re-read after the await: the user may have toggled audio-only while the
      // engine was loading, and the listener is guarded out (state.source is
      // still null), so only a fresh read picks up the current intent.
      if (ref.read(audioModeProvider)) {
        await _engine.setVideoTrack(false);
      }

      state = state.copyWith(
        source: source,
        variant: variant,
        sessionId: source.sessionId,
        isLoading: false,
      );
      _lastReportedPlaying = true;

      // The undo's restored position, if one is pending. After the engine has
      // the media open, so the seek has something to seek in.
      final resume = _resumeAt;
      _resumeAt = null;
      if (resume != null && resume.videoId == item.id) unawaited(seek(resume.position));

      // Immediately, not on the first tick: this is the report that registers
      // the view at all, and a 15 s wait would lose every short watch.
      unawaited(_report('playing'));
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(reportInterval, (_) => unawaited(_report(null)));
    } on RpcException catch (e) {
      if (generation != _generation || _disposed) return;
      await _failOpen(e.message, e.retry, code: e.code);
    } catch (e) {
      if (generation != _generation || _disposed) return;
      // Not an envelope — a bug on this side. `user` is the honest reading:
      // nothing will fix itself, but letting the user try again costs nothing.
      await _failOpen(e.toString(), RpcRetryMode.user);
    }
  }

  void _fail(String message, RpcRetryMode retry, {String? code}) {
    if (_disposed) return;
    state = state.copyWith(
      isLoading: false,
      source: null,
      sessionId: null,
      error: message,
      errorCode: code,
      errorRetry: retry,
    );
  }

  /// `_fail`, plus actually stopping the video — for `open()` only.
  ///
  /// A premiere, a members-only slate, a dead ladder or any other `open()`
  /// failure all mean the same thing: this navigation produced no video to
  /// show. Until this fix, none of them told `_engine` that — `_engine.open`
  /// is only ever called on the *success* path, so a failed `open()` left
  /// whatever was already loaded (the previous video) playing silently under
  /// the slate or the error screen. Reported live: click a video, then a
  /// premiere from the sidebar, and the first video kept playing underneath
  /// the "Premieres in…" card.
  ///
  /// **Not folded into `_fail` itself** — `switchQuality`'s own failure path
  /// shares that helper, and there the previous stream is already gone by the
  /// time it fails (`engine.open` has already replaced the source before
  /// erroring out), so stopping again would be redundant at best and a
  /// regression at worst if that ever changes to keep the old stream alive on
  /// a failed switch.
  ///
  /// If the user has already navigated again by the time this runs, the
  /// caller's own generation check has already returned before reaching
  /// here, so nothing has to be re-checked — `_engine.stop()` racing a newer
  /// `_engine.open()` is left to media_kit's own command ordering, the same
  /// trust every other overlapping engine call in this file already extends.
  Future<void> _failOpen(String message, RpcRetryMode retry, {String? code}) async {
    // A pending resume belongs to the open that just failed. Left set, it would
    // seek the *next* video the user opens to a position from a different one.
    _resumeAt = null;
    _fail(message, retry, code: code);
    if (_disposed) return;
    await _engine.stop();
  }

  /// Where the video is right now — the value an undo has to put back.
  ///
  /// Reads the hold first for the same reason `_report` does: during a quality
  /// switch the engine's own position is zero, and a snapshot taken then would
  /// "restore" the user to the start of the video they were watching.
  Duration get currentPosition => state.hold?.position ?? _engine.position;

  /// Seek the *next* open to [position] — the queue-replacement undo (§3).
  ///
  /// One-shot and consumed by the next successful open, because that is the
  /// shape of the problem: restoring a queue snapshot moves the playhead, which
  /// reopens the video asynchronously, so there is nothing to seek yet at the
  /// moment Undo is pressed. Seeking here directly would land on the mix's
  /// first video, not the restored one.
  ///
  /// Cleared on any failure path too, so a resume cannot leak into a later,
  /// unrelated open.
  void resumeAt(Duration position) {
    if (position <= Duration.zero) return;
    // Bound to the video the queue is on now — the one the restore reopens.
    final videoId = ref.read(queueProvider).current?.id;
    if (videoId != null) _resumeAt = (videoId: videoId, position: position);
  }

  ({String videoId, Duration position})? _resumeAt;

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
    // Autoplay, or stop. `advance` answers false at the end of the queue — and
    // at the end of a mix with a top-up still out, the queue remembers and
    // advances itself when it lands (`QueueController._advanceWhenExtended`).
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
  /// Position comes from the engine's cached stream value, never a property read
  /// (invariant 9) — **except while a quality switch holds one**. Not cosmetic
  /// the way the scrubber is: a report of zero tells YouTube the viewer went
  /// back to the start, and that only ever surfaces as a drifting homepage.
  Future<void> _report(String? reportState, {String? sessionId, int? positionMs}) async {
    final id = sessionId ?? state.sessionId;
    if (id == null) return;

    final engine = _engine;
    final resolved = reportState ?? (engine.playing ? 'playing' : 'paused');

    try {
      await RpcClient.instance.call('playback.report', {
        'sessionId': id,
        'positionMs':
            positionMs ?? (state.hold?.position ?? engine.position).inMilliseconds,
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

  /// One report, now. The cadence timer is 15 s and a test proving *what* a
  /// report carries should not spend 15 s of anyone's life proving *when*.
  @visibleForTesting
  Future<void> reportNow() => _report(null);

  Future<void> togglePlayPause() => _engine.playOrPause();

  /// Seek, and move the hold with it if one is up.
  ///
  /// Every seek in the app goes through here — the scrubber's release, the
  /// arrow keys, `J`/`L`, the deciles — so "scrubbing during a quality switch
  /// works" is one line rather than a rule each caller has to remember. Without
  /// it the scrubber would spring back to the held value the instant the user
  /// let go, which is worse than the snap-to-zero the hold exists to prevent.
  Future<void> seek(Duration to) {
    final held = state.hold;
    if (held != null) state = state.copyWith(hold: held.at(to));
    return _engine.seek(to);
  }

  /// Play or pause **explicitly**, rather than relative to whatever mpv thinks
  /// it is doing.
  ///
  /// This exists for the double-click undo. `playOrPause()` twice in the ~250 ms
  /// of a double click is not reliably a no-op: the second call reads a `playing`
  /// flag the first has not finished updating, so the pair can land as two
  /// toggles in the same direction and the "undo" pauses a video the click
  /// already paused. Restoring a recorded value has no such race.
  Future<void> setPlaying(bool value) => value ? _engine.play() : _engine.pause();

  /// A relative seek, clamped. The ← → J L keys.
  ///
  /// Clamped rather than left to mpv because seeking past the end fires
  /// `completedStream`, and "press → four times near the end" would autoplay the
  /// next video instead of reaching the last few seconds of this one.
  Future<void> seekBy(Duration delta) {
    // Both from the hold during a quality switch. The engine reports zero for
    // each for those few seconds, so `J` would seek relative to the start of the
    // video, and the end-of-video clamp below would be skipped entirely.
    final hold = state.hold;
    final duration = hold?.duration ?? _engine.duration;
    var target = (hold?.position ?? _engine.position) + delta;
    if (target < Duration.zero) target = Duration.zero;
    // `>=`, not `>`: landing *exactly* on the duration ends the media, fires
    // `completedStream` and autoplays the next video — so pressing `→` near the
    // end could skip the video instead of reaching its last seconds.
    if (duration > Duration.zero && target >= duration) {
      target = duration - const Duration(milliseconds: 500);
      if (target < Duration.zero) target = Duration.zero;
    }
    return seek(target);
  }

  /// The `,` and `.` keys. One frame, from the decoder rather than from
  /// arithmetic — see [PlaybackEngine.stepFrame].
  Future<void> stepFrame(int direction) => _engine.stepFrame(direction);

  /// The 0–9 keys: jump to that decile of the video.
  Future<void> seekToFraction(double fraction) {
    // The held duration during a switch, or the deciles are dead for those
    // seconds — the engine's duration is zero and this returns early.
    final duration = state.hold?.duration ?? _engine.duration;
    if (duration <= Duration.zero) return Future<void>.value();
    final clamped = fraction.clamp(0.0, 1.0);
    return seek(Duration(milliseconds: (duration.inMilliseconds * clamped).round()));
  }

  /// mpv's scale is 0–100, and so is everything above this line.
  Future<void> setVolume(double volume) {
    final clamped = volume.clamp(0.0, 100.0);
    // Unmuting by dragging the slider is unmuting. Without this the level to
    // restore stays whatever it was before the *first* mute, forever.
    if (clamped > 0) _volumeBeforeMute = null;
    return _engine.setVolume(clamped);
  }

  Future<void> nudgeVolume(double delta) => setVolume(_engine.volume + delta);

  Future<void> toggleMute() {
    final current = _engine.volume;
    if (current > 0) {
      _volumeBeforeMute = current;
      return _engine.setVolume(0);
    }
    // A restore to zero would be a mute toggle that never unmutes, which is what
    // happens if the video was already silent when it was first muted.
    final restored = _volumeBeforeMute ?? 100;
    _volumeBeforeMute = null;
    return _engine.setVolume(restored > 0 ? restored : 100);
  }

  /// Switch quality without reopening the *video*.
  ///
  /// **No RPC** (§3.5): asking the sidecar again would mint a second session for
  /// one watch and double the history entry. It does cost a media reopen inside
  /// mpv — capture position and play state, open the new URLs, seek back.
  ///
  /// **`isSwitchingQuality` stays true until the picture is back**, not until
  /// the calls are issued: F19 measured those at 306–743 ms against a median
  /// 4.1 s. It is what holds the black cover over the surface.
  Future<void> switchQuality(PlaybackVariant variant, {bool force = false, bool hideCover = false}) async {
    if (!force && state.variant == variant) return;
    // **Incremented, not merely read.** Two picks in quick succession — 1080 then
    // 720 — otherwise captured the *same* generation, so neither guard fired and
    // both ran `engine.open` against the same player, racing over which stream
    // won and both clearing the cover on the way out. Claiming a generation makes
    // the newer pick supersede the older one, exactly as it does in `open`.
    final generation = ++_generation;
    final engine = _engine;

    _preferredHeight = variant.height;

    final position = engine.position;
    final wasPlaying = engine.playing;
    final started = DateTime.now();

    state = state.copyWith(
      variant: variant,
      isSwitchingQuality: !hideCover,
      // Set *before* the reopen, not after: `engine.open` resets the position
      // **and the duration** to zero on its way in, and anything watching would
      // paint both.
      hold: PlaybackHold(position: position, duration: engine.duration),
    );

    try {
      // `retainSubtitle` because the reopen drops mpv's external subtitle track
      // (F19 reopens the media; §2.9). Reattaching inside `engine.open` rather
      // than here puts it after the audio attach, on the same freshly-loaded
      // file, instead of racing the load from out here.
      await engine.open(variant, play: wasPlaying, retainSubtitle: true, isLive: state.source?.durationMs == null);
      if (generation != _generation || _disposed) return;

      // A quality switch reopens the media, which resets vid to auto. If
      // audio-only is active, turn the video track back off.
      if (ref.read(audioModeProvider)) await engine.setVideoTrack(false);

      // **Subscribed before the seek is issued**: `positionStream` is a
      // broadcast stream, so attaching afterwards misses the seek's own event
      // and the cover sits there until the timeout.
      //
      // **The target is where the user is *now*** — the reopen takes seconds and
      // `seek` moves the hold during it, so a scrub mid-switch has named a newer
      // one. The captured local would drag them back to where they just left.
      final target = state.hold?.position ?? position;
      final picture =
          target > Duration.zero ? _waitForPicture(engine, target, wasPlaying) : null;
      if (target > Duration.zero) await engine.seek(target);
      if (generation != _generation || _disposed) return;
      final reopened = DateTime.now().difference(started).inMilliseconds;

      await picture;
      if (generation != _generation || _disposed) return;

      // The numbers the task asks for, from the app rather than from a stopwatch
      // held against the screen. Both of them: what the call cost, and what the
      // *viewer* waited for. Only the second one is the answer.
      stderr.writeln(
        'rill: quality -> ${variant.height}p${variant.fps} itag=${variant.itag} '
        'reopened in $reopened ms, picture back in '
        '${DateTime.now().difference(started).inMilliseconds} ms '
        '(resumed at ${position.inSeconds}s, playing=$wasPlaying)',
      );
    } on Object catch (e) {
      if (generation != _generation || _disposed) return;
      // The stream that was playing a moment ago is gone and this one would not
      // open. That is the same dead end as an empty ladder, and the same offer.
      _fail('Could not switch to ${variant.height}p: $e', RpcRetryMode.user);
      return;
    } finally {
      if (!_disposed && generation == _generation) {
        state = state.copyWith(isSwitchingQuality: false, hold: null);
      }
    }
  }

  /// Wait until playback is back where it was.
  ///
  /// **Past [resumeAt] while playing, merely at it while paused, and the
  /// difference is 5 seconds of wrong picture.** mpv reports `time-pos` at the
  /// target as soon as it *accepts* the seek — measured 2026-08-12: reported at
  /// 448 ms, actually moved past it at 5343 ms — so an "at or past" test lifts
  /// the cover in the middle of the stall it exists to hide. A paused switch
  /// never advances, so there "at" is all there is.
  ///
  /// **Bounded**, or a stream that never reaches the position leaves a black
  /// rectangle where the player was. F19's worst resume was 12.0 s.
  ///
  /// **The target is re-read per event, not captured**: a scrub during the
  /// switch moves the hold, and a backward seek would otherwise leave the cover
  /// up waiting to pass a point the user chose to be behind.
  Future<void> _waitForPicture(
    PlaybackEngine engine,
    Duration resumeAt,
    bool playing,
  ) async {
    try {
      await engine.positionStream.firstWhere((position) {
        if (_disposed) return true;
        final target = state.hold?.position ?? resumeAt;
        return playing ? position > target : position >= target;
      }).timeout(const Duration(seconds: 25));
    } on Object {
      // Timed out, or the stream closed under us. Uncovering on a timeout is the
      // deliberate half of the bound above.
      stderr.writeln('rill: quality switch never reached ${resumeAt.inSeconds}s — uncovering');
    }
  }

  /// Move the queue's cursor back one, if there is one. The previous button.
  void previous() => ref.read(queueProvider.notifier).back();

  /// Move it forward. Distinct from autoplay only in what triggers it.
  void next() => ref.read(queueProvider.notifier).advance();

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
