/// The footer under a populated grid.
///
/// The controller tests pin *when* a paging failure stops the loop. This pins
/// that the user is told: before the footer existed, the error surface only
/// replaced the grid when there were no items, so a feed with content already on
/// screen failed in total silence.
///
/// The state is stubbed rather than driven through a real sidecar. A widget test
/// runs in a fake-async zone, so a live child process makes no progress between
/// `pump`s and the test simply hangs — and what is under test here is the
/// rendering, which the controller tests cannot see.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/feed_controller.dart';
import 'package:rill/ui/pages/feed.dart';

/// A controller that never talks to the transport.
///
/// `FeedController.build` kicks off a real `loadHome`; overriding it is what
/// keeps this test off the process boundary.
class _StubFeed extends FeedController {
  _StubFeed(this.initial);

  final FeedState initial;

  @override
  FeedState build() => initial;
}

FeedState _stateWith({String? error, RpcRetryMode? errorRetry, bool isLoading = false}) {
  return FeedState(
    surface: FeedController.surface,
    items: [
      for (var i = 0; i < 3; i++)
        VideoItem(
          kind: 'video',
          id: 'vid_$i',
          title: 'BASE item $i',
          channelName: 'Fake Channel',
          channelId: 'chan_001',
          channelAvatarUrl: null,
          thumbnailUrl: '',
          durationSeconds: 60,
          isLive: false,
          viewCountText: null,
          publishedText: null,
          badges: const [],
          canWatchLater: false,
          canAddToQueue: false,
        ),
    ],
    continuation: 'PAGE2',
    isLoading: isLoading,
    error: error,
    errorRetry: errorRetry,
  );
}

Future<void> _pump(WidgetTester tester, FeedState state) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [feedProvider.overrideWith(() => _StubFeed(state))],
      child: MaterialApp(
        theme: buildRillTheme(kDefaultAccent),
        home: const FeedPage(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a retry:"user" page failure shows the reason, a retry, and keeps the grid', (tester) async {
    await _pump(tester, _stateWith(error: 'page unavailable', errorRetry: RpcRetryMode.user));

    expect(find.textContaining('page unavailable'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);

    // A failed *next* page must not take the page the user already has.
    expect(find.text('BASE item 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a retry:"no" failure offers no retry button', (tester) async {
    await _pump(tester, _stateWith(error: 'sign in again', errorRetry: RpcRetryMode.no));

    expect(find.textContaining('sign in again'), findsOneWidget);
    // protocol.md §4: retrying changes nothing until something external does.
    expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading the next page shows a spinner, not an error', (tester) async {
    await _pump(tester, _stateWith(isLoading: true));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
