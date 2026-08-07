/// The shell above the `Navigator` (task §1).
///
/// The property being pinned is structural: a player owned by the watch route is
/// destroyed on pop, and a mini-player and background playback become impossible.
/// So the assertions are about what *survives* a push and a pop — the media is
/// not reopened, the engine is not stopped or disposed, and the position is the
/// one it had before the route changed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/pages/watch.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player_shell.dart';

import 'fake_engine.dart';

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late ProviderContainer container;
bool _containerDisposed = false;

/// Disposing the container cancels the report timer.
///
/// It has to happen inside the test body, not in `tearDown`: the widget binding
/// asserts that no timer outlives the tree, and `playback.report`'s periodic
/// timer is a real one. Idempotent, so the `tearDown` below stays honest for the
/// tests that do not reach the end.
void disposeContainer() {
  if (_containerDisposed) return;
  _containerDisposed = true;
  container.dispose();
}

/// Let the real sidecar answer.
///
/// `testWidgets` runs in a fake-async zone where a real subprocess's I/O never
/// progresses, so a `pump` loop waits forever on a response that cannot arrive.
/// `runAsync` steps outside it for exactly as long as the round trip needs.
Future<void> settleReal(WidgetTester tester, [int millis = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: millis)));
  await tester.pumpAndSettle();
}

Future<void> boot() async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  await RpcClient.instance.start();

  engine = FakeEngine();
  _containerDisposed = false;
  container = ProviderContainer(
    overrides: [playbackEngineProvider.overrideWithValue(engine)],
  );
  container.read(playbackProvider);
}

/// `main.dart`'s structure, minus the theme: the shell is mounted through
/// `MaterialApp.builder`, so its child is the `Navigator` itself.
class TestApp extends ConsumerWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => PlayerShell(child: child ?? const SizedBox.shrink()),
      home: const _HomePage(),
    );
  }
}

/// Stands in for the feed: a button, and something long enough to scroll.
///
/// Never disposed, which is fine for a test file — each `pumpWidget` attaches it
/// to the new tree's list and the old one detaches with its element.
final ScrollController homeScroll = ScrollController();

class _HomePage extends ConsumerWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Column(
        children: [
          ElevatedButton(
            onPressed: () => openWatch(ref, video('aaa')),
            child: const Text('open aaa'),
          ),
          Expanded(
            child: ListView.builder(
              controller: homeScroll,
              itemCount: 200,
              itemBuilder: (context, index) => SizedBox(height: 60, child: Text('row $index')),
            ),
          ),
        ],
      ),
    );
  }
}

void main() {
  setUp(() async {
    await boot();
  });

  tearDown(() async {
    disposeContainer();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  testWidgets('the player survives a route push and pop, and keeps its position',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();

    // No player, no mini-player.
    expect(find.byType(MiniPlayer), findsNothing);

    await tester.tap(find.text('open aaa'));
    await tester.pump();
    await settleReal(tester);

    expect(find.byType(WatchPage), findsOneWidget);
    expect(engine.opened, hasLength(1));
    // On the watch page the mini-player is redundant and must not be drawn.
    expect(find.byType(MiniPlayer), findsNothing);

    // Watch a bit.
    engine.emitPosition(const Duration(seconds: 90));
    await tester.pump();

    // Leave.
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(find.byType(WatchPage), findsNothing);
    expect(find.byType(MiniPlayer), findsOneWidget,
        reason: 'leaving the watch page collapses to a mini-player');
    expect(engine.opened, hasLength(1),
        reason: 'a pop must not reopen the media — that is a player inside the route');
    expect(engine.stopCount, 0, reason: 'and must not stop it: background audio is #6');
    expect(engine.disposeCount, 0, reason: 'the player outlives every route');
    expect(engine.position, const Duration(seconds: 90));

    // Return.
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await settleReal(tester);

    expect(find.byType(WatchPage), findsOneWidget);
    expect(find.byType(MiniPlayer), findsNothing);
    expect(engine.opened, hasLength(1), reason: 'expanding is not reopening');
    expect(engine.position, const Duration(seconds: 90),
        reason: 'the position is the one it had before the round trip');

    disposeContainer();
  });

  testWidgets('the video surface moves to the mini-player rather than being duplicated',
      (tester) async {
    // The visible payoff of putting the player above the `Navigator`: the
    // texture belongs to the engine, so the same surface renders on the watch
    // page and, once popped, in the mini-player. Nothing is created or freed by
    // the move — `VideoController` releases on `Player.dispose` alone.
    //
    // The assertion that matters is *exactly one*. Two mounted at once would be
    // two `Texture` widgets on one id, which is the shape of the duplicated
    // transport bar this page already had once.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(FakeEngine.surfaceKey), findsNothing,
        reason: 'nothing is playing, so nothing is mounted');

    await tester.tap(find.text('open aaa'));
    await tester.pump();
    await settleReal(tester);

    expect(find.byKey(FakeEngine.surfaceKey), findsOneWidget);
    expect(
      find.descendant(of: find.byType(WatchPage), matching: find.byKey(FakeEngine.surfaceKey)),
      findsOneWidget,
      reason: 'on the watch page the surface is in the page',
    );

    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(find.byKey(FakeEngine.surfaceKey), findsOneWidget,
        reason: 'one surface, still — not one per mount point');
    expect(
      find.descendant(of: find.byType(MiniPlayer), matching: find.byKey(FakeEngine.surfaceKey)),
      findsOneWidget,
      reason: 'and it is now the mini-player showing it, live rather than as artwork',
    );
    expect(engine.opened, hasLength(1), reason: 'moving the surface is not reopening the media');

    disposeContainer();
  });

  testWidgets('the feed stays mounted under the watch route and keeps its scroll',
      (tester) async {
    // Task §3: "`maintainState` default, so the feed's scroll survives."
    //
    // Asserted as the outcome, not as the flag, because the flag is on the other
    // route: `maintainState` describes whether a route survives being *covered*,
    // so the one that matters belongs to the feed and is MaterialApp's default.
    // Putting `maintainState: false` on the watch route changes nothing — that
    // mutant survives, and it survives correctly.
    //
    // What does kill this test is `pushReplacement` in `showWatchPageIn`
    // (verified: "Found 0 widgets with type _HomePage"), which is the realistic
    // regression — it looks like a tidy-up of the back stack and silently costs
    // the feed everything the user had scrolled past.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();

    homeScroll.jumpTo(1200);
    await tester.pump();
    expect(homeScroll.offset, 1200);

    await tester.tap(find.text('open aaa'));
    await tester.pump();
    await settleReal(tester);
    expect(find.byType(WatchPage), findsOneWidget);

    // Still in the tree, just covered. With `maintainState: false` the subtree
    // is gone and the controller has nothing to report a position for.
    expect(find.byType(_HomePage, skipOffstage: false), findsOneWidget);
    expect(homeScroll.hasClients, isTrue);

    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(homeScroll.offset, 1200, reason: 'the feed came back where it was left');

    disposeContainer();
  });

  /// The watch page laid out at real window sizes.
  ///
  /// A `RenderFlex` overflow is silent in a release build — no stripes, just a
  /// column of tiles cut off past the right edge, which is exactly how the
  /// related rail shipped the first time it was looked at on a 1500 px window.
  /// Here it is an exception, which is a test failure.
  Future<void> layoutAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open aaa'));
    await tester.pump();
    await settleReal(tester);

    expect(find.byType(WatchPage), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'laid out clean at $size');

    // The rail is what actually ran off the edge, and an overflow is not what
    // did it — `Expanded` + a fixed width cannot overflow a `Row`. So this
    // measures the thing directly: every pixel of the rail inside the page.
    final rail = find.byKey(const ValueKey('related-rail'));
    if (rail.evaluate().isNotEmpty) {
      final railRect = tester.getRect(rail);
      final pageRect = tester.getRect(find.byType(WatchPage));
      // ignore: avoid_print
      print('LAYOUT $size: page=$pageRect rail=$railRect');
      expect(railRect.right, lessThanOrEqualTo(pageRect.right + 0.5),
          reason: 'the related rail must not hang off the right edge');
    }
    disposeContainer();
  }

  testWidgets('the watch page fits a wide window', (tester) async {
    await layoutAt(tester, const Size(1500, 850));
  });

  testWidgets('the watch page fits a narrow window', (tester) async {
    await layoutAt(tester, const Size(900, 700));
  });

  testWidgets('tapping a related tile does not push a second watch route', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open aaa'));
    await tester.pump();
    await settleReal(tester);
    expect(find.byType(WatchPage), findsOneWidget);

    // Exactly what a related tap does: move the queue's cursor and ask for the
    // watch page, which is already the top route.
    openWatchIn(container, video('bbb'));
    await tester.pump();
    await settleReal(tester);

    // One watch page, showing the new video. A second route would mean the back
    // button walks a history of videos rather than returning to the feed.
    expect(find.byType(WatchPage), findsOneWidget);
    expect(engine.opened.last.videoUrl, contains('bbb'));

    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(WatchPage), findsNothing);

    disposeContainer();
  });
}
