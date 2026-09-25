/// Chapters on the player's progress bar, through the real controls —
/// `architecture.md` §2.7. The geometry and the mapping are pinned in
/// `scrubber_chapters_test.dart`; this is what the wiring does with them.
///
/// `chapters1` (four chapters over the fake's ten-minute video), `live1` and the
/// ordinary `aaa` come from `fake_sidecar.ts`. The **mutation** run against this
/// file: return the chapter's title regardless of whether the video has chapters
/// and "no chapters → the timestamp alone" fails.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/video_detail.dart';
import 'package:rill/ui/audio_mode_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/controls.dart';
import 'package:rill/ui/player/scrubber_chapters.dart';
import 'package:rill/ui/player/settings_menu.dart';
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
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late NoWindowChrome window;
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
  await RpcClient.instance.call('test.reset', {});
  engine = FakeEngine();
  window = NoWindowChrome();
  _containerDisposed = false;
  container = ProviderContainer(
    overrides: [
      playbackEngineProvider.overrideWithValue(engine),
      windowChromeProvider.overrideWithValue(window),
    ],
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
      home: const Scaffold(body: SizedBox.expand()),
    );
  }
}

Future<void> pumpWatching(WidgetTester tester, {List<String> queue = const ['chapters1']}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const TestApp()));
  await tester.pumpAndSettle();

  container.read(queueProvider.notifier).play(video(queue.first));
  for (final id in queue.skip(1)) {
    container.read(queueProvider.notifier).addToQueue(video(id));
  }
  showWatchPageIn(container);
  await tester.pump();
  await settleReal(tester);
}

/// The scrubber's `Slider`. Its box is the scrubber's box — the `Stack` around
/// it has no other sized child — and its track is inset by the 8 px padding.
final Finder scrubber = find.descendant(of: find.byKey(playerScrubberKey), matching: find.byType(Slider));

const double trackInset = 8;

/// The scrubber's box, and the x that a fraction of the way along its track is.
class Bar {
  Bar(this.rect);

  final Rect rect;

  double get trackLeft => rect.left + trackInset;
  double get trackRight => rect.right - trackInset;
  double get y => rect.center.dy;
  double xAt(double fraction) => trackLeft + fraction * (trackRight - trackLeft);
  Offset at(double fraction) => Offset(xAt(fraction), y);
}

Bar bar(WidgetTester tester) => Bar(tester.getRect(scrubber));

final List<TestGesture> _pointers = [];

/// A mouse that is let go of — by `testBar`, before the container it reports
/// into — when the test ends. Removing it from a tear-down would fire an exit
/// into the controls after their providers were gone.
Future<TestGesture> mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  _pointers.add(gesture);
  await tester.pump();
  return gesture;
}

/// Puts a position and a buffer on the engine's streams and lets the bar
/// rebuild: the event arrives after the frame that would draw it, so one pump
/// is not enough.
Future<void> emit(WidgetTester tester, {Duration? position, Duration? buffer}) async {
  if (position != null) engine.emitPosition(position);
  if (buffer != null) engine.emitBuffer(buffer);
  await tester.pump();
  await tester.pump();
}

/// What the bubble says, or null when there is none.
({String time, String? title})? bubble(WidgetTester tester) {
  if (find.byKey(playerScrubberBubbleKey).evaluate().isEmpty) return null;
  final time = tester.widget<Text>(find.byKey(playerScrubberBubbleTimeKey)).data!;
  final titleFinder = find.byKey(playerScrubberBubbleTitleKey);
  return (time: time, title: titleFinder.evaluate().isEmpty ? null : tester.widget<Text>(titleFinder).data);
}

/// Every rect the scrubber paints, with the colour — the segments, read off the
/// canvas rather than inferred. In the scrubber's own coordinates.
List<({Rect rect, Color color})> painted(WidgetTester tester) {
  final canvas = TestRecordingCanvas();
  tester.renderObject(find.byKey(playerScrubberKey)).paint(TestRecordingPaintingContext(canvas), Offset.zero);
  return [
    for (final call in canvas.invocations)
      if (call.invocation.memberName == #drawRect)
        (
          // The slider's own 8 px padding is carried by the `Slider`'s
          // `CompositedTransformTarget` as a layer offset, which a recording
          // context has no layer to apply — so every rect comes back that far
          // left of where it is on screen.
          rect: (call.invocation.positionalArguments[0] as Rect).shift(const Offset(trackInset, 0)),
          color: (call.invocation.positionalArguments[1] as Paint).color,
        ),
  ];
}

/// Every test in this file, with the container let go before the invariants are
/// checked: `tearDown` runs after them, and the playback controller's report
/// timer would still be pending.
void testBar(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final pointer in _pointers) {
        await pointer.removePointer();
      }
      _pointers.clear();
      disposeContainer();
    }
  });
}

/// Nothing between the bubble and the root clips it — read off the render tree,
/// because a layout rect says nothing about what is painted. Every ancestor that
/// clips must contain the bubble: the player's own box does, the scrubber's
/// (which the bubble overflows) must not be one.
void expectUnclipped(WidgetTester tester) {
  final bubble = tester.renderObject<RenderBox>(find.byKey(playerScrubberBubbleKey));
  final bubbleRect = MatrixUtils.transformRect(bubble.getTransformTo(null), Offset.zero & bubble.size);
  for (RenderObject? ancestor = bubble.parent; ancestor != null; ancestor = ancestor.parent) {
    final clips = switch (ancestor) {
      RenderStack(:final clipBehavior) => clipBehavior != Clip.none,
      RenderClipRect(:final clipBehavior) => clipBehavior != Clip.none,
      RenderClipRRect(:final clipBehavior) => clipBehavior != Clip.none,
      RenderClipPath(:final clipBehavior) => clipBehavior != Clip.none,
      _ => false,
    };
    if (!clips) continue;
    final box = ancestor as RenderBox;
    final clip = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    expect(clip.inflate(0.01).contains(bubbleRect.topLeft) && clip.inflate(0.01).contains(bubbleRect.bottomRight), isTrue,
        reason: '${ancestor.runtimeType} clips to $clip, and the bubble at $bubbleRect is not inside it');
  }
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
    await boot();
  });

  tearDown(disposeContainer);

  final spans = chapterSpans(
    const [
      Chapter(title: 'Intro', startSeconds: 0),
      Chapter(title: 'Explore', startSeconds: 90),
      Chapter(title: 'Build', startSeconds: 300),
      Chapter(title: 'Outro', startSeconds: 480),
    ],
    const Duration(minutes: 10),
  )!;

  group('the bubble', () {
    testBar('names the hovered time and the chapter it is in', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final pointer = await mouse(tester);

      expect(bubble(tester), isNull, reason: 'nothing until the pointer is on the bar');

      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      expect(bubble(tester), (time: '5:00', title: 'Build'));
      expectUnclipped(tester);

      await pointer.moveTo(b.at(0.2));
      await tester.pump();
      expect(bubble(tester), (time: '2:00', title: 'Explore'));

      await pointer.moveTo(b.at(0.85));
      await tester.pump();
      expect(bubble(tester), (time: '8:30', title: 'Outro'));
    });

    testBar('the ends of the track read exactly zero and the duration', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final pointer = await mouse(tester);

      await pointer.moveTo(Offset(b.trackLeft, b.y));
      await tester.pump();
      expect(bubble(tester), (time: '0:00', title: 'Intro'));

      await pointer.moveTo(Offset(b.trackRight, b.y));
      await tester.pump();
      expect(bubble(tester), (time: '10:00', title: 'Outro'));

      // The padding either side is the bar's, not the track's: it clamps.
      await pointer.moveTo(Offset(b.rect.left + 1, b.y));
      await tester.pump();
      expect(bubble(tester)?.time, '0:00');
      await pointer.moveTo(Offset(b.rect.right - 1, b.y));
      await tester.pump();
      expect(bubble(tester)?.time, '10:00');
    });

    testBar('the chapter changes at its boundary and not a pixel before', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final pointer = await mouse(tester);

      // 90 s is 15% of the way along.
      await pointer.moveTo(b.at(0.15) - const Offset(1, 0));
      await tester.pump();
      expect(bubble(tester)?.title, 'Intro');
      await pointer.moveTo(b.at(0.15) + const Offset(1, 0));
      await tester.pump();
      expect(bubble(tester)?.title, 'Explore');
    });

    testBar('a video with no chapters gets the timestamp alone', (tester) async {
      await pumpWatching(tester, queue: ['aaa']);
      final b = bar(tester);
      final pointer = await mouse(tester);

      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      expect(bubble(tester), (time: '5:00', title: null));
      expect(find.byKey(playerScrubberBubbleTitleKey), findsNothing);
    });

    testBar('follows the pointer, above the bar, and stays inside it at either end', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final pointer = await mouse(tester);

      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      final middle = tester.getRect(find.byKey(playerScrubberBubbleKey));
      expect(middle.center.dx, closeTo(b.xAt(0.5), 0.5), reason: 'centred on the pointer');
      expect(middle.bottom, lessThan(b.y), reason: 'above the track');

      await pointer.moveTo(b.at(0.52));
      await tester.pump();
      expect(tester.getRect(find.byKey(playerScrubberBubbleKey)).center.dx, greaterThan(middle.center.dx), reason: 'and follows it');

      await pointer.moveTo(Offset(b.trackLeft, b.y));
      await tester.pump();
      expect(tester.getRect(find.byKey(playerScrubberBubbleKey)).left, greaterThanOrEqualTo(b.rect.left), reason: 'not past the left edge');

      await pointer.moveTo(Offset(b.trackRight, b.y));
      await tester.pump();
      expect(tester.getRect(find.byKey(playerScrubberBubbleKey)).right, lessThanOrEqualTo(b.rect.right), reason: 'not past the right edge');
    });

    testBar('disappears when the pointer leaves, and never appears over the rest of the bar', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final pointer = await mouse(tester);

      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      expect(bubble(tester), isNotNull);

      await pointer.moveTo(tester.getCenter(find.byKey(playerPlayPauseKey)));
      await tester.pump();
      expect(bubble(tester), isNull, reason: 'the transport buttons are not the track');

      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      await pointer.moveTo(b.at(0.5) - const Offset(0, 60));
      await tester.pump();
      expect(bubble(tester), isNull, reason: 'nor the picture above it');
    });

    testBar('does not take the pointer', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final pointer = await mouse(tester);
      await pointer.moveTo(b.at(0.5));
      await tester.pump();

      final bubbleBox = tester.getRect(find.byKey(playerScrubberBubbleKey));
      final bubbleRender = find.byKey(playerScrubberBubbleKey).evaluate().single.renderObject;
      final hits = tester.hitTestOnBinding(bubbleBox.center);
      expect(hits.path.map((entry) => entry.target), isNot(contains(bubbleRender)),
          reason: 'a click where the bubble is drawn reaches what is under it');
      // It is drawn outside the scrubber's box, which hit-testing already skips;
      // the IgnorePointer is for the day it overlaps something.
      expect(
        find.ancestor(of: find.byKey(playerScrubberBubbleKey), matching: find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring)),
        findsWidgets,
      );
    });
  });

  group('while dragging', () {
    testBar('shows the thumb\'s time, follows it, and seeks only on release', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);

      final drag = await tester.startGesture(b.at(0.25), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await drag.moveTo(b.at(0.75));
      await tester.pump();

      expect(bubble(tester), (time: '7:30', title: 'Build'));
      expect(engine.seeks, isEmpty, reason: 'F15: never a seek during the drag');

      await drag.moveTo(b.at(0.9));
      await tester.pump();
      expect(bubble(tester)?.time, '9:00');
      expect(tester.getRect(find.byKey(playerScrubberBubbleKey)).center.dx, closeTo(b.xAt(0.9), 0.5));

      await drag.up();
      await tester.pump();
      expect(engine.seeks, hasLength(1));
      expect(engine.seeks.single.inSeconds, closeTo(540, 2));
    });

    testBar('keeps the thumb\'s time when the pointer wanders off the bar', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);

      final drag = await tester.startGesture(b.at(0.25), kind: PointerDeviceKind.mouse);
      await tester.pump();
      // Up into the picture, x unchanged: the slider still owns the drag, the
      // pointer is no longer over the bar, and the bubble must not vanish.
      await drag.moveTo(b.at(0.6) - const Offset(0, 90));
      await tester.pump();

      expect(bubble(tester), (time: '6:00', title: 'Build'), reason: 'the thumb\'s time, not nothing');
      await drag.up();
      await tester.pump();
    });

    testBar('a tap seeks exactly where it did, and the bubble agrees with where it landed', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final pointer = await mouse(tester);

      // Not 1.0: the slider's own box ends where its track does, and that pixel
      // is outside it, so a tap on it reaches nothing — the hover box is wider.
      for (final fraction in [0.0, 0.13, 0.5, 0.87, 0.999]) {
        engine.seeks.clear();
        await pointer.moveTo(b.at(fraction));
        await tester.pump();
        final hovered = bubble(tester)!.time;

        await tester.tapAt(b.at(fraction), kind: PointerDeviceKind.mouse);
        await tester.pump();

        expect(engine.seeks, hasLength(1), reason: 'one tap, one seek — at $fraction');
        expect(formatClock(engine.seeks.single), hovered,
            reason: 'the tooltip names the position the click lands on, at $fraction of the track');
      }
    });
  });

  group('the segments', () {
    testBar('one per chapter, with the gap at each boundary and nowhere else', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final drawn = painted(tester);

      final extents = segmentExtents(spans, trackInset, b.rect.width - trackInset);
      expect(drawn.map((d) => (left: d.rect.left, right: d.rect.right)), extents,
          reason: 'at position zero it is the remaining layer alone, one rect per chapter');
      expect(drawn.map((d) => d.rect.height).toSet(), {ScrubberMetrics.trackHeight}, reason: 'none grown at rest');
      for (var i = 1; i < extents.length; i++) {
        expect(extents[i].left - extents[i - 1].right, ScrubberMetrics.chapterGap, reason: 'a 2 px gap before segment $i');
      }
    });

    testBar('the played and buffered layers sweep across the gaps', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      await emit(tester, position: const Duration(minutes: 4), buffer: const Duration(minutes: 7));

      double x(double fraction) => trackInset + fraction * (b.rect.width - 2 * trackInset);
      final extents = segmentExtents(spans, trackInset, b.rect.width - trackInset);
      final drawn = painted(tester);
      final played = drawn.first.color;
      final remaining = drawn.last.color;
      final buffered = drawn.map((d) => d.color).toSet().difference({played, remaining}).single;
      List<(double, double)> layer(Color color) => [for (final d in drawn) if (d.color == color) (d.rect.left, d.rect.right)];

      // 4:00 is in the second chapter, 7:00 in the third.
      void expectLayer(Color color, List<(double, double)> want) {
        final got = layer(color);
        expect(got, hasLength(want.length));
        for (var i = 0; i < want.length; i++) {
          expect(got[i].$1, closeTo(want[i].$1, 0.001), reason: 'left of $i');
          expect(got[i].$2, closeTo(want[i].$2, 0.001), reason: 'right of $i');
        }
      }

      expectLayer(played, [(extents[0].left, extents[0].right), (extents[1].left, x(0.4))]);
      expectLayer(buffered, [(x(0.4), extents[1].right), (extents[2].left, x(0.7))]);
      expectLayer(remaining, [(x(0.7), extents[2].right), (extents[3].left, extents[3].right)]);
    });

    testBar('nothing is painted across a gap, at any position', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final extents = segmentExtents(spans, trackInset, b.rect.width - trackInset);

      for (final minutes in [0, 1, 4, 5, 9]) {
        await emit(tester, position: Duration(minutes: minutes), buffer: const Duration(minutes: 7));
        for (final d in painted(tester)) {
          for (var i = 1; i < extents.length; i++) {
            final boundary = (extents[i - 1].right + extents[i].left) / 2;
            expect(d.rect.left < boundary - 0.01 && d.rect.right > boundary + 0.01, isFalse,
                reason: 'at $minutes min, a rect crosses the gap at boundary $i');
          }
        }
      }
    });

    testBar('the segment under the pointer grows about its centre line, and the rest stay put', (tester) async {
      await pumpWatching(tester);
      final b = bar(tester);
      final pointer = await mouse(tester);
      final rest = painted(tester);
      final restCentre = rest.first.rect.center.dy;

      await pointer.moveTo(b.at(0.3)); // the second chapter
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration * 2);

      final grown = painted(tester);
      expect(grown.map((d) => d.rect.height), [
        ScrubberMetrics.trackHeight,
        ScrubberMetrics.trackHeightHovered,
        ScrubberMetrics.trackHeight,
        ScrubberMetrics.trackHeight,
      ]);
      expect(grown.map((d) => d.rect.center.dy).toSet(), {restCentre}, reason: 'symmetric: the bar does not shift');

      // And it is animated, not a snap.
      await pointer.moveTo(b.at(0.6)); // the third
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration ~/ 3);
      final mid = painted(tester).map((d) => d.rect.height).toList();
      expect(mid[1], allOf(greaterThan(ScrubberMetrics.trackHeight), lessThan(ScrubberMetrics.trackHeightHovered)), reason: 'shrinking');
      expect(mid[2], allOf(greaterThan(ScrubberMetrics.trackHeight), lessThan(ScrubberMetrics.trackHeightHovered)), reason: 'growing');

      await tester.pump(ScrubberMetrics.growDuration * 2);
      expect(painted(tester).map((d) => d.rect.height), [4, 4, 7, 4]);

      await pointer.moveTo(Offset.zero);
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration * 2);
      expect(painted(tester).map((d) => d.rect.height).toSet(), {ScrubberMetrics.trackHeight}, reason: 'all back at rest');
    });

    testBar('a video with no chapters is one track, and it grows the same way', (tester) async {
      await pumpWatching(tester, queue: ['aaa']);
      final b = bar(tester);
      final pointer = await mouse(tester);

      expect(painted(tester), hasLength(1));
      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration * 2);
      expect(painted(tester).single.rect.height, ScrubberMetrics.trackHeightHovered);
    });

    testBar('a chapter list cannot outlive its video', (tester) async {
      await pumpWatching(tester, queue: ['chapters1', 'aaa']);
      expect(painted(tester), hasLength(4), reason: 'the first video is segmented');

      await tester.tap(find.byKey(playerNextKey));
      await tester.pump();
      await settleReal(tester);

      expect(painted(tester), hasLength(1), reason: 'the next video has none, and the last one\'s must not paint on it');
      final b = bar(tester);
      final pointer = await mouse(tester);
      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      expect(bubble(tester)?.title, isNull);
    });

    testBar('a quality switch keeps the segments, drawn from the held duration', (tester) async {
      await pumpWatching(tester);
      engine.setPlaying(true);
      engine.emitPosition(const Duration(minutes: 3));
      await tester.pump();

      final gate = Completer<void>();
      engine.openGate = gate.future;
      await tester.tap(find.byKey(playerQualityButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('720p'));
      await tester.pump();
      engine.emitPosition(Duration.zero);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(engine.duration, Duration.zero, reason: 'the engine really is reporting nothing');
      final b = bar(tester);
      expect(painted(tester).map((d) => (left: d.rect.left, right: d.rect.right)).take(1), isNotEmpty);
      expect(
        painted(tester).where((d) => d.color != painted(tester).last.color).isNotEmpty,
        isTrue,
        reason: 'the position is held, so something is played',
      );
      final pointer = await mouse(tester);
      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      expect(bubble(tester), (time: '5:00', title: 'Build'), reason: 'against the held ten minutes, not the engine\'s zero');

      gate.complete();
      engine.openGate = null;
      await tester.pump();
      engine.emitPosition(const Duration(minutes: 3, milliseconds: 100));
      await settleReal(tester);
    });
  });

  group('a live stream', () {
    testBar('has no segments and no bubble — the bar is as it was', (tester) async {
      await pumpWatching(tester, queue: ['live1']);
      final b = bar(tester);
      final pointer = await mouse(tester);

      await pointer.moveTo(b.at(0.5));
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration * 2);

      expect(bubble(tester), isNull);
      expect(find.byKey(playerScrubberBubbleKey), findsNothing);
      // The plain track: never more than played + buffered + remaining, and
      // none of it grown.
      final drawn = painted(tester);
      expect(drawn.length, lessThanOrEqualTo(4));
      expect(drawn.map((d) => d.rect.height).toSet(), {ScrubberMetrics.trackHeight});
    });
  });

  group('in every layout', () {
    /// The bubble is above the track and inside the bar.
    void expectBubbleWellPlaced(WidgetTester tester, Bar b) {
      final box = tester.getRect(find.byKey(playerScrubberBubbleKey));
      expect(box.bottom, lessThan(b.y - ScrubberMetrics.trackHeightHovered / 2), reason: 'above the track');
      expect(box.left, greaterThanOrEqualTo(b.rect.left));
      expect(box.right, lessThanOrEqualTo(b.rect.right));
      expectUnclipped(tester);
    }

    testBar('fullscreen, where nothing above the Navigator has an Overlay', (tester) async {
      await pumpWatching(tester);
      await tester.tap(find.byKey(playerFullscreenKey));
      await tester.pumpAndSettle();
      expect(container.read(playerViewProvider).fullscreen, isTrue);

      final b = bar(tester);
      final pointer = await mouse(tester);
      await pointer.moveTo(b.at(0.5));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(bubble(tester), (time: '5:00', title: 'Build'));
      expectBubbleWellPlaced(tester, b);
      await pointer.moveTo(Offset(b.trackRight, b.y));
      await tester.pump();
      expectBubbleWellPlaced(tester, b);
    });

    testBar('audio-only', (tester) async {
      await pumpWatching(tester);
      container.read(audioModeProvider.notifier).setMode(true);
      // Not `pumpAndSettle`: the audio layout never stops animating.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(playerQualityButtonKey), findsNothing, reason: 'this is the audio bar — it has no quality button');

      final b = bar(tester);
      final pointer = await mouse(tester);
      await pointer.moveTo(b.at(0.5));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(bubble(tester), (time: '5:00', title: 'Build'));
      expectBubbleWellPlaced(tester, b);
    });

    testBar('a vertical video, where the scrubber shares its row with the clock', (tester) async {
      await pumpWatching(tester);
      engine.setWidth(720);
      engine.setHeight(1280);
      await tester.pumpAndSettle();
      expect(find.byKey(playerVerticalVolumeKey), findsOneWidget, reason: 'this is the vertical layout');

      final b = bar(tester);
      expect(b.rect.height, lessThan(40), reason: 'the scrubber is a bar, not the height of the player');
      final pointer = await mouse(tester);
      await pointer.moveTo(b.at(0.5));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(bubble(tester), (time: '5:00', title: 'Build'));
      expectBubbleWellPlaced(tester, b);
      await pointer.moveTo(Offset(b.trackLeft, b.y));
      await tester.pump();
      expectBubbleWellPlaced(tester, b);
    });
  });
}
