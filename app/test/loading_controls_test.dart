/// The player controls while a video is still opening — `docs/todo.md` 98, issue #21.
///
/// The harness is `focus_watch_page_test.dart`'s: the real watch page in the real
/// shell, a fake sidecar, and a fake engine whose `openGate` holds the open in
/// flight so the loading state can be pressed on.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/focus_ring.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/controls.dart';
import 'package:rill/ui/player/settings_menu.dart' show playerQualityButtonKey;
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';
import 'sidecar_idle.dart';

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Fake Channel',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

class _TestApp extends ConsumerWidget {
  const _TestApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => FocusRing(child: PlayerShell(child: child ?? const SizedBox.shrink())),
      home: const Scaffold(body: SizedBox.shrink()),
    );
  }
}

void main() {
  late FakeEngine engine;
  late ProviderContainer container;
  late Completer<void> gate;
  var disposed = false;

  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() => RpcClient.instance.killForTestAndWait());

  setUp(() async {
    await RpcClient.instance.call('test.reset', {});
    disposed = false;
    engine = FakeEngine();
    // Held until a test lets go: the sidecar answers, the engine is still opening.
    gate = Completer<void>();
    engine.openGate = gate.future;
    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
      ],
    );
    container.read(playbackProvider);
  });

  /// Called at the end of each test, as `focus_watch_page_test.dart` does: the
  /// controller's timers belong to the container, and the framework checks for
  /// pending ones before a `tearDown` runs.
  void finish() {
    if (!gate.isCompleted) gate.complete();
    if (disposed) return;
    disposed = true;
    container.dispose();
  }

  tearDown(finish);

  /// A video opening, held at the engine: the load a viewer waits through.
  Future<void> openLoading(
    WidgetTester tester, {
    List<String> alsoQueue = const [],

    /// Run straight after the open starts, before the sidecar can have answered.
    void Function()? beforeAnswer,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const _TestApp()));
    await tester.pump();
    openWatchIn(container, video('vid-1'));
    for (final id in alsoQueue) {
      container.read(queueProvider.notifier).addToQueue(video(id));
    }
    beforeAnswer?.call();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    // Frames, not `pumpAndSettle`: the load spinner animates for as long as it is up.
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(playbackProvider).isLoading, isTrue, reason: 'the engine open is being held');
  }

  Future<void> release(WidgetTester tester) async {
    gate.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settleWithSidecar(tester);
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> press(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    await tester.pump();
  }

  testWidgets('the controls are on the page while the video is still opening', (tester) async {
    await openLoading(tester);

    expect(find.byKey(playerPlayPauseKey), findsOneWidget);
    expect(find.byKey(playerScrubberKey), findsOneWidget);
    expect(find.byKey(playerMuteKey), findsOneWidget);

    await release(tester);
    expect(container.read(playbackProvider).isLoading, isFalse);
    expect(find.byKey(playerPlayPauseKey), findsOneWidget, reason: 'the same bar carries on after the load');
    finish();
  });

  testWidgets('pausing during the load opens the video paused, and the button says so throughout', (tester) async {
    await openLoading(tester);
    expect(find.bySemanticsLabel('Pause'), findsWidgets, reason: 'wants to play by default');

    await press(tester, playerPlayPauseKey);

    expect(container.read(playbackProvider).wantPlaying, isFalse);
    expect(find.bySemanticsLabel('Play'), findsWidgets, reason: 'the button shows the wanted state, not the engine\'s');

    await release(tester);
    expect(engine.playing, isFalse, reason: 'it opened paused, on its first frame');
    expect(container.read(playbackProvider).isLoading, isFalse);
    expect(find.bySemanticsLabel('Play'), findsWidgets, reason: 'and the engine agrees with the button now');
    finish();
  });

  testWidgets('pause then play again before it has opened still plays', (tester) async {
    await openLoading(tester);

    await press(tester, playerPlayPauseKey);
    await press(tester, playerPlayPauseKey);
    expect(container.read(playbackProvider).wantPlaying, isTrue);

    await release(tester);
    expect(engine.playing, isTrue);
    finish();
  });

  testWidgets('seeking does nothing until the video has opened', (tester) async {
    await openLoading(tester);

    await container.read(playbackProvider.notifier).seek(const Duration(seconds: 30));
    await container.read(playbackProvider.notifier).seekBy(const Duration(seconds: 10));
    expect(engine.seeks, isEmpty);

    await release(tester);
    await container.read(playbackProvider.notifier).seek(const Duration(seconds: 30));
    expect(engine.seeks, [const Duration(seconds: 30)]);
    finish();
  });

  group('a quality chosen while loading', () {
    List<int> openedHeights() => engine.opened.map((variant) => variant.height).toList();

    testWidgets('before the sidecar has answered is the one the video opens at', (tester) async {
      await openLoading(
        tester,
        beforeAnswer: () => container.read(playbackProvider.notifier).chooseHeightWhileLoading(720),
      );
      expect(container.read(playbackProvider).preferredHeight, 720);

      await release(tester);
      expect(openedHeights(), [720], reason: 'one open, at the height asked for, not the best one first');
      expect(container.read(playbackProvider).variant?.height, 720);
      finish();
    });

    testWidgets('while the engine is already opening another is switched to once it has opened', (tester) async {
      await openLoading(tester);
      expect(openedHeights(), [2160], reason: 'the open in flight is the best rung, nothing was chosen');

      container.read(playbackProvider.notifier).chooseHeightWhileLoading(360);
      await release(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 50));

      expect(openedHeights(), [2160, 360]);
      expect(container.read(playbackProvider).variant?.height, 360);
      finish();
    });

    testWidgets('can be picked from the quality menu, which has the heights to pick from', (tester) async {
      await openLoading(tester);

      await press(tester, playerQualityButtonKey);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Applies when the video opens'), findsOneWidget);
      expect(find.text('720p'), findsOneWidget);

      await tester.tap(find.text('720p'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(container.read(playbackProvider).preferredHeight, 720);
      finish();
    });

    testWidgets('does nothing once the video has opened: that is a switch, not a choice', (tester) async {
      await openLoading(tester);
      await release(tester);

      container.read(playbackProvider.notifier).chooseHeightWhileLoading(360);
      expect(container.read(playbackProvider).preferredHeight, isNull);
      finish();
    });
  });

  testWidgets('next while loading moves on to the next video at once', (tester) async {
    await openLoading(tester, alsoQueue: ['vid-2']);
    expect(container.read(playbackProvider).item?.id, 'vid-1');

    await press(tester, playerNextKey);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(container.read(playbackProvider).item?.id, 'vid-2', reason: 'the viewer is not made to wait for vid-1 first');

    await release(tester);
    final state = container.read(playbackProvider);
    expect(state.item?.id, 'vid-2');
    expect(state.isLoading, isFalse);
    expect(state.wantPlaying, isTrue, reason: 'the next video plays unless the viewer pauses it');
    finish();
  });
}
