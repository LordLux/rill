import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:rill/data/playback/engine.dart';
import 'package:rill/domain/playback_source.dart';

/// A [PlaybackEngine] with no libmpv behind it.
///
/// `flutter test` has no native player, so this is the only way to test what the
/// playback controller *does* — which variant it opens, when it opens one at
/// all, and what it does when a media ends. It also records enough to assert the
/// things that would otherwise only be visible on screen.
class FakeEngine implements PlaybackEngine {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _buffer = StreamController<Duration>.broadcast();
  final _width = StreamController<int?>.broadcast();
  final _height = StreamController<int?>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  /// Every variant handed to [open], in order.
  final List<PlaybackVariant> opened = [];
  int stopCount = 0;
  int disposeCount = 0;
  final List<Duration> seeks = [];

  /// Every [stepFrame] direction, in order. `-1` and `1` — the `,` and `.` keys.
  final List<int> frameSteps = [];

  /// Every volume handed to [setVolume], in order — "it looked silent" is not an assertion.
  final List<double> volumes = [];

  Duration _positionValue = Duration.zero;
  Duration _durationValue = Duration.zero;
  bool _playingValue = false;
  bool _bufferingValue = false;
  Duration _bufferValue = Duration.zero;
  int? _widthValue;
  int? _heightValue;
  double _volumeValue = 100;

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
  Stream<double> get volumeStream => _volume.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;

  @override
  Duration get position => _positionValue;
  @override
  Duration get duration => _durationValue;
  @override
  bool get playing => _playingValue;
  @override
  bool get buffering => _bufferingValue;
  @override
  Duration get buffer => _bufferValue;
  @override
  int? get width => _widthValue;
  @override
  int? get height => _heightValue;
  @override
  double get volume => _volumeValue;

  /// Stands in for the `Texture` widget. Keyed so a test can find it wherever
  /// it is currently mounted — which is the point: there is one surface, and it
  /// moves between the watch page and the mini-player.
  static const Key surfaceKey = ValueKey('fake-video-surface');

  @override
  Widget videoSurface({BoxFit fit = BoxFit.contain}) =>
      const SizedBox.expand(key: surfaceKey);

  /// Held open by a test that needs `open` to still be in flight later. media_kit really can
  /// take ~20 s here, waiting on a duration before it attaches the audio track.
  Future<void>? openGate;

  /// Every ASS document handed to [setSubtitle], nulls included.
  ///
  /// A log rather than just the current value: "the caption survived a quality
  /// switch" is a claim about the *sequence* — detached by the reopen, then put
  /// back — and a test reading only the final value cannot tell that from one
  /// where nothing ever happened.
  final List<String?> subtitles = [];

  String? _subtitle;

  @override
  String? get subtitle => _subtitle;

  @override
  Future<void> setSubtitle(String? ass) async {
    _subtitle = ass;
    subtitles.add(ass);
  }

  @override
  Future<void> open(PlaybackVariant variant, {bool play = true, bool retainSubtitle = false}) async {
    opened.add(variant);
    // Exactly `MediaKitEngine`'s behaviour: the reopen drops mpv's external
    // subtitle track, and only `retainSubtitle` puts it back. Modelled here
    // rather than assumed away, because "captions survive a quality switch" is
    // otherwise a test that passes against an engine that never dropped them.
    final retained = retainSubtitle ? _subtitle : null;
    _subtitle = null;

    // **Cleared on the way in, before anything is awaited — as `MediaKitEngine`
    // does.** A reopened media reports nothing valid until it loads, and that is
    // the whole hazard a quality switch has to paper over. The fake used to keep
    // the previous duration and set the new one only on the way *out*, so the
    // window where the engine says `0 of 0` did not exist here at all — and the
    // bug where the scrubber's range collapses to 1 ms and pins the thumb to the
    // far right was invisible to every test in this file.
    emitPosition(Duration.zero);
    _durationValue = Duration.zero;
    _duration.add(_durationValue);
    setWidth(null);
    setHeight(null);

    final gate = openGate;
    if (gate != null) await gate;

    _durationValue = const Duration(minutes: 10);
    _duration.add(_durationValue);
    // The real engine clears this and lets mpv report what it actually decodes.
    // Here the variant is taken at its word, which is enough for "the menu marks
    // what is playing" without pretending to model a mid-stream downgrade.
    setWidth(variant.height * 16 ~/ 9); // Best guess for fake
    setHeight(variant.height);
    setPlaying(play);
    if (retained != null) await setSubtitle(retained);
  }

  @override
  Future<void> play() async => setPlaying(true);
  @override
  Future<void> pause() async => setPlaying(false);
  @override
  Future<void> playOrPause() async => setPlaying(!_playingValue);
  /// Record the seek and go nowhere. Stands in for mpv taking its time — which
  /// is the ordinary case, not a pathological one: F19 measured a median 4.1 s
  /// between a seek being issued and the position coming back.
  bool swallowSeeks = false;

  /// Reports the target and stops there, which is what a seek does. Playback
  /// carrying on *past* the target is a separate thing a test drives with
  /// [emitPosition] — modelling it in here silently added 100 ms to every
  /// subsequent relative seek and broke the arithmetic the shortcut tests pin.
  @override
  Future<void> seek(Duration to) async {
    seeks.add(to);
    if (!swallowSeeks) emitPosition(to);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    _volumeValue = volume;
    _volume.add(volume);
  }

  /// mpv's `frame-step` pauses; so does this, or the assertion "stepping a frame
  /// leaves a still picture" would pass here and fail in front of a user.
  @override
  Future<void> stepFrame(int direction) async {
    frameSteps.add(direction);
    setPlaying(false);
  }

  /// One of the hover preview's two "there is a picture now" signals, and what
  /// the busy spinner watches.
  void setBuffering(bool value) {
    _bufferingValue = value;
    _buffering.add(value);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    setPlaying(false);
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _buffering.close();
    await _buffer.close();
    await _width.close();
    await _height.close();
    await _volume.close();
    await _completed.close();
  }

  // --- test drivers ---

  void emitPosition(Duration value) {
    _positionValue = value;
    _position.add(value);
  }

  void emitBuffer(Duration value) {
    _bufferValue = value;
    _buffer.add(value);
  }

  void setWidth(int? value) {
    _widthValue = value;
    _width.add(value);
  }

  void setHeight(int? value) {
    _heightValue = value;
    _height.add(value);
  }

  void setPlaying(bool value) {
    _playingValue = value;
    _playing.add(value);
  }

  /// The media reached its end — what drives queue autoplay.
  void complete() => _completed.add(true);
}
