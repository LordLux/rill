import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'data/playback/engine.dart';
import 'domain/feed_item.dart';
import 'theme/accent.dart';
import 'theme/app_theme.dart';
import 'ui/audio_delay_probe.dart';
import 'ui/debug_player.dart';
import 'ui/hover_preview.dart';
import 'ui/page_wrapper.dart';
import 'ui/pages/feed.dart';
import 'ui/playback_controller.dart';
import 'ui/player/captions_probe.dart';
import 'ui/player/controls_probe.dart';
import 'ui/player/launch_probe.dart';
import 'ui/player_shell.dart';
import 'ui/queue_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // If the harness environment variables are set, boot directly into the debug player harness
  if (Platform.environment.containsKey('NY_MODE') || Platform.environment.containsKey('NY_VIDEO_ID')) {
    final config = HarnessConfig.fromEnvironment();
    try {
      final source = await StreamSource.load(config);
      runApp(HarnessApp(config: config, source: source));
    } on Object catch (error) {
      stderr.writeln('harness: $error');
      runApp(FailedApp(message: '$error'));
    }
    return;
  }

  // `RILL_AUDIO_PROBE=<plan>` measures the resume/seek audio delay and exits.
  final probePlan = Platform.environment['RILL_AUDIO_PROBE']?.trim();
  if (probePlan != null && probePlan.isNotEmpty) {
    _runAudioProbe(probePlan);
    return;
  }

  // Boot the app normally.
  //
  // The engine is created here, on the `ProviderScope` — above the `MaterialApp`
  // and therefore above the `Navigator`. That placement is the whole of task
  // §1: a `Player` owned by the watch route is destroyed on pop, which makes a
  // mini-player and background playback impossible. Owned this high, playback
  // surviving a route change is not a feature, it is the absence of a bug.
  // `RILL_LAUNCH_PROBE` needs mpv's own log to tell a dead URL from one mpv
  // never opened. Off otherwise: `v` is thousands of lines a run.
  final engine = MediaKitEngine(
    logLevel: Platform.environment['RILL_LAUNCH_PROBE'] == '1' ? MPVLogLevel.v : null,
  );

  final drawerOpen = await readDrawerOpen();

  final container = ProviderContainer(
    overrides: [
      playbackEngineProvider.overrideWithValue(engine),
      drawerStateProvider.overrideWith(() => DrawerStateController(initial: drawerOpen)),
    ],
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const RillApp(),
    ),
  );

  _openOnLaunch(container);
  runControlsProbe(container);
  runLaunchProbe(container);
  runCaptionsProbe(container);
}

/// Run the audio-delay probe and exit.
///
/// `RILL_AUDIO_PROBE="resume:2x10,seek:+60x10"`, `RILL_AUDIO_PROBE_VIDEO=<id>`,
/// `RILL_AUDIO_PROBE_OUT=<path>`, `RILL_AUDIO_PROBE_VERBOSE=1` for mpv at `v`.
void _runAudioProbe(String plan) {
  final steps = plan.split(',').map(ProbeStep.parse).nonNulls.toList();
  if (steps.isEmpty) {
    stderr.writeln('probe: nothing parseable in "$plan"');
    exit(2);
  }

  final engine = MediaKitEngine(
    logLevel: Platform.environment['RILL_AUDIO_PROBE_VERBOSE'] == '1' ? MPVLogLevel.v : null,
  );

  final probe = AudioDelayProbe(
    engine: engine,
    videoId: Platform.environment['RILL_AUDIO_PROBE_VIDEO']?.trim() ?? 'aqz-KE-bpKQ',
    plan: steps,
    outPath: Platform.environment['RILL_AUDIO_PROBE_OUT']?.trim() ?? 'audio-delay.json',
  );

  // A real window, because `observeProperty` waits on the `VideoController`
  // attaching a texture and that never completes without one. See `ProbeApp`.
  runApp(ProbeApp(engine: engine));

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await probe.run();
    } on Object catch (error, stack) {
      stderr.writeln('probe: FAILED $error\n$stack');
      exit(1);
    }
    exit(0);
  });
}

/// What a tile would have supplied. `video.info` replaces every one of these a
/// moment later; this is only what the page shows meanwhile.
VideoItem _placeholderItem(String videoId) => VideoItem(
      kind: 'video',
      id: videoId,
      title: videoId,
      channelName: '',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: false,
      canAddToQueue: false,
    );

/// `RILL_OPEN_VIDEO=<id>[,<id>…]` plays the first and queues the rest, as soon
/// as there is a frame. `RILL_SEEK_TO_END=1` jumps each one to five seconds from
/// its end.
///
/// The same debug affordance as the `NY_*` harness above, for the half of the
/// app that needs a mouse: it drives exactly what a tile tap and the queue
/// button drive — the queue's cursor, and the route — so a run can be exercised
/// end to end without a hand on it. Unset, it costs one environment lookup at
/// startup and nothing else.
///
/// The seek exists because of what it makes checkable. "Queue three videos, let
/// one finish, next starts" is a real-player property: a widget test can prove
/// the controller advances when `completedStream` fires, but only mpv can prove
/// that stream fires at all at end of media. Waiting out three videos to find
/// out is why that check kept not happening.
void _openOnLaunch(ProviderContainer container) {
  final raw = Platform.environment['RILL_OPEN_VIDEO']?.trim();
  if (raw == null || raw.isEmpty) return;

  final ids = raw.split(',').map((id) => id.trim()).where((id) => id.isNotEmpty).toList();
  if (ids.isEmpty) return;

  // Every cursor move, on stderr — the queue's behaviour read off a log instead
  // of off a screenshot.
  container.listen(queueProvider, (previous, next) {
    stderr.writeln(
      'rill: queue cursor=${next.currentIndex} current=${next.current?.id ?? '-'} '
      'of ${next.items.length} [${next.items.map((i) => i.id).join(', ')}]',
    );
  });

  if (Platform.environment['RILL_SEEK_TO_END'] == '1') {
    final engine = container.read(playbackEngineProvider);
    engine.durationStream.listen((duration) {
      if (duration <= const Duration(seconds: 30)) return;
      final target = duration - const Duration(seconds: 5);
      stderr.writeln('rill: RILL_SEEK_TO_END — seeking to $target of $duration');
      unawaited(engine.seek(target));
    });
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    stderr.writeln('rill: RILL_OPEN_VIDEO=${ids.join(',')} — opening the watch page');
    openWatchIn(container, _placeholderItem(ids.first));
    for (final id in ids.skip(1)) {
      container.read(queueProvider.notifier).addToQueue(_placeholderItem(id));
    }
  });
}

class RillApp extends ConsumerWidget {
  const RillApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watching the seed here is the whole re-theming mechanism: every role every
    // widget reads is derived from it, so one rebuild repaints the app.
    final accent = ref.watch(accentProvider);

    return MaterialApp(
      title: 'Rill',
      theme: buildRillTheme(accent),
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      // `builder` wraps the `Navigator`, so `child` here *is* it. That is what
      // puts the shell — and the mini-player it draws — above every route
      // instead of inside one.
      //
      // The hover-preview scope sits above the shell for the same reason: the feed and the
      // related rail draw the same tiles, and one controller above both is what keeps "one
      // shared preview player, never one per tile" true.
      builder: (context, child) => HoverPreviewScopeHost(
        shell: ref.watch(playbackEngineProvider),
        // Lazy and called at most once, so a user who never hovers pays for no second mpv. A
        // *second* engine rather than the shell's: previewing on that one would open media over
        // whatever is paused there and take its position with it.
        engineFactory: MediaKitEngine.new,
        child: PlayerShell(child: child ?? const SizedBox.shrink()),
      ),
      home: const FeedPage(),
    );
  }
}
