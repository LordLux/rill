/// The members-only slate — a video that exists, is fine, and is behind a
/// membership.
///
/// Reported from the app on 2026-09-09: opening one from the members shelf
/// showed "This video would not open" above a *Try again* that could never
/// work, listing every declined tier. Two things were wrong and this file
/// covers both:
///
///   - the sidecar's ladder collected `VIDEO_MEMBERS_ONLY` as an ordinary
///     decline and exhausted into `STREAM_UNAVAILABLE` (`resolve.ts`'s rethrow
///     named `VIDEO_UPCOMING` alone — asserted in `sidecar/test/members-only.test.ts`);
///   - the watch page read only the error code, so a locale whose refusal prose
///     the sidecar cannot classify would have kept the failure screen even
///     though `video.info` knew perfectly well what the video was.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/pages/watch.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';

import 'fake_engine.dart';

/// Matches `MEMBERS_ID` / `MEMBERS_LOCALE_ID` in `fake_sidecar.ts`.
const String membersId = 'members1';
const String membersLocaleId = 'memberslocale1';
const String membersNoChannelId = 'membersnochan1';

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Markiplier',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late ProviderContainer container;
bool _containerDisposed = false;

/// See `premiere_test.dart` — a container disposed in `tearDown` is disposed
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

  Future<void> openWith(WidgetTester tester, VideoItem item) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();
    openWatchIn(container, item);
    await tester.pump();
    await settleReal(tester);
  }

  Future<void> open(WidgetTester tester, String id) => openWith(tester, video(id));

  testWidgets('a members-only video shows the slate, not the failure screen',
      (tester) async {
    await open(tester, membersId);

    final playback = container.read(playbackProvider);
    expect(playback.isMembersOnly, isTrue);
    expect(playback.canRetry, isFalse,
        reason: 'retry is `no` — a Try again cannot buy a membership');

    expect(find.byKey(membersOnlySlateKey), findsOneWidget);
    // The reported bug, verbatim.
    expect(find.text('This video would not open.'), findsNothing);
    expect(find.text('Try again'), findsNothing);

    disposeContainer();
  });

  testWidgets('a blank channel name on the tile does not leave a dangling full stop',
      (tester) async {
    // Seen for real: "This video is for members of ." — `VideoItem.channelName`
    // is a non-nullable `String`, so a tile built before the name is known
    // holds `''`, and a `== null` check misses it entirely. The name is taken
    // from `video.info` (which this page has already fetched) and blank is
    // treated as absent.
    await openWith(tester, video(membersId).copyWith(channelName: ''));

    expect(find.textContaining('members of .'), findsNothing);
    expect(find.textContaining('Fake Channel'), findsWidgets,
        reason: 'video.info knows the name even when the tile does not');

    disposeContainer();
  });

  testWidgets('with no name anywhere it falls back to a whole sentence',
      (tester) async {
    await openWith(tester, video(membersNoChannelId).copyWith(channelName: ''));

    expect(find.text('This video is for channel members.'), findsOneWidget);
    expect(find.textContaining('members of'), findsNothing);

    disposeContainer();
  });

  testWidgets('the slate names the channel and offers a disabled Join',
      (tester) async {
    await open(tester, membersId);

    expect(find.textContaining('Fake Channel'), findsWidgets);
    expect(find.byKey(membersOnlyJoinKey), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(membersOnlyJoinKey)).onPressed, isNull,
        reason: 'joining is a purchase flow this app does not implement, so it '
            'does not pretend to');

    disposeContainer();
  });

  testWidgets('the structural flag alone is enough — a locale the sidecar could not classify',
      (tester) async {
    // `memberslocale1` fails with a plain `STREAM_UNAVAILABLE`: the sidecar
    // classifies members-only from YouTube's *prose*, which is localised, so on
    // some locale it will simply miss. `video.info` still carries
    // `isMembersOnly` from a badge style YouTube does not translate, and that
    // is what has to carry the screen.
    await open(tester, membersLocaleId);

    final playback = container.read(playbackProvider);
    expect(playback.isMembersOnly, isFalse,
        reason: 'the error code genuinely did not say so — that is the premise');
    expect(playback.error, isNotNull);

    expect(find.byKey(membersOnlySlateKey), findsOneWidget,
        reason: 'the structural flag from video.info carries it');
    expect(find.text('This video would not open.'), findsNothing);

    disposeContainer();
  });

  testWidgets('an ordinary failure still gets the failure screen', (tester) async {
    // MUTATION: drop the `playback.error != null` gate, or widen the flag to any
    // video, and this fails — a dead video would offer to join a channel.
    await open(tester, 'broken1');

    expect(find.byKey(membersOnlySlateKey), findsNothing);
    expect(find.text('This video would not open.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget, reason: 'this one really can be retried');

    disposeContainer();
  });

  testWidgets('a premiere still gets the premiere slate, not this one',
      (tester) async {
    // The two terminal codes sit next to each other in one `if` chain; putting
    // the members branch first would have swallowed premieres.
    await open(tester, 'premiere1');

    expect(find.byKey(premiereSlateKey), findsOneWidget);
    expect(find.byKey(membersOnlySlateKey), findsNothing);

    disposeContainer();
  });
}
