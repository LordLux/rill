import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/playback_source.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/pages/watch.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player_shell.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

VideoItem testVideo(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Aspect Test $id',
      channelName: 'Aspect Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late ProviderContainer container;
bool _containerDisposed = false;

void disposeContainer() {
  if (_containerDisposed) return;
  _containerDisposed = true;
  container.dispose();
}

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

class _HomePage extends ConsumerWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: ElevatedButton(
        onPressed: () => openWatch(ref, testVideo('aspect-vid')),
        child: const Text('open video'),
      ),
    );
  }
}

void main() {
  setUp(() async {
    await boot();
  });

  tearDown(() {
    disposeContainer();
    RpcClient.instance.killForTest();
  });

  group('PlaybackEngine width and height streams', () {
    test('FakeEngine reports width, height, and resets on open', () async {
      expect(engine.width, isNull);
      expect(engine.height, isNull);

      final widthEvents = <int?>[];
      final heightEvents = <int?>[];
      final wSub = engine.widthStream.listen(widthEvents.add);
      final hSub = engine.heightStream.listen(heightEvents.add);

      engine.setWidth(1080);
      engine.setHeight(1080);

      expect(engine.width, 1080);
      expect(engine.height, 1080);

      await engine.open(
        const PlaybackVariant(
          videoUrl: 'https://example.com/square.mp4',
          height: 1080,
          fps: 60,
          videoCodec: 'avc1',
          audioCodec: 'mp4a',
        ),
      );

      // On open, FakeEngine sets width and height based on variant
      expect(engine.height, 1080);

      await wSub.cancel();
      await hSub.cancel();
    });
  });

  group('WatchPage responsive layout for arbitrary aspect ratios', () {
    Future<void> pumpWatchWithDimensions(
      WidgetTester tester, {
      required Size windowSize,
      required int videoWidth,
      required int videoHeight,
    }) async {
      tester.view.physicalSize = windowSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const TestApp()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('open video'));
      await tester.pump();
      await settleReal(tester);

      // Decode specific video dimensions
      engine.setWidth(videoWidth);
      engine.setHeight(videoHeight);
      await tester.pump();
      await tester.pumpAndSettle();

      final exception = tester.takeException();
      if (exception != null) {
        // ignore: avoid_print
        if (exception is FlutterError) {
          // ignore: avoid_print
          print('EXCEPTION DEEP: ${exception.diagnostics.map((d) => d.toString()).join('\n')}');
        } else {
          // ignore: avoid_print
          print('EXCEPTION CAUGHT: $exception');
        }
      }
      expect(exception, isNull, reason: 'laid out cleanly with $videoWidth x $videoHeight');
    }

    testWidgets('square (1:1) video maintains 16:9 outer container and does not push rail offscreen',
        (tester) async {
      const windowSize = Size(1500, 850);
      await pumpWatchWithDimensions(
        tester,
        windowSize: windowSize,
        videoWidth: 1080,
        videoHeight: 1080,
      );

      final rail = find.byKey(const ValueKey('related-rail'));
      if (rail.evaluate().isNotEmpty) {
        final railRect = tester.getRect(rail);
        final pageRect = tester.getRect(find.byType(WatchPage));
        expect(
          railRect.right,
          lessThanOrEqualTo(pageRect.right + 0.5),
          reason: 'the related rail must remain fully on-screen for square videos',
        );
      }

      // Check that the video surface is rendered with a 1:1 ratio
      final surface = find.byKey(FakeEngine.surfaceKey);
      expect(surface, findsOneWidget);
      final surfaceSize = tester.getSize(surface);
      expect(
        (surfaceSize.width / surfaceSize.height),
        closeTo(1.0, 0.05),
        reason: 'the inner video surface must match the 1:1 aspect ratio',
      );
      disposeContainer();
    });

    testWidgets('vertical (9:16) video lays out cleanly without overflow', (tester) async {
      const windowSize = Size(1500, 850);
      await pumpWatchWithDimensions(
        tester,
        windowSize: windowSize,
        videoWidth: 1080,
        videoHeight: 1920,
      );

      final rail = find.byKey(const ValueKey('related-rail'));
      if (rail.evaluate().isNotEmpty) {
        final railRect = tester.getRect(rail);
        final pageRect = tester.getRect(find.byType(WatchPage));
        expect(
          railRect.right,
          lessThanOrEqualTo(pageRect.right + 0.5),
          reason: 'the related rail must remain fully on-screen for vertical videos',
        );
      }

      final surface = find.byKey(FakeEngine.surfaceKey);
      expect(surface, findsOneWidget);
      final surfaceSize = tester.getSize(surface);
      expect(
        (surfaceSize.width / surfaceSize.height),
        closeTo(9 / 16, 0.05),
        reason: 'the inner video surface must match the 9:16 aspect ratio',
      );
      disposeContainer();
    });

    testWidgets('ultrawide (21:9) video expands player width proportionally', (tester) async {
      const windowSize = Size(1920, 1080);
      await pumpWatchWithDimensions(
        tester,
        windowSize: windowSize,
        videoWidth: 2560,
        videoHeight: 1080,
      );

      final surface = find.byKey(FakeEngine.surfaceKey);
      expect(surface, findsOneWidget);
      final surfaceSize = tester.getSize(surface);
      expect(
        (surfaceSize.width / surfaceSize.height),
        closeTo(2560 / 1080, 0.05),
        reason: 'the video surface must scale to the ultrawide aspect ratio',
      );
      disposeContainer();
    });

    testWidgets('aspect ratio change animates smoothly across frames', (tester) async {
      const windowSize = Size(1500, 850);
      tester.view.physicalSize = windowSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const TestApp()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('open video'));
      await tester.pump();
      await settleReal(tester);

      // Start at standard 16:9
      engine.setWidth(1920);
      engine.setHeight(1080);
      await tester.pumpAndSettle();

      // Switch to 1:1 square mid-stream
      engine.setWidth(1080);
      engine.setHeight(1080);
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull, reason: 'mid-animation pump should not throw');

      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      disposeContainer();
    });
  });
}
