/// One watch page at a time — Task 36 (todo 90).
///
/// A page opened over the watch page (a playlist, the search results) that then
/// plays something used to stack a second watch page over it, and Back had to
/// walk through every one. `showWatchPageIn` now pushes the new watch route and
/// removes the buried one, and the tracker reports nothing for a route that is
/// removed from under the top.
///
/// Through the real shell, the real watch, playlist and results pages, the fake
/// engine and the fake sidecar. Mounted pages are counted with
/// `skipOffstage: false`, because a covered route stays in the tree.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/pages/playlist.dart' show PlaylistPage, openPlaylistPage, playlistRouteName;
import 'package:rill/ui/pages/search_results.dart';
import 'package:rill/ui/feed_controller.dart' show searchProvider;
import 'package:rill/ui/pages/watch.dart' show WatchPage;
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player_shell.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

late FakeEngine engine;
late ProviderContainer container;
late WidgetRef appRef;
bool _disposed = false;

void disposeContainer() {
  if (_disposed) return;
  _disposed = true;
  container.dispose();
}

/// A real wait for the sidecar, then the frames it caused.
Future<void> settleReal(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

VideoItem _video(int n) => VideoItem(
      kind: 'video',
      id: 'pl$n',
      title: 'Video $n',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/pl$n/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

/// `playlist.get`, which the fake sidecar does not speak: one page of five.
class _Playlists implements MixService {
  @override
  Future<PlaylistResult> getPlaylist(String playlistId, {String? continuation}) async =>
      PlaylistResult(header: null, title: 'My Playlist', videoCount: 5, items: [for (var i = 0; i < 5; i++) _video(i)]);

  @override
  Future<MixStart> start(String playlistId, {String? videoId, String? params}) async => throw UnimplementedError();

  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) async => throw UnimplementedError();
}

class TestApp extends ConsumerWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    appRef = ref;
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => PlayerShell(child: child ?? const SizedBox.shrink()),
      home: Scaffold(
        body: ElevatedButton(
          onPressed: () => openSearchOrVideo(ref, 'https://www.youtube.com/watch?v=q_QyaPhykuI'),
          child: const Text('watch link'),
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

Finder get watchPages => find.byType(WatchPage, skipOffstage: false);
Finder get homeButton => find.text('watch link', skipOffstage: false);

String? get current => container.read(currentRouteProvider);
String? get section => container.read(sectionRouteProvider);

/// Home → a video → its playlist's page, with the watch page buried under it.
Future<void> watchThenPlaylist(WidgetTester tester) async {
  await pumpApp(tester);
  await tester.tap(find.text('watch link'));
  await tester.pump();
  await settleReal(tester);
  expect(current, watchRouteName);

  openPlaylistPage('PL_one');
  await settleReal(tester);
  expect(find.byType(PlaylistPage), findsOneWidget);
  expect(current, playlistRouteName);
  expect(watchPages, findsOneWidget, reason: 'the watch page is covered, not gone');
}

Future<void> back(WidgetTester tester) async {
  rootNavigatorKey.currentState!.pop();
  await tester.pumpAndSettle();
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
        mixServiceProvider.overrideWithValue(_Playlists()),
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
      ],
    );
    container.read(playbackProvider);
  });

  void testWatch(String description, Future<void> Function(WidgetTester tester) body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        disposeContainer();
      }
    });
  }

  testWatch('a row played from the playlist page leaves one watch route, and Back goes page by page', (tester) async {
    await watchThenPlaylist(tester);

    await tester.tap(find.text('Video 1'));
    await tester.pump();
    await settleReal(tester);

    expect(current, watchRouteName);
    expect(watchPages, findsOneWidget, reason: 'the buried watch page is gone, not stacked under a second one');

    await back(tester);
    expect(find.byType(PlaylistPage), findsOneWidget, reason: 'Back reaches the page the video was opened from');
    expect(current, playlistRouteName);
    expect(watchPages, findsNothing);

    await back(tester);
    expect(find.byType(PlaylistPage), findsNothing);
    expect(homeButton, findsOneWidget, reason: 'and then what was under the old watch page');
    expect(current, homeRouteName);
  });

  testWatch('a result played from a search started on the watch page does the same', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('watch link'));
    await tester.pump();
    await settleReal(tester);

    openSearch(appRef, 'lofi beats');
    await settleReal(tester);
    expect(find.byType(SearchResultsPage), findsOneWidget);
    expect(current, searchRouteName);
    // The search starts a frame after the page builds and answers over the wire.
    for (var i = 0; i < 20 && container.read(searchProvider).isLoading; i++) {
      await settleReal(tester);
    }
    expect(container.read(searchProvider).items, isNotEmpty);

    await tester.tap(find.text('lofi beats result 1'));
    await tester.pump();
    await settleReal(tester);

    expect(current, watchRouteName);
    expect(watchPages, findsOneWidget);

    await back(tester);
    expect(find.byType(SearchResultsPage), findsOneWidget);
    expect(watchPages, findsNothing);

    await back(tester);
    expect(homeButton, findsOneWidget);
    expect(current, homeRouteName);
  });

  testWatch('Back from the playlist page without playing anything returns to the same watch page', (tester) async {
    await watchThenPlaylist(tester);
    final before = tester.element(watchPages);

    await back(tester);

    expect(current, watchRouteName);
    expect(watchPages, findsOneWidget);
    expect(identical(tester.element(watchPages), before), isTrue, reason: 'nothing was removed or rebuilt');
  });

  testWatch('removing the buried watch page reports no navigation', (tester) async {
    await watchThenPlaylist(tester);
    // `showWatchPageIn` reads the route provider, so these are what every
    // consumer of it is told, in order, from the click on.
    final routes = <String?>[];
    final miniplayer = <bool>[];
    container.listen(currentRouteProvider, (_, next) => routes.add(next));
    container.listen(miniPlayerShownProvider, (_, next) => miniplayer.add(next));

    await tester.tap(find.text('Video 1'));
    await tester.pump();
    await settleReal(tester);

    expect(routes, [watchRouteName], reason: 'playlist → watch, and never the page that was under the old watch page');
    expect(current, watchRouteName);
    expect(section, playlistRouteName, reason: 'the rail stays where the click was, and the removal did not move it');
    expect(container.read(miniPlayerShownProvider), isFalse);
    expect(miniplayer, isNot(contains(true)), reason: 'the miniplayer is never floated over the new watch page');
  });

  testWatch('removing it does not reopen or reload the video', (tester) async {
    await watchThenPlaylist(tester);
    final opensBefore = engine.opened.length;

    await tester.tap(find.text('Video 1'));
    await tester.pump();
    await settleReal(tester);

    // The row itself plays one video; the removal adds nothing to it.
    expect(engine.opened.length, opensBefore + 1);
    expect(container.read(queueProvider).current?.id, 'pl1');
    expect(engine.stopCount, 0, reason: 'nothing was stopped by dropping the old page');
  });
}
