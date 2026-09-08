/// **Throwaway measurement entrypoint for Task 19 phase 5.** Never wired into
/// the app; run it explicitly:
///
///   flutter build windows --release -t lib/probe_task19.dart
///   .\build\windows\x64\runner\Release\rill.exe
///
/// (`flutter run --release -t …` also works but does not always relay the app's
/// stdout back; building and launching the exe from the shell does.)
///
/// **The render-loop half needs `libass_layer.dart` instrumented** — see the
/// header of `lib/ui/player/libass_probe.dart` for the four hunks. Without them
/// the `--- LibassLayer render loop ---` block reports all zeros and everything
/// else still measures.
///
/// **This overwrites `build/windows/x64/runner/Release/`** with the probe app.
/// Re-run `flutter build windows --release` afterwards to put the real app back.
///
/// It is a real Flutter Windows process, so it has the plugins, the real
/// `MediaKitEngine` (`VideoController` and all) over the bundled `libmpv-2.dll`,
/// the real `libass-9.dll` beside the executable, and a real frame scheduler.
/// That is the whole point: everything measured here is measured against the
/// artefacts the app actually loads (hard invariant 8).
///
/// It plays a **local file** — the clock being measured is mpv's own
/// property-observation timer, which knows nothing about where the bytes came
/// from — and drives the real [LibassLayer] with a real captured caption
/// document.
///
///   RILL_PROBE_MEDIA   local video path       (default: a webm in Downloads)
///   RILL_PROBE_ASS     .ass document to mount (default: the karaoke fixture)
///   RILL_PROBE_SECONDS how long to record     (default: 30)
///   RILL_PROBE_SEEK    seek here first, in ms (default: 0)
library;

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'data/playback/engine.dart';
import 'domain/playback_source.dart';
import 'ui/playback_controller.dart';
import 'ui/player/libass_layer.dart';
import 'ui/player/libass_probe.dart';

const _defaultMedia = r'C:\Users\LordLux\Downloads\product-story-en.webm';
const _defaultAss =
    r'C:\Projects\NativeYouTube\app\test\probe_fixtures\karaoke-L-BgxLtMxh0.ass';

String _stats(String label, List<int> micros) {
  if (micros.isEmpty) return '$label  <no samples>';
  final s = [...micros]..sort();
  String at(double p) =>
      (s[((s.length - 1) * p).round()] / 1000).toStringAsFixed(2);
  final sum = s.fold<int>(0, (a, b) => a + b);
  return '$label  n=${s.length} '
      'min=${(s.first / 1000).toStringAsFixed(2)} '
      'p50=${at(0.5)} p90=${at(0.9)} p99=${at(0.99)} '
      'max=${(s.last / 1000).toStringAsFixed(2)} '
      'mean=${(sum / s.length / 1000).toStringAsFixed(2)}  (ms)';
}

/// Every `Dialogue:` (startMs, endMs) in an ASS document.
List<(int, int)> _assCues(String ass) {
  final out = <(int, int)>[];
  for (final line in ass.split(RegExp(r'\r?\n'))) {
    if (!line.trimLeft().toLowerCase().startsWith('dialogue:')) continue;
    final f = line.substring(line.indexOf(':') + 1).split(',');
    if (f.length < 3) continue;
    final a = _assTime(f[1].trim()), b = _assTime(f[2].trim());
    if (a != null && b != null && b > a) out.add((a, b));
  }
  return out;
}

int? _assTime(String s) {
  final m = RegExp(r'^(\d+):(\d\d):(\d\d)\.(\d\d)$').firstMatch(s);
  if (m == null) return null;
  return int.parse(m.group(1)!) * 3600000 +
      int.parse(m.group(2)!) * 60000 +
      int.parse(m.group(3)!) * 1000 +
      int.parse(m.group(4)!) * 10;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final engine = MediaKitEngine();
  final container = ProviderContainer(
    overrides: [playbackEngineProvider.overrideWithValue(engine)],
  );

  runApp(UncontrolledProviderScope(
    container: container,
    child: _ProbeApp(engine: engine),
  ));
}

class _ProbeApp extends StatefulWidget {
  final MediaKitEngine engine;
  const _ProbeApp({required this.engine});

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final _frames = <FrameTiming>[];
  final _posArrivalsUs = <int>[];
  final _posValuesMs = <int>[];
  final _posWallUs = <int>[];
  final _clock = Stopwatch()..start();
  int _lastPos = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    widget.engine.positionStream.listen((p) {
      final now = _clock.elapsedMicroseconds;
      if (_lastPos >= 0) _posArrivalsUs.add(now - _lastPos);
      _lastPos = now;
      _posValuesMs.add(p.inMilliseconds);
      _posWallUs.add(now);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onTimings(List<FrameTiming> timings) => _frames.addAll(timings);

  Future<void> _run() async {
    final media = Platform.environment['RILL_PROBE_MEDIA'] ?? _defaultMedia;
    final assPath = Platform.environment['RILL_PROBE_ASS'] ?? _defaultAss;
    final seconds =
        int.tryParse(Platform.environment['RILL_PROBE_SECONDS'] ?? '') ?? 30;
    final seekMs = int.tryParse(Platform.environment['RILL_PROBE_SEEK'] ?? '') ?? 0;

    print('PROBE: media=$media exists=${File(media).existsSync()}');
    print('PROBE: ass=$assPath exists=${File(assPath).existsSync()}');

    await widget.engine.open(
      PlaybackVariant(
        videoUrl: media,
        height: 1080,
        fps: 30,
        videoCodec: 'vp9',
        audioCodec: 'opus',
      ),
      play: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await widget.engine.setSubtitle(File(assPath).readAsStringSync());
    // The real app rebuilds the layer when `captionsProvider` changes; here
    // nothing does, so nudge it so `LibassLayer.build` sees the document.
    setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    setState(() {});
    if (seekMs > 0) {
      await widget.engine.seek(Duration(milliseconds: seekMs));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      print('PROBE: after seek, position=${widget.engine.position}');
    }

    // Settle: discard everything from the open itself.
    await Future<void>.delayed(const Duration(seconds: 2));
    _frames.clear();
    _posArrivalsUs.clear();
    _posValuesMs.clear();
    _posWallUs.clear();
    _lastPos = -1;
    LibassProbe.reset();
    LibassProbe.enabled = true;
    final t0 = _clock.elapsedMicroseconds;

    await Future<void>.delayed(Duration(seconds: seconds));
    LibassProbe.enabled = false;
    final elapsedMs = (_clock.elapsedMicroseconds - t0) / 1000;

    print('');
    print('===== TASK 19 PHASE 5 PROBE =====');
    print('window: ${elapsedMs.toStringAsFixed(0)} ms of playback');
    print('mode: ${const bool.fromEnvironment('dart.vm.product') ? 'release/AOT' : 'debug/JIT'}');
    print('');

    // --- (a) positionStream cadence ---------------------------------------
    print('--- positionStream ---');
    print('events=${_posValuesMs.length} '
        'first=${_posValuesMs.isEmpty ? null : _posValuesMs.first}ms '
        'last=${_posValuesMs.isEmpty ? null : _posValuesMs.last}ms');
    print(_stats('inter-arrival (wall) ', _posArrivalsUs));
    final steps = <int>[];
    for (var i = 1; i < _posValuesMs.length; i++) {
      final d = _posValuesMs[i] - _posValuesMs[i - 1];
      if (d != 0) steps.add(d.abs() * 1000);
    }
    print(_stats('reported value step  ', steps));
    for (final w in [200, 1200, 3000]) {
      var covered = 0, empty = 0;
      if (_posValuesMs.length > 1) {
        final lo = _posValuesMs.first, hi = _posValuesMs.last;
        for (var b = lo; b + w <= hi; b += w) {
          final hit = _posValuesMs.any((v) => v >= b && v < b + w);
          if (hit) {
            covered++;
          } else {
            empty++;
          }
        }
      }
      print('media-time windows of ${w}ms: covered=$covered empty=$empty');
    }
    var gapsOver200 = 0, gapsOver1200 = 0;
    for (final g in _posArrivalsUs) {
      if (g > 200000) gapsOver200++;
      if (g > 1200000) gapsOver1200++;
    }
    print('wall gaps >200ms: $gapsOver200   >1200ms: $gapsOver1200');
    print('');

    // --- (b) the render loop ------------------------------------------------
    print('--- LibassLayer render loop (real widget, real libass-9.dll) ---');
    print('scheduleRender calls   = ${LibassProbe.scheduled}');
    print('render iterations      = ${LibassProbe.rendered}');
    print('coalesced (dropped)    = ${LibassProbe.coalesced}'
        '   <- a position event that arrived while a render was in flight');
    print(_stats('isolate round trip   ', LibassProbe.isolateUs));
    print(_stats('decode+group (main)  ', LibassProbe.decodeUs));
    print(_stats('total per iteration  ', LibassProbe.totalUs));
    print('distinct nowMs rendered= ${LibassProbe.nowMs.toSet().length}');
    for (final w in [200, 1200, 3000]) {
      final r = [...LibassProbe.nowMs]..sort();
      var covered = 0, empty = 0;
      if (r.length > 1) {
        for (var b = r.first; b + w <= r.last; b += w) {
          if (r.any((v) => v >= b && v < b + w)) {
            covered++;
          } else {
            empty++;
          }
        }
      }
      print('RENDERED media-time windows of ${w}ms: covered=$covered empty=$empty');
    }
    if (LibassProbe.nowMs.length > 1) {
      final d = <int>[];
      for (var i = 1; i < LibassProbe.nowMs.length; i++) {
        d.add((LibassProbe.nowMs[i] - LibassProbe.nowMs[i - 1]).abs() * 1000);
      }
      print(_stats('rendered nowMs step  ', d));
    }
    // The question both cadence measurements actually turn on: every cue in the
    // document that was on screen during the window — did the render loop draw
    // at least one frame while it was live?
    final cues = _assCues(File(assPath).readAsStringSync());
    final rendered = [...LibassProbe.nowMs]..sort();
    if (rendered.isNotEmpty) {
      final lo = rendered.first, hi = rendered.last;
      var live = 0, missed = 0, single = 0;
      final missedList = <String>[];
      final perCue = <int>[];
      for (final c in cues) {
        if (c.$2 <= lo || c.$1 >= hi) continue; // not on screen in the window
        live++;
        final n = rendered.where((t) => t >= c.$1 && t < c.$2).length;
        perCue.add(n);
        if (n == 0) {
          missed++;
          if (missedList.length < 10) {
            missedList.add('${c.$1}-${c.$2}ms (${c.$2 - c.$1}ms long)');
          }
        } else if (n == 1) {
          single++;
        }
      }
      perCue.sort();
      print('cues live in the window = $live   '
          'with ZERO renders = $missed   with exactly one = $single');
      if (perCue.isNotEmpty) {
        print('renders per live cue: min=${perCue.first} '
            'p50=${perCue[perCue.length ~/ 2]} max=${perCue.last}');
      }
      if (missedList.isNotEmpty) print('  missed: ${missedList.join(', ')}');
    }
    print('');

    // --- (c) frame scheduler -----------------------------------------------
    print('--- FrameTiming (${_frames.length} frames) ---');
    final build = [for (final f in _frames) f.buildDuration.inMicroseconds];
    final raster = [for (final f in _frames) f.rasterDuration.inMicroseconds];
    final total = [for (final f in _frames) f.totalSpan.inMicroseconds];
    print(_stats('build                ', build));
    print(_stats('raster               ', raster));
    print(_stats('totalSpan            ', total));
    const budget60 = 16667;
    const budget120 = 8333;
    var over60 = 0, over120 = 0, jank2x = 0;
    for (final f in _frames) {
      final t = f.totalSpan.inMicroseconds;
      if (t > budget60) over60++;
      if (t > budget120) over120++;
      if (t > 2 * budget60) jank2x++;
    }
    print('frames over 16.67ms=$over60  over 8.33ms=$over120  over 33.3ms=$jank2x'
        '  (${_frames.isEmpty ? 0 : (over60 * 100 / _frames.length).toStringAsFixed(1)}% / '
        '${_frames.isEmpty ? 0 : (jank2x * 100 / _frames.length).toStringAsFixed(1)}%)');
    print('===== END =====');

    await Future<void>.delayed(const Duration(milliseconds: 400));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(child: widget.engine.videoSurface()),
            // Not `const`: an identical const instance never rebuilds, and
            // `LibassLayer.build` is where it picks up `engine.subtitle`.
            // ignore: prefer_const_constructors
            Positioned.fill(child: LibassLayer(aspectRatio: 16 / 9)),
          ],
        ),
      ),
    );
  }
}
