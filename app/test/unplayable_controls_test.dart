/// A video that cannot be played — a premiere, a members-only video, a rate
/// limit, a plain failure — and what the player's chrome does about it.
///
/// Two things were wrong. The members-only and premiere slates were laid out from
/// a time when the progress bar was not drawn over them, so their button sat
/// behind it. And the scrubber and the play button were live controls on a
/// player with no media: a click, a Space or a media key reached an engine that
/// had been stopped.
///
/// **Mutation** run against this file: remove the `enabled` gate on the play
/// button's `onPressed` and the "disabled" group fails; set
/// `playerControlsClearance` back to 20 and the "clears the bar" group fails.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/player/scrubber_bar.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/controls.dart';
import 'package:rill/ui/player/player_slates.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

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
bool _disposed = false;

void disposeContainer() {
  if (_disposed) return;
  _disposed = true;
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

/// The id, and what makes it unplayable — the fake sidecar's own ids.
const unplayable = <String, String>{
  'members1': 'a members-only video',
  'premiere1': 'a premiere',
  'broken1': 'a plain failure',
  'ratelimited1': 'a rate limit',
};

void main() {
  test('only a failed open is unplayable', () {
    expect(const PlaybackState().isUnplayable, isFalse, reason: 'nothing open is not a failure');
    expect(const PlaybackState(isLoading: true).isUnplayable, isFalse, reason: 'loading is not one either');
    expect(const PlaybackState(error: 'x', errorCode: 'VIDEO_UPCOMING').isUnplayable, isTrue);
    expect(const PlaybackState(error: 'x', errorCode: 'VIDEO_MEMBERS_ONLY').isUnplayable, isTrue);
    expect(const PlaybackState(error: 'x', errorCode: 'RATE_LIMITED').isUnplayable, isTrue);
    expect(const PlaybackState(error: 'x').isUnplayable, isTrue);
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
    _disposed = false;
    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
      ],
    );
    container.read(playbackProvider);
  });

  /// Every test lets the container go before the invariants run.
  void testPlayer(String description, Future<void> Function(WidgetTester tester) body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        disposeContainer();
      }
    });
  }

  Future<void> open(WidgetTester tester, String id, {Size size = const Size(1400, 1000), List<String> then = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const TestApp()));
    await tester.pumpAndSettle();
    openWatchIn(container, video(id));
    for (final next in then) {
      container.read(queueProvider.notifier).addToQueue(video(next));
    }
    await tester.pump();
    await settleReal(tester);
  }

  final scrubber = find.descendant(of: find.byKey(playerScrubberKey), matching: find.byType(ScrubberBar));

  group('the slate clears the control bar', () {
    for (final size in const [Size(1400, 1000), Size(900, 700)]) {
      testPlayer('a members-only slate\'s button, in a ${size.width.toInt()} px window', (tester) async {
        await open(tester, 'members1', size: size);

        final bar = tester.getRect(find.byKey(playerControlsBarKey));
        final button = tester.getRect(find.byKey(membersOnlyJoinKey));
        expect(button.bottom, lessThanOrEqualTo(bar.top), reason: 'the button is above the bar, not behind it');
        expect(button.bottom, greaterThan(bar.top - 40), reason: 'and still down at the bottom, not floating');
      });

      testPlayer('a premiere slate\'s button, in a ${size.width.toInt()} px window', (tester) async {
        await open(tester, 'premiere1', size: size);

        final bar = tester.getRect(find.byKey(playerControlsBarKey));
        final button = tester.getRect(find.byKey(premiereNotifyKey));
        expect(button.bottom, lessThanOrEqualTo(bar.top));
      });
    }
  });

  group('when nothing can be played', () {
    for (final entry in unplayable.entries) {
      final id = entry.key;
      final what = entry.value;

      testPlayer('$what: the scrubber and the play button are disabled', (tester) async {
        await open(tester, id, then: ['aaa']);

        expect(tester.widget<ScrubberBar>(scrubber).onChanged, isNull, reason: 'no dragging or tapping the bar');
        expect(tester.widget<IconButton>(find.byKey(playerPlayPauseKey)).onPressed, isNull);
        // Skipping past it is exactly when next is wanted.
        expect(tester.widget<IconButton>(find.byKey(playerNextKey)).onPressed, isNotNull);
      });

      testPlayer('$what: a tap on the bar, a click on the picture and the keyboard do nothing', (tester) async {
        await open(tester, id);
        expect(engine.playing, isFalse);

        await tester.tapAt(tester.getCenter(scrubber), kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(engine.seeks, isEmpty, reason: 'the bar did not seek');

        // The picture: a single click plays and pauses an ordinary video.
        await tester.tapAt(tester.getCenter(find.byType(PlayerControls)) - const Offset(0, 60));
        await tester.pump(const Duration(milliseconds: 400));
        expect(engine.playing, isFalse, reason: 'the click did not play anything');

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(engine.playing, isFalse, reason: 'Space did not either');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
        await tester.pump();
        expect(engine.seeks, isEmpty, reason: 'nor did the seek keys');
      });
    }

    testPlayer('the mini-player\'s play button is disabled too', (tester) async {
      await open(tester, 'members1');
      toMiniPlayerIn(container);
      await tester.pumpAndSettle();

      final play = find.ancestor(
        of: find.descendant(of: find.byType(MiniPlayer), matching: find.byIcon(Icons.play_arrow)),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(play).onPressed, isNull);
    });
  });

  group('an ordinary video', () {
    testPlayer('keeps every one of them', (tester) async {
      await open(tester, 'aaa');
      // Playing: the play button is the pause icon and is live.
      expect(tester.widget<ScrubberBar>(scrubber).onChanged, isNotNull);
      expect(tester.widget<IconButton>(find.byKey(playerPlayPauseKey)).onPressed, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(engine.playing, isFalse, reason: 'it was playing, and Space paused it');
    });

    testPlayer('seeks from the bar as before', (tester) async {
      await open(tester, 'aaa');
      await tester.tapAt(tester.getCenter(scrubber), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(engine.seeks, hasLength(1));
    });
  });
}
