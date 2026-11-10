/// `RILL_STANDBY_PROBE=<n>` — `n` quality switches back to back through the real second player, for `todo.md` 109.
///
/// Open a video with `RILL_OPEN_VIDEO=<id>`; once it plays, this alternates between its best rung and the next
/// distinct one and waits for each switch to end, then exits. The numbers come from the app's own log
/// (`second player: …`, `quality -> … in place: …`, `fresh urls: …`) and from `RILL_MPV_LOG`; this prints only which
/// switch it started and how long the call took. `sidecar/scratch/run-standby-arms.ps1` and `standby-arms.ts` (not
/// tracked) ran it in arms and summarised them for `todo.md` 109.
///
/// Unset, it costs one environment lookup at startup.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/hard_exit.dart';
import 'player/controls.dart' show distinctQualities;
import 'playback_controller.dart';

void runStandbyProbe(ProviderContainer container) {
  final count = int.tryParse(Platform.environment['RILL_STANDBY_PROBE'] ?? '');
  if (count == null || count <= 0) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run(container, count)));
}

void _say(String line) => stderr.writeln('probe: $line');

Future<void> _wait(int millis) => Future<void>.delayed(Duration(milliseconds: millis));

Future<void> _run(ProviderContainer container, int count) async {
  final engine = container.read(playbackEngineProvider);
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (engine.position < const Duration(seconds: 6) || container.read(playbackProvider).source == null) {
      if (DateTime.now().isAfter(deadline)) {
        _say('FAILED nothing played for 6 s within 90 s');
        hardExit(1);
      }
      await _wait(250);
    }
    final rungs = distinctQualities(container.read(playbackProvider).source!.variants);
    if (rungs.length < 2) {
      _say('FAILED the ladder has one rung');
      hardExit(1);
    }
    final best = rungs.first;
    final other = rungs.skip(1).firstWhere((v) => v.height == 1440 && v.fps >= 50, orElse: () => rungs[1]);
    _say('playing at ${container.read(playbackProvider).variant?.height}p; alternating ${best.height}p${best.fps} itag ${best.itag} '
        'and ${other.height}p${other.fps} itag ${other.itag}, $count switches');

    final playback = container.read(playbackProvider.notifier);
    for (var i = 1; i <= count; i++) {
      final target = i.isOdd ? other : best;
      final started = DateTime.now();
      _say('SWITCH $i to ${target.height}p${target.fps} itag ${target.itag} at ${engine.position.inSeconds}s');
      await playback.switchQuality(target);
      _say('SWITCH $i returned after ${DateTime.now().difference(started).inMilliseconds} ms, at ${engine.position.inSeconds}s, '
          'mpv ${engine.width}x${engine.height}, playing=${engine.playing}');
      if (engine.duration - engine.position < const Duration(seconds: 40)) {
        _say('the video is nearly over after $i switches; stopping early');
        break;
      }
      await _wait(5000);
    }
    _say('done');
  } on Object catch (error, stack) {
    _say('FAILED $error\n$stack');
    hardExit(1);
  }
  hardExit(0);
}
