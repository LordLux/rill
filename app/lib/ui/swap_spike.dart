import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/playback/engine.dart';
import '../data/rpc/client.dart';
import '../domain/playback_source.dart';

/// Step 1 of `docs/todo.md` 109: can a second player stand by and be swapped in without a gap?
/// `RILL_VIDEO_ADD_PROBE=1` plus `RILL_VIDEO_ADD_PROBE_SWAP=1`. Nothing here is the design; it is
/// the smallest rig that answers the three questions the spike was set:
///
///  1. **The surface.** Two `Video` widgets in one stack, the standby either `Offstage` or
///     stacked *under* the active one, the swap a visibility change. Does the standby's frame
///     show at the target with no black frame? Seen by capturing the composited tree every
///     frame (`RepaintBoundary.toImage`, a few dozen pixels wide) and counting black ones around
///     the swap; a baseline of the video playing proves the capture can see a texture at all.
///  2. **The seam.** At the swap the sound gap, and whether the clock ever steps back, from the
///     players' own `audio-pts` and `time-pos` events with wall-clock stamps, not from the
///     property stream the UI reads.
///  3. **The cost.** The process's private bytes before the standby exists, with it ready,
///     after the swap with the first player stopped, and after that player is disposed.
///
/// The standby is opened paused, aimed at `clock + 3.5 s` (the measured ready time of 2.5 to
/// 3.1 s is longer than the 1.5 s first guessed), with a 6 s read-ahead; it is re-aimed with a
/// 1.2 s lead if the clock gets too close. The swap starts the standby, pauses the first player
/// and flips the visibility together, 0.12 s before the clock reaches the target, which is about
/// what the pause takes to land.
class SwapSpike {
  SwapSpike({required this.videoId, required this.outPath});

  final String videoId;
  final String outPath;

  final ValueNotifier<_Rig?> _rig = ValueNotifier<_Rig?>(null);
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object?>> _results = [];

  int get _us => _clock.elapsedMicroseconds;
  int get _ms => _clock.elapsedMilliseconds;

  void _say(String line) => stderr.writeln('probe: $line');

  Widget app() {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        // ignore: rill_lints/no_color_literals
        backgroundColor: Colors.black,
        body: ValueListenableBuilder<_Rig?>(
          valueListenable: _rig,
          builder: (context, rig, _) {
            if (rig == null) return const SizedBox.shrink();
            return RepaintBoundary(
              key: rig.boundary,
              child: ValueListenableBuilder<bool>(
                valueListenable: rig.bActive,
                builder: (context, bActive, _) => rig.layout == 'offstage'
                    ? Stack(fit: StackFit.expand, children: [
                        Offstage(offstage: bActive, child: rig.a.videoWidget()),
                        Offstage(offstage: !bActive, child: rig.b.videoWidget()),
                      ])
                    // The standby is always there, painted first and covered; hiding the active
                    // one reveals it.
                    : Stack(fit: StackFit.expand, children: [
                        rig.b.videoWidget(),
                        Offstage(offstage: bActive, child: rig.a.videoWidget()),
                      ]),
              ),
            );
          },
        ),
      ),
    );
  }

  // --- helpers ---

  Future<Map<String, double>?> _memory() async {
    const script = r'''
$p = Get-Process -Id PIDHERE
"$($p.PrivateMemorySize64) $($p.WorkingSet64)"
''';
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-Command', script.replaceAll('PIDHERE', '$pid')])
          .timeout(const Duration(seconds: 20));
      final parts = '${r.stdout}'.trim().split(' ');
      return {'privateMB': int.parse(parts[0]) / 1048576, 'workingSetMB': int.parse(parts[1]) / 1048576};
    } on Object {
      return null;
    }
  }

  Future<void> _waitFor(bool Function() test, int timeoutMs) async {
    final until = _ms + timeoutMs;
    while (_ms < until && !test()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// A seek has finished: `seeking` true then false, or never true and false for 0.6 s.
  Future<int> _seekDone(MediaKitEngine e, Duration target) async {
    final started = _ms;
    var saw = false;
    final done = Completer<void>();
    final sub = e.seekingStream.listen((on) {
      if (on) saw = true;
      if (!on && saw && !done.isCompleted) done.complete();
    });
    await e.seek(target);
    await Future.any([done.future, Future<void>.delayed(const Duration(seconds: 15))]);
    if (!saw) await Future<void>.delayed(const Duration(milliseconds: 600));
    await sub.cancel();
    return _ms - started;
  }

  final Map<String, List<(int, double)>> _events = {};

  Future<void> _watch(MediaKitEngine e, String tag) async {
    for (final property in const ['audio-pts', 'time-pos']) {
      final key = '$tag/$property';
      _events[key] = [];
      try {
        await e.diagnostics.observeProperty(property, (value) async {
          final v = double.tryParse(value);
          if (v != null) _events[key]!.add((_us, v));
        }).timeout(const Duration(seconds: 10));
      } on TimeoutException {
        _say('$tag: observeProperty($property) did not complete in 10 s (the texture never initialised?)');
      }
    }
  }

  // --- the frame capture ---

  final List<(int, double, double)> _frames = []; // t µs, mean luma, fraction near black
  bool _capturing = false;

  Future<void> _capture() async {
    while (_capturing) {
      await WidgetsBinding.instance.endOfFrame;
      final rig = _rig.value;
      final object = rig?.boundary.currentContext?.findRenderObject();
      if (object is! RenderRepaintBoundary || !object.attached) continue;
      try {
        final width = object.size.width;
        if (width <= 0) continue;
        final image = await object.toImage(pixelRatio: 48 / width);
        final data = await image.toByteData();
        image.dispose();
        if (data == null) continue;
        var sum = 0.0;
        var dark = 0;
        final pixels = data.lengthInBytes ~/ 4;
        for (var i = 0; i < pixels; i++) {
          final r = data.getUint8(i * 4);
          final g = data.getUint8(i * 4 + 1);
          final b = data.getUint8(i * 4 + 2);
          final luma = 0.299 * r + 0.587 * g + 0.114 * b;
          sum += luma;
          if (luma < 6) dark++;
        }
        _frames.add((_us, sum / pixels, dark / pixels));
      } on Object {
        // A frame that could not be captured is a hole in the record, not a result.
      }
    }
  }

  // --- the run ---

  Future<void> run() async {
    final response = await RpcClient.instance.call('playback.open', {'videoId': videoId});
    final ladder = PlaybackSource.fromJson(response as Map<String, dynamic>).variants.where((v) => v.audioUrl != null).toList();
    PlaybackVariant rung(int height, int fps) =>
        ladder.firstWhere((v) => v.height == height && v.fps == fps && v.videoCodec.startsWith('vp9'), orElse: () => ladder.last);
    final r720 = rung(720, 60);
    final r1080 = rung(1080, 60);
    final r1440 = rung(1440, 60);
    final r2160 = rung(2160, 60);
    _say('rungs: ${[r720, r1080, r1440, r2160].map((v) => '${v.height}p${v.fps} itag=${v.itag}').join(', ')}');

    final only = Platform.environment['RILL_VIDEO_ADD_PROBE_SWAP_ONLY']?.split(',');
    final scenarios = <(String, PlaybackVariant, PlaybackVariant)>[
      ('1080p60 -> 720p60', r1080, r720),
      ('2160p60 -> 1440p60', r2160, r1440),
      ('1080p60 -> 2160p60', r1080, r2160),
    ];
    for (final layout in ['offstage', 'under']) {
      for (final (name, a, b) in scenarios) {
        if (only != null && !only.contains(layout) && !only.contains(name)) continue;
        try {
          await _scenario(layout, name, a, b);
        } on Object catch (error, stack) {
          _say('$layout / $name FAILED: $error\n$stack');
          _results.add({'layout': layout, 'scenario': name, 'failed': '$error'});
        }
        _write();
      }
    }
    _say('wrote $outPath');
  }

  Future<void> _scenario(String layout, String name, PlaybackVariant ra, PlaybackVariant rb) async {
    _say('=== $layout: $name');
    final a = MediaKitEngine();
    final b = MediaKitEngine();
    final rig = _Rig(a, b, layout);
    _events.clear();
    _frames.clear();
    // Mounted first: media_kit waits for a surface before it will do anything to a player, and
    // a `setVolume` awaited before that never returns.
    _rig.value = rig;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await a.setVolume(0).timeout(const Duration(seconds: 10), onTimeout: () => _say('A: setVolume did not return in 10 s'));
    await b.setVolume(0).timeout(const Duration(seconds: 10), onTimeout: () => _say('B: setVolume did not return in 10 s (its surface never initialised?)'));
    await _watch(a, 'A');
    await _watch(b, 'B');
    final result = <String, Object?>{'layout': layout, 'scenario': name};

    // A plays at the rung under test, deep enough in that the content is not an intro.
    await a.open(ra);
    await a.seek(const Duration(seconds: 150));
    await _waitFor(() => a.position > const Duration(seconds: 152), 20000);
    _capturing = true;
    unawaited(_capture());
    await Future<void>.delayed(const Duration(seconds: 3));
    final baseline = _frames.where((f) => f.$1 > _us - 2500000).map((f) => f.$2).toList();
    final baselineLuma = baseline.isEmpty ? 0.0 : baseline.reduce((x, y) => x + y) / baseline.length;
    result['captureSeesTheVideo'] = baselineLuma > 8;
    result['baselineMeanLuma'] = baselineLuma;
    result['memoryBeforeStandby'] = await _memory();

    // The standby: paused, a short read-ahead, aimed past where it will be ready.
    await b.diagnostics.setProperty('demuxer-readahead-secs', '6');
    await b.diagnostics.setProperty('cache-secs', '10');
    final swapLead = int.tryParse(Platform.environment['RILL_SWAP_TRIGGER_MS'] ?? '') ?? 30;
    final prepStart = _ms;
    await b.open(rb, play: false);
    final openMs = _ms - prepStart;
    final firstLead = int.tryParse(Platform.environment['RILL_SWAP_FIRST_LEAD_MS'] ?? '') ?? 5000;
    final reaimLead = int.tryParse(Platform.environment['RILL_SWAP_REAIM_LEAD_MS'] ?? '') ?? 2500;
    var target = a.position + Duration(milliseconds: firstLead);
    var seekMs = await _seekDone(b, target);
    final aims = <String>['lead ${firstLead}ms: seek took $seekMs ms, clock then ${(target - a.position).inMilliseconds} ms short of the target'];
    var reaims = 0;
    // A re-aim is a seek inside what is already read: 0.5 to 1.7 s measured, so its lead is longer than that.
    while (a.position > target - const Duration(milliseconds: 600) && reaims < 4) {
      reaims++;
      target = a.position + Duration(milliseconds: reaimLead);
      seekMs = await _seekDone(b, target);
      aims.add('re-aim ${reaimLead}ms: seek took $seekMs ms, clock then ${(target - a.position).inMilliseconds} ms short of the target');
    }
    result['aims'] = aims;
    result['standbyOpenMs'] = openMs;
    result['standbyReadyMs'] = _ms - prepStart;
    result['standbyLastSeekMs'] = seekMs;
    result['reaims'] = reaims;
    result['standbyPositionAtReady'] = b.position.inMilliseconds / 1000;
    result['clockAtReady'] = a.position.inMilliseconds / 1000;
    result['memoryStandbyReady'] = await _memory();
    final stillAhead = target - a.position;
    _say('aims: ${aims.join('; ')}');
    _say('standby ready ${_ms - prepStart} ms after the start (open $openMs, seek $seekMs), re-aims $reaims, '
        'target is ${stillAhead.inMilliseconds} ms ahead of the clock');
    if (stillAhead < const Duration(milliseconds: 100)) {
      result['verdict'] = 'standby was not ready before the clock reached the target; no swap made';
      await _teardown(a, b);
      _results.add(result);
      return;
    }

    // The swap, a few tens of ms before the clock gets there: the pause and play commands land in
    // 7 to 9 ms (measured), and an earlier trigger skips that much of the sound.
    await a.positionStream.firstWhere((p) => p >= target - Duration(milliseconds: swapLead)).timeout(const Duration(seconds: 20));
    final tSwap = _us;
    final aPositionAtSwap = a.position.inMilliseconds / 1000;
    final commands = Future.wait<void>([b.play(), a.pause()]);
    rig.bActive.value = true;
    await commands;
    final commandsDoneMs = (_us - tSwap) / 1000;
    await Future<void>.delayed(const Duration(seconds: 6));
    _capturing = false;

    List<(int, double)> after(String key, int from) => _events[key]!.where((e) => e.$1 >= from).toList();
    List<(int, double)> before(String key, int to) => _events[key]!.where((e) => e.$1 <= to).toList();
    final aAudio = before('A/audio-pts', tSwap + 400000);
    final bAudio = after('B/audio-pts', tSwap).where((e) => e.$2 > target.inMilliseconds / 1000 - 0.3).toList();
    final aClock = before('A/time-pos', tSwap + 400000);
    final bClock = after('B/time-pos', tSwap).where((e) => e.$2 > target.inMilliseconds / 1000 - 0.3).toList();
    if (aAudio.isNotEmpty && bAudio.isNotEmpty) {
      final lastA = aAudio.last;
      final firstB = bAudio.first;
      final wallGap = (firstB.$1 - lastA.$1) / 1000;
      final ptsStep = (firstB.$2 - lastA.$2) * 1000;
      result['audioLastA_ms_afterSwapStart'] = (lastA.$1 - tSwap) / 1000;
      result['audioFirstB_ms_afterSwapStart'] = (firstB.$1 - tSwap) / 1000;
      result['audioPtsStepMs'] = ptsStep; // B's first pts minus A's last; negative is back
      final gap = wallGap - ptsStep; // wall time between them beyond what the pts jump accounts for
      result['audioGapMs'] = gap;
      result['silenceMs'] = gap > 0 ? gap : 0.0; // nothing played for this long
      result['contentSkippedMs'] = gap < 0 ? -gap : 0.0; // this much of the sound was never played
    }
    if (aClock.isNotEmpty && bClock.isNotEmpty) {
      result['clockStepMs'] = (bClock.first.$2 - aClock.last.$2) * 1000; // negative is back
    }
    var worstBack = 0.0;
    final merged = [...aClock.map((e) => (e.$1, e.$2)), ...bClock.map((e) => (e.$1, e.$2))]..sort((x, y) => x.$1.compareTo(y.$1));
    for (var i = 1; i < merged.length; i++) {
      final step = merged[i].$2 - merged[i - 1].$2;
      if (step < worstBack) worstBack = step;
    }
    result['worstClockStepBackMs'] = worstBack * 1000;

    final around = _frames.where((f) => f.$1 >= tSwap - 300000 && f.$1 <= tSwap + 1500000).toList();
    result['framesCapturedAroundSwap'] = around.length;
    result['blackFramesAroundSwap'] = around.where((f) => f.$3 > 0.9).length;
    result['darkestMeanLumaAroundSwap'] = around.isEmpty ? null : around.map((f) => f.$2).reduce((x, y) => x < y ? x : y);
    result['aPositionAtSwapStart'] = aPositionAtSwap;
    result['commandsDoneMs'] = commandsDoneMs;
    result['targetSeconds'] = target.inMilliseconds / 1000;

    // The first player goes, and what that frees.
    await a.stop();
    await Future<void>.delayed(const Duration(seconds: 2));
    result['memoryAfterSwapFirstStopped'] = await _memory();
    await a.dispose();
    await Future<void>.delayed(const Duration(seconds: 3));
    result['memoryFirstDisposed'] = await _memory();
    final s = result;
    _say('swap: silence ${(s['silenceMs'] as num?)?.toStringAsFixed(0)} ms, sound skipped ${(s['contentSkippedMs'] as num?)?.toStringAsFixed(0)} ms (pts step ${(s['audioPtsStepMs'] as num?)?.toStringAsFixed(0)} ms), '
        'clock step ${(s['clockStepMs'] as num?)?.toStringAsFixed(0)} ms, worst step back ${(s['worstClockStepBackMs'] as num?)?.toStringAsFixed(0)} ms, '
        'black frames ${s['blackFramesAroundSwap']} of ${s['framesCapturedAroundSwap']} (darkest mean luma ${(s['darkestMeanLumaAroundSwap'] as num?)?.toStringAsFixed(1)}; '
        'the capture ${s['captureSeesTheVideo'] == true ? 'sees' : 'DOES NOT SEE'} the video, baseline ${baselineLuma.toStringAsFixed(1)})');
    _say('memory MB private: before ${_mb(s['memoryBeforeStandby'])}, standby ready ${_mb(s['memoryStandbyReady'])}, '
        'after swap and first stopped ${_mb(s['memoryAfterSwapFirstStopped'])}, first disposed ${_mb(s['memoryFirstDisposed'])}');
    _rig.value = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await b.dispose();
    _results.add(result);
  }

  String _mb(Object? m) => m is Map ? (m['privateMB'] as double).toStringAsFixed(0) : 'n/a';

  Future<void> _teardown(MediaKitEngine a, MediaKitEngine b) async {
    _capturing = false;
    _rig.value = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await a.dispose();
    await b.dispose();
  }

  void _write() {
    File(outPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'video': videoId, 'results': _results}));
  }
}

class _Rig {
  _Rig(this.a, this.b, this.layout);

  final MediaKitEngine a;
  final MediaKitEngine b;
  final String layout;
  final ValueNotifier<bool> bActive = ValueNotifier<bool>(false);
  final GlobalKey boundary = GlobalKey();
}

/// Wired from `main.dart` as `RILL_VIDEO_ADD_PROBE=1` plus `RILL_VIDEO_ADD_PROBE_SWAP=1`.
void runSwapSpike(void Function(Widget) runApp, void Function(int) exit) {
  final spike = SwapSpike(
    videoId: Platform.environment['RILL_VIDEO_ADD_PROBE_VIDEO']?.trim() ?? 'aqz-KE-bpKQ',
    outPath: Platform.environment['RILL_VIDEO_ADD_PROBE_OUT']?.trim() ?? 'video-add-swap.json',
  );
  runApp(spike.app());
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await spike.run();
    } on Object catch (error, stack) {
      stderr.writeln('probe: FAILED $error\n$stack');
      exit(1);
    }
    exit(0);
  });
}
