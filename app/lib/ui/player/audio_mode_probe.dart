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
