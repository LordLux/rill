/// The caption drag handle, mounted — Task 19.
///
/// **Its own file, and its own harness, because of `runAsync`.** These are
/// widget tests, so they run inside `FakeAsync`, where a bare `Future.delayed`
/// never completes; but the setup talks to a *real* sidecar process over stdio.
/// Every line that waits on real I/O therefore goes through `tester.runAsync`,
/// which is exactly the seam `caption_style_test.dart` avoids by using plain
/// `test()`. Mixing the two conventions in one file is how a suite acquires a
/// ten-minute timeout nobody can explain.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/captions_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/caption_drag_layer.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

VideoItem _video(String id) => VideoItem(
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

/// The player surface these tests draw into.
///
/// 1920x1080 at 16:9 so the widget's pixels and the ASS document's `PlayRes` are
/// 1:1 — an assertion can then be written in the units `ass.ts` computes in,
/// rather than in units derived from a scale factor the test also has to get
/// right.
const Size _surface = Size(1920, 1080);

/// Boot a sidecar, play a video, turn on a track, and mount the layer.
///
/// Returns with a caption on screen. Everything up to the mount runs under
/// `runAsync`; the pumps after it do not, so the gesture assertions are ordinary
/// widget-test time.
Future<void> pumpWithCaption(WidgetTester tester, {String text = 'a caption'}) async {
  await tester.binding.setSurfaceSize(_surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.runAsync(() async {
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();

    engine = FakeEngine();
    container = ProviderContainer(
      overrides: [playbackEngineProvider.overrideWithValue(engine)],
    );
    container.read(playbackProvider);
    container.read(captionsProvider);

    container.read(queueProvider.notifier).play(_video('a'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await container.read(captionsProvider.notifier).select('.en');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  addTearDown(() {
    container.dispose();
    RpcClient.instance.killForTest();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1920,
            height: 1080,
            child: CaptionDragLayer(aspectRatio: 16 / 9),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  // mpv's `sub-text`, which is where the words come from — see
  // `PlaybackEngine.subtitleTextStream`. The stream hop is real, so it needs one
  // `runAsync` of its own before the frame that reads it.
  await tester.runAsync(() async {
    engine.subtitleText.add(text);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pump();
}

void main() {
  testWidgets('there is nothing to grab until a caption is on screen', (tester) async {
    await tester.binding.setSurfaceSize(_surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      RpcClient.instance.killForTest();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
      await RpcClient.instance.start();
      engine = FakeEngine();
      container = ProviderContainer(
        overrides: [playbackEngineProvider.overrideWithValue(engine)],
      );
      container.read(playbackProvider);
      container.read(captionsProvider);
      container.read(queueProvider.notifier).play(_video('a'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    addTearDown(() {
      container.dispose();
      RpcClient.instance.killForTest();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1920,
              height: 1080,
              child: CaptionDragLayer(aspectRatio: 16 / 9),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(captionDragHandleKey), findsNothing,
        reason: 'captions are off — there is no caption to move');
  });

  testWidgets('the handle sits where the caption is, and takes the grab cursor',
      (tester) async {
    await pumpWithCaption(tester);

    final handle = tester.getRect(find.byKey(captionDragHandleKey));
    // Bottom-centre on the default anchor — the same pixel `ass.ts` computes for
    // an undragged, unpositioned cue.
    expect(handle.center.dx, closeTo(960, 1));
    expect(handle.bottom, closeTo(1020, 1));

    final region = tester.widget<MouseRegion>(
      find
          .ancestor(
            of: find.byKey(captionDragHandleKey),
            matching: find.byType(MouseRegion),
          )
          .first,
    );
    expect(region.cursor, SystemMouseCursors.grab);
  });

  testWidgets('the ghost moves during the drag and the real caption does not',
      (tester) async {
    await pumpWithCaption(tester);

    final attachedBefore = engine.subtitles.length;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(captionDragHandleKey)),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(-192, -108));
    await tester.pump();

    // **Nothing is re-rendered mid-gesture.** What follows the cursor is a
    // Flutter-drawn ghost; the document mpv is holding is untouched until
    // release, which is what makes the gesture smooth and stops the text
    // re-wrapping under the cursor.
    expect(find.byKey(captionDragGhostKey), findsOneWidget);
    expect(engine.subtitles.length, attachedBefore,
        reason: 'no `sub-add` while the gesture is running');
    expect(container.read(captionsProvider).offset.isZero, isTrue);

    await gesture.up();
    await tester.pump();

    final offset = container.read(captionsProvider).offset;
    expect(offset.dx, closeTo(-0.1, 0.01));
    expect(offset.dy, closeTo(-0.1, 0.01));
    expect(find.byKey(captionDragGhostKey), findsNothing);
  });

  // **What happens after the offset lands in state is not tested here**, and
  // deliberately. The commit is a real round trip, and a future created inside a
  // widget test's `FakeAsync` zone cannot be completed by the I/O that a later
  // `runAsync` performs — the assertion passes or fails on the timing of the
  // harness rather than on the behaviour. `caption_style_test.dart` covers that
  // half with plain `test()`: `setOffset` puts the delta on the wire and the
  // regenerated document reaches the engine. What this file is for is the
  // gesture, and the gesture ends at `CaptionsState.offset`.

  testWidgets('the drag cannot push the caption out of the frame', (tester) async {
    await pumpWithCaption(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(captionDragHandleKey)),
    );
    await tester.pump();
    // Far past the bottom-right corner, in one throw.
    await gesture.moveBy(const Offset(4000, 4000));
    await tester.pump();

    final ghost = tester.getRect(find.byKey(captionDragGhostKey));
    expect(ghost.right, lessThanOrEqualTo(1920));
    expect(ghost.bottom, lessThanOrEqualTo(1080));
    expect(ghost.left, greaterThanOrEqualTo(0));

    await gesture.up();
    await tester.pump();
  });
}
