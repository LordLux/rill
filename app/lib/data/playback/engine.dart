import 'dart:async';

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
  Stream<bool> get bufferingStream;

  /// Fires once per media that plays to its end. Drives queue autoplay.
  Stream<bool> get completedStream;

  /// The last values seen on the streams above. Never a property read.
  Duration get position;
  Duration get duration;
  bool get playing;

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

  /// Stop playback and release the current media. The engine stays usable.
  Future<void> stop();

  Future<void> dispose();
}

/// The real engine: one `media_kit` [Player] for the whole app.
///
/// Owned by the shell above the `Navigator` (task §1), so a route pop cannot
/// take it — and with it the audio and the position — down.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine() {
    _player = Player();
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
    ]);
  }

  late final Player _player;
  late final VideoController _video;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  /// The controller, which outlives every route. Prefer [videoSurface].
  VideoController get videoController => _video;

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
    try {
      await (_player.platform as NativePlayer).setProperty('stream-lavf-o', streamLavfOptions);
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
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get playing => _playing;

  /// Open a variant: video first, then the audio track attached to it.
  ///
  /// The wait before `setAudioTrack` is the fix for the audio-attach race in
  /// `architecture.md` §4 — `audio-add … select` is ignored until a file is
  /// loaded and the demuxer reports a duration (F15). Guarded on the duration
  /// already being known, because a fast load has already fired the event and
  /// `firstWhere` on a stream that has passed waits forever.
  @override
  Future<void> open(PlaybackVariant variant, {bool play = true}) async {
    _position = Duration.zero;
    _duration = Duration.zero;

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
