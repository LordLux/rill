/// `RILL_CONTROLS_PROBE=1` — task 16's measurements, taken from the real app.
///
/// The same family of debug affordance as `RILL_OPEN_VIDEO` and
/// `RILL_SEEK_TO_END` in `main.dart`, and for the same reason: two of the things
/// this task has to report are only observable against real libmpv in a real
/// window, and neither is reachable from a widget test.
///
/// 1. **What a quality switch costs in wall-clock time.** Asked for explicitly,
///    because it decides whether an automatic stepper is worth building.
/// 2. **Whether a mode change tears down the video output.** That is a stop
///    condition, and it has a direct instrument: `VideoController.id` changes
///    when the output is rebuilt (F18's "what is observable" note). Comparing it
///    across theatre and fullscreen answers the question rather than inferring
///    it from the picture not blinking.
///
/// Unset, this costs one environment lookup at startup.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playback/engine.dart';
import '../playback_controller.dart';
import 'controls.dart';
import 'view_mode.dart';
import 'window_chrome.dart';

void runControlsProbe(ProviderContainer container) {
  if (Platform.environment['RILL_CONTROLS_PROBE'] != '1') return;
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_probe(container)));
}

void _say(String line) => stderr.writeln('probe: $line');

bool _same(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> _wait([int millis = 2000]) => Future<void>.delayed(Duration(milliseconds: millis));

Future<void> _probe(ProviderContainer container) async {
  final engine = container.read(playbackEngineProvider);
  final view = container.read(playerViewProvider.notifier);

  // `VideoController.id` is the texture handle. A `null` here means the output
  // has not attached yet; a *changed* value later means it was rebuilt.
  int? textureId() => engine is MediaKitEngine ? engine.videoController.id.value : null;

  try {
    _say('waiting for playback');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    // The ladder is part of the wait, not something to read once playback moves.
    // `PlaybackController.open` assigns `source` *after* `engine.open` returns,
    // and `engine.open` is still waiting on a duration and an audio track well
    // after mpv has started advancing the position — so "the picture is moving"
    // does not imply "the state has the variants". One run in three got here
    // with an empty ladder and silently skipped every quality measurement.
    while (engine.position <= Duration.zero ||
        engine.duration <= Duration.zero ||
        container.read(playbackProvider).source == null) {
      if (DateTime.now().isAfter(deadline)) {
        _say('FAILED nothing started playing within 60 s');
        exit(1);
      }
      await _wait(250);
    }

    final source = container.read(playbackProvider).source;
    final variants = source?.variants ?? const [];
    _say('playing. duration=${engine.duration} variants=${variants.length} '
        '[${variants.map((v) => '${v.height}p${v.fps}').join(', ')}]');

    // The baseline is taken **after** a settle, not at the first frame.
    // media_kit frees and recreates the texture once the video's real size is
    // known — `Free Texture` → `Create Texture` a second after the open — so a
    // baseline read any earlier reports every later comparison as a rebuild.
    // The first version of this probe did exactly that and called four
    // unchanged ids "REBUILT".
    await _wait(3000);
    var last = textureId();
    _say('texture id at rest: $last');

    void checkTexture(String label) {
      final now = textureId();
      _say('$label: texture=$now ${now == last ? 'UNCHANGED' : 'REBUILT'} '
          'pos=${engine.position} playing=${engine.playing}');
      last = now;
    }

    // --- modes -------------------------------------------------------------
    //
    // The window's own rectangle, read from Win32 either side of a fullscreen
    // round trip. "Exit restores the previous bounds" is otherwise a claim no
    // test can reach: `flutter test` has no window, so the fake can only record
    // that the window was asked.
    final chrome = container.read(windowChromeProvider);
    List<int>? bounds() => chrome is Win32WindowChrome ? chrome.debugBounds() : null;
    // The style as well as the rectangle: bitsdojo_window draws a custom frame,
    // and a restored rectangle with a changed style is a native title bar coming
    // back, which the bounds alone would call RESTORED.
    String style() {
      final value = chrome is Win32WindowChrome ? chrome.debugStyle() : null;
      return value == null ? 'unreadable' : '0x${value.toUnsigned(32).toRadixString(16)}';
    }

    view.toggleTheatre();
    await _wait();
    checkTexture('theatre on');

    final before = bounds();
    final styleBefore = style();
    _say('window before fullscreen: $before style=$styleBefore');

    view.toggleFullscreen();
    await _wait(3000);
    checkTexture('fullscreen on');
    _say('window while fullscreen: ${bounds()} style=${style()}');

    // Esc twice: fullscreen first, then theatre.
    _say('escape consumed=${view.escape()}');
    await _wait(3000);
    checkTexture('fullscreen off');
    final after = bounds();
    final styleAfter = style();
    _say('window after fullscreen: $after '
        '${before != null && after != null ? (_same(before, after) ? 'RESTORED' : 'CHANGED') : 'unreadable'}'
        ' style=$styleAfter ${styleAfter == styleBefore ? 'RESTORED' : 'CHANGED'}');

    _say('escape consumed=${view.escape()}');
    await _wait();
    checkTexture('theatre off');

    // --- quality -----------------------------------------------------------
    //
    // **Two numbers, and only the second one is the answer.** `switchQuality`
    // prints how long its own call took — the reopen plus the seek being
    // *issued*. What a viewer experiences is when the picture starts moving
    // again, and F18 already measured that a seek alone costs 0.8–4.6 s on this
    // machine. So this times from before the call until `time-pos` passes the
    // position it resumed from, which is F18's own method.
    //
    // Position comes off the engine's cached stream value, never a property
    // read (hard invariant 9).
    // **The frame-loop stall, measured rather than described as "it freezes".**
    //
    // A persistent frame callback fires once per frame while the UI isolate is
    // free. The gap between consecutive callbacks *is* the freeze: no frames are
    // produced while the isolate is blocked, so the largest gap across a switch
    // is how long the app was unresponsive. Wall-clock rather than the frame
    // timestamp Flutter passes, because that timestamp is the vsync the frame
    // was scheduled for and would hide exactly the delay being looked for.
    var lastFrame = DateTime.now();
    var worstGapMs = 0;
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      final now = DateTime.now();
      final gap = now.difference(lastFrame).inMilliseconds;
      if (gap > worstGapMs) worstGapMs = gap;
      lastFrame = now;
    });

    final playback = container.read(playbackProvider.notifier);
    for (final variant in distinctQualities(variants)) {
      // Read through the container, not `playback.state`: a `Notifier`'s `state`
      // is protected and visible-for-testing, and this is neither.
      final open = container.read(playbackProvider).variant;
      if (variant.height == open?.height && variant.fps == open?.fps) continue;
      final before = engine.position;
      final started = DateTime.now();
      lastFrame = DateTime.now();
      worstGapMs = 0;

      await playback.switchQuality(variant);

      final deadline = started.add(const Duration(seconds: 30));
      while (engine.position <= before && DateTime.now().isBefore(deadline)) {
        await _wait(50);
      }
      final resumed = DateTime.now().difference(started).inMilliseconds;

      _say('RESUME ${variant.height}p${variant.fps} itag=${variant.itag}: '
          '$resumed ms to move past ${before.inSeconds}s, '
          'worst frame gap $worstGapMs ms, '
          'mpv reports ${engine.height}p, playing=${engine.playing}, '
          'texture=${textureId()}');
      // Let it settle so the next measurement starts from steady playback
      // rather than from the tail of this one.
      await _wait(3000);
    }

    _say('done');
  } on Object catch (error, stack) {
    _say('FAILED $error\n$stack');
    exit(1);
  }
  exit(0);
}
