/// A throttled open says so — `RATE_LIMITED`, `retry: "user"`, decided
/// 2026-09-17.
///
/// YouTube limits a connection's anonymous resolution after heavy use
/// ("Sign in to confirm you're not a bot", F20). Before this, that reached the
/// watch page as "This video would not open" plus a list of declined tiers,
/// which blames a video that is fine. The retry stays: the limit lifts after
/// minutes, and the user is the one who knows when to try again.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';

import 'fake_engine.dart';

/// Match `RATE_LIMITED_ID` and `BROKEN_ID` in `fake_sidecar.ts`.
const String rateLimitedId = 'ratelimited1';
const String brokenId = 'broken1';

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late ProviderContainer container;
bool _containerDisposed = false;

/// See `premiere_test.dart`: a container disposed in `tearDown` is disposed
/// after Flutter's pending-timer check, and the failure names a timer rather
/// than the test.
void disposeContainer() {
  if (_containerDisposed) return;
  _containerDisposed = true;
  container.dispose();
}

class TestApp extends ConsumerWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => PlayerShell(child: child ?? const SizedBox.shrink()),
      home: const Scaffold(body: SizedBox.shrink()),
    );
  }
}

Future<void> settleReal(WidgetTester tester, [int millis = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: millis)));
  await tester.pumpAndSettle();
}

void main() {
  test('the state knows a throttle from any other failure', () {
    const throttled = PlaybackState(error: 'x', errorCode: 'RATE_LIMITED', errorRetry: RpcRetryMode.user);
    const broken = PlaybackState(error: 'x', errorCode: 'STREAM_UNAVAILABLE', errorRetry: RpcRetryMode.user);
    expect(throttled.isRateLimited, isTrue);
    expect(throttled.canRetry, isTrue);
    expect(broken.isRateLimited, isFalse);
  });

  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() => RpcClient.instance.killForTestAndWait());

  setUp(() async {
    await RpcClient.instance.call('test.reset', {});
    engine = FakeEngine();
    _containerDisposed = false;
    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
      ],
    );
    container.read(playbackProvider);
  });

  tearDown(disposeContainer);

  Future<void> open(WidgetTester tester, String id) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();
    openWatchIn(container, video(id));
    await tester.pump();
    await settleReal(tester);
  }

  testWidgets('a throttled open blames the connection, not the video, and offers a retry', (tester) async {
    await open(tester, rateLimitedId);

    expect(container.read(playbackProvider).isRateLimited, isTrue);
    expect(find.text('YouTube is limiting requests from this connection.'), findsOneWidget);
    expect(find.text('Wait a few minutes, then try again.'), findsOneWidget);
    expect(find.text('This video would not open.'), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Try again'), findsOneWidget);

    disposeContainer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an ordinary failure keeps its own wording', (tester) async {
    // The control for the test above.
    await open(tester, brokenId);

    expect(find.text('This video would not open.'), findsOneWidget);
    expect(find.text('YouTube is limiting requests from this connection.'), findsNothing);

    disposeContainer();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
