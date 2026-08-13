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
  if (Platform.environment['RILL_FEXP_PROBE'] == '1') {
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_fexpProbe()));
    return;
  }
  if (Platform.environment['RILL_LAUNCH_PROBE'] != '1') return;
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_probe(container)));
}

/// `RILL_FEXP_PROBE=1` — is the poisoned experiment bucket per session or per
/// request?
///
/// F20 found `fexp=51946838` on 12/12 failing mints and 0/13 healthy ones, and
/// could not reproduce it outside the app. The app mints **one** resolve session
/// at startup and reuses it; a standalone script makes a fresh one per run. If
/// the bucket is assigned per *session*, a short-lived session would never carry
/// it and a long-lived one would carry it for life — which fits 33% of launches
/// against 0/12 standalone exactly.
///
/// Two arms in one launch, because one alone cannot separate the hypotheses:
///
///  - **the same video, repeatedly.** Requires the sidecar's `/player` cache to
///    be off (`SIDECAR_PLAYER_RESPONSE_TTL_MS=0`), or every repeat is one
///    request wearing ten hats.
///  - **different videos.** A flag that is constant across the same video but
///    varies across different ones is per-*video*, not per-session — which the
///    first arm alone would happily misread as a session property.
///
/// Constant across both arms ⇒ per session. Varying within a launch ⇒ per
/// request, and the session idea is dead.
Future<void> _fexpProbe() async {
  const flag = '51946838';
  const others = [
    'jNQXAC9IVRw', 'dQw4w9WgXcQ', '9bZkp7q19f0', 'kJQP7kiw5Fk',
    'fJ9rUzIMcZQ', 'YQHsXMglC9A',
  ];
  const repeats = 6;
  final record = <String, Object?>{'startedAt': DateTime.now().toIso8601String()};

  Future<Map<String, Object?>> resolve(String videoId) async {
    try {
      final response = await RpcClient.instance.call('playback.open', {'videoId': videoId});
      final source = PlaybackSource.fromJson(response as Map<String, dynamic>);
      final url = Uri.parse(source.variants.first.videoUrl);
      final fexp = url.queryParameters['fexp'] ?? '';
      return {
        'videoId': videoId,
        'flagged': fexp.split(',').contains(flag),
        'fexp': fexp,
      };
    } on Object catch (e) {
      return {'videoId': videoId, 'error': e.toString()};
    }
  }

  try {
    final sameVideo = <Map<String, Object?>>[];
    for (var i = 0; i < repeats; i++) {
      sameVideo.add(await resolve('aqz-KE-bpKQ'));
    }
    final differentVideos = <Map<String, Object?>>[];
    for (final id in others) {
      differentVideos.add(await resolve(id));
    }

    bool? verdictOf(List<Map<String, Object?>> rows) {
      final flags = rows.where((r) => r['flagged'] != null).map((r) => r['flagged'] as bool).toSet();
      return flags.length == 1 ? flags.first : null;
    }

    record['sameVideo'] = sameVideo;
    record['differentVideos'] = differentVideos;
    record['sameVideoConstant'] = verdictOf(sameVideo);
    record['differentVideosConstant'] = verdictOf(differentVideos);
    final all = [...sameVideo, ...differentVideos]
        .where((r) => r['flagged'] != null)
        .map((r) => r['flagged'] as bool)
        .toSet();
    record['launchConstant'] = all.length == 1;
    record['launchFlagged'] = all.length == 1 ? all.first : null;
    await _emit(record);
    exit(0);
  } on Object catch (error) {
    record['probeError'] = '$error';
    await _emit(record);
    exit(2);
  }
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
    // The URL itself, on **every** launch. Diffing a failing mint against a
    // healthy one needs both populations, and the first pass only kept the
    // failures — which made every difference look significant because there was
    // nothing to compare it with.
    record['videoUrl'] = attempted?.videoUrl;
    record['audioUrl'] = attempted?.audioUrl;

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
      // Both shapes. Bounded is the control; open-ended is what ffmpeg sends
      // and the only one that has ever been refused.
      record['videoBounded'] = await _probeUrl(attempted.videoUrl, 'bytes=0-1');
      record['videoOpenEnded'] = await _probeUrl(attempted.videoUrl, 'bytes=0-');
      final audioUrl = attempted.audioUrl;
      record['audioBounded'] = audioUrl == null ? null : await _probeUrl(audioUrl, 'bytes=0-1');
      record['audioOpenEnded'] = audioUrl == null ? null : await _probeUrl(audioUrl, 'bytes=0-');
    }

    // --- 3b. are the *other rungs* of this same resolution healthy? -------
    //
    // The ladder declines tiers; nothing declines variants. If the sibling URLs
    // from the same `/player` answer ffmpeg's request shape, a fallback down
    // `variants[]` — which already ships ranked — recovers the launch for free.
    // If they are all refused, the whole mint is poisoned and only a re-resolve
    // can help. `playback.open` here is served from the sidecar's TTL'd cache,
    // so it returns *the list the app actually used* rather than a new one.
    try {
      final again =
          await RpcClient.instance.call('playback.open', {'videoId': record['videoId']});
      final same = PlaybackSource.fromJson(again as Map<String, dynamic>);
      record['siblingsFromCache'] = same.variants.first.videoUrl == attempted?.videoUrl;

      final seen = <String>{};
      final rungs = <Map<String, Object?>>[];
      for (final v in same.variants) {
        if (!seen.add('${v.height}x${v.fps}')) continue;
        if (rungs.length >= 6) break;
        rungs.add({
          'itag': v.itag,
          'height': v.height,
          'openEnded': await _probeUrl(v.videoUrl, 'bytes=0-'),
        });
      }
      record['rungs'] = rungs;
    } on Object catch (e) {
      record['rungsError'] = e.toString();
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
Future<String> _probeUrl(String url, [String range = 'bytes=0-1']) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, range);
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
