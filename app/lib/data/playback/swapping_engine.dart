import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../domain/playback_source.dart';
import 'engine.dart';

/// How the second player is aimed and when it is swapped in. Every number is from the spike
/// (`todo.md` 109): the standby was ready 1.2 to 1.5 s after it started, a seek inside what it
/// had read took 0.5 to 1.8 s, and the pause and play commands land in 7 to 9 ms.
class SwapTuning {
  const SwapTuning({
    this.firstLead = const Duration(seconds: 5),
    this.reaimLead = const Duration(milliseconds: 2500),
    this.trigger = const Duration(milliseconds: 30),
    this.tooClose = const Duration(milliseconds: 600),
    this.openTimeout = const Duration(seconds: 25),
    this.prepareTimeout = const Duration(seconds: 30),
    this.maxReaims = 4,
    this.maxFailures = 3,
  });

  /// How far past the clock the first aim lands: the standby must be ready before the clock gets there.
  final Duration firstLead;

  /// The lead of a re-aim, at least. A re-aim is a seek inside what is read, and it takes as long
  /// as it takes: from the second re-aim on, the larger of this and twice the last seek plus a second.
  final Duration reaimLead;

  /// How long before the clock reaches the target the swap begins, which is what the commands take.
  /// Earlier skips that much of the sound; later is that much silence.
  final Duration trigger;

  /// A seek that ends with the target this close to the clock (or behind it) is a miss: aim again.
  final Duration tooClose;

  final Duration openTimeout;
  final Duration prepareTimeout;
  final int maxReaims;

  /// Standbys that failed in a row before the engine stops trying and uses the in-place switch.
  final int maxFailures;

  /// The defaults, with `RILL_SWAP_FIRST_LEAD_MS`, `RILL_SWAP_REAIM_LEAD_MS` and
  /// `RILL_SWAP_TRIGGER_MS` for a measurement run.
  factory SwapTuning.fromEnvironment() {
    Duration? read(String name) {
      final value = int.tryParse(Platform.environment[name] ?? '');
      return value == null ? null : Duration(milliseconds: value);
    }

    const defaults = SwapTuning();
    return SwapTuning(
      firstLead: read('RILL_SWAP_FIRST_LEAD_MS') ?? defaults.firstLead,
      reaimLead: read('RILL_SWAP_REAIM_LEAD_MS') ?? defaults.reaimLead,
      trigger: read('RILL_SWAP_TRIGGER_MS') ?? defaults.trigger,
    );
  }
}

/// Raised inside a swap for anything that ends it without a swap. The caller falls back to the
/// in-place switch; the reason only goes to the log.
class _SwapAbandoned implements Exception {
  const _SwapAbandoned(this.why);
  final String why;

  @override
  String toString() => why;
}

/// One stream of the engine, re-emitted from whichever player is active.
class _Forward<T> {
  _Forward(this._select);

  final Stream<T> Function(SwapSlot slot) _select;
  final StreamController<T> _out = StreamController<T>.broadcast();
  StreamSubscription<T>? _subscription;

  Stream<T> get stream => _out.stream;

  void bind(SwapSlot slot) {
    final old = _subscription;
    if (old != null) unawaited(old.cancel());
    _subscription = _select(slot).listen((value) {
      if (!_out.isClosed) _out.add(value);
    });
  }

  /// A value that is state, handed to the listeners when the source changes: the new player does
  /// not announce what it already holds.
  void push(T value) {
    if (!_out.isClosed) _out.add(value);
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _out.close();
  }
}

/// The engine the app uses: two players behind one [PlaybackEngine], so that a quality switch
/// need not stop the picture and the sound (`todo.md` 109, `architecture.md` §2.16).
///
/// One player is **active**. A switch opens the new quality in a **standby** — paused, with a
/// read-ahead — aims it a few seconds past the clock, and swaps at the moment the clock gets
/// there: the standby starts, the active pauses, and every stream below is re-pointed. The old
/// player is stopped and disposed; the next switch makes a new standby.
///
/// Everything else is the active player's, forwarded. The fallbacks, in order: the standby cannot
/// be made ready, and the in-place switch (the active player's own `switchVideo`) runs; that
/// refuses, and the caller reopens the media.
class SwappingEngine implements PlaybackEngine {
  SwappingEngine(
    this._create, {
    this.tuning = const SwapTuning(),
    this.enabled = true,
    Future<void> Function()? settle,
    this.trace,
  }) : _settle = settle ?? _afterFrames {
    _active = _create();
    _bind(_active);
  }

  final SwapSlot Function() _create;
  final SwapTuning tuning;
  final bool enabled;
  final Future<void> Function() _settle;

  /// One line per decision; null off. The app logs to stderr.
  void Function(String line)? trace;

  late SwapSlot _active;
  SwapSlot? _standby;

  /// Bumped by anything that makes a swap in progress pointless: a new media, a stop, a dispose.
  int _epoch = 0;

  /// Bumped when the viewer moves the clock, which makes an aimed standby wrong.
  int _clockGeneration = 0;

  int _failures = 0;
  bool _disposed = false;
  final List<Future<void>> _retiring = [];

  /// The `playing` the engine answers while the standby has not yet said it is playing.
  bool? _assumePlaying;

  final ValueNotifier<int> _surface = ValueNotifier<int>(0);
  int _mountedSurfaces = 0;

  /// The player showing now. For diagnostics and tests.
  SwapSlot get active => _active;

  /// A standby exists: a swap is being prepared.
  bool get hasStandby => _standby != null;

  void _say(String line) {
    final sink = trace;
    if (sink != null) sink(line);
  }

  // --- Streams, re-pointed at the swap ---

  final _position = _Forward<Duration>((s) => s.positionStream);
  final _duration = _Forward<Duration>((s) => s.durationStream);
  final _playing = _Forward<bool>((s) => s.playingStream);
  final _buffering = _Forward<bool>((s) => s.bufferingStream);
  final _buffer = _Forward<Duration>((s) => s.bufferStream);
  final _width = _Forward<int?>((s) => s.widthStream);
  final _height = _Forward<int?>((s) => s.heightStream);
  final _volumeForward = _Forward<double>((s) => s.volumeStream);
  final _completed = _Forward<bool>((s) => s.completedStream);
  final _videoOutput = _Forward<bool>((s) => s.videoOutputStream);
  final _audioMissingForward = _Forward<bool>((s) => s.audioMissingStream);
  final _seekingForward = _Forward<bool>((s) => s.seekingStream);
  final _subtitleText = _Forward<String?>((s) => s.subtitleTextStream);

  void _bind(SwapSlot slot) {
    _position.bind(slot);
    _duration.bind(slot);
    _playing.bind(slot);
    _buffering.bind(slot);
    _buffer.bind(slot);
    _width.bind(slot);
    _height.bind(slot);
    _volumeForward.bind(slot);
    _completed.bind(slot);
    _videoOutput.bind(slot);
    _audioMissingForward.bind(slot);
    _seekingForward.bind(slot);
    _subtitleText.bind(slot);
  }

  /// After the swap: what the new player holds, to everyone who listens to the old one's streams.
  /// `playing` is not among them (see [_assumePlaying]) and `completed` is an event, not a state.
  void _announce(SwapSlot slot) {
    _position.push(slot.position);
    _duration.push(slot.duration);
    _buffering.push(slot.buffering);
    _buffer.push(slot.buffer);
    _width.push(slot.width);
    _height.push(slot.height);
    _volumeForward.push(slot.volume);
    _videoOutput.push(slot.videoOutputReady);
    _audioMissingForward.push(slot.audioMissing);
    _seekingForward.push(slot.seeking);
  }

  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get bufferingStream => _buffering.stream;
  @override
  Stream<Duration> get bufferStream => _buffer.stream;
  @override
  Stream<int?> get widthStream => _width.stream;
  @override
  Stream<int?> get heightStream => _height.stream;
  @override
  Stream<double> get volumeStream => _volumeForward.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<bool> get videoOutputStream => _videoOutput.stream;
  @override
  Stream<bool> get audioMissingStream => _audioMissingForward.stream;
  @override
  Stream<bool> get seekingStream => _seekingForward.stream;
  @override
  Stream<String?> get subtitleTextStream => _subtitleText.stream;

  @override
  Duration get position => _active.position;
  @override
  Duration get duration => _active.duration;
  @override
  bool get playing => _assumePlaying ?? _active.playing;
  @override
  bool get buffering => _active.buffering;
  @override
  Duration get buffer => _active.buffer;
  @override
  int? get width => _active.width;
  @override
  int? get height => _active.height;
  @override
  double get volume => _active.volume;
  @override
  bool get videoOutputReady => _active.videoOutputReady;
  @override
  bool get audioMissing => _active.audioMissing;
  @override
  bool get seeking => _active.seeking;

  // --- The surface ---

  @override
  final LayerLink videoLayerLink = LayerLink();

  @override
  Widget videoWidget({BoxFit fit = BoxFit.contain}) => _SwapSurface(engine: this, fit: fit);

  @override
  Widget videoSurface({BoxFit fit = BoxFit.contain}) =>
      CompositedTransformTarget(link: videoLayerLink, child: videoWidget(fit: fit));

  // --- What both players must agree on ---

  String? _subtitle;
  bool _subtitleVisible = true;

  @override
  String? get subtitle => _subtitle;

  @override
  Future<void> setSubtitle(String? ass) async {
    _subtitle = ass;
    final standby = _standby;
    if (standby != null) unawaited(standby.setSubtitle(ass).catchError((Object _) {}));
    await _active.setSubtitle(ass);
  }

  @override
  Future<void> setSubtitleVisible(bool visible) async {
    _subtitleVisible = visible;
    final standby = _standby;
    if (standby != null) unawaited(standby.setSubtitleVisible(visible).catchError((Object _) {}));
    await _active.setSubtitleVisible(visible);
  }

  @override
  Future<void> setVolume(double volume) async {
    final standby = _standby;
    if (standby != null) unawaited(standby.setVolume(volume).catchError((Object _) {}));
    await _active.setVolume(volume);
  }

  @override
  Future<void> setVideoTrack(bool enabled) async {
    // Audio-only: no picture shows, so a standby has nothing to swap in for.
    if (!enabled) await _dropStandby();
    await _active.setVideoTrack(enabled);
  }

  // --- Everything that is the active player's alone ---

  @override
  Future<void> open(
    PlaybackVariant variant, {
    bool play = true,
    bool Function()? shouldPlay,
    bool retainSubtitle = false,
    bool isLive = false,
  }) async {
    _epoch++;
    await _dropStandby();
    return _active.open(variant, play: play, shouldPlay: shouldPlay, retainSubtitle: retainSubtitle, isLive: isLive);
  }

  @override
  Future<void> play() {
    _assumePlaying = null;
    return _active.play();
  }

  @override
  Future<void> pause() {
    _assumePlaying = null;
    return _active.pause();
  }

  @override
  Future<void> playOrPause() {
    final was = playing;
    _assumePlaying = null;
    return was ? _active.pause() : _active.play();
  }

  @override
  Future<void> seek(Duration to) {
    _clockGeneration++;
    return _active.seek(to);
  }

  @override
  Future<void> stepFrame(int direction) {
    _clockGeneration++;
    return _active.stepFrame(direction);
  }

  @override
  Future<void> stop() async {
    _epoch++;
    await _dropStandby();
    return _active.stop();
  }

  @override
  bool canSwitchVideo(PlaybackVariant variant) => _active.canSwitchVideo(variant);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    await _dropStandby();
    await Future.wait(_retiring);
    for (final forward in <_Forward<Object?>>[
      _position,
      _duration,
      _playing,
      _buffering,
      _buffer,
      _width,
      _height,
      _volumeForward,
      _completed,
      _videoOutput,
      _audioMissingForward,
      _seekingForward,
      _subtitleText,
    ]) {
      await forward.close();
    }
    await _active.dispose();
    _surface.dispose();
  }

  // --- The switch ---

  @override
  Future<VideoSwitch> switchVideo(PlaybackVariant variant) async {
    final active = _active;
    if (!active.canSwitchVideo(variant)) return VideoSwitch.unsupported;
    if (_wantsSecondPlayer()) {
      try {
        await _swapTo(variant);
        _failures = 0;
        return VideoSwitch.done;
      } on _SwapAbandoned catch (abandoned) {
        _say('second player: ${abandoned.why}; switching in place');
      } on Object catch (error) {
        _failures++;
        _say('second player failed ($error, $_failures in a row); switching in place');
      }
      await _dropStandby();
    }
    return _active.switchVideo(variant);
  }

  bool _wantsSecondPlayer() =>
      enabled && !_disposed && _failures < tuning.maxFailures && _mountedSurfaces > 0 && _active.videoEnabled;

  /// Throws [_SwapAbandoned] when this swap is no longer the thing to do.
  void _stillWanted(int epoch, SwapSlot old, DateTime deadline) {
    if (_disposed || epoch != _epoch) throw const _SwapAbandoned('the media changed');
    if (!identical(old, _active)) throw const _SwapAbandoned('the active player changed');
    if (!old.videoEnabled) throw const _SwapAbandoned('the picture was turned off');
    if (DateTime.now().isAfter(deadline)) throw const _SwapAbandoned('the standby was not ready in time');
  }

  Future<void> _swapTo(PlaybackVariant variant) async {
    final epoch = _epoch;
    final old = _active;
    final deadline = DateTime.now().add(tuning.prepareTimeout);
    final dropsAtStart = old.droppedFrames;
    final standby = await _startStandby(old);
    _stillWanted(epoch, old, deadline);
    final openStarted = DateTime.now();
    await standby.open(variant, play: false).timeout(tuning.openTimeout);
    _say('second player: standby opened in ${DateTime.now().difference(openStarted).inMilliseconds} ms');
    _stillWanted(epoch, old, deadline);
    await standby.setSubtitleVisible(_subtitleVisible);
    await standby.setSubtitle(_subtitle);

    var lead = tuning.firstLead;
    var reaims = 0;
    final started = DateTime.now();
    while (true) {
      _stillWanted(epoch, old, deadline);
      final generation = _clockGeneration;
      final wasPlaying = old.playing;
      // Paused, the clock stands still, so the standby goes exactly there and the swap is a flip.
      final target = wasPlaying ? old.position + lead : old.position;
      final seekStarted = DateTime.now();
      await standby.seekAndWait(target).timeout(tuning.openTimeout);
      final seekTook = DateTime.now().difference(seekStarted);
      _stillWanted(epoch, old, deadline);
      if (generation != _clockGeneration || old.playing != wasPlaying) {
        _say('second player: the viewer moved the clock or the play state; aiming again');
        continue;
      }
      if (!wasPlaying) {
        _say('second player: standby ready after ${DateTime.now().difference(started).inMilliseconds} ms, swapping paused');
        await _swap(old, standby, playing: false);
        return;
      }
      final ahead = target - old.position;
      if (ahead < tuning.tooClose) {
        reaims++;
        if (reaims > tuning.maxReaims) throw const _SwapAbandoned('the standby never got ahead of the clock');
        // The first seek is cold (4.4 s in the app, 0.5 to 1.8 s in the spike) and says little about
        // the next, which lands inside what is read; only a re-aim that was itself slow lengthens the lead.
        final wanted = seekTook * 2 + const Duration(seconds: 1);
        lead = reaims > 1 && wanted > tuning.reaimLead ? wanted : tuning.reaimLead;
        _say('second player: seek took ${seekTook.inMilliseconds} ms, ${ahead.inMilliseconds} ms ahead; re-aim $reaims with ${lead.inMilliseconds} ms');
        continue;
      }
      final reached = await _waitForClock(old, target - tuning.trigger, generation, epoch, deadline);
      if (!reached) continue;
      _say('second player: standby ready after ${DateTime.now().difference(started).inMilliseconds} ms, '
          'swapping at ${old.position.inMilliseconds} ms for ${target.inMilliseconds} ms');
      _say('second player: the viewed player dropped ${old.droppedFrames - dropsAtStart} frames while the standby was made');
      await _swap(old, standby, playing: true);
      return;
    }
  }

  /// True when [old]'s clock has reached [at]; false when the viewer moved the clock or paused first.
  Future<bool> _waitForClock(SwapSlot old, Duration at, int generation, int epoch, DateTime deadline) async {
    if (old.position >= at) return true;
    final done = Completer<bool>();
    late final StreamSubscription<Duration> positions;
    late final StreamSubscription<bool> plays;
    Timer? poll;
    void finish(bool value) {
      if (done.isCompleted) return;
      poll?.cancel();
      done.complete(value);
    }

    positions = old.positionStream.listen((value) {
      // A position that got there by a seek is not the clock arriving: the aim is stale.
      if (generation != _clockGeneration) {
        finish(false);
      } else if (value >= at) {
        finish(true);
      }
    });
    plays = old.playingStream.listen((value) {
      if (!value) finish(false);
    });
    // The checks that need no event: a seek, a stop, the deadline.
    poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (generation != _clockGeneration) finish(false);
      if (_disposed || epoch != _epoch || DateTime.now().isAfter(deadline)) finish(false);
    });
    try {
      final reached = await done.future;
      _stillWanted(epoch, old, deadline);
      return reached;
    } finally {
      poll.cancel();
      await positions.cancel();
      await plays.cancel();
    }
  }

  /// A new player, mounted, and set up like the active one. The surface comes first: media_kit
  /// does nothing to a player whose texture has no widget (a `setVolume` awaited before that
  /// never returned in the spike).
  Future<SwapSlot> _startStandby(SwapSlot old) async {
    await _dropStandby();
    final standby = _create();
    _standby = standby;
    _surface.value++;
    await _settle();
    await standby.setVolume(old.volume).timeout(const Duration(seconds: 10));
    await standby.prepareStandby();
    return standby;
  }

  Future<void> _swap(SwapSlot old, SwapSlot standby, {required bool playing}) async {
    _active = standby;
    _standby = null;
    _bind(standby);
    _assumePlaying = playing ? true : null;
    // The commands are issued together and the picture changes in the same frame: the sound and
    // the clock are the standby's from the moment it plays.
    final commands = playing ? Future.wait<void>([standby.play(), old.pause()]) : Future.value(<void>[]);
    _surface.value++;
    _announce(standby);
    await commands;
    if (playing) {
      unawaited(
        standby.playingStream.firstWhere((value) => value, orElse: () => true).timeout(const Duration(seconds: 1), onTimeout: () => true).whenComplete(() {
          if (!_disposed) _assumePlaying = null;
        }),
      );
    }
    _retiring.add(_retire(old));
  }

  /// The old player leaves the tree, then stops (which ends its downloads) and is disposed.
  Future<void> _retire(SwapSlot old) async {
    try {
      await _settle();
      await old.stop();
      await old.dispose();
    } on Object catch (error) {
      _say('second player: retiring the old player failed: $error');
    }
  }

  Future<void> _dropStandby() async {
    final standby = _standby;
    if (standby == null) return;
    _standby = null;
    _surface.value++;
    final retired = _retire(standby);
    _retiring.add(retired);
    await retired;
  }
}

Future<void> _afterFrames() async {
  await WidgetsBinding.instance.endOfFrame;
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

/// The two players' pictures in one place: the active one shown, the standby kept in the tree
/// but off stage so its texture is live and brought on by a flag, not by a build.
class _SwapSurface extends StatefulWidget {
  const _SwapSurface({required this.engine, required this.fit});

  final SwappingEngine engine;
  final BoxFit fit;

  @override
  State<_SwapSurface> createState() => _SwapSurfaceState();
}

class _SwapSurfaceState extends State<_SwapSurface> {
  @override
  void initState() {
    super.initState();
    widget.engine._mountedSurfaces++;
  }

  @override
  void dispose() {
    widget.engine._mountedSurfaces--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    return ValueListenableBuilder<int>(
      valueListenable: engine._surface,
      builder: (context, _, _) {
        final active = engine._active;
        final standby = engine._standby;
        // Keyed by player, so a swap moves no state: the standby's `Video` is the one that was
        // already there, and only its `offstage` changes.
        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(key: ObjectKey(active), offstage: false, child: active.videoWidget(fit: widget.fit)),
            if (standby != null) Offstage(key: ObjectKey(standby), offstage: true, child: standby.videoWidget(fit: widget.fit)),
          ],
        );
      },
    );
  }
}
