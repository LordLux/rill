/// `RILL_LAUNCH_PROBE=1` — why does a launch sometimes resolve a stream and
/// never show a frame?
///
/// Observed during task 16's device runs: **2 of 6 launches** resolved normally
/// (tier 1, 22 variants) and then produced no picture at all. That was written
/// off as F11's intermittent 403 on a freshly resolved URL — but F11 measured
/// roughly 2 in 20, and 2 in 6 is a different number. Either the rate moved or
/// it is a different mechanism, and one report cannot tell which.
///
/// This probe answers three questions per launch, and is deliberately incapable
/// of fixing anything:
///
///  1. **Did the URL die, or did mpv never open it?** On failure it issues its
///     own bounded range request against the resolved video and audio URLs. A
///     403 says the URL is dead; a 200/206 says the bytes were there and mpv did
///     not get them.
///  2. **What did mpv say?** `player.stream.error` and the mpv log, filtered to
///     the lines that carry a transport failure. A silent stall and a reported
///     one are different bugs.
///  3. **How long did it wait, and does a *fresh* URL recover?** The ladder
///     declines tiers, but nothing re-resolves a URL that resolved and then
///     died — so on failure this asks for a new one and tries again, and records
///     whether that works. Measuring the recovery, not installing it.
///
/// One NDJSON line per launch on stdout of the log file, so twenty launches
/// aggregate with `jq`. Exits non-zero only if the probe itself broke.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playback/engine.dart';
import '../../data/rpc/client.dart';
import '../../domain/playback_source.dart';
import '../playback_controller.dart';

/// How long to wait for a first frame before calling the launch a failure.
///
/// The app's own audio-attach guard gives up at 20 s (`architecture.md` §4), so
/// anything past ~25 s has already failed inside `engine.open`. 45 s leaves room
/// to see that happen rather than racing it.
const Duration _firstFrameDeadline = Duration(seconds: 45);

void runLaunchProbe(ProviderContainer container) {
  if (Platform.environment['RILL_LAUNCH_PROBE'] != '1') return;
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_probe(container)));
}

Future<void> _probe(ProviderContainer container) async {
  final started = DateTime.now();
  final record = <String, Object?>{
    'startedAt': started.toIso8601String(),
    'videoId': Platform.environment['RILL_OPEN_VIDEO']?.trim(),
  };

  final engine = container.read(playbackEngineProvider);
  final mpvErrors = <String>[];
  final mpvLog = <String>[];
  StreamSubscription<Object?>? errorSub;
  StreamSubscription<Object?>? logSub;

  if (engine is MediaKitEngine) {
    // mpv's error channel is distinct from its log — F18 needed both, and a
    // transport failure has turned up on each of them at different times.
    errorSub = engine.errorStream.listen((e) => mpvErrors.add(e));
    logSub = engine.logStream.listen((line) {
      final text = '${line.prefix}: ${line.text}';
      // Everything mpv says about opening or moving bytes. Unfiltered `v` output
      // is thousands of lines a run and would bury the two that matter.
      if (RegExp(r'403|http|tcp|stream|open|fail|error|reconnect', caseSensitive: false)
          .hasMatch(text)) {
        if (mpvLog.length < 40) mpvLog.add(text);
      }
    });
  }

  try {
    // --- 1. the open, however it ends ------------------------------------
    //
    // Waiting on "source or error" rather than on resolution alone, because the
    // two failures look identical from outside: `PlaybackController.open`
    // publishes `source` only *after* `engine.open` returns, and clears it again
    // on failure — so an RPC that resolved 22 variants and an engine that timed
    // out 20 s later both arrive here as `source == null`.
    final settledIn = await _waitFor(
      () =>
          container.read(playbackProvider).source != null ||
          container.read(playbackProvider).error != null,
      const Duration(seconds: 40),
    );
    final playback = container.read(playbackProvider);
    final source = playback.source;
    record['settleMs'] = settledIn?.inMilliseconds;
    record['openError'] = playback.error;

    // The variant is only observable from the engine on the failing path.
    final attempted = engine is MediaKitEngine ? engine.lastOpened : null;
    record['reachedEngine'] = attempted != null;
    record['itag'] = attempted?.itag ?? playback.variant?.itag;
    record['height'] = attempted?.height ?? playback.variant?.height;
    record['variants'] = source?.variants.length;
    record['transport'] = source?.transport;

    // --- 2. first frame ---------------------------------------------------
    final frameAt = source == null
        ? null
        : await _waitFor(
            () => engine.position > Duration.zero && engine.duration > Duration.zero,
            _firstFrameDeadline,
          );

    record['firstFrameMs'] = frameAt?.inMilliseconds;
    record['durationMs'] = engine.duration.inMilliseconds;
    record['mpvErrors'] = mpvErrors;
    record['mpvLog'] = mpvLog;

    if (frameAt != null) {
      record['outcome'] = 'played';
      await _emit(record);
      exit(0);
    }

    // Which of the two failures this was. `engine-timeout` is the audio-attach
    // guard in `MediaKitEngine.open` giving up; `no-frame` is an open that
    // returned and then never produced a picture; `rpc-failed` never reached the
    // engine at all.
    record['outcome'] = attempted == null
        ? 'rpc-failed'
        : (source == null ? 'engine-timeout' : 'no-frame');

    // --- 3. is the URL dead, or was it never opened? ----------------------
    if (attempted != null) {
      record['videoUrlStatus'] = await _probeUrl(attempted.videoUrl);
      final audioUrl = attempted.audioUrl;
      record['audioUrlStatus'] = audioUrl == null ? null : await _probeUrl(audioUrl);
    }

    // --- 4. does a freshly resolved URL recover? --------------------------
    //
    // Nothing in the app does this today: the ladder declines *tiers*, and a URL
    // that resolved and then died is not a tier declining. Whether a new one
    // works is the difference between "retry the resolve" and "something else is
    // wrong", so it is measured here before anybody writes the retry.
    if (attempted != null) {
      try {
        final retryStarted = DateTime.now();
        final response =
            await RpcClient.instance.call('playback.open', {'videoId': record['videoId']});
        final fresh = PlaybackSource.fromJson(response as Map<String, dynamic>);
        final freshVariant = fresh.variants.firstWhere(
          (v) => v.itag == attempted.itag,
          orElse: () => fresh.variants.first,
        );
        record['retryUrlChanged'] = freshVariant.videoUrl != attempted.videoUrl;
        record['retryUrlStatus'] = await _probeUrl(freshVariant.videoUrl);

        await engine.open(freshVariant);
        final retryFrame = await _waitFor(
          () => engine.position > Duration.zero && engine.duration > Duration.zero,
          const Duration(seconds: 30),
        );
        record['retryMs'] = DateTime.now().difference(retryStarted).inMilliseconds;
        record['retryPlayed'] = retryFrame != null;
      } on Object catch (e) {
        record['retryPlayed'] = false;
        record['retryError'] = e.toString();
      }
    }

    await _emit(record);
    exit(0);
  } on Object catch (error, stack) {
    record['outcome'] = 'probe-broke';
    record['probeError'] = '$error';
    record['probeStack'] = stack.toString().split(String.fromCharCode(10)).take(4).join(' | ');
    record['mpvErrors'] = mpvErrors;
    record['mpvLog'] = mpvLog;
    await _emit(record);
    exit(2);
  } finally {
    unawaited(errorSub?.cancel());
    unawaited(logSub?.cancel());
  }
}

/// Poll until [ready], returning how long it took — or null on deadline.
///
/// Polling a *cached* stream value, never a property read: hard invariant 9, and
/// F15 measured what the other way costs.
Future<Duration?> _waitFor(bool Function() ready, Duration deadline) async {
  final started = DateTime.now();
  while (DateTime.now().difference(started) < deadline) {
    if (ready()) return DateTime.now().difference(started);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

/// The HTTP status a two-byte range request gets, or a description of why not.
///
/// **Bounded and drained deliberately.** F11 records the live suite panicking
/// Bun by cancelling a 712 MB body mid-flight, so this asks for two bytes and
/// reads them rather than aborting a stream the server is still filling.
Future<String> _probeUrl(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    final response = await request.close().timeout(const Duration(seconds: 15));
    final status = response.statusCode;
    await response.drain<void>();
    return '$status';
  } on Object catch (e) {
    return 'threw: ${e.runtimeType}';
  } finally {
    client.close(force: true);
  }
}

/// One NDJSON line, flushed before the process exits.
Future<void> _emit(Map<String, Object?> record) async {
  final path = Platform.environment['RILL_LAUNCH_PROBE_OUT']?.trim();
  final line = jsonEncode(record);
  if (path == null || path.isEmpty) {
    stderr.writeln('launch-probe: $line');
    return;
  }
  final file = File(path);
  await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  stderr.writeln('launch-probe: ${record['outcome']} '
      '(frame=${record['firstFrameMs']}ms video=${record['videoUrlStatus']} '
      'retry=${record['retryPlayed']})');
}
