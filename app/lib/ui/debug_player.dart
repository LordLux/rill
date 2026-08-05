import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/rpc/client.dart';
import '../theme/accent.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'debug_constants.dart';

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
      track: env['NY_TRACK'] ?? 'vp9',
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
}

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

  static Future<StreamSource> load(HarnessConfig config) async {
    final rpc = RpcClient.instance;
    await rpc.start();

    stderr.writeln('harness calling auth.verify');
    final authRes = await rpc.call('auth.verify', {});
    stderr.writeln('harness auth.verify: $authRes');

    stderr.writeln('harness calling playback.open');
    final json = await rpc.call('playback.open', {'videoId': config.videoId}) as Map<String, dynamic>;
    
    final variants = json['variants'] as List<dynamic>;
    stderr.writeln('harness returned source with ${variants.length} variants: $variants');
    final variant0 = variants[0] as Map<String, dynamic>;
    
    return StreamSource(
      videoId: config.videoId,
      videoUrl: variant0['videoUrl'] as String,
      audioUrl: variant0['audioUrl'] as String?,
      itag: variant0['itag'] as int?,
      codec: variant0['videoCodec'] as String?,
      capturedAt: null,
      expiresAt: null,
      durationMs: json['durationMs'] as int?,
    );
  }
}

typedef _GetProcessTimesC = Int32 Function(IntPtr process, Pointer<Uint64> creation,
    Pointer<Uint64> exit, Pointer<Uint64> kernel, Pointer<Uint64> user);
typedef _GetProcessTimesDart = int Function(int process, Pointer<Uint64> creation,
    Pointer<Uint64> exit, Pointer<Uint64> kernel, Pointer<Uint64> user);

double? processCpuSeconds() {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getProcessTimes =
        kernel32.lookupFunction<_GetProcessTimesC, _GetProcessTimesDart>('GetProcessTimes');
    final buffer = calloc<Uint64>(4);
    try {
      final ok = getProcessTimes(-1, buffer, buffer + 1, buffer + 2, buffer + 3);
      if (ok == 0) return null;
      return (buffer[2] + buffer[3]) / 10000000.0;
    } finally {
      calloc.free(buffer);
    }
  } on Object {
    return null;
  }
}

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

class FailedApp extends StatelessWidget {
  const FailedApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = buildRillTheme(kDefaultAccent);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: theme.tokens.scrim,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(message, style: TextStyle(color: theme.colorScheme.error)),
          ),
        ),
      ),
    );
  }
}

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key, required this.config, required this.source});

  final HarnessConfig config;
  final StreamSource source;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildRillTheme(kDefaultAccent),
        home: HarnessPage(config: config, source: source),
      );
}

class HarnessPage extends StatefulWidget {
  const HarnessPage({super.key, required this.config, required this.source});

  final HarnessConfig config;
  final StreamSource source;

  @override
  State<HarnessPage> createState() => _HarnessPageState();
}

class _HarnessPageState extends State<HarnessPage> {
  late final Player _player = Player(
    configuration: PlayerConfiguration(logLevel: widget.config.logLevel),
  );

  late final VideoController _video = VideoController(
    _player,
    configuration: VideoControllerConfiguration(hwdec: widget.config.hwdec),
  );

  final Stopwatch _clock = Stopwatch();
  final Map<String, String> _properties = {};
  final Map<int, Map<String, Object?>> _seeks = {};
  final List<String> _logLines = [];

  final List<List<num>> _dropSeries = [];

  Timer? _ticker;
  Timer? _sampler;
  StreamSubscription<PlayerLog>? _logs;
  int _scheduleIndex = 0;
  bool _finished = false;

  String? _lavfOptionsSet;
  String? _lavfOptionsReadBack;
  String? _audioTrackError;

  double? _positionBeforeFirstSeek;
  int? _dropsAtStart;
  double? _cpuAtStart;
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

    if (config.setRequestSize) {
      _lavfOptionsSet = streamLavfOptions;
      await _native.setProperty('stream-lavf-o', streamLavfOptions);
      _lavfOptionsReadBack = await _native.getProperty('stream-lavf-o');
      stderr.writeln('harness stream-lavf-o set="$_lavfOptionsSet" read="$_lavfOptionsReadBack"');
    }

    await _player.open(Media(source.videoUrl), play: true);
    _clock.start();

    if (source.audioUrl != null) {
      try {
        if (_player.state.duration <= Duration.zero) {
          await _player.stream.duration
              .firstWhere((d) => d > Duration.zero)
              .timeout(const Duration(seconds: 20));
        }
        await _player.setAudioTrack(AudioTrack.uri(source.audioUrl!, title: 'YouTube audio'));
      } on Object catch (error) {
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
      'maxSamplerGapSeconds': _maxSamplerGap(),
      'seekIssuedAt': _seekIssuedAt.map((k, v) => MapEntry('$k', v)),
      'mpvClientApiVersion': mpvClientApiVersion(),
      'properties': Map<String, String>.from(_properties),
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
    final theme = Theme.of(context);
    final tokens = theme.tokens;
    return Scaffold(
      // Letterbox around a video frame, not a themed surface.
      backgroundColor: tokens.scrim,
      body: Column(
        children: [
          Expanded(
            child: _audioTrackError != null
                ? Center(
                    child: Text(
                      'AUDIO ATTACH FAILED:\n$_audioTrackError',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 24),
                    ),
                  )
                : Video(controller: _video),
          ),
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
                  style: TextStyle(color: tokens.onScrim.withValues(alpha: 0.7), fontSize: 12),
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
                            style: TextStyle(color: theme.colorScheme.error)),
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
