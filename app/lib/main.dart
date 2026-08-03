/// Task 07 — the media_kit harness.
///
/// Deliberately not an app. It is the smallest Flutter program that can answer
/// whether `media_kit` behaves like the libmpv it wraps, because every playback
/// finding in this project (F10–F13) was measured through libmpv's **C API**
/// while the app drives it through media_kit's Dart FFI binding and its ANGLE
/// render path instead. F13's own measurement-gap note says that gap is
/// reasoning, not evidence.
///
/// One window. No feed, no tiles, no state management, no theming.
///
/// Everything is driven by environment variables so one build serves every
/// measurement — a `--dart-define` needs a rebuild per mode, and rebuilding
/// between runs of the same question is how you end up comparing two binaries:
///
///   NY_STREAM_JSON  path to `spiking/07-out/stream.json`; found by walking up
///                   from the working directory when unset
///   NY_MODE         manual (default) · q1 · q2 · q3
///   NY_TRACK        av1 (default, spike 05's track) · vp9
///   NY_OPTIONS      baseline (default) · request_size
///   NY_HWDEC        override media_kit's `hwdec=auto` — `no` is Q3's control
///   NY_LOGLEVEL     mpv log level; `debug` for decoder-selection detail
///   NY_OUT          where an automated run writes its verdict
///   NY_RUN          a label carried through to the verdict, for run 1..5
///
/// stdout stays clean here too; the harness talks on stderr.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'data/rpc/client.dart';


// ---------------------------------------------------------------------------
// The measurement plan
// ---------------------------------------------------------------------------

/// Spike 05's check 4, unchanged: four seeks, at these wall-clock seconds.
///
/// Identical to the C-API run on purpose — the whole point of this task is that
/// the only difference between the two measurements is media_kit.
const List<(int, int)> seekPlan = [(8, 300), (16, 60), (24, 500), (32, 120)];

/// Seconds after a seek before its position is read.
const int checkDelaySeconds = 5;

/// Wall-clock second the run ends.
const int quitAtSeconds = 40;

/// **Position must advance past the target, never equal it.**
///
/// mpv sets `time-pos` the instant a seek is queued, so a frozen player reports
/// exactly 300.0 and reads as a success. Spike 05's failing baseline did
/// precisely that. This margin is what tells a seek from a stall.
const double advancedByAtLeast = 0.5;

/// F11 and F13's value. 1 MB.
const int requestSizeBytes = 1048576;

/// The hedge `sidecar/src/playback/mpv-options.ts` records, plus the seek-size
/// companion spike 05 used. The shipped build accepts both and ignores them.
const String streamLavfOptions =
    'request_size=$requestSizeBytes,short_seek_size=$requestSizeBytes';

/// mpv properties sampled for the readout and the verdict.
///
/// `hwdec-current` and the decoder description are both here because they can
/// disagree, and when they do the disagreement is the finding.
const List<String> observedProperties = [
  'mpv-version',
  'ffmpeg-version',
  'hwdec',
  'hwdec-current',
  'video-codec',
  'current-tracks/video/decoder-desc',
  'audio-codec',
  'avsync',
  'frame-drop-count',
  'decoder-frame-drop-count',
  'track-list/count',
  'aid',
  'vo',
  'stream-lavf-o',
  'demuxer-cache-time',
  'video-params/w',
  'video-params/h',
  'video-params/pixelformat',
  'video-params/hw-pixelformat',
  'container-fps',
  'estimated-vf-fps',
];

/// How often the property sample runs.
///
/// Each sample is one FFI round trip per property, and this harness is the only
/// other thing on the CPU that Q3 is trying to measure. 1 Hz keeps the readout
/// live without the observer showing up in the observation.
const Duration sampleInterval = Duration(seconds: 1);

/// mpv log lines worth keeping — the decoder question is settled in the log,
/// not in a property. "Using hardware decoding (d3d11va-copy)" and
/// "Falling back to software decoding" are both statements no property makes.
final RegExp interestingLogLines =
    RegExp(r'hwdec|hardware|software decoding|decoder|dav1d|Using|VO:|AO:', caseSensitive: false);

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

enum HarnessMode { manual, q1, q2, q3 }

class HarnessConfig {
  const HarnessConfig({
    required this.mode,
    required this.track,
    required this.setRequestSize,
    required this.videoId,
    required this.outPath,
    required this.runLabel,
    required this.hwdec,
    required this.logLevel,
  });

  final HarnessMode mode;
  final String track;
  final bool setRequestSize;
  final String videoId;
  final String? outPath;
  final String runLabel;


  /// null leaves media_kit's own default (`auto`) alone. `no` is Q3's control:
  /// if forcing software decode costs the same CPU, the "hardware decoding"
  /// the log claims was not doing any work.
  final String? hwdec;
  final MPVLogLevel logLevel;

  bool get automated => mode != HarnessMode.manual;

  static HarnessConfig fromEnvironment() {
    final env = Platform.environment;
    final mode = HarnessMode.values.firstWhere(
      (m) => m.name == (env['NY_MODE'] ?? 'manual'),
      orElse: () => HarnessMode.manual,
    );

    return HarnessConfig(
      mode: mode,
      track: env['NY_TRACK'] ?? 'av1',
      // Q2 is the question "can this be set at all", so that mode always sets
      // it. Q1 is explicitly the no-options baseline: F13 expects 4/4 with
      // nothing set, and anything less is the finding.
      setRequestSize: mode == HarnessMode.q2 || env['NY_OPTIONS'] == 'request_size',
      videoId: env['NY_VIDEO_ID'] ?? 'aqz-KE-bpKQ',
      outPath: env['NY_OUT'],
      runLabel: env['NY_RUN'] ?? '1',
      hwdec: env['NY_HWDEC'],
      logLevel: MPVLogLevel.values.firstWhere(
        (l) => l.name == (env['NY_LOGLEVEL'] ?? 'info'),
        orElse: () => MPVLogLevel.info,
      ),
    );

  }

  // _findStreamJson removed as we don't use file anymore

}

// ---------------------------------------------------------------------------
// The resolved stream
// ---------------------------------------------------------------------------

class StreamSource {
  const StreamSource({
    required this.videoId,
    required this.videoUrl,
    required this.audioUrl,
    required this.itag,
    required this.codec,
    required this.capturedAt,
    required this.expiresAt,
    required this.durationMs,
  });

  final String videoId;
  final String videoUrl;
  final String? audioUrl;
  final int? itag;
  final String? codec;
  final String? capturedAt;
  final String? expiresAt;
  final int? durationMs;

  /// Fetches source from sidecar over RPC.
  static Future<StreamSource> load(HarnessConfig config) async {
    final rpc = RpcClient.instance;
    await rpc.start();

    stderr.writeln('harness calling auth.verify');
    final authRes = await rpc.call('auth.verify', {});
    stderr.writeln('harness auth.verify: $authRes');

    stderr.writeln('harness calling playback.open');
    final json = await rpc.call('playback.open', {'videoId': config.videoId}) as Map<String, dynamic>;
    
    // The sidecar's PlaybackSource predates the variants[] amendment from protocol.md §3.5.
    // We are consuming what the sidecar actually returns (a single videoUrl/audioUrl pair).
    stderr.writeln('harness returned source: $json');
    
    return StreamSource(
      videoId: config.videoId,
      videoUrl: json['videoUrl'] as String,
      audioUrl: json['audioUrl'] as String?,
      itag: null, // The current PlaybackSource doesn't expose itag at the top level
      codec: json['videoCodec'] as String?,
      capturedAt: null,
      expiresAt: null,
      durationMs: json['durationMs'] as int?,
    );

  }

}

// ---------------------------------------------------------------------------
// Native odds and ends
// ---------------------------------------------------------------------------

typedef _GetProcessTimesC = Int32 Function(IntPtr process, Pointer<Uint64> creation,
    Pointer<Uint64> exit, Pointer<Uint64> kernel, Pointer<Uint64> user);
typedef _GetProcessTimesDart = int Function(int process, Pointer<Uint64> creation,
    Pointer<Uint64> exit, Pointer<Uint64> kernel, Pointer<Uint64> user);

/// Kernel + user CPU seconds for this process — spike 05's `time.process_time()`.
///
/// media_kit decodes on its own threads inside this process, so process-wide is
/// the right scope. FILETIME is eight bytes, so four `Uint64` slots read it.
double? processCpuSeconds() {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getProcessTimes =
        kernel32.lookupFunction<_GetProcessTimesC, _GetProcessTimesDart>('GetProcessTimes');
    final buffer = calloc<Uint64>(4);
    try {
      // -1 is GetCurrentProcess()'s pseudo-handle.
      final ok = getProcessTimes(-1, buffer, buffer + 1, buffer + 2, buffer + 3);
      if (ok == 0) return null;
      return (buffer[2] + buffer[3]) / 10000000.0; // 100 ns units.
    } finally {
      calloc.free(buffer);
    }
  } on Object {
    return null;
  }
}

/// `MPV_CLIENT_API_VERSION`, straight from the DLL this build actually loaded.
///
/// §1 asks for it by name, and it is worth the six lines: F10–F13 are about one
/// specific artefact, and a pin that resolves correctly still says nothing about
/// what CMake fetched or what the exe ended up loading. High word major, low
/// word minor.
String? mpvClientApiVersion() {
  try {
    final lib = DynamicLibrary.open('libmpv-2.dll');
    final version =
        lib.lookupFunction<Uint32 Function(), int Function()>('mpv_client_api_version')();
    return '${version >> 16}.${version & 0xFFFF}';
  } on Object {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final config = HarnessConfig.fromEnvironment();
  try {
    final source = await StreamSource.load(config);
    runApp(HarnessApp(config: config, source: source));
  } on Object catch (error) {
    stderr.writeln('harness: $error');
    runApp(FailedApp(message: '$error'));
  }
}

class FailedApp extends StatelessWidget {
  const FailedApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(message, style: const TextStyle(color: Colors.redAccent)),
            ),
          ),
        ),
      );
}

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key, required this.config, required this.source});

  final HarnessConfig config;
  final StreamSource source;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: HarnessPage(config: config, source: source),
      );
}

// ---------------------------------------------------------------------------
// The harness
// ---------------------------------------------------------------------------

class HarnessPage extends StatefulWidget {
  const HarnessPage({super.key, required this.config, required this.source});

  final HarnessConfig config;
  final StreamSource source;

  @override
  State<HarnessPage> createState() => _HarnessPageState();
}

class _HarnessPageState extends State<HarnessPage> {
  // `logLevel` is what makes `stream.log` carry anything. It is the only way to
  // see mpv say which decoder it picked; `hwdec-current` reports the method that
  // was *selected*, which is not the same claim.
  late final Player _player = Player(
    configuration: PlayerConfiguration(logLevel: widget.config.logLevel),
  );

  // `hwdec` is a first-class field on `VideoControllerConfiguration`, not a raw
  // property poke: media_kit's Windows controller defaults it to `auto` and
  // `vo` to `libmpv` (the ANGLE path). Overriding it here is how Q3's control
  // run asks for software decode.
  late final VideoController _video = VideoController(
    _player,
    configuration: VideoControllerConfiguration(hwdec: widget.config.hwdec),
  );

  final Stopwatch _clock = Stopwatch();
  final Map<String, String> _properties = {};
  final Map<int, Map<String, Object?>> _seeks = {};
  final List<String> _logLines = [];

  /// `(second, vo drops, decoder drops)`, once per sample.
  ///
  /// A total says how many frames were lost; only the series says whether they
  /// were lost steadily or in one burst at startup, and those are different
  /// findings about the same number.
  final List<List<num>> _dropSeries = [];

  Timer? _ticker;
  Timer? _sampler;
  StreamSubscription<PlayerLog>? _logs;
  int _scheduleIndex = 0;
  bool _finished = false;

  /// Q2's evidence: what `setProperty` was handed, and what came back out.
  String? _lavfOptionsSet;
  String? _lavfOptionsReadBack;
  String? _audioTrackError;

  /// Position just before the first seek — "did it play at all", separately from
  /// "did it seek", because a run that never started answers neither question.
  double? _positionBeforeFirstSeek;

  /// Frame drops sampled once playback is up, so the count is over the run and
  /// not over the startup.
  ///
  /// Only meaningful in Q3: mpv resets the drop counters on every seek, so the
  /// delta across a seek plan measures nothing.
  int? _dropsAtStart;

  /// CPU at the moment playback is up, so the run's cost excludes the Flutter
  /// engine starting, the window opening and the stream being opened.
  double? _cpuAtStart;

  /// When each seek was actually *issued*, in clock seconds.
  ///
  /// Not the same as when it was scheduled, and the difference is not academic:
  /// `NativePlayer.getProperty` is a blocking FFI call on the UI isolate, and it
  /// can sit on mpv's core lock for seconds while a seek is in flight. When it
  /// does, the timer catches up and would otherwise run a seek and its own check
  /// in the same pass — reading `time-pos` microseconds after queuing the seek,
  /// which is exactly the "exactly 300.0" that means *stalled*. That would
  /// manufacture the finding this task exists to test for.
  final Map<int, double> _seekIssuedAt = {};

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  NativePlayer get _native => _player.platform as NativePlayer;

  Future<void> _start() async {
    final config = widget.config;
    final source = widget.source;

    stderr.writeln(
      'harness mode=${config.mode.name} track=${config.track} itag=${source.itag} '
      'codec=${source.codec} run=${config.runLabel} '
      'options=${config.setRequestSize ? 'request_size' : 'baseline'}',
    );

    _logs = _player.stream.log.listen((entry) {
      if (!interestingLogLines.hasMatch(entry.text)) return;
      final line = '[${entry.prefix}] ${entry.text}';
      if (_logLines.length < 200) _logLines.add(line);
      stderr.writeln('mpv $line');
    });

    // Q2. Set before the file is opened, because `stream-lavf-o` is read when
    // ffmpeg opens the stream — setting it afterwards would be reachable and
    // useless. `NativePlayer.setProperty` is the entire API surface here, and it
    // discards mpv's return code, so reading the value back is the only signal
    // available about whether it landed at all.
    if (config.setRequestSize) {
      _lavfOptionsSet = streamLavfOptions;
      await _native.setProperty('stream-lavf-o', streamLavfOptions);
      _lavfOptionsReadBack = await _native.getProperty('stream-lavf-o');
      stderr.writeln('harness stream-lavf-o set="$_lavfOptionsSet" read="$_lavfOptionsReadBack"');
    }

    await _player.open(Media(source.videoUrl), play: true);
    _clock.start();

    // §2.4's two-URL design, expressed through media_kit: `AudioTrack.uri`
    // issues mpv's `audio-add … select`, which is the `--audio-file` equivalent.
    // It needs a loaded file, so wait for the demuxer to report a duration.
    if (source.audioUrl != null) {
      try {
        await _player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 20));
        await _player.setAudioTrack(AudioTrack.uri(source.audioUrl!, title: 'YouTube audio'));
      } on Object catch (error) {
        // A stop condition, not a harness detail: §2.4's two-URL design depends
        // on there being a supported way to do this.
        _audioTrackError = '$error';
        stderr.writeln('harness: attaching the audio track failed: $error');
      }
    }

    _sampler = Timer.periodic(sampleInterval, (_) async {
      await _sampleProperties();
      if (mounted) setState(() {});
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 100), _tick);
  }

  // -------------------------------------------------------------------------
  // The run
  // -------------------------------------------------------------------------

  /// `(second, action, index, target)`, flattened from `seekPlan` so one cursor
  /// walks the whole run.
  late final List<(int, String, int, int)> _schedule = () {
    final entries = <(int, String, int, int)>[];
    for (var i = 0; i < seekPlan.length; i++) {
      final (at, target) = seekPlan[i];
      entries.add((at, 'seek', i + 1, target));
      entries.add((at + checkDelaySeconds, 'check', i + 1, target));
    }
    entries.add((quitAtSeconds, 'quit', 0, 0));
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    return entries;
  }();

  void _tick(Timer timer) {
    if (!widget.config.automated || _finished) return;

    final now = _clock.elapsedMilliseconds / 1000.0;
    while (_scheduleIndex < _schedule.length && _schedule[_scheduleIndex].$1 <= now) {
      final (_, kind, index, target) = _schedule[_scheduleIndex];

      // A check is due `checkDelaySeconds` after its seek *went out*, not after
      // the clock says so. Leave the cursor where it is and come back.
      if (kind == 'check' && widget.config.mode != HarnessMode.q3) {
        final issued = _seekIssuedAt[index];
        if (issued == null || now - issued < checkDelaySeconds) return;
      }
      _scheduleIndex++;

      switch (kind) {
        case 'seek':
          if (index == 1) {
            _positionBeforeFirstSeek = _positionSeconds;
            _dropsAtStart = _dropCount;
            _cpuAtStart = processCpuSeconds();
          }
          // Q3 measures a plain 40 s run: seeking would move the decoder around
          // and make the dropped-frame count answer a different question.
          if (widget.config.mode == HarnessMode.q3) break;
          stderr.writeln('harness seek $index -> $target (from $_positionSeconds)');
          _seekIssuedAt[index] = now;
          unawaited(_player.seek(Duration(seconds: target)));
        case 'check':
          if (widget.config.mode == HarnessMode.q3) break;
          final position = _positionSeconds;
          final advanced = position > target + advancedByAtLeast;
          _seeks[index] = {'target': target, 'position': position, 'ok': advanced};
          stderr.writeln(
            'harness seek $index ${advanced ? 'OK' : 'STALLED'} target=$target pos=$position',
          );
        case 'quit':
          _finished = true;
          unawaited(_finish());
      }
    }
  }

  double get _positionSeconds => _player.state.position.inMilliseconds / 1000.0;

  int? get _dropCount => int.tryParse(_properties['frame-drop-count'] ?? '');

  double _maxSamplerGap() {
    var worst = 0.0;
    for (var i = 1; i < _dropSeries.length; i++) {
      final gap = _dropSeries[i][0] - _dropSeries[i - 1][0];
      if (gap > worst) worst = gap.toDouble();
    }
    return worst;
  }

  Future<void> _sampleProperties() async {
    for (final name in observedProperties) {
      try {
        _properties[name] = await _native.getProperty(name);
      } on Object {
        _properties[name] = '';
      }
    }
    if (_clock.isRunning) {
      _dropSeries.add([
        double.parse((_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)),
        _dropCount ?? -1,
        int.tryParse(_properties['decoder-frame-drop-count'] ?? '') ?? -1,
      ]);
    }
  }

  Future<void> _finish() async {
    _ticker?.cancel();
    _sampler?.cancel();
    final cpuAtEnd = processCpuSeconds();
    await _sampleProperties();

    final passed = _seeks.values.where((s) => s['ok'] == true).length;
    // mpv resets both drop counters on a seek, so a delta across the seek plan
    // measures the last seek's tail and nothing else. Q3 is the only mode where
    // this number means what it says.
    final measuresDrops = widget.config.mode == HarnessMode.q3;
    final verdict = <String, Object?>{
      'mode': widget.config.mode.name,
      'run': widget.config.runLabel,
      'videoId': widget.source.videoId,
      'track': widget.config.track,
      'itag': widget.source.itag,
      'codec': widget.source.codec,
      'options': widget.config.setRequestSize ? 'request_size' : 'baseline',
      'hwdecRequested': widget.config.hwdec ?? '(media_kit default)',
      'streamLavfOptionsSet': _lavfOptionsSet,
      'streamLavfOptionsReadBack': _lavfOptionsReadBack,
      'audioTrackError': _audioTrackError,
      'playedBeforeFirstSeek': _positionBeforeFirstSeek,
      'played': (_positionBeforeFirstSeek ?? 0) > 0.5,
      'positionAtEnd': _positionSeconds,
      'seeksOk': passed,
      'seeksTotal': widget.config.mode == HarnessMode.q3 ? 0 : seekPlan.length,
      'seeks': _seeks.map((k, v) => MapEntry('$k', v)),
      'dropsDuringRun': measuresDrops ? (_dropCount ?? 0) - (_dropsAtStart ?? 0) : null,
      'cpuSeconds': cpuAtEnd,
      'cpuDuringRunSeconds':
          (cpuAtEnd != null && _cpuAtStart != null) ? cpuAtEnd - _cpuAtStart! : null,
      'runSeconds': _clock.elapsedMilliseconds / 1000.0,
      // The sampler runs at a fixed 1 Hz, so the largest gap between samples is
      // the longest the UI isolate was blocked — mostly by `getProperty` sitting
      // on mpv's core lock through a seek. A number worth having: it is the
      // difference between "the player stalled" and "the app stopped asking".
      'maxSamplerGapSeconds': _maxSamplerGap(),
      'seekIssuedAt': _seekIssuedAt.map((k, v) => MapEntry('$k', v)),
      'mpvClientApiVersion': mpvClientApiVersion(),
      'properties': Map<String, String>.from(_properties),
      // Emitted in every mode: the seek plan resets the counters, so Q1's series
      // is the only way to compare a post-seek window against Q3's uninterrupted
      // one — and those two turned out to disagree.
      'dropSeries': _dropSeries,
      'log': _logLines,
      'finishedAt': DateTime.now().toUtc().toIso8601String(),
    };

    final encoded = const JsonEncoder.withIndent('  ').convert(verdict);
    final out = widget.config.outPath;
    if (out != null) {
      await File(out).parent.create(recursive: true);
      await File(out).writeAsString('$encoded\n');
      stderr.writeln('harness wrote $out');
    }
    stderr.writeln(encoded);

    await _player.dispose();
    exit(0);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  void dispose() {
    _ticker?.cancel();
    _sampler?.cancel();
    unawaited(_logs?.cancel());
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _player.state;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(child: Video(controller: _video)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final (_, target) in seekPlan)
                      ElevatedButton(
                        onPressed: () => _player.seek(Duration(seconds: target)),
                        child: Text('seek ${target}s'),
                      ),
                    ElevatedButton(
                      onPressed: _player.playOrPause,
                      child: Text(state.playing ? 'pause' : 'play'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DefaultTextStyle(
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('position ${_fmt(state.position)} / ${_fmt(state.duration)}   '
                          'buffered ${_fmt(state.buffer)}   '
                          'cache ${_properties['demuxer-cache-time'] ?? '?'}s'),
                      Text('decoder ${_properties['hwdec-current'] ?? '?'} / '
                          '${_properties['current-tracks/video/decoder-desc'] ?? '?'}   '
                          'video ${_properties['video-codec'] ?? '?'} '
                          '${_properties['video-params/w'] ?? '?'}x${_properties['video-params/h'] ?? '?'}   '
                          'audio ${_properties['audio-codec'] ?? '?'} '
                          '(aid ${_properties['aid'] ?? '?'}, ${_properties['track-list/count'] ?? '?'} tracks)   '
                          'avsync ${_properties['avsync'] ?? '?'}'),
                      Text('dropped ${_properties['frame-drop-count'] ?? '?'} vo / '
                          '${_properties['decoder-frame-drop-count'] ?? '?'} decoder   '
                          'cpu ${processCpuSeconds()?.toStringAsFixed(1) ?? '?'}s   '
                          't+${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'),
                      Text('${_properties['mpv-version'] ?? '?'} · '
                          '${_properties['ffmpeg-version'] ?? '?'} · '
                          'client api ${mpvClientApiVersion() ?? '?'}'),
                      Text('itag ${widget.source.itag} ${widget.source.codec}   '
                          'stream-lavf-o "${_properties['stream-lavf-o'] ?? ''}"   '
                          '${widget.config.mode.name} run ${widget.config.runLabel}'),
                      if (_audioTrackError != null)
                        Text('audio track FAILED: $_audioTrackError',
                            style: const TextStyle(color: Colors.redAccent)),
                      if (_seeks.isNotEmpty)
                        Text(_seeks.entries
                            .map((e) => '${e.key}:${e.value['target']}→'
                                '${(e.value['position'] as double).toStringAsFixed(1)}'
                                '${e.value['ok'] == true ? ' OK' : ' STALLED'}')
                            .join('   ')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
