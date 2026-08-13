import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/playback_source.dart';
import '../../ui/debug_constants.dart';

/// The player, as everything above it is allowed to see it.
///
/// An interface rather than `Player` directly, for two reasons that are not
/// symmetrical. The small one is that `flutter test` has no libmpv, so a
/// controller talking to `Player` cannot be tested at all. The large one is
/// **hard invariant 9**: everything a caller can reach here is a stream or a
/// value this class already cached from one. There is no `getProperty` on this
/// surface, so no future caller can poll one from the UI isolate — F15 measured
/// a 6.4 s frame-loop freeze doing exactly that, and it manufactured a false
/// "seek is broken" reading before the harness was corrected.
abstract class PlaybackEngine {
  /// Position, duration and buffering come from mpv's event stream (invariant 9).
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;

  /// mpv waiting rather than presenting: opening a file, repositioning after a
  /// seek, or genuinely starved of data.
  ///
  /// **Wider than "the cache ran dry", and that is what makes it useful.**
  /// media_kit raises this from `core-idle` as well as `paused-for-cache`, and
  /// F18 measured seeks as ~95% `core-idle` (median 2458 ms of 2600) with
  /// `paused-for-cache` at **zero in all 75 samples** — so a spinner keyed on
  /// cache starvation alone would never appear on the thing that actually makes
  /// the user wait. media_kit also suppresses the `core-idle` that a `pause`
  /// causes, so this does not fire on a deliberate pause.
  ///
  /// It does **not** cover the long-pause resume penalty: F18 found those never
  /// touch `core-idle` or `paused-for-cache` at all, so a 0.5–2.3 s resume after
  /// a long idle shows nothing. Known gap, no signal available for it.
  Stream<bool> get bufferingStream;

  /// How far the demuxer has read ahead — the scrubber's buffered range.
  Stream<Duration> get bufferStream;

  /// The height mpv is **actually decoding**, which is not the height that was
  /// asked for: a variant can be opened and then serve something else, and the
  /// quality menu that reports the request rather than the result is the one
  /// that lies exactly when it matters. Null until the first frame is decoded.
  Stream<int?> get heightStream;

  /// mpv's own volume, 0–100. Streamed rather than assumed, so a volume set from
  /// anywhere is the one the slider draws.
  Stream<double> get volumeStream;

  /// Fires once per media that plays to its end. Drives queue autoplay.
  Stream<bool> get completedStream;

  /// The last values seen on the streams above. Never a property read.
  Duration get position;
  Duration get duration;
  bool get playing;

  /// Whether mpv is waiting rather than presenting — see [bufferingStream].
  bool get buffering;
  Duration get buffer;
  int? get height;
  double get volume;

  /// The video surface, for whichever widget is currently showing it.
  ///
  /// A method on the engine rather than a `Video` built at each call site,
  /// because the thing being shared is subtle and worth having exactly one
  /// statement of: **the texture belongs to the engine, not to the widget.**
  /// `VideoController` allocates the native `VideoOutput` and registers its
  /// release on `Player.dispose` — so a `Video` widget unmounting frees nothing,
  /// and this is a `Texture` id reference that any subtree may hold. Nothing
  /// resizes on layout either; `setSize` is only ever called explicitly.
  ///
  /// That is what lets the watch page and the mini-player show live video from
  /// one player without either of them owning it, and without a texture being
  /// created or freed when the route changes.
  Widget videoSurface({BoxFit fit = BoxFit.contain});

  Future<void> open(PlaybackVariant variant, {bool play = true});
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration to);
  Future<void> setVolume(double volume);

  /// One frame forward (`direction > 0`) or back — the `,` and `.` keys.
  ///
  /// A distinct operation from [seek] rather than a seek of 1/fps, because
  /// "one frame" is a thing only the decoder knows: a computed seek lands *near*
  /// the neighbouring frame and rounds differently on variable frame rate.
  Future<void> stepFrame(int direction);

  /// Stop playback and release the current media. The engine stays usable.
  Future<void> stop();

  Future<void> dispose();
}

/// The real engine: one `media_kit` [Player] for the whole app.
///
/// Owned by the shell above the `Navigator` (task §1), so a route pop cannot
/// take it — and with it the audio and the position — down.
class MediaKitEngine implements PlaybackEngine {
  /// [logLevel] is for measurement harnesses only. mpv at `v` is the level that
  /// shows stream opens and cache events — the per-track evidence no property
  /// exposes, because `demuxer-cache-state` describes one demuxer and an
  /// external audio track is a second one. It is off in the app.
  MediaKitEngine({MPVLogLevel? logLevel}) {
    _player = Player(
      configuration: logLevel == null
          ? const PlayerConfiguration()
          : PlayerConfiguration(logLevel: logLevel),
    );
    _video = VideoController(_player);

    // The one option architecture §2.4 says to set unconditionally. The build
    // media_kit ships (mpv v0.36.0-403 / FFmpeg n6.0) accepts it, echoes it back
    // and ignores it — it has no such AVOption (F12/F15, and hard invariant 8
    // is about exactly this false positive). It costs nothing here and is the
    // difference between 0/4 and 4/4 seeks on any FFmpeg from Lavf 62.10.101
    // onward, so a future pin bump is a non-event instead of a silent freeze.
    unawaited(_setStreamOptions());

    _subscriptions.addAll([
      _player.stream.position.listen((value) => _position = value),
      _player.stream.duration.listen((value) => _duration = value),
      _player.stream.playing.listen((value) => _playing = value),
      _player.stream.buffering.listen((value) => _buffering = value),
      _player.stream.buffer.listen((value) => _buffer = value),
      _player.stream.height.listen((value) => _height = value),
      _player.stream.volume.listen((value) => _volume = value),
    ]);
  }

  late final Player _player;
  late final VideoController _video;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  Duration _buffer = Duration.zero;
  int? _height;
  double _volume = 100;

  /// The controller, which outlives every route. Prefer [videoSurface].
  VideoController get videoController => _video;

  /// The variant handed to the last [open], **for diagnostics only**.
  ///
  /// `PlaybackController` publishes `source` and `variant` to state only *after*
  /// `open` returns, so when `open` throws — the 20 s audio-attach timeout being
  /// the case that matters — nothing above the engine ever learns which URL was
  /// being played. That is precisely the failure worth investigating, and it was
  /// unobservable from outside. Nothing that renders reads this.
  PlaybackVariant? lastOpened;

  /// mpv itself, **for diagnostics only** — hard invariant 9's own carve-out.
  ///
  /// Nothing that renders may touch this. `getProperty` is a blocking FFI call
  /// that can sit on mpv's core lock through a seek (F15 recorded a 6.4 s
  /// freeze), so the UI reads streams and this exists for measurement harnesses
  /// that need `observeProperty` — which delivers on mpv's event thread and
  /// polls nothing.
  NativePlayer get diagnostics => _player.platform as NativePlayer;

  /// mpv's own log lines. Empty unless the engine was built with a `logLevel`.
  Stream<PlayerLog> get logStream => _player.stream.log;

  /// mpv's error channel — failures it reports rather than logs. Diagnostics.
  Stream<String> get errorStream => _player.stream.error;

  /// `controls: NoVideoControls` because every caller draws its own.
  ///
  /// media_kit_video mounts `AdaptiveVideoControls` by default, and on Windows
  /// that is a full second transport bar — its own scrubber, clock and volume
  /// slider painted over ours, both live and both responding to clicks.
  @override
  Widget videoSurface({BoxFit fit = BoxFit.contain}) {
    return Video(controller: _video, controls: NoVideoControls, fit: fit);
  }

  Future<void> _setStreamOptions() async {
    // `RILL_STREAM_LAVF_O` replaces the value for one run. Measurement only —
    // it exists so ffmpeg's `reconnect*` options can be tested **one at a time**
    // against a real 15-minute idle, which is the only way to know which of them
    // matters rather than that some combination did. Unset in ordinary use.
    final override = Platform.environment['RILL_STREAM_LAVF_O']?.trim();
    final value = (override == null || override.isEmpty) ? streamLavfOptions : override;
    if (override != null && override.isNotEmpty) {
      stderr.writeln('engine: stream-lavf-o overridden -> $value');
    }
    try {
      await (_player.platform as NativePlayer).setProperty('stream-lavf-o', value);
    } on Object {
      // media_kit discards mpv's return code anyway (F15), so a throw here is
      // the binding failing, not mpv refusing. Nothing this app does depends on
      // the option, so it is not worth failing a launch over.
    }
  }

  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;
  @override
  Stream<Duration> get bufferStream => _player.stream.buffer;
  @override
  Stream<int?> get heightStream => _player.stream.height;
  @override
  Stream<double> get volumeStream => _player.stream.volume;
  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get playing => _playing;
  @override
  bool get buffering => _buffering;
  @override
  Duration get buffer => _buffer;
  @override
  int? get height => _height;
  @override
  double get volume => _volume;

  /// Open a variant: video first, then the audio track attached to it.
  ///
  /// The wait before `setAudioTrack` is the fix for the audio-attach race in
  /// `architecture.md` §4 — `audio-add … select` is ignored until a file is
  /// loaded and the demuxer reports a duration (F15). Guarded on the duration
  /// already being known, because a fast load has already fired the event and
  /// `firstWhere` on a stream that has passed waits forever.
  @override
  Future<void> open(PlaybackVariant variant, {bool play = true}) async {
    lastOpened = variant;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffer = Duration.zero;
    // Cleared rather than left: this is what the quality menu reads as "actually
    // playing", and a stale height from the *previous* variant would keep
    // claiming the old one for as long as it took the first frame to decode —
    // which is precisely the window a user watches after switching.
    _height = null;

    await _player.open(Media(variant.videoUrl), play: play);

    final audioUrl = variant.audioUrl;
    if (audioUrl == null) return;

    if (_player.state.duration <= Duration.zero) {
      await _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 20));
    }
    await _player.setAudioTrack(AudioTrack.uri(audioUrl, title: 'YouTube audio'));
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> playOrPause() => _player.playOrPause();
  @override
  Future<void> seek(Duration to) => _player.seek(to);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  /// mpv's own `frame-step` / `frame-back-step`.
  ///
  /// **This is not the property read hard invariant 9 forbids.** That rule is
  /// about *polling* `getProperty` from the UI isolate — a blocking read that can
  /// sit on mpv's core lock (F15 recorded a 6.4 s freeze). This writes: it is one
  /// `mpv_command` per key press, the same call `Player.seek` and `Player.play`
  /// already make through this binding, and it reads nothing back.
  ///
  /// Both commands pause as a side effect. That is mpv's behaviour and also
  /// YouTube's — frame stepping is something done to a still picture — so it is
  /// left alone rather than papered over with a `play()` afterwards.
  ///
  /// `frame-back-step` is documented as slow and best-effort: it seeks precisely
  /// and can miss. Nothing above this depends on it landing exactly, and the
  /// alternative — refusing to bind the key — is worse than an occasional
  /// two-frame jump.
  @override
  Future<void> stepFrame(int direction) => (_player.platform as NativePlayer)
      .command([direction < 0 ? 'frame-back-step' : 'frame-step']);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
  }
}
