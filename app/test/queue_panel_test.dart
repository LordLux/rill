/// The queue panel's removals, which are animated and therefore deferred.
///
/// The X changes the queue ~340 ms after it is pressed, and everything the user
/// does in that gap lands on a list that is still moving. These pin both halves:
/// the row animates before the queue changes, and the queue still ends up minus
/// exactly the videos whose X was pressed.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/pages/playlist.dart';
import 'package:rill/ui/player_shell.dart' show currentRouteProvider, homeRouteName, rootNavigatorKey, routeTrackerProvider;
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

/// A list source whose top-ups never answer, so a header test sees the queue
/// exactly as it was set rather than mid-fetch or after a failed one.
class _SilentMixService implements MixService {
  _SilentMixService({this.failPages = false});

  /// Fail every page request instead of leaving it unanswered.
  final bool failPages;

  @override
  Future<MixStart> start(String playlistId, {String? videoId, String? params}) => Completer<MixStart>().future;
  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) => Completer<MixExtension>().future;
  @override
  Future<PlaylistResult> getPlaylist(String playlistId, {String? continuation}) =>
      failPages ? Future.error(StateError('network down')) : Completer<PlaylistResult>().future;
}

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

  testWidgets('hovering the X names it, to its left and inside the row', (tester) async {
    await pumpPanel(tester, ['a', 'b']);
    final row = rowFor('b');
    await mouse.moveTo(tester.getCenter(row));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final remove = find.descendant(of: row, matching: find.byWidgetPredicate((w) => w is ShortcutTooltip && w.label == 'Remove'));
    await mouse.moveTo(tester.getCenter(remove));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final bubble = find.text('Remove');
    expect(bubble, findsOneWidget);
    expect(tester.getTopRight(bubble).dx, lessThanOrEqualTo(tester.getTopLeft(remove).dx), reason: 'to the left of the X');
  });

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
  testWidgets('Playlist source shows playlist title', (tester) async {
    container = ProviderContainer();
    addTearDown(container.dispose);

    // Provide a queue state that is a playlist
    container.read(queueProvider.notifier).debugSetStateForTest(QueueState(
      items: [video('1'), video('2')],
      currentIndex: 0,
      mix: const MixQueue(playlistId: 'PL123', title: 'My Playlist', isPlaylist: true),
    ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: EmbeddedQueuePanel(maxHeight: 360)),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('My Playlist'), findsOneWidget);
    expect(find.text('Mixes are playlists YouTube makes for you'), findsNothing);
    expect(find.byIcon(Icons.playlist_play), findsOneWidget);
    expect(find.byIcon(Icons.podcasts), findsNothing, reason: 'that one is the mix\'s');

    // For a playlist, the menu has children so right-clicking it will open a menu.
    // MenuAnchor itself is present. We can just check that it has children by looking at its children list, or simulating a right click.
    final anchor = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
    expect(anchor.menuChildren.isNotEmpty, true, reason: 'menu is present for playlists');
  });

  group('a playlist\'s header menu', () {
    /// A playlist queue long enough to scroll, in a page that scrolls too, as
    /// the watch page mounts it.
    Future<void> pumpPanel(WidgetTester tester) async {
      container = ProviderContainer(
        overrides: [mixServiceProvider.overrideWithValue(_SilentMixService())],
      );
      addTearDown(container.dispose);
      container.read(queueProvider.notifier).debugSetStateForTest(QueueState(
        items: [for (var i = 1; i <= 20; i++) video('$i')],
        currentIndex: 0,
        mix: const MixQueue(playlistId: 'PL123', title: 'My Playlist', isPlaylist: true, exhausted: true, totalCount: 20),
      ));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          navigatorObservers: [container.read(routeTrackerProvider)],
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Column(children: [EmbeddedQueuePanel(maxHeight: 360), SizedBox(height: 2000)]),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> pumpWithMenu(WidgetTester tester) async {
      await pumpPanel(tester);
      await tester.tap(find.text('My Playlist'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Go to Playlist'), findsOneWidget, reason: 'a right-click opens the menu');
    }

    // A menu only the mouse can open is not done (Task 35 §3.4): the header is
    // already a Tab stop, and the two keys Windows gives a context menu open it.
    testWidgets('opens from the keyboard, with Shift+F10 and with the context-menu key', (tester) async {
      await pumpPanel(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('Go to Playlist'), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('Go to Playlist'), findsOneWidget, reason: 'Shift+F10 on the focused header');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Go to Playlist'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(find.text('Go to Playlist'), findsOneWidget, reason: 'the context-menu key on the focused header');
    });

    testWidgets('Copy link puts the playlist\'s own address on the clipboard and says so', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpWithMenu(tester);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(copied, 'https://www.youtube.com/playlist?list=PL123');
      expect(find.text('Link copied to clipboard'), findsOneWidget);
    });

    testWidgets('Go to Playlist pushes the playlist\'s page, and Back comes back', (tester) async {
      await pumpWithMenu(tester);

      await tester.tap(find.text('Go to Playlist'));
      // Not `pumpAndSettle`: the page's spinner never settles while its list is loading.
      // The menu closes, then the route builds, then it comes on stage.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(find.byType(PlaylistPage), findsOneWidget);
      // A real route, reported by the tracker — never a name written into the
      // provider by hand, which told the shell the watch page had been left
      // while it was still on screen.
      expect(container.read(currentRouteProvider), playlistRouteName);

      rootNavigatorKey.currentState!.pop();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(PlaylistPage), findsNothing);
      expect(container.read(currentRouteProvider), homeRouteName);
    });

    // The header is the menu's own anchor, so a press on it is not the outside
    // press that dismisses the menu everywhere else: it has to be handled.
    testWidgets('a click on the header closes it, and is not also a click on the header', (tester) async {
      await pumpWithMenu(tester);
      // The list's own crossfade, among the header's and the rows'.
      bool expanded() =>
          tester
              .widget<AnimatedCrossFade>(
                find.byWidgetPredicate((w) => w is AnimatedCrossFade && w.firstChild is ConstrainedBox && w.secondChild is SizedBox),
              )
              .crossFadeState ==
          CrossFadeState.showFirst;
      expect(expanded(), isTrue);

      // Left of where the menu opened, so the press lands on the header and not on the menu.
      final onHeader = tester.getCenter(find.text('My Playlist')) + const Offset(-30, 0);
      await tester.tapAt(onHeader);
      await tester.pumpAndSettle();
      expect(find.text('Go to Playlist'), findsNothing);
      expect(expanded(), isTrue, reason: 'dismissing the menu does not collapse the queue');

      await tester.tapAt(onHeader);
      await tester.pumpAndSettle();
      expect(expanded(), isFalse, reason: 'with no menu open the header collapses as before');
    });

    testWidgets('a right-click on the header moves it there instead of only closing it', (tester) async {
      await pumpWithMenu(tester);
      final before = tester.getTopLeft(find.text('Go to Playlist'));

      await tester.tapAt(tester.getCenter(find.text('My Playlist')) + const Offset(-30, 4), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Go to Playlist'), findsOneWidget, reason: 'open again, in one click');
      final after = tester.getTopLeft(find.text('Go to Playlist'));
      expect(after.dx, closeTo(before.dx - 30, 1));
      expect(after.dy, closeTo(before.dy + 4, 1));
    });

    testWidgets('closes when the page scrolls its header away', (tester) async {
      await pumpWithMenu(tester);

      final page = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      page.jumpTo(40);
      await tester.pumpAndSettle();

      expect(find.text('Go to Playlist'), findsNothing);
    });

    testWidgets('closes when the queue itself scrolls', (tester) async {
      await pumpWithMenu(tester);

      final list = tester
          .state<ScrollableState>(
            find.descendant(of: find.byType(ReorderableListView), matching: find.byType(Scrollable)).first,
          )
          .position;
      list.jumpTo(40);
      await tester.pumpAndSettle();

      expect(find.text('Go to Playlist'), findsNothing);
    });
  });

  testWidgets('Mix source shows mix text, and its menu is the link alone', (tester) async {
    container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(queueProvider.notifier).debugSetStateForTest(QueueState(
      items: [video('1'), video('2')],
      currentIndex: 0,
      mix: const MixQueue(playlistId: 'RD123', title: 'My Mix', isPlaylist: false),
    ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: EmbeddedQueuePanel(maxHeight: 360)),
      ),
    ));
    await tester.pumpAndSettle();

    final anchor = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
    // A mix has a link and no page: one entry, where a playlist has two.
    expect(anchor.menuChildren, hasLength(1));
  });

  // The header builds its collapsed and its expanded subtitle at once and
  // crossfades them, so both are in the tree and both can be read here.
  group('a playlist\'s header', () {
    Future<void> pumpPlaylist(
      WidgetTester tester, {
      required int at,
      required MixQueue mix,
      bool failPages = false,
    }) async {
      container = ProviderContainer(
        overrides: [mixServiceProvider.overrideWithValue(_SilentMixService(failPages: failPages))],
      );
      addTearDown(container.dispose);
      container.read(queueProvider.notifier).debugSetStateForTest(QueueState(
        items: [video('1'), video('2'), video('3')],
        currentIndex: at,
        mix: mix,
      ));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: EmbeddedQueuePanel(maxHeight: 360))),
      ));
      await tester.pumpAndSettle();
    }

    const whole = MixQueue(playlistId: 'PL123', title: 'My Playlist', isPlaylist: true, exhausted: true, totalCount: 5);

    testWidgets('knowing where it ends is not the end', (tester) async {
      await pumpPlaylist(tester, at: 0, mix: whole);

      expect(find.text(' · Next: Video 2'), findsOneWidget);
      expect(find.text(' · End of playlist'), findsNothing);
      expect(find.text('1 / 3'), findsOneWidget, reason: 'all of it is loaded, so the real length');
    });

    Finder crossFadeOver(String text) =>
        find.ancestor(of: find.text(text), matching: find.byType(AnimatedCrossFade));

    testWidgets('the position stays put: only what follows it changes with the panel', (tester) async {
      await pumpPlaylist(tester, at: 0, mix: whole);

      // Once, and outside any crossfade: collapsing cannot fade it against itself.
      expect(find.text('1 / 3'), findsOneWidget);
      expect(crossFadeOver('1 / 3'), findsNothing);
      // What is next belongs to the collapsed state, so it is the half that fades.
      expect(crossFadeOver(' · Next: Video 2'), findsOneWidget);
    });

    testWidgets('the last video says so, and the end is said when it finishes', (tester) async {
      await pumpPlaylist(tester, at: 2, mix: whole);

      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.text(' · Last video'), findsOneWidget);
      expect(find.text(' · End of playlist'), findsNothing);

      container.read(queueProvider.notifier).playedOut();
      await tester.pumpAndSettle();

      // Said in both states, so it is one widget with nothing to animate.
      expect(find.text('3 / 3'), findsOneWidget, reason: 'the position is still there at the end');
      expect(find.text(' · End of playlist'), findsOneWidget);
      expect(crossFadeOver(' · End of playlist'), findsNothing);
      expect(find.text(' · Last video'), findsNothing);
    });

    testWidgets('rows are numbered, and the playing one shows its arrow instead', (tester) async {
      await pumpPlaylist(tester, at: 1, mix: whole);

      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsNothing, reason: 'the playing row has the arrow in its place');
      expect(find.text('3'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('a hand-built queue has no numbers', (tester) async {
      await pumpPanel(tester, ['aaa', 'bbb', 'ccc']);

      expect(find.text('2'), findsNothing);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('a page that failed to load is said after the position, open or closed', (tester) async {
      await pumpPlaylist(
        tester,
        at: 0,
        failPages: true,
        mix: const MixQueue(playlistId: 'PL123', title: 'My Playlist', isPlaylist: true, continuation: 'more', totalCount: 135),
      );

      expect(find.text('1 / 135'), findsOneWidget);
      // One widget, outside any crossfade: the same line in both states.
      expect(find.text(' · Paused. Couldn\'t load more'), findsOneWidget);
      expect(crossFadeOver(' · Paused. Couldn\'t load more'), findsNothing);
      expect(find.text(' · Next: Video 2'), findsNothing);
    });

    testWidgets('while pages are still to come, the position is against the whole playlist', (tester) async {
      await pumpPlaylist(
        tester,
        at: 0,
        mix: const MixQueue(playlistId: 'PL123', title: 'My Playlist', isPlaylist: true, continuation: 'more', totalCount: 135),
      );

      expect(find.text('1 / 135'), findsOneWidget);
      expect(find.text('1 / 3'), findsNothing);
    });
  });

  group("the header menu's link", () {
    QueueState queueOf(MixQueue? mix) => QueueState(
          items: [for (var i = 1; i <= 3; i++) video('$i')],
          currentIndex: 1,
          mix: mix,
        );

    test('a mix is the video it is on, in that mix; a playlist is its own page; a plain queue has none', () {
      expect(
        queueLinkFor(queueOf(const MixQueue(playlistId: 'RDabc', title: 'My Mix'))),
        'https://www.youtube.com/watch?v=2&list=RDabc',
      );
      expect(
        queueLinkFor(queueOf(const MixQueue(playlistId: 'PL123', title: 'List', isPlaylist: true))),
        'https://www.youtube.com/playlist?list=PL123',
      );
      expect(queueLinkFor(queueOf(null)), isNull);
    });

    Future<void> pumpPanel(WidgetTester tester, MixQueue? mix) async {
      container = ProviderContainer(
        overrides: [mixServiceProvider.overrideWithValue(_SilentMixService())],
      );
      addTearDown(container.dispose);
      container.read(queueProvider.notifier).debugSetStateForTest(queueOf(mix));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: EmbeddedQueuePanel(maxHeight: 360))),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a mix offers Copy link and nowhere to go, and copies the link', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpPanel(tester, const MixQueue(playlistId: 'RDabc', title: 'My Mix'));
      await tester.tap(find.text('My Mix'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Go to Playlist'), findsNothing, reason: 'a mix has no page');
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(copied, 'https://www.youtube.com/watch?v=2&list=RDabc');
      expect(find.text('Link copied to clipboard'), findsOneWidget);
    });

    // Asked of the mix on purpose: its one short entry is the menu that came out
    // narrow. A playlist's "Go to Playlist" is wide enough to pass on its own.
    testWidgets('the menu is 200 wide even when all it holds is Copy link', (tester) async {
      await pumpPanel(tester, const MixQueue(playlistId: 'RDabc', title: 'My Mix'));
      await tester.tap(find.text('My Mix'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      final row = tester.getSize(find.byType(MenuItemButton));
      expect(tester.getSize(find.text('Copy link')).width, lessThan(150), reason: 'narrower than the minimum by itself');
      expect(row.width, 200);
    });

    testWidgets('a queue put together by hand opens no menu at all', (tester) async {
      await pumpPanel(tester, null);
      final header = find.descendant(of: find.byType(EmbeddedQueuePanel), matching: find.byType(InkWell)).first;
      await tester.tap(header, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
    });
  });

  group('a playlist\'s number column', () {
    test('widens over the ten rows before a longer number', () {
      expect(numberColumnDigits(50, 4), 2);
      expect(numberColumnDigits(90, 4), 2, reason: 'the ramp starts here');
      expect(numberColumnDigits(95, 4), 2.5);
      expect(numberColumnDigits(100, 4), 3, reason: 'full width as 100 comes into view');
      expect(numberColumnDigits(101, 4), 3);
      expect(numberColumnDigits(990, 4), 3);
      expect(numberColumnDigits(995, 4), 3.5);
      expect(numberColumnDigits(1000, 4), 4);
    });

    test('is never wider than the playlist\'s last number needs', () {
      expect(numberColumnDigits(98, 2), 2);
      expect(numberColumnDigits(5000, 3), 3);
    });

    testWidgets('follows the scroll, and comes back the way it went', (tester) async {
      container = ProviderContainer(
        overrides: [mixServiceProvider.overrideWithValue(_SilentMixService())],
      );
      addTearDown(container.dispose);
      container.read(queueProvider.notifier).debugSetStateForTest(QueueState(
        items: [for (var i = 1; i <= 150; i++) video('$i')],
        currentIndex: 0,
        mix: const MixQueue(playlistId: 'PL123', title: 'Long', isPlaylist: true, exhausted: true, totalCount: 150),
      ));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: EmbeddedQueuePanel(maxHeight: 360))),
      ));
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(
            find.descendant(of: find.byType(ReorderableListView), matching: find.byType(Scrollable)).first,
          )
          .position;
      final rowExtent = position.extentTotal / 150;

      /// The width of the column the row numbered [number] sits in.
      double columnOf(int number) =>
          tester.getSize(find.ancestor(of: find.text('$number'), matching: find.byType(SizedBox)).first).width;

      /// Scroll until [row]'s top edge is at the bottom of the list.
      Future<void> bringToBottomEdge(double row) async {
        position.jumpTo((row - 1) * rowExtent - position.viewportDimension);
        await tester.pumpAndSettle();
      }

      final atTop = columnOf(2);
      expect(atTop, lessThan(14), reason: 'single digits do not get the room 150 needs');

      await bringToBottomEdge(60);
      expect(columnOf(58), closeTo(14, 0.01), reason: 'two digits, well short of 90');

      await bringToBottomEdge(95);
      expect(columnOf(93), closeTo(17.5, 0.01), reason: 'half way through the ramp');

      await bringToBottomEdge(100);
      expect(columnOf(98), closeTo(21, 0.01), reason: 'ready before 100 shows');

      await bringToBottomEdge(95);
      expect(columnOf(93), closeTo(17.5, 0.01), reason: 'the same on the way back up');

      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(columnOf(2), atTop);
    });
  });
}
