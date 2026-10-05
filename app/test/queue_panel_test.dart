/// The queue panel's removals, which are animated and therefore deferred.
///
/// The X changes the queue ~340 ms after it is pressed, and everything the user
/// does in that gap lands on a list that is still moving. These pin both halves:
/// the row animates before the queue changes, and the queue still ends up minus
/// exactly the videos whose X was pressed.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/queue_controller.dart';
import 'package:rill/ui/widgets/queue_panel.dart';
import 'package:rill/ui/widgets/shortcut_tooltip.dart';

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

/// The queue's ids in order — the assertion that matters in every test here.
List<String> idsIn(ProviderContainer container) =>
    container.read(queueProvider).items.map((i) => i.id).toList();

void main() {
  late ProviderContainer container;

  /// The one mouse, moved from row to row.
  ///
  /// One per test and not one per click: a second `addPointer` while the first
  /// is still down trips an assertion inside `MouseTracker` itself. A user has
  /// one pointer too, which is what makes two rows leaving at once take two
  /// trips across the panel rather than two hands.
  late TestGesture mouse;

  /// A panel over a queue of [ids], with the first one playing.
  ///
  /// **Under two nested `LayoutBuilder`s, as the watch page mounts it.** They
  /// build their child during layout, so anything the panel dirties as it builds
  /// is a framework assertion rather than a wrong pixel. Pumped bare into a
  /// `Scaffold` the same mistake passes silently.
  Future<void> pumpPanel(WidgetTester tester, List<String> ids) async {
    container = ProviderContainer();
    addTearDown(container.dispose);

    final queue = container.read(queueProvider.notifier);
    queue.play(video(ids.first));
    for (final id in ids.skip(1)) {
      queue.addToQueue(video(id));
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: LayoutBuilder(
              builder: (context, outer) => Row(
                children: [
                  const SizedBox(width: 72), // the collapsed nav rail
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, inner) => SingleChildScrollView(
                        child: Column(
                          children: const [EmbeddedQueuePanel(maxHeight: 800)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Past the staggered slide-in the panel plays for a queue it did not build.
    await tester.pumpAndSettle();

    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
  }

  /// The row showing [id]. `findsNWidgets(2)` for a video queued twice.
  Finder rowFor(String id) =>
      find.ancestor(of: find.text('Video $id'), matching: find.byType(ListTile));

  /// Press the X on [row].
  ///
  /// The button only exists under the pointer, so this hovers first — which is
  /// also what a user does.
  Future<void> clickRemoveOn(WidgetTester tester, Finder row) async {
    await mouse.moveTo(tester.getCenter(row));
    await tester.pump();
    // The X fades in over 50 ms (`AnimatedCrossFade`), and since the row became
    // a `Stack` it is not hit-testable on the very first frame of that fade —
    // a tap aimed at its centre lands on the `ListTile` body. No person can
    // click inside one frame of hovering, so this waits the way a pointer does.
    await tester.pump(const Duration(milliseconds: 100));

    final remove = find.descendant(of: row, matching: find.byWidgetPredicate((w) => w is ShortcutTooltip && w.label == 'Remove'));
    expect(remove, findsOneWidget, reason: 'the X is not reachable on this row');
    await tester.tap(remove, warnIfMissed: false);
    await tester.pump();
  }

  Future<void> clickRemove(WidgetTester tester, String id) async {
    final row = rowFor(id);
    expect(row, findsOneWidget, reason: 'no single row for $id');
    await clickRemoveOn(tester, row);
  }

  testWidgets('the row slides out before the queue changes', (tester) async {
    await pumpPanel(tester, ['a', 'b', 'c', 'd']);

    // Where the row below sits while nothing is moving.
    final below = tester.getTopLeft(rowFor('d')).dy;

    await clickRemove(tester, 'c');

    // Mid-slide: the row is still there, so is the video, and nothing below it
    // has started to move yet — the gap closes after the slide, not during.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Video c'), findsOneWidget);
    expect(idsIn(container), ['a', 'b', 'c', 'd'], reason: 'the queue must not change on the click');
    expect(tester.getTopLeft(rowFor('d')).dy, below);

    // Into the collapse: the row is closing the gap it will leave, so what
    // follows it has begun to rise — and has not arrived yet either.
    await tester.pump(const Duration(milliseconds: 170));
    final rising = tester.getTopLeft(rowFor('d')).dy;
    expect(rising, lessThan(below));
    expect(rising, greaterThan(tester.getTopLeft(rowFor('c')).dy));

    await tester.pumpAndSettle();
    expect(idsIn(container), ['a', 'b', 'd']);
    expect(find.text('Video c'), findsNothing);
  });

  testWidgets('three fast clicks remove the three videos that were clicked', (tester) async {
    await pumpPanel(tester, ['a', 'b', 'c', 'd', 'e', 'f']);

    // The user's own example, at the speed that breaks an index: row 3, row 5,
    // row 4, none of them given time to finish.
    await clickRemove(tester, 'c');
    await tester.pump(const Duration(milliseconds: 60));
    await clickRemove(tester, 'e');
    await tester.pump(const Duration(milliseconds: 60));
    await clickRemove(tester, 'd');

    await tester.pumpAndSettle();

    expect(idsIn(container), ['a', 'b', 'f']);
  });

  testWidgets('the same video queued twice loses the copy that was clicked', (tester) async {
    await pumpPanel(tester, ['a', 'dup', 'b', 'dup']);

    // Both rows read "Video dup"; the second one is the one being pressed.
    expect(rowFor('dup'), findsNWidgets(2));

    await clickRemoveOn(tester, rowFor('dup').last);
    await tester.pumpAndSettle();

    expect(idsIn(container), ['a', 'dup', 'b'], reason: 'the trailing copy was the one clicked');
  });

  testWidgets('a second click on a row already leaving removes only one video', (tester) async {
    await pumpPanel(tester, ['a', 'b', 'c', 'd']);

    await clickRemove(tester, 'c');
    await tester.pump(const Duration(milliseconds: 40));

    // The X on a committed row goes invisible but stays in the tree — the row
    // keeps its layout while it slides — so this presses at it three more times
    // the way an impatient user would. `Visibility` makes the hits miss and the
    // panel turns away anything that gets through.
    final x = find.descendant(of: rowFor('c'), matching: find.byWidgetPredicate((w) => w is ShortcutTooltip && w.label == 'Remove'));
    for (var i = 0; i < 3; i++) {
      await tester.tap(x, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 20));
    }

    await tester.pumpAndSettle();
    expect(idsIn(container), ['a', 'b', 'd'], reason: 'four presses on one row remove one video');
  });

  testWidgets('the removal that empties the panel takes the panel with it', (tester) async {
    await pumpPanel(tester, ['a', 'b']);

    await clickRemove(tester, 'b');
    await tester.pumpAndSettle();

    expect(idsIn(container), ['a']);
    expect(find.byType(ListTile), findsNothing, reason: 'a one-item queue has no panel');
  });

  testWidgets('a row collapsing under an open tooltip does not mutate layout', (tester) async {
    // **The pointer has to be on the button, not on the row** — architecture
    // §2.8. Every other test here hovers the row's centre, so no tooltip is ever
    // open and all of them pass while the app throws on the same gesture.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    container = ProviderContainer();
    addTearDown(container.dispose);
    final queue = container.read(queueProvider.notifier);
    queue.play(video('a'));
    for (final id in ['b', 'c', 'd', 'e', 'f']) {
      queue.addToQueue(video(id));
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: LayoutBuilder(
              builder: (context, outer) => Row(
                children: [
                  const SizedBox(width: 72),
                  Expanded(
                    child: LayoutBuilder(
                      // A lazy sliver, as the watch page's own scroller is: it
                      // builds the panel *during* layout, which is what makes a
                      // mutation from inside the frame illegal rather than
                      // merely untidy.
                      builder: (context, inner) => ListView(
                        children: const [EmbeddedQueuePanel(maxHeight: 360)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = rowFor('c');
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // the X's fade-in; see clickRemoveOn

    final x = find.descendant(of: row, matching: find.byWidgetPredicate((w) => w is ShortcutTooltip && w.label == 'Remove'));
    await mouse.moveTo(tester.getCenter(x));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('Remove'),
      findsOneWidget,
      reason: 'the tooltip has to be open, or this test proves nothing',
    );

    await mouse.down(tester.getCenter(x));
    await tester.pump();
    await mouse.up();
    await tester.pump();

    // Frame by frame across the whole exit: the throw lands on the one where
    // the gap finishes closing, and `pumpAndSettle` would swallow which.
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.takeException(), isNull, reason: 'threw $i frames into the exit');
    }

    expect(idsIn(container), ['a', 'b', 'd', 'e', 'f']);
  });

  testWidgets('a removal in flight survives the panel going away', (tester) async {
    await pumpPanel(tester, ['a', 'b', 'c', 'd']);

    await clickRemove(tester, 'c');
    await tester.pump(const Duration(milliseconds: 40));

    // The watch page can be popped mid-slide. The click was still a decision.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
    // Pumped by the clock rather than by `pumpAndSettle`: with the panel gone
    // nothing is animating, so settling would return without ever reaching the
    // moment this removal comes due.
    await tester.pump(const Duration(milliseconds: 400));

    expect(idsIn(container), ['a', 'b', 'd']);
  });
}
