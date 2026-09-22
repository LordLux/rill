import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rill/data/playback/engine.dart';
import 'package:rill/domain/playback_source.dart';

/// Measures what `vid=no` actually costs — task 28 §1.
///
/// The question this exists to answer is whether `vid=no` stops the **video
/// HTTP fetch** or only the decode. That cannot be measured from outside the
/// process: Windows' per-process I/O counters do not see mpv's socket reads
/// (measured 2026-09-22 — 10 KB of process I/O against 1.2 MB at the NIC over
/// the same 20 s), and the NIC total is system-wide. mpv's own demuxer byte
/// counters are the only instrument with correct attribution.
///
/// It must run against a **real adaptive pair** — a separate video URL with an
/// audio URL attached alongside — because that is the shape the question is
/// about. A single muxed URL cannot answer it: there is no separate video
/// stream to stop fetching. Signed URLs come from `playback.open`, written to
/// the JSON file below; they expire in hours, so re-fetch before each run.
///
/// Never wired into the app. See `app/test/README.md`.
const String kVariantPath = 'M:/Projects/rill/sidecar/scratch/probe-variant.json';
const String kOutPath = 'M:/Projects/rill/sidecar/scratch/probe-audio-bytes.csv';

/// Long enough for mpv's read-ahead to reach steady state before each phase is
/// scored, so a phase measures streaming rather than the cache filling.
const Duration kSettle = Duration(seconds: 20);
const Duration kPhase = Duration(seconds: 120);
const Duration kEvery = Duration(seconds: 10);

/// Sampled every tick. Whichever of these libmpv answers is the one used —
/// `demuxer-cache-state` is a MAP, and sub-property access through `/` is not
/// guaranteed across builds, so the whole map is captured as a fallback.
const List<String> kProps = [
  'vid',
  'time-pos',
  'stream-pos',
  'cache-speed',
  'demuxer-cache-duration',
  'video-bitrate',
  'audio-bitrate',
  // Read whole. The `demuxer-cache-state/total-bytes` sub-property path
  // returned empty against this build (measured 2026-09-22), so the map is
  // captured and parsed here instead. `raw-input-rate` inside it is the
  // bytes-per-second actually coming off the network, which is the number
  // task 28 §1 is asking for.
  'demuxer-cache-state',
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final engine = MediaKitEngine();

  runApp(
    MaterialApp(
      home: Scaffold(
        body: FutureBuilder(
          future: _run(engine),
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
    log('# videoId=${spec['videoId']} ${spec['height']}p itag=${spec['itag']}');
    log('# audioUrl=${spec['audioUrl'] == null ? 'NULL (muxed - cannot answer the question)' : 'present'}');

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

    log('phase,elapsed_s,${kProps.join(",")}');

    Future<void> sample(String phase, Stopwatch clock) async {
      final values = <String>[];
      for (final p in kProps) {
        try {
          values.add((await native.getProperty(p)).replaceAll(',', ';'));
        } catch (e) {
          values.add('ERR');
        }
      }
      log('$phase,${clock.elapsedMilliseconds ~/ 1000},${values.join(",")}');
    }

    for (final phase in ['video', 'audio-only']) {
      if (phase == 'audio-only') {
        log('# setVideoTrack(false)');
        final sw = Stopwatch()..start();
        await engine.setVideoTrack(false);
        sw.stop();
        log('# vid=no applied in ${sw.elapsedMilliseconds}ms');
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      final clock = Stopwatch()..start();
      while (clock.elapsed < kPhase) {
        await sample(phase, clock);
        await Future<void>.delayed(kEvery);
      }
      clock.stop();
    }

    log('# done');
  } catch (e, st) {
    log('# FAILED: $e');
    log('# $st');
  }

  await out.close();
  exit(0);
}
