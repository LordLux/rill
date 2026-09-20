import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import 'engine.dart';

/// `RILL_MPV_LOG=<path>` — one file with both players' side of playback.
///
/// Diagnostics only, and off unless the variable is set. Each line is
/// `<time> [<engine>] <what>`, for three sources that can disagree, which is
/// the point:
///
/// - `call` — what the app asked media_kit to do.
/// - `kit` — what media_kit *believes* (`playing`, `buffering`, `completed`).
///   Its `playing` is a Dart-side copy, updated by its own calls and by a
///   filtered view of mpv's events.
/// - `mpv` — mpv's actual properties, through `observeProperty`, plus mpv's
///   own log at `v`.
///
/// `observeProperty` makes media_kit read each change with a blocking
/// `mpv_get_property_string` on this isolate — the read hard invariant 9 keeps
/// out of the app. It is here for the same reason `audio_delay_probe.dart` uses
/// it: this is a measurement, never a default.
///
/// Stream URLs are logged by mpv at `v`. They are anonymous (the resolve path
/// sends no cookie), but they name this machine's IP address, so the file is
/// not something to attach anywhere unedited.
class MpvLog {
  MpvLog._(this._file);

  /// The log `RILL_MPV_LOG` asks for, or `null`.
  static final MpvLog? instance = _open();

  static MpvLog? _open() {
    final path = Platform.environment['RILL_MPV_LOG']?.trim();
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path).openSync(mode: FileMode.append);
      stderr.writeln('rill: mpv log -> ${File(path).absolute.path}');
      return MpvLog._(file)..write('log', '--- started, pid $pid');
    } on Object catch (error) {
      stderr.writeln('rill: RILL_MPV_LOG=$path not writable ($error)');
      return null;
    }
  }

  final RandomAccessFile _file;

  /// mpv's level while logging. `v` shows stream opens, cache and audio-output
  /// events; `debug` is an order of magnitude more and rarely needed.
  static const MPVLogLevel level = MPVLogLevel.v;

  /// Properties that decide whether the clock moves. `pause` is the one
  /// media_kit's `playing` is supposed to mirror.
  static const List<String> _properties = [
    'pause',
    'core-idle',
    'paused-for-cache',
    'idle-active',
    'eof-reached',
    'seeking',
    'current-ao',
    'current-vo',
  ];

  /// Written synchronously, so the lines before a crash are on disk.
  void write(String engine, String line) {
    try {
      _file.writeStringSync('${DateTime.now().toIso8601String()} [$engine] $line\n');
    } on Object {
      // A diagnostic must never take playback down with it.
    }
  }

  /// Log everything [engine] reports, labelled [name].
  void attach(MediaKitEngine engine, String name) {
    engine.trace = (line) => write(name, 'call $line');

    engine.playingStream.listen((value) => write(name, 'kit playing=$value'));
    engine.bufferingStream.listen((value) => write(name, 'kit buffering=$value'));
    engine.completedStream.listen((value) => write(name, 'kit completed=$value'));
    engine.errorStream.listen((value) => write(name, 'kit error: $value'));
    engine.logStream.listen((entry) => write(name, 'mpv ${entry.level} [${entry.prefix}] ${entry.text}'));

    // Once a second at most: enough to see the clock start or stall.
    var lastSecond = -1;
    engine.positionStream.listen((position) {
      final second = position.inSeconds;
      if (second == lastSecond) return;
      lastSecond = second;
      write(name, 'kit position=${second}s');
    });

    // `observeProperty` waits for the video controller, which a lazily
    // created preview engine only has once a tile mounts its surface.
    unawaited(() async {
      for (final property in _properties) {
        try {
          await engine.diagnostics.observeProperty(property, (value) async {
            write(name, 'mpv $property=$value');
          });
        } on Object catch (error) {
          write(name, 'observe $property failed: $error');
        }
      }
    }());
  }
}

/// A [MediaKitEngine] with [MpvLog] attached when `RILL_MPV_LOG` is set.
///
/// [logLevel] is honoured when there is no log, so the launch probe keeps its
/// own switch.
MediaKitEngine createEngine(String name, {MPVLogLevel? logLevel}) {
  final log = MpvLog.instance;
  final engine = MediaKitEngine(logLevel: log != null ? MpvLog.level : logLevel);
  log?.attach(engine, name);
  return engine;
}
