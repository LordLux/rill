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
  final _completed = StreamController<bool>.broadcast();

  /// Every variant handed to [open], in order.
  final List<PlaybackVariant> opened = [];
  int stopCount = 0;
  int disposeCount = 0;
  final List<Duration> seeks = [];

  Duration _positionValue = Duration.zero;
  Duration _durationValue = Duration.zero;
  bool _playingValue = false;

  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get durationStream => _duration.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get bufferingStream => _buffering.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;

  @override
  Duration get position => _positionValue;
  @override
  Duration get duration => _durationValue;
  @override
  bool get playing => _playingValue;

  /// Stands in for the `Texture` widget. Keyed so a test can find it wherever
  /// it is currently mounted — which is the point: there is one surface, and it
  /// moves between the watch page and the mini-player.
  static const Key surfaceKey = ValueKey('fake-video-surface');

  @override
  Widget videoSurface({BoxFit fit = BoxFit.contain}) =>
      const SizedBox.expand(key: surfaceKey);

  @override
  Future<void> open(PlaybackVariant variant, {bool play = true}) async {
    opened.add(variant);
    _positionValue = Duration.zero;
    _durationValue = const Duration(minutes: 10);
    _duration.add(_durationValue);
    setPlaying(play);
  }

  @override
  Future<void> play() async => setPlaying(true);
  @override
  Future<void> pause() async => setPlaying(false);
  @override
  Future<void> playOrPause() async => setPlaying(!_playingValue);
  @override
  Future<void> seek(Duration to) async {
    seeks.add(to);
    emitPosition(to);
  }

  @override
  Future<void> setVolume(double volume) async {}

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
    await _completed.close();
  }

  // --- test drivers ---

  void emitPosition(Duration value) {
    _positionValue = value;
    _position.add(value);
  }

  void setPlaying(bool value) {
    _playingValue = value;
    _playing.add(value);
  }

  /// The media reached its end — what drives queue autoplay.
  void complete() => _completed.add(true);
}
