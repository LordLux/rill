/// Premieres — a video that exists, is fine, and has not started.
///
/// Reported from the app: opening one showed "This video would not open" above a
/// *Try again* button that could only fail for another nine days. The video was
/// never broken; `playback.open` had no way to say so.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/player/player_slates.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';
import 'package:rill/ui/queue_controller.dart';
import 'package:rill/ui/widgets/media_tile.dart';

import 'fake_engine.dart';

/// Matches `PREMIERE_ID` / `PREMIERE_AT_MS` in `fake_sidecar.ts`.
const String premiereId = 'premiere1';
const int premiereAtMs = 1787670000000;

VideoItem video(String id, {int? premiereAt}) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: '',
      isLive: false,
      premiereAtMs: premiereAt,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late ProviderContainer container;
bool _containerDisposed = false;

/// Dispose inside the test body, not in `tearDown`.
///
/// `PlaybackController` runs a periodic `playback.report` timer for as long as
/// something is open, and Flutter checks for pending timers *before* `tearDown`
/// runs — so a container disposed there is disposed too late and the test fails
/// with "A Timer is still pending even after the widget tree was disposed",
/// which says nothing about what the test was checking.
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

  tearDownAll(() async {
    await RpcClient.instance.killForTestAndWait();
  });

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

  // -------------------------------------------------------------------------
  // The watch page
  // -------------------------------------------------------------------------

  testWidgets('a premiere shows its date and a reminder, not a failure', (tester) async {
    await open(tester, premiereId);

    final playback = container.read(playbackProvider);
    expect(playback.isUpcoming, isTrue);
    expect(playback.canRetry, isFalse,
        reason: 'retry is `no` — a Try again here can only fail until the date');

    expect(find.byKey(premiereSlateKey), findsOneWidget);
    expect(find.text('This video would not open.'), findsNothing,
        reason: 'the reported bug: nothing is wrong with the video');
    expect(find.text('Try again'), findsNothing);
    expect(find.byKey(premiereNotifyKey), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(premiereNotifyKey)).onPressed, isNull,
        reason: 'the reminder is not wired to YouTube yet, so it does not pretend to be');
 
    disposeContainer();
  });

  testWidgets('an ordinary failure still gets the failure screen', (tester) async {
    // MUTATION: render the slate for every error rather than for `isUpcoming`
    // and this fails — a dead video would offer a reminder for a premiere that
    // is never coming.
    // `broken1` always fails to resolve — a well-known id rather than a sidecar
    // restart, so one process serves the whole file.
    await open(tester, 'broken1');

    expect(container.read(playbackProvider).isUpcoming, isFalse);
    expect(find.byKey(premiereSlateKey), findsNothing);
    expect(find.text('This video would not open.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget, reason: 'this one really can be retried');
 
    disposeContainer();
  });

  testWidgets('a premiere opened after a real video replaces its state', (tester) async {
    await open(tester, 'aaa');
    expect(container.read(playbackProvider).isUpcoming, isFalse);
    expect(engine.playing, isTrue, reason: 'the real video must actually be playing first');

    container.read(queueProvider.notifier).play(video(premiereId));
    await tester.pump();
    await settleReal(tester);

    expect(container.read(playbackProvider).isUpcoming, isTrue,
        reason: 'the error code has to be set on the new open, not left behind');

    // Reported live: clicking a premiere from the sidebar left the *previous*
    // video playing, inaudibly, underneath the "Premieres in…" card — nothing
    // called `open` failing ever told the engine to stop, because `engine.open`
    // is only ever reached on the success path.
    expect(engine.stopCount, greaterThan(0),
        reason: 'a failed open must stop whatever was already playing');
    expect(engine.playing, isFalse,
        reason: 'the previous video must not keep playing under the premiere slate');

    // And back again — the code must be *cleared*, which `??` in a copyWith
    // cannot do (hard invariant 10).
    container.read(queueProvider.notifier).play(video('bbb'));
    await tester.pump();
    await settleReal(tester);
    expect(container.read(playbackProvider).isUpcoming, isFalse);
    expect(container.read(playbackProvider).errorCode, isNull);
 
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // The text
  // -------------------------------------------------------------------------

  group('premiereText', () {
    test('prefers the timestamp, because a date is what someone plans around', () {
      final at = DateTime(2026, 8, 22, 15, 5).millisecondsSinceEpoch;
      expect(premiereText(at, 'Premieres in 9 days'), 'Premieres 22/8/2026 at 15:05');
    });

    test('falls back to YouTube\'s prose when no timestamp arrived', () {
      // `video.info` may not have answered yet, or a layout hid the field. The
      // error message always carries something.
      expect(premiereText(null, 'Premieres in 9 days'), 'Premieres in 9 days');
    });

    test('says something even with neither', () {
      expect(premiereText(null, null), 'Premieres soon');
    });
  });

  group('tilePremiereLabel', () {
    test('is short enough to sit under a channel name', () {
      final at = DateTime(2026, 8, 22, 15, 5).millisecondsSinceEpoch;
      expect(tilePremiereLabel(at), 'Notify me • 22/8 15:05');
    });
  });

  // -------------------------------------------------------------------------
  // The feed card
  // -------------------------------------------------------------------------

  testWidgets('a premiere tile offers a reminder; an ordinary tile does not', (tester) async {
    Future<void> pumpTile(VideoItem item) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Center(child: SizedBox(width: 320, child: MediaTile(spec: specFor(item)!))),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpTile(video('aaa'));
    expect(find.byKey(tileNotifyKey), findsNothing);

    await pumpTile(video(premiereId, premiereAt: premiereAtMs));
    expect(find.byKey(tileNotifyKey), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(tileNotifyKey)).onPressed, isNull);
 
    disposeContainer();
  });

  test('the premiere time survives the DTO round trip', () {
    // The field has to reach Flutter through `freezed`'s `fromJson`, which is
    // where a missing key becomes a crash rather than a null.
    final item = FeedItem.fromJson({
      'kind': 'video',
      'id': premiereId,
      'title': 'Ado',
      'channelName': 'Ado',
      'channelId': null,
      'channelAvatarUrl': null,
      'thumbnailUrl': '',
      'durationSeconds': null,
      'isLive': false,
      'viewCountText': null,
      'publishedText': null,
      'badges': <String>[],
      'premiereAtMs': premiereAtMs,
      'canWatchLater': true,
      'canAddToQueue': true,
    }) as VideoItem;
    expect(item.premiereAtMs, premiereAtMs);

    // And absent means null, not a throw — every other tile in every feed.
    final ordinary = FeedItem.fromJson({
      'kind': 'video',
      'id': 'aaa',
      'title': 'x',
      'channelName': 'y',
      'thumbnailUrl': '',
      'isLive': false,
      'canWatchLater': false,
      'canAddToQueue': false,
    }) as VideoItem;
    expect(ordinary.premiereAtMs, isNull);
  });
}
