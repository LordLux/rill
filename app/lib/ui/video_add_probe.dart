import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show MPVLogLevel;

import '../data/playback/engine.dart';
import '../data/rpc/client.dart';
import '../domain/playback_source.dart';
import 'audio_delay_probe.dart' show ProbeApp;

/// Drives the engine's in-place quality switch (`docs/todo.md` 103) on a real ladder, in the real
/// app, and writes down what it did: `RILL_VIDEO_ADD_PROBE=1`.
///
/// The first version of this probe called `video-add` by hand and found what the engine now
/// does for it (the added track is read from its own start, so playback stands still until a
/// seek; a refused URL is not an error in Dart). This one exercises the engine that came of
/// that, against YouTube's own streams: the open (the audio is the file, the video is added),
/// switches across height, frame rate and codec including into and out of avc1, a switch while
/// paused, audio-only and back, and a URL that will not open. For each it reports how long the
/// call took, where the clock was before and after, and whether it kept moving.
///
/// `RILL_VIDEO_ADD_PROBE_VIDEO=<id>` picks the video (default a 4K60 one with vp9, av01 and
/// avc1 rungs), `RILL_VIDEO_ADD_PROBE_OUT` names the JSON file, `RILL_VIDEO_ADD_PROBE_VERBOSE=1`
/// puts mpv at `v` and keeps its lines in the JSON. Silent: the volume is 0.
/// Everything read from mpv comes through `observeProperty` (hard invariant 9).
class VideoAddProbe {
  VideoAddProbe({required this.engine, required this.videoId, required this.outPath});

  final MediaKitEngine engine;
  final String videoId;
  final String outPath;

  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, String> _latest = {};
  final List<Map<String, Object?>> _results = [];
  final List<String> _logs = [];

  int get _nowMs => _clock.elapsedMilliseconds;

  // `vid`, `seeking` and `vo-configured` are the engine's own observers, and mpv allows one each.
  static const List<String> _properties = [
    'time-pos',
    'avsync',
    'video-params/w',
    'video-params/h',
    'video-format',
    'track-list/count',
    'core-idle',
    'paused-for-cache',
    'pause',
  ];

  double? _number(String property) => double.tryParse(_latest[property] ?? '');

  /// The furthest the clock got since the last reset. A switch that ends behind it has sent the
  /// clock back, which is what the first version of this probe printed and did not flag.
  double _maxPos = 0;
  /// True inside a switch; the verbose mpv lines are kept only then (the open alone is hundreds).
  bool _gapWindow = false;

  void _say(String line) => stderr.writeln('probe: $line');

  String _name(PlaybackVariant v) => '${v.height}p${v.fps} ${v.videoCodec.split('.').first} itag=${v.itag}';

  Future<void> _observe() async {
    engine.logStream.listen((entry) {
      // Only inside a switch: the open alone is hundreds of lines at this level.
      if (_gapWindow && _logs.length < 800 && Platform.environment['RILL_VIDEO_ADD_PROBE_VERBOSE'] == '1') {
        _logs.add('${_nowMs}ms [${entry.prefix}] ${entry.text}'.trim());
      }
    });
    for (final property in _properties) {
      await engine.diagnostics.observeProperty(property, (value) async {
        _latest[property] = value;
        if (property == 'time-pos') {
          final seconds = double.tryParse(value);
          if (seconds != null && seconds > _maxPos) _maxPos = seconds;
        }
      });
    }
  }

  /// `RILL_VIDEO_ADD_PROBE_LOCAL=<dir>` with `v1.webm`, `v2.webm` and `a.webm` (the files
  /// `sidecar/scratch/measure-video-add.ts` describes): a switch whose new quality's first byte
  /// is held 3 s, the slow add a real network gives, on demand. On YouTube the add is quick
  /// enough that the old quality's clock barely runs ahead of it, which let a seek back to the
  /// start of the switch go unnoticed; here it runs 3 s ahead and the seek has to land there.
  Future<void> _runLocal(String dir) async {
    await engine.setVolume(0);
    final server = await Process.start(
      'bun',
      ['run', '${Directory.current.path}/sidecar/scratch/measure-video-add-server.ts'],
      environment: {'MEDIA': dir, 'DELAY_V2_MS': '3000'},
    );
    final port = Completer<int>();
    server.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('PORT ') && !port.isCompleted) port.complete(int.parse(line.substring(5)));
    });
    server.stderr.drain<void>();
    final base = 'http://127.0.0.1:${await port.future}';
    PlaybackVariant variant(String name, int height) => PlaybackVariant(
          videoUrl: '$base/$name.webm',
          audioUrl: '$base/a.webm',
          itag: height,
          height: height,
          fps: 25,
          videoCodec: 'vp9',
          audioCodec: 'opus',
        );
    final v1 = variant('v1', 240);
    final v2 = variant('v2', 252);
    try {
      await _observe();
      await engine.open(v1);
      await engine.seek(const Duration(seconds: 15));
      await _advancing();
      await _switch('slow add (new quality held 3 s)', v1, v2);
      final record = _results.last;
      final back = record['clockWentBackBy'] as double;
      _say(back > 0.5 ? 'LOCAL: the clock went back by ${back.toStringAsFixed(1)} s' : 'LOCAL: the clock did not go back');
    } finally {
      server.kill();
      _write();
    }
  }

  Future<void> run() async {
    final local = Platform.environment['RILL_VIDEO_ADD_PROBE_LOCAL']?.trim();
    if (local != null && local.isNotEmpty) {
      await _runLocal(local);
      return;
    }
    await engine.setVolume(0);
    final response = await RpcClient.instance.call('playback.open', {'videoId': videoId});
    final ladder = PlaybackSource.fromJson(response as Map<String, dynamic>).variants;
    final adaptive = ladder.where((v) => v.audioUrl != null).toList();
    if (adaptive.isEmpty) throw StateError('no adaptive variants for $videoId');
    _say('ladder: ${ladder.map(_name).join('; ')}');
    _say('muxed rungs: ${ladder.where((v) => v.audioUrl == null).map(_name).join(', ').isEmpty ? 'none in this ladder' : 'some'}');

    await _observe();

    PlaybackVariant? pick(bool Function(PlaybackVariant) test) {
      for (final v in adaptive) {
        if (test(v)) return v;
      }
      return null;
    }

    bool codec(PlaybackVariant v, String name) => v.videoCodec.startsWith(name);
    final vp9360 = pick((v) => v.height == 360 && codec(v, 'vp9'));
    final avc360 = pick((v) => v.height == 360 && codec(v, 'avc1'));
    final vp9720 = pick((v) => v.height == 720 && v.fps > 30 && codec(v, 'vp9'));
    final av1720 = pick((v) => v.height == 720 && v.fps > 30 && codec(v, 'av01'));
    final start = vp9360 ?? adaptive.last;

    // 1. The open: the audio is the file, the video is added.
    _say('--- open ${_name(start)}');
    final opened = Stopwatch()..start();
    await engine.open(start);
    final openMs = opened.elapsedMilliseconds;
    final firstPicture = await _waitFor(() => engine.videoOutputReady, 15000);
    _results.add({
      'step': 'open',
      'variant': _name(start),
      'openMs': openMs,
      'pictureMs': opened.elapsedMilliseconds,
      'pictureSeen': firstPicture,
      'vid': engine.diagnosticVid,
      'added': engine.diagnosticAddedVideoIds,
      'audioMissing': engine.audioMissing,
      'tracks': _latest['track-list/count'],
    });
    _say('    open $openMs ms, picture at ${opened.elapsedMilliseconds} ms, vid=${engine.diagnosticVid} added=${engine.diagnosticAddedVideoIds}');
    await engine.seek(const Duration(seconds: 120));
    await _advancing();
    _write();

    // 2. Switches. Each starts from a clock that is moving.
    var current = start;
    final steps = <(String, PlaybackVariant?)>[
      ('height 360 -> 720p60', vp9720),
      ('codec vp9 -> av1 (720p60)', av1720),
      ('into avc1 (360p)', avc360),
      ('out of avc1 (back to vp9 360p)', vp9360),
      ('height 360 -> 720p60 again', vp9720),
    ];
    for (final (label, target) in steps) {
      if (target == null || target == current) {
        _say('SKIPPED $label: no suitable rung');
        _results.add({'step': label, 'skipped': true});
        continue;
      }
      await _switch(label, current, target);
      current = target;
      _write();
    }

    // 3. A switch while paused: the clock cannot be the signal.
    final low = vp9360 ?? adaptive.last;
    _say('--- switch while paused ${_name(current)} -> ${_name(low)}');
    await engine.pause();
    await Future<void>.delayed(const Duration(seconds: 1));
    final pausedAt = _number('time-pos');
    final pausedWatch = Stopwatch()..start();
    final pausedResult = await engine.switchVideo(low);
    final pausedMs = pausedWatch.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(seconds: 2));
    _results.add({
      'step': 'paused switch',
      'to': _name(low),
      'result': pausedResult.name,
      'ms': pausedMs,
      'posBefore': pausedAt,
      'posAfter': _number('time-pos'),
      'video': '${_latest['video-params/w']}x${_latest['video-params/h']} ${_latest['video-format']}',
      'added': engine.diagnosticAddedVideoIds,
      'stillPaused': _latest['pause'],
    });
    _say('    paused switch ${pausedResult.name} in $pausedMs ms (the engine\'s own deadline is 20 s), clock $pausedAt -> ${_number('time-pos')}, '
        '${_latest['video-params/w']}x${_latest['video-params/h']}, pause=${_latest['pause']}');
    current = low;
    await engine.play();
    await _advancing();
    _write();

    // 4. Audio-only and back, with a quality picked while the video is off.
    _say('--- audio-only, a pick, and back');
    await engine.setVideoTrack(false);
    await Future<void>.delayed(const Duration(seconds: 3));
    final offTracks = engine.diagnosticAddedVideoIds;
    final clockOff0 = _number('time-pos');
    await Future<void>.delayed(const Duration(seconds: 2));
    final clockOff1 = _number('time-pos');
    final recorded = vp9720 ?? current;
    final recordedResult = await engine.switchVideo(recorded);
    final back = Stopwatch()..start();
    await engine.setVideoTrack(true);
    final addMs = back.elapsedMilliseconds;
    final pictureBack = await _waitFor(() => engine.videoOutputReady, 20000);
    _results.add({
      'step': 'audio-only round trip',
      'addedWhileOff': offTracks,
      'clockWhileOff': [clockOff0, clockOff1],
      'pickWhileOff': _name(recorded),
      'pickResult': recordedResult.name,
      'setVideoTrackOnMs': addMs,
      'pictureBackMs': back.elapsedMilliseconds,
      'pictureSeen': pictureBack,
      'video': '${_latest['video-params/w']}x${_latest['video-params/h']}',
      'added': engine.diagnosticAddedVideoIds,
    });
    _say('    off: added=$offTracks, clock $clockOff0 -> $clockOff1; pick ${_name(recorded)} ${recordedResult.name}; '
        'video back: add $addMs ms, picture ${back.elapsedMilliseconds} ms, now ${_latest['video-params/w']}x${_latest['video-params/h']}');
    current = recorded;
    await _advancing();
    _write();

    // 5. A stream that will not open: the old quality has to keep playing.
    _say('--- refused URL');
    final dead = current.copyWith(videoUrl: 'https://127.0.0.1:9/dead.webm', itag: 999, height: current.height == 360 ? 240 : 360);
    final posBefore = _number('time-pos');
    final refusedWatch = Stopwatch()..start();
    final refused = await engine.switchVideo(dead);
    final refusedMs = refusedWatch.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(seconds: 3));
    _results.add({
      'step': 'refused',
      'result': refused.name,
      'ms': refusedMs,
      'clockAdvanced': (_number('time-pos') ?? 0) - (posBefore ?? 0),
      'added': engine.diagnosticAddedVideoIds,
      'vid': engine.diagnosticVid,
    });
    _say('    ${refused.name} after $refusedMs ms, old quality kept playing: clock advanced ${(_number('time-pos') ?? 0) - (posBefore ?? 0)} s, added=${engine.diagnosticAddedVideoIds}');

    if (_logs.isNotEmpty) _results.add({'step': 'mpv log', 'lines': _logs});
    _write();
    _say('wrote $outPath');
  }

  Future<bool> _waitFor(bool Function() test, int timeoutMs) async {
    final until = _nowMs + timeoutMs;
    while (_nowMs < until) {
      if (test()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return false;
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
    final before = _number('time-pos');
    _maxPos = before ?? 0;
    _gapWindow = true;
    final watch = Stopwatch()..start();
    final result = await engine.switchVideo(to);
    final ms = watch.elapsedMilliseconds;
    final at = _number('time-pos');
    // The clock ran on with the old quality while the new one was fetched; the seek must land
    // there and not back at `before`. Taken now, before the window below runs on.
    final wentBack = _maxPos - (at ?? _maxPos);
    // A little longer, so a stall that begins as the call returns is counted too.
    await Future<void>.delayed(const Duration(seconds: 2));
    _gapWindow = false;
    // Three seconds on: did the clock keep going, and is the picture the new one?
    await Future<void>.delayed(const Duration(seconds: 3));
    final later = _number('time-pos');
    final record = <String, Object?>{
      'step': label,
      'from': _name(from),
      'to': _name(to),
      'result': result.name,
      'ms': ms,
      'posBefore': before,
      'posAtReturn': at,
      'furthestClockDuringSwitch': _maxPos,
      'clockWentBackBy': wentBack,
      'posThreeSecondsOn': later,
      'clockAdvancedAfter': (later ?? 0) - (at ?? 0),
      'video': '${_latest['video-params/w']}x${_latest['video-params/h']} ${_latest['video-format']}',
      'vid': engine.diagnosticVid,
      'added': engine.diagnosticAddedVideoIds,
      'avsync': _number('avsync'),
    };
    _results.add(record);
    if (wentBack > 0.5) _say('    !!! JUMPED BACK by ${wentBack.toStringAsFixed(1)} s (furthest $_maxPos, landed $at)');
    _say('    ${result.name} in $ms ms, furthest $_maxPos, clock $before -> $at -> $later (${((later ?? 0) - (at ?? 0)).toStringAsFixed(1)} s in 3 s), '
        '${record['video']}, vid=${engine.diagnosticVid} added=${engine.diagnosticAddedVideoIds}, avsync=${record['avsync']}');
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
