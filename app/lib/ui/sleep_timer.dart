/// The sleep timer (Task 38): when it ends, what it waits for, the fade, and what happens after.
///
/// The rules are `architecture.md` §2.18; the comments here say where each one is kept.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/system_power.dart';
import '../domain/now_playing_track.dart' show chapterIndexAt;
import '../domain/video_detail.dart';
import 'playback_controller.dart';
import 'queue_controller.dart';
import 'spoken.dart';
import 'video_info.dart';

export '../data/system_power.dart' show SleepEndAction, SystemPower;

/// What the timer waits for.
enum SleepKind {
  off,

  /// Real time from the moment it is set, playing or paused.
  duration,

  /// The end of the chapter the playhead is in. A seek into another chapter moves it.
  chapterEnd,

  /// The controller's real ending, where autoplay would advance.
  videoEnd,

  /// After N chapters, counted across autoplayed videos.
  chapters,

  /// After N videos.
  videos;

  /// The kinds whose end is known in advance, and so fade over their last [SleepTimerController.fadeLength].
  bool get fades => this == duration || this == chapterEnd || this == videoEnd;
}

@immutable
class SleepTimerState {
  const SleepTimerState({this.kind = SleepKind.off, this.total, this.left, this.target = 1, this.started = 1, this.fading = false});

  final SleepKind kind;

  /// A [SleepKind.duration]'s length as chosen, for the menu to tick. Null for the other kinds.
  final Duration? total;

  /// A [SleepKind.duration]'s time left, rounded up to the second. Null for the other kinds.
  final Duration? left;

  /// N, for [SleepKind.chapters] and [SleepKind.videos].
  final int target;

  /// How many chapters or videos have started since the timer was set, the current one included.
  /// It fires at the end of a chapter or video once this has reached [target].
  final int started;

  /// Inside the fade: the output is going down. Nothing the viewer does in the window stops it —
  /// only turning the timer off does (the user's call, 2026-11-22, §2.18).
  final bool fading;

  bool get isOn => kind != SleepKind.off;

  /// Chapters or videos still to go, the current one included.
  int get toGo => math.max(1, target - started + 1);

  /// What the menu's root row and the moon's tooltip say it waits for.
  String get waitsFor => switch (kind) {
    SleepKind.off => 'Off',
    SleepKind.duration => formatSleepLeft(left ?? Duration.zero),
    SleepKind.chapterEnd => 'End of chapter',
    SleepKind.videoEnd => 'End of video',
    // One left reads as where it ends, not as a count (the user's wording, 2026-11-22).
    SleepKind.chapters => toGo == 1 ? 'At the end of this chapter' : 'After $toGo chapters',
    SleepKind.videos => toGo == 1 ? 'At the end of this video' : 'After $toGo videos',
  };

  SleepTimerState copyWith({Object? left = _unchanged, int? started, bool? fading}) => SleepTimerState(
    kind: kind,
    total: total,
    // Sentinel, hard invariant 10: `left` is cleared by kinds that have none.
    left: identical(left, _unchanged) ? this.left : left as Duration?,
    target: target,
    started: started ?? this.started,
    fading: fading ?? this.fading,
  );

  @override
  bool operator ==(Object other) =>
      other is SleepTimerState && other.kind == kind && other.total == total && other.left == left && other.target == target && other.started == started && other.fading == fading;

  @override
  int get hashCode => Object.hash(kind, total, left, target, started, fading);

  @override
  String toString() => 'SleepTimerState($kind, left: $left, $started/$target, fading: $fading)';
}

const Object _unchanged = Object();

/// `12:34`, or `1:02:03` past the hour.
String formatSleepLeft(Duration left) {
  final seconds = left.inSeconds;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// A monotonic clock: time since some fixed point, never the wall clock, so a duration counts the
/// same whatever the system time does. A provider so a test can drive it.
final sleepClockProvider = Provider<Duration Function()>((ref) {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
});

/// The end actions, real or fake.
final systemPowerProvider = Provider<SystemPower>((ref) => Win32SystemPower());

class SleepTimerController extends Notifier<SleepTimerState> {
  /// How long the output fades before an end known in advance. Mutable only for tests.
  @visibleForTesting
  static Duration fadeLength = const Duration(seconds: 5);

  /// How often the countdown and the fade are worked out. Mutable only for tests.
  @visibleForTesting
  static Duration tick = const Duration(milliseconds: 100);

  /// The largest step the position may take between two samples and still be playback moving on,
  /// rather than a jump. A chapter boundary crossed by a bigger step is a seek, and moves the
  /// target instead of ending the chapter.
  static const Duration _naturalStep = Duration(seconds: 3);

  Timer? _ticker;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _disposed = false;

  /// While firing: pausing and the end action are under way, and nothing may fire again.
  bool _firing = false;

  /// [SleepKind.duration]'s end, on [sleepClockProvider]'s clock.
  Duration? _deadline;

  /// The video the chapter tracking is about, and the chapter it is in.
  String? _videoId;
  int? _chapter;
  Duration? _lastPosition;

  /// The chapter list [_chapter] was worked out from. The list arrives with `video.info`, which can
  /// be after playback started: when it changes, the chapter is worked out again, silently, since a
  /// jump from "no chapters" to "chapter 2" is the list arriving, not chapter 1 ending.
  List<Chapter> _chaptersSeen = const [];

  /// A seek in flight: samples are ignored until one lands near it, because the ones before it
  /// still carry the old position.
  Duration? _seekTarget;
  Duration _seekAt = Duration.zero;

  double _gain = 1;

  Duration _now() => ref.read(sleepClockProvider)();

  @override
  SleepTimerState build() {
    final signals = ref.read(playbackSignalsProvider);
    signals.holdAtRealEnding = _holdAtRealEnding;
    ref.listen(queueProvider.select((queue) => queue.version), (_, _) => _onQueueMoved());
    // The queue played out short of N: nothing it waits for can end now, and left on it would count
    // a video started hours later and fire there.
    ref.listen(queueProvider.select((queue) => queue.playedOut), (_, out) {
      if (out && (state.kind == SleepKind.chapters || state.kind == SleepKind.videos) && !_firing) off();
    });
    ref.onDispose(() {
      _disposed = true;
      _disarm();
      if (signals.holdAtRealEnding == _holdAtRealEnding) signals.holdAtRealEnding = null;
    });
    return const SleepTimerState();
  }

  // --- Setting it ---

  /// `Off`, or any other choice replacing this one: the way to stop a timer (decided).
  void off() {
    _disarm();
    _setGain(1, force: true);
    if (!_disposed) state = const SleepTimerState();
  }

  void startDuration(Duration length) {
    _arm(SleepTimerState(kind: SleepKind.duration, total: length, left: _roundUp(length)));
    _deadline = _now() + length;
    _onTick();
  }

  void endOfChapter() => _arm(const SleepTimerState(kind: SleepKind.chapterEnd));

  void endOfVideo() => _arm(const SleepTimerState(kind: SleepKind.videoEnd));

  void afterChapters(int n) => _arm(SleepTimerState(kind: SleepKind.chapters, target: n.clamp(1, 99)));

  void afterVideos(int n) => _arm(SleepTimerState(kind: SleepKind.videos, target: n.clamp(1, 99)));

  void _arm(SleepTimerState next) {
    _disarm();
    _setGain(1, force: true);
    state = next;
    _videoId = ref.read(playbackProvider).item?.id;
    _chapter = null;
    _chaptersSeen = const [];
    _lastPosition = null;
    _seekTarget = null;
    final engine = ref.read(playbackEngineProvider);
    final signals = ref.read(playbackSignalsProvider);
    _subscriptions.addAll([
      engine.positionStream.listen(_onPosition),
      engine.playingStream.listen((_) => _applyGain()),
      signals.seeks.listen(_onSeek),
    ]);
    _ticker = Timer.periodic(tick, (_) => _onTick());
  }

  void _disarm() {
    _ticker?.cancel();
    _ticker = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _deadline = null;
  }

  // --- Following playback ---

  List<Chapter> _chapters() {
    final id = _videoId;
    if (id == null) return const [];
    return ref.read(videoInfoProvider(id)).value?.chapters ?? const [];
  }

  /// A new video started — autoplay, Next, a click, the queue. Each counts as one, whether or not
  /// the one before it ended. A reopen of the same video (a retry, a recovery) does not move the
  /// queue and does not count.
  void _onQueueMoved() {
    if (!state.isOn || _firing) return;
    final queue = ref.read(queueProvider);
    final current = queue.current;
    if (current == null) {
      // Playback stopped (the miniplayer's close, a cleared queue): no player is left to show the
      // timer or to change it, so it goes too. A mix starting is empty for a moment, and is not this.
      if (queue.startingMixId == null) off();
      return;
    }
    _videoId = current.id;
    _chapter = null;
    _chaptersSeen = const [];
    _lastPosition = null;
    _seekTarget = null;
    if (state.kind != SleepKind.duration) state = state.copyWith(started: state.started + 1);
  }

  Duration? _videoPosition(Duration enginePosition) {
    final playback = ref.read(playbackProvider);
    if (playback.isLoading || playback.item == null || playback.item!.id != _videoId) return null;
    // From the hold during a reopen, when the engine says zero (§2.7).
    return playback.hold?.position ?? enginePosition;
  }

  void _onSeek(Duration to) {
    _seekTarget = to;
    _seekAt = _now();
    _chaptersSeen = _chapters();
    _chapter = chapterIndexAt(_chaptersSeen, to) ?? 0;
    _lastPosition = to;
  }

  void _onPosition(Duration enginePosition) {
    if (!state.isOn || _firing) return;
    final position = _videoPosition(enginePosition);
    if (position == null) return;
    final target = _seekTarget;
    if (target != null) {
      if ((position - target).abs() > const Duration(milliseconds: 1500) && _now() - _seekAt < const Duration(seconds: 15)) return;
      _seekTarget = null;
    }
    final chapters = _chapters();
    if (!listEquals(chapters, _chaptersSeen)) {
      _chaptersSeen = chapters;
      _chapter = null;
    }
    final index = chapterIndexAt(chapters, position) ?? 0;
    final last = _lastPosition;
    _lastPosition = position;
    final was = _chapter;
    _chapter = index;
    if (was == null || index == was) return;
    // A boundary crossed by playback moving on ends a chapter. One crossed by a jump is a seek
    // nobody announced (a reopen landing): the target moves, and nothing ends.
    final step = last == null ? null : position - last;
    final natural = index == was + 1 && step != null && step >= Duration.zero && step <= _naturalStep;
    if (natural) _chapterEnded();
  }

  /// A chapter ended by playing to its end — not the last one, whose end is the video's real
  /// ending and arrives at [_holdAtRealEnding].
  void _chapterEnded() {
    switch (state.kind) {
      case SleepKind.chapterEnd:
        unawaited(_fire());
      case SleepKind.chapters:
        if (state.started >= state.target) {
          unawaited(_fire());
        } else {
          state = state.copyWith(started: state.started + 1);
        }
      default:
        break;
    }
  }

  /// The controller's real ending (`PlaybackSignals.holdAtRealEnding`). True: it fires here, paused
  /// at the end, and autoplay does not move on.
  bool _holdAtRealEnding() {
    if (!state.isOn || _firing) return false;
    final take = switch (state.kind) {
      SleepKind.chapterEnd || SleepKind.videoEnd => true,
      SleepKind.chapters || SleepKind.videos => state.started >= state.target,
      _ => false,
    };
    if (take) unawaited(_fire());
    return take;
  }

  /// How long until the end, for the kinds that know it. Null when it is not known yet (a video
  /// still opening) or never is.
  Duration? _remaining() {
    switch (state.kind) {
      case SleepKind.duration:
        final deadline = _deadline;
        return deadline == null ? null : deadline - _now();
      case SleepKind.videoEnd:
      case SleepKind.chapterEnd:
        final engine = ref.read(playbackEngineProvider);
        final position = _videoPosition(engine.position);
        if (position == null) return null;
        final playback = ref.read(playbackProvider);
        if (playback.source?.durationMs == null) return null; // live: no end
        final held = playback.hold?.duration;
        final duration = held ?? (engine.duration > Duration.zero ? engine.duration : (playback.source?.duration ?? Duration.zero));
        if (duration <= Duration.zero) return null;
        if (state.kind == SleepKind.videoEnd) return duration - position;
        final chapters = _chapters();
        final index = _chapter ?? chapterIndexAt(chapters, position) ?? 0;
        final end = index + 1 < chapters.length ? Duration(seconds: chapters[index + 1].startSeconds) : duration;
        return end - position;
      default:
        return null;
    }
  }

  void _onTick() {
    if (!state.isOn || _firing || _disposed) return;
    final remaining = _remaining();
    if (state.kind == SleepKind.duration && remaining != null && remaining <= Duration.zero) {
      unawaited(_fire());
      return;
    }
    final fading = state.kind.fades && remaining != null && remaining <= fadeLength;
    final left = state.kind == SleepKind.duration && remaining != null ? _roundUp(remaining) : null;
    if (left != state.left || fading != state.fading) state = state.copyWith(left: left, fading: fading);
    _applyGain();
  }

  // --- The fade ---

  /// The fade's floor, in decibels below the level the viewer set: where it ends, the moment
  /// before the pause.
  static const double _fadeFloorDb = 60;

  /// The gain the output should be at now, and **1 whenever playback is not playing** — restored
  /// the moment it pauses, so it is never silent at the next play.
  ///
  /// **Even in decibels, not in volume.** The ear hears loudness logarithmically, so a fade that
  /// takes the same number of dB off every second sounds like a steady fade; one linear in amplitude
  /// barely changes for most of its length and then drops. The gain multiplies mpv's `volume`, which
  /// mpv cubes (`player/audio.c`), so the amplitude is `gain³`: a fall of `floor × p` dB at
  /// progress `p` is `gain = 10^(−floor × p / 60)`. At 60 dB that is `10^−p`.
  double _targetGain() {
    if (!state.isOn || !state.fading) return 1;
    if (!ref.read(playbackEngineProvider).playing) return 1;
    final remaining = _remaining();
    if (remaining == null) return 1;
    final progress = (1 - remaining.inMicroseconds / fadeLength.inMicroseconds).clamp(0.0, 1.0);
    return fadeGainAt(progress);
  }

  /// [_targetGain]'s curve at [progress] (0 at the fade's start, 1 at its end).
  @visibleForTesting
  static double fadeGainAt(double progress) => math.pow(10, -_fadeFloorDb * progress.clamp(0.0, 1.0) / 60).toDouble();

  void _applyGain() => _setGain(_targetGain());

  void _setGain(double gain, {bool force = false}) {
    if (_disposed) return;
    // Only an unchanged gain is dropped: a tick outside the fade asks for 1 again and again. Inside
    // it every tick is a step of the same few dB, and dropping small ones would make the quiet end
    // coarse.
    if (!force && gain == _gain) return;
    _gain = gain;
    unawaited(ref.read(playbackEngineProvider).setOutputGain(gain));
  }

  // --- Firing ---

  /// Pause (the fade has brought the output down), restore the volume, turn the timer off, say so,
  /// then run the end action — in that order (§2.18).
  Future<void> _fire() async {
    if (_firing || _disposed) return;
    _firing = true;
    final action = ref.read(sleepEndActionProvider);
    _disarm();
    try {
      await ref.read(playbackProvider.notifier).setPlaying(false);
    } on Object {
      // A pause that failed still ends the timer; the note and the action are what is left.
    }
    if (_disposed) return;
    _setGain(1, force: true);
    state = const SleepTimerState();
    _firing = false;
    ref.read(sleepNoteProvider.notifier).show('Sleep timer: paused');
    ref.read(sleepEndProvider.notifier).begin(action);
  }

  static Duration _roundUp(Duration d) {
    if (d <= Duration.zero) return Duration.zero;
    final whole = Duration(seconds: d.inSeconds);
    return whole == d ? whole : whole + const Duration(seconds: 1);
  }
}

final sleepTimerProvider = NotifierProvider<SleepTimerController, SleepTimerState>(SleepTimerController.new);

/// The end action chosen. **Not remembered across a restart of Rill** (the orchestrator's safety
/// suggestion, kept): it goes back to *Do nothing*, so a shutdown chosen weeks ago surprises no one.
/// While Rill runs it stays until changed, firing included.
class SleepEndActionChoice extends Notifier<SleepEndAction> {
  @override
  SleepEndAction build() => SleepEndAction.nothing;

  void set(SleepEndAction action) => state = action;
}

final sleepEndActionProvider = NotifierProvider<SleepEndActionChoice, SleepEndAction>(SleepEndActionChoice.new);

/// The short note the player shows after the timer fired.
class SleepNote extends Notifier<String?> {
  @visibleForTesting
  static Duration showFor = const Duration(seconds: 5);

  Timer? _hide;

  @override
  String? build() {
    ref.onDispose(() => _hide?.cancel());
    return null;
  }

  void show(String note) {
    _hide?.cancel();
    state = note;
    _hide = Timer(showFor, () => state = null);
  }
}

final sleepNoteProvider = NotifierProvider<SleepNote, String?>(SleepNote.new);

/// A system action waiting out its countdown.
@immutable
class SleepCountdown {
  const SleepCountdown(this.action, this.left, {Duration? total}) : total = total ?? left;

  final SleepEndAction action;
  final Duration left;

  /// The whole countdown, which is what a screen reader is told once.
  final Duration total;

  /// "Shutting down".
  String get verb => switch (action) {
    SleepEndAction.sleep => 'Going to sleep',
    SleepEndAction.hibernate => 'Hibernating',
    SleepEndAction.restart => 'Restarting',
    _ => 'Shutting down',
  };

  /// "Shutting down in 30 s".
  String get label => '$verb in ${left.inSeconds} s';

  @override
  bool operator ==(Object other) => other is SleepCountdown && other.action == action && other.left == left;

  @override
  int get hashCode => Object.hash(action, left);
}

/// Runs the end action. A system action — Sleep, Hibernate, Shut down, Restart — waits out a 30 s
/// countdown with a *Cancel* first (the orchestrator's safety suggestion, kept): a mistaken shutdown
/// can lose work in other apps. This is separate from the timer, which has no warning.
class SleepEndController extends Notifier<SleepCountdown?> {
  /// Mutable only for tests.
  @visibleForTesting
  static Duration systemActionDelay = const Duration(seconds: 30);

  Timer? _countdown;

  @override
  SleepCountdown? build() {
    ref.onDispose(() => _countdown?.cancel());
    return null;
  }

  void begin(SleepEndAction action) {
    _countdown?.cancel();
    _countdown = null;
    if (action == SleepEndAction.nothing) return;
    if (!action.isSystem) {
      unawaited(ref.read(systemPowerProvider).run(action));
      return;
    }
    state = SleepCountdown(action, systemActionDelay);
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      final current = state;
      if (current == null) {
        timer.cancel();
        return;
      }
      final left = current.left - const Duration(seconds: 1);
      if (left > Duration.zero) {
        state = SleepCountdown(action, left, total: current.total);
        return;
      }
      timer.cancel();
      _countdown = null;
      state = null;
      unawaited(ref.read(systemPowerProvider).run(action));
    });
  }

  void cancel() {
    _countdown?.cancel();
    _countdown = null;
    state = null;
  }
}

final sleepEndProvider = NotifierProvider<SleepEndController, SleepCountdown?>(SleepEndController.new);

/// The last values typed on the *Custom…* page, so the next one opens on them.
@immutable
class SleepCustomValues {
  const SleepCustomValues({this.seconds = 30 * 60, this.chapters = 2, this.videos = 2});

  final int seconds;
  final int chapters;
  final int videos;

  static const String secondsKey = 'sleep_custom_seconds';
  static const String chaptersKey = 'sleep_custom_chapters';
  static const String videosKey = 'sleep_custom_videos';

  static Future<SleepCustomValues> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return SleepCustomValues(
        seconds: (prefs.getInt(secondsKey) ?? 30 * 60).clamp(1, maxSeconds),
        chapters: (prefs.getInt(chaptersKey) ?? 2).clamp(1, 99),
        videos: (prefs.getInt(videosKey) ?? 2).clamp(1, 99),
      );
    } on Object {
      return const SleepCustomValues();
    }
  }

  static Future<void> write({int? seconds, int? chapters, int? videos}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (seconds != null) await prefs.setInt(secondsKey, seconds);
      if (chapters != null) await prefs.setInt(chaptersKey, chapters);
      if (videos != null) await prefs.setInt(videosKey, videos);
    } on Object {
      // A value that did not stick still started the timer.
    }
  }

  /// 23:59:59, the longest the duration fields accept.
  static const int maxSeconds = 23 * 3600 + 59 * 60 + 59;
}

/// The menu's root row and the moon's tooltip: what it waits for, and the action after it when
/// there is one — `12:34 · then Sleep`.
String sleepTimerSummary(SleepTimerState timer, SleepEndAction action) {
  if (!timer.isOn) return 'Off';
  return action == SleepEndAction.nothing ? timer.waitsFor : '${timer.waitsFor} · then ${action.label}';
}

/// [sleepTimerSummary] as a screen reader says it: a time left in words, never digits (`spoken.dart`).
String sleepTimerSpokenSummary(SleepTimerState timer, SleepEndAction action) {
  if (timer.kind != SleepKind.duration) return sleepTimerSummary(timer, action);
  final left = '${spokenDuration(timer.left ?? Duration.zero)} left';
  return action == SleepEndAction.nothing ? left : '$left, then ${action.label}';
}
