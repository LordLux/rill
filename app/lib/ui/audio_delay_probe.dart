import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

// `AppExitResponse` lives in dart:ui, not services; prefixed because dart:ui
// also exports names material already owns.
import 'dart:ui' as ui show AppExitResponse;

import 'package:flutter/material.dart';

import '../data/playback/engine.dart';
import '../data/rpc/client.dart';
import '../domain/playback_source.dart';

/// Measures how long audio takes to come back after a resume or a seek.
///
/// The reported symptom is roughly a second of silence after pressing play. The
/// question this answers first is *which* second: whether playback as a whole
/// stalls, or whether video runs while the audio track is still catching up —
/// and whether the delay grows with how long the player sat paused. A delay
/// that scales with pause length is an idle connection being torn down, which
/// is a different problem from a seek re-sync and has different fixes.
///
/// Everything here reads mpv through `observeProperty`, which fetches on mpv's
/// own event thread and delivers a string. No polling, no `getProperty` from
/// the UI isolate (hard invariant 9); the harness that did poll manufactured a
/// false reading once already (F15).
///
/// Run with `RILL_AUDIO_PROBE=<plan>`, where plan is a comma-separated list of
/// `resume:<pauseSeconds>`, `seek:+<n>` or `seek:-<n>`, each optionally
/// suffixed `x<samples>`. `RILL_AUDIO_PROBE_OUT` names the JSON file.
class AudioDelayProbe {
  AudioDelayProbe({
    required this.engine,
    required this.videoId,
    required this.plan,
    required this.outPath,
  });

  final MediaKitEngine engine;
  final String videoId;
  final List<ProbeStep> plan;
  final String outPath;

  /// The last value seen for each observed property, with the millisecond it
  /// arrived. `observeProperty` gives us strings; everything numeric is parsed
  /// once here rather than at each comparison.
  final Map<String, _Observation> _latest = {};

  /// Every observation during the current event, for the trace in the output.
  final List<Map<String, Object?>> _trace = [];

  /// mpv's log lines, kept in their own list with their own budget.
  ///
  /// They shared the trace's 400-entry cap once, and property changes — which
  /// arrive dozens per second — crowded them out: four samples produced six to
  /// nine log lines each, which was not enough to say whether the audio URL
  /// reconnected as well as the video one. The whole question this probe exists
  /// to answer lives in these lines, so they get their own room.
  final List<Map<String, Object?>> _logTrace = [];
  bool _tracing = false;

  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object?>> _samples = [];

  static const List<String> _properties = [
    'audio-pts',
    'time-pos',
    'core-idle',
    'paused-for-cache',
    'demuxer-cache-duration',
    'demuxer-cache-time',
    'cache-buffering-state',
  ];

  int get _nowMs => _clock.elapsedMilliseconds;

  /// Everything the app can see about its own environment coming apart.
  ///
  /// Two probe runs exited mid-measurement with an orderly `~VideoOutput`, no
  /// Windows error event and no Dart stack. The first explanation — the machine
  /// entering standby — is **falsified**: the event log shows no power
  /// transition within twenty minutes of either death. So this logs every
  /// surface that could carry the real one, and a heartbeat, so a run that dies
  /// again says how far it got and what it saw first.
  void _watchForTeardown() {
    // Flutter's own lifecycle. On Windows this is what a hide, a minimise or a
    // shutdown request arrives as.
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) => _always('lifecycle: $state'),
      onExitRequested: () async {
        _always('lifecycle: EXIT REQUESTED');
        return ui.AppExitResponse.exit;
      },
    );

    // media_kit's error channel — mpv's own failures, distinct from its log.
    _subscriptions.add(engine.errorStream.listen((e) => _always('player error: $e')));

    // The texture id. If the video output is torn down and rebuilt underneath
    // us, this is the one observable that changes — and it is the hook a
    // recovery would have to hang on.
    final controller = engine.videoController;
    void onId() => _always('texture id -> ${controller.id.value}');
    controller.id.addListener(onId);

    // A heartbeat, so the last line before an exit is a timestamp rather than
    // silence. Also proves the isolate was alive right up to the end.
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      _always('heartbeat t+${(_nowMs / 1000).toStringAsFixed(0)}s '
          'playing=${engine.playing} pos=${engine.position.inSeconds}s');
    });
  }

  /// Held so neither is collected. The probe runs for the life of the process
  /// and cancels nothing — a teardown watcher that stops watching before the
  /// teardown would be worse than not having one.
  // ignore: unused_field
  AppLifecycleListener? _lifecycle;
  // ignore: unused_field
  Timer? _heartbeat;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Logged to stderr regardless of whether a sample is being traced.
  void _always(String line) {
    stderr.writeln('probe: $line');
    _note(line);
  }

  Future<void> run() async {
    if (Platform.environment['RILL_AUDIO_PROBE_NO_AWAKE'] == '1') {
      stderr.writeln('probe: NOT holding the machine awake (deliberate, for reproduction)');
    } else {
      _keepMachineAwake();
    }
    _watchForTeardown();
    stderr.writeln('probe: resolving $videoId');
    final response = await RpcClient.instance.call('playback.open', {'videoId': videoId});
    final source = PlaybackSource.fromJson(response as Map<String, dynamic>);
    final variant = source.best;
    if (variant == null) throw StateError('no playable variant for $videoId');

    stderr.writeln(
      'probe: ${variant.height}p${variant.fps} ${variant.videoCodec}'
      ' + ${variant.audioCodec}, audio ${variant.audioUrl == null ? 'MUXED' : 'separate'}',
    );
    if (variant.audioUrl == null) {
      throw StateError('this variant is muxed — there is no external audio track to measure');
    }

    // Log lines are the only per-track evidence: mpv exposes one
    // `demuxer-cache-state`, and the external audio demuxer is not it.
    engine.playingStream.listen((playing) => _note('playing=$playing'));
    final logs = engine.logStream.listen((entry) {
      final line = '[${entry.prefix}] ${entry.text}'.trim();
      if (_interesting.hasMatch(line)) _note(line);
    });

    for (final property in _properties) {
      await engine.diagnostics.observeProperty(property, (value) async {
        _record(property, value);
      });
    }

    await engine.open(variant);
    await _waitUntilAdvancing();

    for (final step in plan) {
      for (var sample = 1; sample <= step.samples; sample++) {
        stderr.writeln('probe: ${step.label} sample $sample/${step.samples}');
        final measured = await _measure(step, sample);
        _samples.add(measured);
        _write();
      }
    }

    await logs.cancel();
    _write();
    stderr.writeln('probe: wrote $outPath');
  }

  /// Hold the machine awake for the duration of the probe.
  ///
  /// Not a convenience — without it this measurement cannot be taken at all.
  /// media_kit releases its wakelock the moment playback pauses
  /// (`video_texture.dart:346`), so a probe whose whole method is *pausing for
  /// five minutes* leaves nothing holding the machine up. Two runs died exactly
  /// that way: standby is 20 minutes here, and both processes disappeared with
  /// an orderly `~VideoOutput` and no Dart stack.
  ///
  /// `SetThreadExecutionState` is per-process and lapses when the process exits;
  /// it changes no user setting. `ES_CONTINUOUS` makes the request stick rather
  /// than resetting the idle timer once.
  static void _keepMachineAwake() {
    if (!Platform.isWindows) return;
    const int esContinuous = 0x80000000;
    const int esSystemRequired = 0x00000001;
    const int esDisplayRequired = 0x00000002;
    try {
      final setState = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<Uint32 Function(Uint32), int Function(int)>('SetThreadExecutionState');
      final previous = setState(esContinuous | esSystemRequired | esDisplayRequired);
      stderr.writeln('probe: holding the machine awake (previous state 0x${previous.toRadixString(16)})');
    } on Object catch (error) {
      stderr.writeln('probe: WARNING could not hold the machine awake ($error) — '
          'a long-pause arm may be cut short by standby');
    }
  }

  /// mpv lines worth keeping: a new connection, a cache event, a track change.
  static final RegExp _interesting = RegExp(
    r'(https?:|stream|cache|demux|audio|ao/|aid|reconnect|open|EOF|seek|Cache|track)',
    caseSensitive: false,
  );

  void _note(String line) {
    if (!_tracing) return;
    if (_logTrace.length > 300) return;
    _logTrace.add({'at': _nowMs, 'log': line});
  }

  void _record(String property, String value) {
    final numeric = double.tryParse(value);
    _latest[property] = _Observation(value: value, numeric: numeric, atMs: _nowMs);
    if (_tracing && _trace.length <= 400) {
      _trace.add({'at': _nowMs, 'property': property, 'value': value});
    }
  }

  double? _number(String property) => _latest[property]?.numeric;
  String? _string(String property) => _latest[property]?.value;

  /// Wait until both clocks are moving, so a measurement starts from playback
  /// rather than from a still-loading file.
  Future<void> _waitUntilAdvancing({Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    final startAudio = _number('audio-pts');
    final startTime = _number('time-pos');
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final audio = _number('audio-pts');
      final time = _number('time-pos');
      if (audio != null && time != null && audio != startAudio && time != startTime) return;
    }
    stderr.writeln('probe: WARNING clocks never started advancing');
  }

  Future<Map<String, Object?>> _measure(ProbeStep step, int sample) async {
    // Settle first: a measurement taken while the previous one is still
    // draining measures the previous one.
    await Future<void>.delayed(const Duration(seconds: 3));

    _trace.clear();
    _logTrace.clear();
    _tracing = true;

    final Map<String, Object?> result = {
      'kind': step.kind,
      'label': step.label,
      'sample': sample,
    };

    double target;
    if (step.kind == 'resume') {
      await engine.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final pausedAt = _number('time-pos') ?? 0;
      result['pausedAtSeconds'] = pausedAt;
      result['pauseSeconds'] = step.seconds;

      _note('--- paused, waiting ${step.seconds}s ---');
      await Future<void>.delayed(Duration(milliseconds: (step.seconds * 1000).round()));
      _note('--- resuming ---');

      // Anything from here is what the resume cost.
      target = pausedAt;
      final t0 = _nowMs;
      result['cacheBeforeSeconds'] = _number('demuxer-cache-duration');
      result['cacheStateBefore'] = _string('cache-buffering-state');
      await engine.play();
      await _awaitAdvance(result, t0, target);
    } else {
      final from = _number('time-pos') ?? 0;
      target = (from + step.seconds).clamp(5.0, (engine.duration.inSeconds - 30).toDouble());
      result['fromSeconds'] = from;
      result['targetSeconds'] = target;

      _note('--- seeking $from -> $target ---');
      final t0 = _nowMs;
      result['cacheBeforeSeconds'] = _number('demuxer-cache-duration');
      result['cacheStateBefore'] = _string('cache-buffering-state');
      await engine.seek(Duration(milliseconds: (target * 1000).round()));
      await _awaitAdvance(result, t0, target);
    }

    result['cacheAfterSeconds'] = _number('demuxer-cache-duration');
    result['trace'] = List<Map<String, Object?>>.from(_trace);
    result['logs'] = List<Map<String, Object?>>.from(_logTrace);
    _tracing = false;

    // Make sure we are playing again before the next sample.
    if (!engine.playing) await engine.play();
    return result;
  }

  /// Watch both clocks past [target] and record when each got there.
  ///
  /// "Advanced" is deliberately `> target + 0.05`, not "changed": after a seek
  /// both properties report the target immediately, and reporting a position is
  /// not the same as playing from it.
  Future<void> _awaitAdvance(
    Map<String, Object?> result,
    int t0,
    double target, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    int? audioAt;
    int? timeAt;
    var pausedForCacheMs = 0;
    var coreIdleMs = 0;
    int? lastTick;

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final tick = _nowMs;
      final elapsed = lastTick == null ? 0 : tick - lastTick;
      lastTick = tick;
      if (_string('paused-for-cache') == 'yes') pausedForCacheMs += elapsed;
      if (_string('core-idle') == 'yes') coreIdleMs += elapsed;

      final audio = _number('audio-pts');
      final time = _number('time-pos');
      if (audioAt == null && audio != null && audio > target + 0.05) {
        audioAt = _latest['audio-pts']!.atMs;
      }
      if (timeAt == null && time != null && time > target + 0.05) {
        timeAt = _latest['time-pos']!.atMs;
      }
      if (audioAt != null && timeAt != null) break;
    }

    result['audioResumeMs'] = audioAt == null ? null : audioAt - t0;
    result['videoResumeMs'] = timeAt == null ? null : timeAt - t0;
    result['audioMinusVideoMs'] =
        (audioAt == null || timeAt == null) ? null : audioAt - timeAt;
    result['pausedForCacheMs'] = pausedForCacheMs;
    result['coreIdleMs'] = coreIdleMs;

    await _watchForStall(result);
  }

  /// Keep watching after playback resumes, for audio going quiet while video
  /// keeps going.
  ///
  /// The reported symptom is a second of *silence*, not a second of nothing, and
  /// the two are different measurements. mpv's master clock is the audio clock
  /// by default, so `time-pos` and `audio-pts` normally move together and the
  /// first-advance figures above cannot tell them apart. What would show the
  /// symptom is `audio-pts` standing still while `time-pos` walks on — so that
  /// is measured directly, for three seconds after the resume.
  Future<void> _watchForStall(
    Map<String, Object?> result, {
    Duration window = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(window);
    var worstStallMs = 0;
    var lastAudio = _number('audio-pts');
    var lastAudioChangeMs = _nowMs;
    var videoAdvancedDuringStall = false;
    var lastTime = _number('time-pos');

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final audio = _number('audio-pts');
      final time = _number('time-pos');

      if (audio != null && audio != lastAudio) {
        lastAudio = audio;
        lastAudioChangeMs = _nowMs;
      } else {
        final stall = _nowMs - lastAudioChangeMs;
        if (stall > worstStallMs) {
          worstStallMs = stall;
          // Only interesting if the picture kept moving through it.
          videoAdvancedDuringStall = time != null && lastTime != null && time > lastTime + 0.05;
        }
      }
      if (time != null) lastTime = time;
    }

    result['worstAudioStallMs'] = worstStallMs;
    result['videoAdvancedDuringStall'] = videoAdvancedDuringStall;
  }

  void _write() {
    final report = {
      'videoId': videoId,
      'writtenAt': DateTime.now().toUtc().toIso8601String(),
      'samples': _samples,
    };
    File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report));
  }
}

/// The probe's window: the video surface and nothing else.
///
/// Not decoration. `observeProperty` waits on the `VideoController` finishing
/// initialisation, and that never happens without a Flutter view to attach a
/// texture to — the first version of this probe ran headless and hung there,
/// silently, before its first sample. Mounting the real surface also keeps the
/// measurement faithful: the app renders while it plays, and a frame loop
/// competing for mpv's core lock is part of what is being measured.
class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key, required this.engine});

  final MediaKitEngine engine;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: engine.videoSurface()),
      );
}

class _Observation {
  const _Observation({required this.value, required this.numeric, required this.atMs});
  final String value;
  final double? numeric;
  final int atMs;
}

class ProbeStep {
  const ProbeStep({
    required this.kind,
    required this.seconds,
    required this.samples,
    required this.label,
  });

  /// `resume` or `seek`.
  final String kind;

  /// Pause length for a resume; signed offset for a seek.
  final double seconds;
  final int samples;
  final String label;

  /// `resume:2x10`, `seek:+60x10`, `seek:-60x10`.
  static ProbeStep? parse(String spec) {
    final match = RegExp(r'^(resume|seek):([+-]?[\d.]+)(?:x(\d+))?$').firstMatch(spec.trim());
    if (match == null) return null;
    return ProbeStep(
      kind: match.group(1)!,
      seconds: double.parse(match.group(2)!),
      samples: int.tryParse(match.group(3) ?? '') ?? 1,
      label: spec.trim(),
    );
  }
}
