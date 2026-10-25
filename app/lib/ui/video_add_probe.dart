import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show MPVLogLevel;

import '../data/playback/engine.dart';
import '../data/rpc/client.dart';
import '../domain/playback_source.dart';
import 'audio_delay_probe.dart' show ProbeApp;

/// Measures a quality switch done as `video-add` on the playing file instead of a reopen
/// (`docs/todo.md` 103): the part of the design that `sidecar/scratch/measure-video-add.ts`
/// could not, because that harness had no Dart, no YouTube and no real DASH timeline.
///
/// Four questions, each against a real ladder from `playback.open`:
///  1. Does `await NativePlayer.command(['video-add', …])` leave the UI isolate alone while it
///     waits for the new stream? Measured as the longest gap between 10 ms timer ticks, which
///     is also what a dropped-frame stall would look like.
///  2. Is the new track's position right? The switch happens at a non-zero position, and the
///     probe reports whether `time-pos` ever stepped backwards or jumped, and `avsync` before
///     and after (a track that started at the wrong offset shows up as a constant A/V skew).
///  3. Does a switch across an fps change and across a codec change behave the same?
///  4. What does a refused URL look like from Dart? media_kit's async command only *logs* a
///     failure, so the thing a design can rely on has to be named here.
///
/// It also reports the `expire=` of the audio URL, since `video-add` keeps the audio the file
/// was opened with and a long pause could outlive it.
///
/// Run with `RILL_VIDEO_ADD_PROBE=1`; `RILL_VIDEO_ADD_PROBE_VIDEO=<id>` picks the video (default
/// a 4K60 one with vp9, av01 and avc1 rungs) and `RILL_VIDEO_ADD_PROBE_OUT` names the JSON file.
/// Everything read from mpv comes through `observeProperty` (hard invariant 9).
class VideoAddProbe {
  VideoAddProbe({required this.engine, required this.videoId, required this.outPath});

  final MediaKitEngine engine;
  final String videoId;
  final String outPath;

  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, String> _latest = {};
  final List<Map<String, Object?>> _trace = [];
  final List<String> _logs = [];
  final List<Map<String, Object?>> _results = [];
  bool _tracing = false;

  int get _nowMs => _clock.elapsedMilliseconds;

  static const List<String> _properties = [
    'time-pos',
    'avsync',
    'video-params/w',
    'video-params/h',
    'video-format',
    'vid',
    'aid',
    'track-list/count',
    'core-idle',
    'paused-for-cache',
    'pause',
    'audio-pts',
    'estimated-frame-number',
    'seeking',
  ];

  /// Where the clock and the flags that explain a stall are every [every] for [total]: the
  /// summaries (`clockAdvanced`) cannot say whether it stopped, or why.
  Future<List<String>> _timeline(Duration total, {Duration every = const Duration(milliseconds: 500)}) async {
    final lines = <String>[];
    final until = _nowMs + total.inMilliseconds;
    while (_nowMs < until) {
      lines.add('${_nowMs}ms t=${_latest['time-pos']} audio-pts=${_latest['audio-pts']} frame=${_latest['estimated-frame-number']} '
          'vo=${engine.videoOutputReady} seeking=${_latest['seeking']} cache=${_latest['paused-for-cache']} '
          'idle=${_latest['core-idle']} pause=${_latest['pause']}');
      await Future<void>.delayed(every);
    }
    return lines;
  }

  double? _number(String property) => double.tryParse(_latest[property] ?? '');

  void _say(String line) => stderr.writeln('probe: $line');

  Future<void> run() async {
    // Silent: a minute of someone's speakers is not part of the measurement.
    await engine.setVolume(0);
    final response = await RpcClient.instance.call('playback.open', {'videoId': videoId});
    final source = PlaybackSource.fromJson(response as Map<String, dynamic>);
    final ladder = source.variants;
    if (ladder.isEmpty) throw StateError('no variants for $videoId');
    _say('ladder for $videoId:');
    for (final v in ladder) {
      _say('  ${v.height}p${v.fps} ${v.videoCodec} itag=${v.itag} audio=${v.audioUrl == null ? 'MUXED' : v.audioCodec}');
    }
    final muxed = ladder.where((v) => v.audioUrl == null).toList();
    _say('muxed rungs: ${muxed.isEmpty ? 'none in this ladder' : muxed.map((v) => '${v.height}p itag=${v.itag}').join(', ')}');

    final audioUrl = ladder.firstWhere((v) => v.audioUrl != null).audioUrl!;
    _say('audio URL ${_expiry(audioUrl)}; video URL ${_expiry(ladder.first.videoUrl)}');

    engine.logStream.listen((entry) {
      final line = '[${entry.prefix}] ${entry.text}'.trim();
      final verbose = Platform.environment['RILL_VIDEO_ADD_PROBE_VERBOSE'] == '1';
      if (_tracing && _logs.length < 600 && (verbose || RegExp(r'(video|track|open|fail|error|http|stream)', caseSensitive: false).hasMatch(line))) {
        _logs.add('${_nowMs}ms $line');
      }
    });
    for (final property in _properties) {
      await engine.diagnostics.observeProperty(property, (value) async {
        _latest[property] = value;
        if (_tracing && _trace.length < 3000 && (property == 'time-pos' || property == 'avsync' || property == 'video-params/w')) {
          _trace.add({'at': _nowMs, 'p': property, 'v': value});
        }
      });
    }

    // Starts light and low: the downloads add up over four switches.
    final pairs = _choose(ladder);
    final start = pairs.start;
    _say('start: ${_name(start)}');
    await engine.open(start);
    await _advancing();
    await engine.seek(const Duration(seconds: 120));
    await _advancing();
    _say('playing at ${_number('time-pos')?.toStringAsFixed(1)} s, vid=${_latest['vid']} aid=${_latest['aid']}');

    // The control: no video-add at all. The clock froze after the first run's switches, and
    // whether that is the switch or the probe's own playback has to be known first.
    final control = await _timeline(const Duration(seconds: 20), every: const Duration(seconds: 1));
    _results.add({'label': 'control-no-video-add', 'timeline': control});
    _say('control, 20 s of plain playback: t ${control.first.split(' ')[1]} .. ${control.last.split(' ')[1]}');

    var current = start;
    for (final (label, target) in pairs.steps) {
      if (target == null) {
        _say('SKIPPED $label: no suitable pair in this ladder');
        _results.add({'label': label, 'skipped': true});
        continue;
      }
      await _switch(label, current, target);
      current = target;
      _write();
      // `RILL_VIDEO_ADD_PROBE_STEPS=1`: stop after that many switches (a verbose log of one).
      final limit = int.tryParse(Platform.environment['RILL_VIDEO_ADD_PROBE_STEPS'] ?? '');
      if (limit != null && _results.where((r) => r['from'] != null).length >= limit) {
        _say('stopped after $limit switch(es)');
        return;
      }
    }

    if (Platform.environment['RILL_VIDEO_ADD_PROBE_DIAGNOSE'] == '1') await _diagnose(ladder);
    await _refused();
    _write();
    _say('wrote $outPath');
  }

  String _name(PlaybackVariant v) => '${v.height}p${v.fps} ${v.videoCodec} itag=${v.itag}';

  /// How long a URL has left, from its `expire=` query value.
  String _expiry(String url) {
    final expire = int.tryParse(Uri.tryParse(url)?.queryParameters['expire'] ?? '');
    if (expire == null) return 'has no expire=';
    final left = DateTime.fromMillisecondsSinceEpoch(expire * 1000).difference(DateTime.now());
    return 'expires in ${(left.inMinutes / 60).toStringAsFixed(1)} h';
  }

  ({PlaybackVariant start, List<(String, PlaybackVariant?)> steps}) _choose(List<PlaybackVariant> ladder) {
    final adaptive = ladder.where((v) => v.audioUrl != null).toList();
    PlaybackVariant? pick(bool Function(PlaybackVariant) test) {
      for (final v in adaptive) {
        if (test(v)) return v;
      }
      return null;
    }

    // Same codec throughout the first two steps, so each one changes one thing.
    final start = pick((v) => v.height == 360 && v.fps <= 30) ?? adaptive.last;
    final codec = start.videoCodec.split('.').first;
    bool sameCodec(PlaybackVariant v) => v.videoCodec.split('.').first == codec;
    final taller = pick((v) => sameCodec(v) && v.fps <= 30 && v.height == 720) ?? pick((v) => sameCodec(v) && v.fps <= 30 && v.height > start.height);
    // The same height at 60 where the ladder has it, else the lowest 60 of the codec: the ladder
    // of a video that has no 480p60 still has a 720p60, and a switch across fps is what matters.
    final faster = taller == null
        ? null
        : pick((v) => sameCodec(v) && v.height == taller.height && v.fps > 30) ??
            adaptive.reversed.cast<PlaybackVariant?>().firstWhere((v) => v != null && sameCodec(v) && v.fps > 30, orElse: () => null);
    final otherCodec = (faster ?? taller) == null
        ? null
        : pick((v) => !sameCodec(v) && v.height == (faster ?? taller)!.height && v.fps == (faster ?? taller)!.fps) ??
            pick((v) => !sameCodec(v) && v.height == (faster ?? taller)!.height);
    return (
      start: start,
      steps: [
        ('height', taller),
        ('fps', faster),
        ('codec', otherCodec),
        ('back-to-start', start),
      ],
    );
  }

  /// Milliseconds until the clock has moved 0.4 s past [from], or null if it never does in 20 s.
  Future<int?> _clockMovesFrom(double from) async {
    final started = _nowMs;
    while (_nowMs - started < 20000) {
      final now = _number('time-pos');
      if (now != null && now > from + 0.4 && _latest['seeking'] != 'yes') return _nowMs - started;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return null;
  }

  Future<void> _advancing() async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    var last = _number('time-pos');
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final now = _number('time-pos');
      if (now != null && last != null && now > last + 0.3) return;
      last ??= now;
    }
    _say('WARNING the clock never started advancing');
  }

  Future<void> _switch(String label, PlaybackVariant from, PlaybackVariant to) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    _say('--- $label: ${_name(from)} -> ${_name(to)}');
    final result = <String, Object?>{'label': label, 'from': _name(from), 'to': _name(to)};

    _trace.clear();
    _logs.clear();
    _tracing = true;

    final beforePos = _number('time-pos');
    final beforeAvsync = _number('avsync');
    final oldVid = _latest['vid'];
    final tracksBefore = _latest['track-list/count'];
    result['posBefore'] = beforePos;
    result['avsyncBefore'] = beforeAvsync;
    result['vidBefore'] = oldVid;
    result['trackCountBefore'] = tracksBefore;

    // The longest gap between 10 ms ticks while the command is out: the UI isolate's stall.
    final ticks = Stopwatch()..start();
    var last = 0;
    var longestGap = 0;
    final monitor = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = ticks.elapsedMilliseconds;
      if (now - last > longestGap) longestGap = now - last;
      last = now;
    });

    final started = _nowMs;
    var error = '';
    try {
      await engine.diagnostics.command(['video-add', to.videoUrl, 'select']);
    } on Object catch (e) {
      error = '$e';
    }
    final commandMs = _nowMs - started;
    monitor.cancel();
    final posAtReturn = _number('time-pos');
    result['commandMs'] = commandMs;
    result['uiLongestGapMs'] = longestGap;
    result['commandError'] = error;
    result['posAtReturn'] = posAtReturn;
    if (beforePos != null && posAtReturn != null) {
      result['posExpectedAtReturn'] = beforePos + commandMs / 1000;
      result['posOffFromExpected'] = posAtReturn - (beforePos + commandMs / 1000);
    }

    // **The new track is read from its own start, so without this playback sits at the old
    // position** (measured: the clock and the audio froze for as long as it was left, and any seek
    // revived them; the mpv log shows the new demuxer's cached range at 0 to 8 s while playback
    // waits at 141 s). A seek to where it is puts every demuxer in the same place.
    final target = posAtReturn ?? 0;
    final seekIssued = _nowMs;
    await engine.seek(Duration(milliseconds: (target * 1000).round()));
    final movingAfter = await _clockMovesFrom(target);
    result['seekToMovingMs'] = movingAfter;
    result['totalSwitchMs'] = movingAfter == null ? null : commandMs + (_nowMs - seekIssued);
    result['timelineAfterSwitch'] = await _timeline(const Duration(seconds: 3));
    result['avsyncAfter'] = _number('avsync');
    result['vidAfter'] = _latest['vid'];
    result['video'] = '${_latest['video-params/w']}x${_latest['video-params/h']} ${_latest['video-format']}';
    result['trackCountAfter'] = _latest['track-list/count'];
    result['aidAfter'] = _latest['aid'];

    // The clock: did it step backwards or jump anywhere in the trace?
    double? previous;
    var backwards = 0.0;
    var biggestStep = 0.0;
    for (final entry in _trace) {
      if (entry['p'] != 'time-pos') continue;
      final value = double.tryParse('${entry['v']}');
      if (value == null) continue;
      if (previous != null) {
        if (value < previous && previous - value > backwards) backwards = previous - value;
        if (value - previous > biggestStep) biggestStep = value - previous;
      }
      previous = value;
    }
    result['clockWentBackBySeconds'] = backwards;
    result['biggestClockStepSeconds'] = biggestStep;
    result['avsyncSamples'] = _trace.where((e) => e['p'] == 'avsync').map((e) => double.tryParse('${e['v']}')).whereType<double>().toList();

    // Take the old track off, as a real switch would, and see the clock keep going.
    final removeAt = _nowMs;
    final posBeforeRemove = _number('time-pos');
    var removeError = '';
    if (oldVid != null && oldVid != 'no') {
      try {
        await engine.diagnostics.command(['video-remove', oldVid]);
      } on Object catch (e) {
        removeError = '$e';
      }
    }
    result['timelineAfterRemove'] = await _timeline(const Duration(seconds: 3));
    result['removeMs'] = _nowMs - removeAt;
    result['removeError'] = removeError;
    result['vidAfterRemove'] = _latest['vid'];
    result['trackCountAfterRemove'] = _latest['track-list/count'];
    result['clockAdvancedAfterRemove'] = (_number('time-pos') ?? 0) - (posBeforeRemove ?? 0);

    // Seek inside the added track and see it land.
    final seekTo = (_number('time-pos') ?? 120) + 30;
    await engine.seek(Duration(milliseconds: (seekTo * 1000).round()));
    result['timelineAfterSeek'] = await _timeline(const Duration(seconds: 6));
    result['seekTarget'] = seekTo;
    result['posAfterSeek'] = _number('time-pos');
    result['avsyncAfterSeek'] = _number('avsync');
    result['mpvLog'] = List<String>.of(_logs);
    _tracing = false;

    _results.add(result);
    _say('    command ${result['commandMs']} ms, then seek-to-moving ${result['seekToMovingMs']} ms (total ${result['totalSwitchMs']} ms), UI longest gap ${result['uiLongestGapMs']} ms, clock back by '
        '${result['clockWentBackBySeconds']} s, biggest step ${(result['biggestClockStepSeconds'] as double).toStringAsFixed(2)} s, '
        'avsync ${result['avsyncBefore']} -> ${result['avsyncAfter']}, ${result['video']}, vid ${result['vidBefore']} -> ${result['vidAfter']} -> ${result['vidAfterRemove']}, '
        'seek $seekTo -> ${result['posAfterSeek']}');
  }

  /// The clock froze after every `video-add … select` above. What revives it, and does the new
  /// track's size matter? A switch to a track of the *same* size first, then a pause toggle, then
  /// the same switch again with `vid` set by hand instead of `select`.
  Future<void> _diagnose(List<PlaybackVariant> ladder) async {
    final same = <String, Object?>{'label': 'diagnose'};
    PlaybackVariant? find(int height, bool Function(PlaybackVariant) test) {
      for (final v in ladder) {
        if (v.audioUrl != null && v.height == height && test(v)) return v;
      }
      return null;
    }

    final vp9 = find(360, (v) => v.videoCodec.startsWith('vp9'));
    final av1 = find(360, (v) => v.videoCodec.startsWith('av01'));
    final avc = find(360, (v) => v.videoCodec.startsWith('avc1'));
    if (vp9 == null || av1 == null || avc == null) {
      _say('SKIPPED diagnose: no 360p vp9, av01 and avc1 in this ladder');
      return;
    }
    // Back to a known state: playing, clock moving.
    await engine.seek(const Duration(seconds: 300));
    await _advancing();
    same['clockMovingBefore'] = await _timeline(const Duration(seconds: 2), every: const Duration(seconds: 1));
    _tracing = true;

    _say('--- diagnose: same-size switch ${_name(vp9)} -> ${_name(av1)} (select)');
    await engine.diagnostics.command(['video-add', av1.videoUrl, 'select']);
    same['sameSizeSelect'] = await _timeline(const Duration(seconds: 4), every: const Duration(seconds: 1));

    _say('--- diagnose: pause toggle');
    await engine.diagnostics.command(['set', 'pause', 'yes']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.diagnostics.command(['set', 'pause', 'no']);
    same['afterPauseToggle'] = await _timeline(const Duration(seconds: 4), every: const Duration(seconds: 1));

    _say('--- diagnose: no select, then vid by hand (${_name(avc)})');
    final tracksBefore = int.tryParse(_latest['track-list/count'] ?? '') ?? 0;
    await engine.diagnostics.command(['video-add', avc.videoUrl, 'auto']);
    same['addedWithoutSelect'] = await _timeline(const Duration(seconds: 3), every: const Duration(seconds: 1));
    same['tracksBeforeAdd'] = tracksBefore;
    same['tracksAfterAdd'] = _latest['track-list/count'];
    same['vidAfterAddAuto'] = _latest['vid'];
    // The new track's id is the highest one: external tracks are numbered in the order added.
    final newId = (int.tryParse(_latest['vid'] ?? '') ?? 0) + 1;
    await engine.diagnostics.command(['set', 'vid', '$newId']);
    same['afterVidByHand'] = await _timeline(const Duration(seconds: 4), every: const Duration(seconds: 1));
    same['vidFinal'] = _latest['vid'];
    same['mpvLog'] = List<String>.of(_logs);
    _tracing = false;
    _results.add(same);
    _say('    diagnose written to the json');
  }

  /// A URL that cannot be fetched: what Dart gets to see.
  Future<void> _refused() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    _say('--- refused URL');
    _logs.clear();
    _tracing = true;
    final tracksBefore = _latest['track-list/count'];
    final vidBefore = _latest['vid'];
    final posBefore = _number('time-pos');
    var error = '';
    final started = _nowMs;
    try {
      await engine.diagnostics.command(['video-add', 'https://127.0.0.1:9/dead.webm', 'select']);
    } on Object catch (e) {
      error = '$e';
    }
    final ms = _nowMs - started;
    await Future<void>.delayed(const Duration(seconds: 3));
    _tracing = false;
    final result = <String, Object?>{
      'label': 'refused',
      'commandMs': ms,
      'threw': error.isNotEmpty,
      'error': error,
      'trackCountBefore': tracksBefore,
      'trackCountAfter': _latest['track-list/count'],
      'vidBefore': vidBefore,
      'vidAfter': _latest['vid'],
      'clockAdvanced': (_number('time-pos') ?? 0) - (posBefore ?? 0),
      'mpvLog': List<String>.of(_logs),
    };
    _results.add(result);
    _say('    command returned after $ms ms, threw=${error.isNotEmpty}, tracks $tracksBefore -> ${_latest['track-list/count']}, '
        'vid $vidBefore -> ${_latest['vid']}, clock advanced ${result['clockAdvanced']} s; mpv said ${_logs.length} relevant lines');
  }

  void _write() {
    File(outPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'video': videoId, 'results': _results}));
  }
}

/// Wired from `main.dart` as `RILL_VIDEO_ADD_PROBE=1`.
void runVideoAddProbe(void Function(Widget) runApp, void Function(int) exit) {
  final engine = MediaKitEngine(
    logLevel: Platform.environment['RILL_VIDEO_ADD_PROBE_VERBOSE'] == '1' ? MPVLogLevel.v : null,
  );
  final probe = VideoAddProbe(
    engine: engine,
    videoId: Platform.environment['RILL_VIDEO_ADD_PROBE_VIDEO']?.trim() ?? 'aqz-KE-bpKQ',
    outPath: Platform.environment['RILL_VIDEO_ADD_PROBE_OUT']?.trim() ?? 'video-add.json',
  );
  runApp(ProbeApp(engine: engine));
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await probe.run();
    } on Object catch (error, stack) {
      stderr.writeln('probe: FAILED $error\n$stack');
      exit(1);
    }
    exit(0);
  });
}
