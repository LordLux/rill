/// Submitting the search box: a pasted link to one video plays it, and
/// everything else is searched (`openSearchOrVideo`).
///
/// Through the real function, the real shell and the fake sidecar — the sidecar
/// records every `search.query`, which is how "the link was not searched" is
/// proved rather than assumed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/ui/pages/search_results.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

late FakeEngine engine;
late ProviderContainer container;
bool _disposed = false;

void disposeContainer() {
  if (_disposed) return;
  _disposed = true;
  container.dispose();
}

/// A real wait for the sidecar, then the frames it caused. The results page
/// never stops animating while it loads, so it is pumped rather than settled.
Future<void> settleReal(WidgetTester tester, {bool settle = true}) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

const shortLink = 'https://www.youtube.com/shorts/SbRTk0ca7WY?feature=share';

/// One button per thing a user can submit.
class TestApp extends ConsumerWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget submit(String label, String text) => ElevatedButton(
          onPressed: () => openSearchOrVideo(ref, text),
          child: Text(label),
        );

    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => PlayerShell(child: child ?? const SizedBox.shrink()),
      home: Scaffold(
        body: Column(
          children: [
            submit('short link', shortLink),
            submit('watch link', 'https://www.youtube.com/watch?v=q_QyaPhykuI&t=42s'),
            submit('query', 'lofi beats'),
            submit('sentence', 'watch this https://youtu.be/q_QyaPhykuI please'),
          ],
        ),
      ),
    );
  }
}

Future<void> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const TestApp()));
  await tester.pumpAndSettle();
}

Future<List<String?>> searched(WidgetTester tester) async {
  final log = await tester.runAsync(() => RpcClient.instance.call('test.searchLog', {})) as Map;
  return [for (final call in log['searchCalls'] as List) (call as Map)['q'] as String?];
}

void main() {
  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() async {
    await RpcClient.instance.killForTestAndWait();
  });

  setUp(() async {
    await RpcClient.instance.call('test.reset', {});
    engine = FakeEngine();
    _disposed = false;
    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
      ],
    );
    container.read(playbackProvider);
  });

  /// Every test ends by letting the container go before the invariants run — the
  /// playback controller's report timer would still be pending otherwise.
  void testLink(String description, Future<void> Function(WidgetTester tester) body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        disposeContainer();
      }
    });
  }

  testLink('a pasted Shorts link opens the Short, and is never searched', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('short link'));
    await tester.pump();
    await settleReal(tester);

    expect(container.read(queueProvider).current?.id, 'SbRTk0ca7WY');
    expect(container.read(currentRouteProvider), watchRouteName, reason: 'on the watch page, not the results');
    expect(await searched(tester), isEmpty, reason: 'YouTube\'s own search has nothing for a /shorts/ link');
  });

  testLink('a pasted watch link opens the video, ignoring what rides along', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('watch link'));
    await tester.pump();
    await settleReal(tester);

    expect(container.read(queueProvider).current?.id, 'q_QyaPhykuI');
    expect(container.read(currentRouteProvider), watchRouteName);
    expect(await searched(tester), isEmpty);
  });

  testLink('anything else is searched, as before', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('query'));
    await tester.pump();
    await settleReal(tester, settle: false);
    // The page's own load, still landing: dispose under it and it throws.
    await settleReal(tester, settle: false);

    expect(container.read(currentRouteProvider), searchRouteName);
    expect(container.read(queueProvider).isEmpty, isTrue, reason: 'nothing was opened');
    expect(await searched(tester), ['lofi beats']);
  });

  testLink('a sentence with a link in it is a search, not a link', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('sentence'));
    await tester.pump();
    await settleReal(tester, settle: false);
    // The page's own load, still landing: dispose under it and it throws.
    await settleReal(tester, settle: false);

    expect(container.read(currentRouteProvider), searchRouteName);
    expect(container.read(queueProvider).isEmpty, isTrue);
    expect(await searched(tester), ['watch this https://youtu.be/q_QyaPhykuI please']);
  });
}
