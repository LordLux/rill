import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rill/data/playback/engine.dart';
import 'package:rill/domain/playback_source.dart';

/// Measures what `vid=no` actually costs, and what says when it is over.
///
/// **§1 — does it stop the fetch or only the decode?** Answered 2026-09-22: the
/// fetch. `total-bytes` goes to 0 and `stream-pos` freezes. That cannot be
/// measured from outside the process — Windows' per-process I/O counters do not
/// see mpv's socket reads (10 KB of process I/O against 1.2 MB at the NIC over
/// the same 20 s), and the NIC total is system-wide and noisier than the signal.
///
/// **The restore direction — which property says the picture is back?**
/// `width` does not: measured 2026-09-23, it survives `vid=no` entirely, so
/// waiting on it returns instantly and a spinner keyed to it never appears.
/// That is what this third phase is for. It re-enables the track and samples
/// every candidate once a second, so the one that actually flips — and how long
/// the viewer waits for it — is read off the table rather than assumed.
///
/// It must run against a **real adaptive pair** — a separate video URL with an
/// audio URL attached — because that is the shape the question is about. Signed
/// URLs come from `playback.open` into the JSON below; they expire in hours.
///
/// Never wired into the app. See `app/test/README.md`.
const String kVariantPath = 'M:/Projects/rill/sidecar/scratch/probe-variant.json';
const String kOutPath = 'M:/Projects/rill/sidecar/scratch/probe-audio-bytes.csv';

const Duration kSettle = Duration(seconds: 15);
const Duration kVideoPhase = Duration(seconds: 5);
const Duration kAudioPhase = Duration(seconds: 20);

/// Generous: the whole point is to catch a restore that takes ten seconds.
const Duration kRestorePhase = Duration(seconds: 60);
const Duration kEvery = Duration(seconds: 1);

/// Every candidate for "there is a picture again", sampled together so they can
/// be compared against each other on one timeline.
const List<String> kProps = [
  'vid',
  'width',
  'dwidth',
  'vo-configured',
  'video-bitrate',
  'estimated-vf-fps',
  'frame-drop-count',
  'paused-for-cache',
  'demuxer-cache-duration',
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final engine = MediaKitEngine();

  runApp(
    MaterialApp(
      home: Scaffold(
        body: FutureBuilder(
          future: Platform.environment['PROBE_SCENARIO'] == 'open'
              ? _runOpenPaths(engine)
              : _run(engine),
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text(snapshot.error.toString());
            return const Center(child: Text('Running probe...'));
          },
        ),
      ),
    ),
  );
}

Future<void> _run(MediaKitEngine engine) async {
  final out = File(kOutPath).openWrite();
  final native = engine.diagnostics;

  void log(String line) {
    out.writeln(line);
    debugPrint('[probe] $line');
  }

  try {
    final spec = jsonDecode(await File(kVariantPath).readAsString()) as Map<String, dynamic>;
    log('# videoId=${spec['videoId']} ${spec['height']}p itag=${spec['itag']} '
        'durationMs=${spec['durationMs']}');
    log('# audioUrl=${spec['audioUrl'] == null ? 'NULL (muxed)' : 'present'}');

    await engine.open(
      PlaybackVariant(
        videoUrl: spec['videoUrl'] as String,
        audioUrl: spec['audioUrl'] as String?,
        height: spec['height'] as int? ?? 720,
        fps: spec['fps'] as int? ?? 30,
        videoCodec: spec['videoCodec'] as String? ?? 'h264',
        audioCodec: spec['audioCodec'] as String? ?? 'opus',
      ),
      play: true,
    );
    log('# opened, settling ${kSettle.inSeconds}s');
    await Future<void>.delayed(kSettle);

    // `engineWidth` is media_kit's own cached value — the one the app actually
    // reads. `rect` is the VideoController's, which drives the texture.
    log('phase,ms,engineWidth,rect,${kProps.join(",")}');

    Future<void> sample(String phase, Stopwatch clock) async {
      final values = <String>[];
      for (final p in kProps) {
        try {
          values.add((await native.getProperty(p)).replaceAll(',', ';'));
        } catch (e) {
          values.add('ERR');
        }
      }
      final rect = engine.videoController.rect.value;
      final rectText = rect == null ? 'null' : '${rect.width.toInt()}x${rect.height.toInt()}';
      log('$phase,${clock.elapsedMilliseconds},${engine.width},$rectText,${values.join(",")}');
    }

    Future<void> phase(String name, Duration length) async {
      final clock = Stopwatch()..start();
      while (clock.elapsed < length) {
        await sample(name, clock);
        await Future<void>.delayed(kEvery);
      }
      clock.stop();
    }

    await phase('video', kVideoPhase);

    var sw = Stopwatch()..start();
    await engine.setVideoTrack(false);
    sw.stop();
    log('# setVideoTrack(false) returned in ${sw.elapsedMilliseconds}ms');
    await phase('audio-only', kAudioPhase);

    // The measurement that matters: ms is time since the call was issued, so
    // whichever column changes first — and when — is the answer.
    sw = Stopwatch()..start();
    await engine.setVideoTrack(true);
    sw.stop();
    log('# setVideoTrack(true) returned in ${sw.elapsedMilliseconds}ms');
    await phase('restore', kRestorePhase);

    log('# done');
  } catch (e, st) {
    log('# FAILED: $e');
    log('# $st');
  }

  await out.close();
  exit(0);
}


/// **How an audio-only track is opened — measured, not assumed.**
///
/// Three opens of the same variant, each sampled every 250 ms from the moment
/// the open is issued:
///
///  - `old`   — the route `9299ed3` took: video on for the open, off once loaded.
///    Whatever the video demuxer fetched and whether a frame decoded before the
///    drop is the waste the new route exists to remove.
///  - `new`   — video off before the open, so `MediaKitEngine.open` attaches the
///    audio through `audio-files` at load. It must still play and still get a
///    duration, or it is the 20 s hang again.
///  - `video` — an ordinary video-mode open straight afterwards. `audio-files`
///    is an option and persists across loads, so this checks it was cleared and
///    did not leak the previous track in as a second audio stream.
Future<void> _runOpenPaths(MediaKitEngine engine) async {
  final out = File(kOutPath).openWrite();
  final native = engine.diagnostics;
  void log(String line) {
    out.writeln(line);
    debugPrint('[probe] $line');
  }

  Future<String> prop(String name) async {
    try {
      return await native.getProperty(name);
    } catch (_) {
      return 'ERR';
    }
  }

  int? totalBytes(String cache) =>
      int.tryParse(RegExp(r'"total-bytes":(\d+)').firstMatch(cache)?.group(1) ?? '');

  /// Audio tracks as "id:selected:external", from the JSON `track-list` string.
  Future<String> audioTracks() async {
    try {
      final list = jsonDecode(await native.getProperty('track-list')) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .where((t) => t['type'] == 'audio')
          .map((t) => '${t['id']}:${t['selected'] == true ? 'SEL' : '-'}:${t['external'] == true ? 'ext' : 'int'}')
          .join(' ');
    } catch (e) {
      return 'ERR($e)';
    }
  }

  try {
    final spec = jsonDecode(await File(kVariantPath).readAsString()) as Map<String, dynamic>;
    final variant = PlaybackVariant(
      videoUrl: spec['videoUrl'] as String,
      audioUrl: spec['audioUrl'] as String?,
      height: spec['height'] as int? ?? 720,
      fps: spec['fps'] as int? ?? 30,
      videoCodec: spec['videoCodec'] as String? ?? 'h264',
      audioCodec: spec['audioCodec'] as String? ?? 'opus',
    );
    log('# videoId=${spec['videoId']} ${spec['height']}p itag=${spec['itag']}');
    log('# audioUrl contains ";": ${(spec['audioUrl'] as String?)?.contains(';')}');
    log('scenario,ms,time-pos,duration,vid,vo-configured,video-demux-total-bytes');

    Future<void> scenario(String name, Future<void> Function() openIt) async {
      final clock = Stopwatch()..start();
      var peak = 0;
      var decoded = false;
      var firstPlayMs = -1;
      final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) async {
        final pos = await prop('time-pos');
        final vo = await prop('vo-configured');
        final bytes = totalBytes(await prop('demuxer-cache-state')) ?? 0;
        if (bytes > peak) peak = bytes;
        if (vo == 'yes') decoded = true;
        final p = double.tryParse(pos) ?? 0;
        if (firstPlayMs < 0 && p > 0.2) firstPlayMs = clock.elapsedMilliseconds;
        log('$name,${clock.elapsedMilliseconds},$pos,${await prop('duration')},'
            '${await prop('vid')},$vo,$bytes');
      });
      Object? failure;
      try {
        await openIt();
      } catch (e) {
        failure = e;
      }
      final opened = clock.elapsedMilliseconds;
      await Future<void>.delayed(const Duration(seconds: 12));
      sampler.cancel();
      log('# $name: open returned in ${opened}ms${failure == null ? '' : ' THREW $failure'}, '
          'first audio at ${firstPlayMs}ms, peak video-demuxer bytes $peak, '
          'a frame decoded: $decoded, audio tracks [${await audioTracks()}]');
      await engine.stop();
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    await scenario('old', () async {
      await engine.setVideoTrack(true);
      await engine.open(variant);
      await engine.setVideoTrack(false);
    });
    await scenario('new', () async {
      await engine.setVideoTrack(false);
      await engine.open(variant);
    });
    await scenario('video', () async {
      await engine.setVideoTrack(true);
      await engine.open(variant);
    });
    log('# done');
  } catch (e, st) {
    log('# FAILED: $e');
    log('# $st');
  }
  await out.close();
  exit(0);
}
