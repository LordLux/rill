/// Keyboard follow-ups to Task 32 (`docs/todo.md` 83): the things found by Tabbing
/// through the real app after the first pass.
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/domain/comment.dart';
import 'package:rill/ui/focus_ring.dart';
import 'package:rill/ui/widgets/comments_section.dart' show CommentTile;
import 'package:rill/ui/focus_surface.dart';
import 'package:rill/ui/page_wrapper.dart';
import 'package:rill/ui/pages/search_results.dart' show SearchFiltersDialog;
import 'package:rill/ui/pages/watch.dart' show LinkifiedText;
import 'package:rill/ui/widgets/comment_composer.dart';
import 'package:rill/ui/widgets/media_tile.dart';

import 'focus_traversal_test.dart' show focused, tabThrough;

void main() {
  // The app's own state machine, as in `main`: on after Tab, off after a click or Esc.
  setUp(KeyboardNavigation.install);

  void bigWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('keyboard navigation is only after Tab', () {
    Widget app() => MaterialApp(
      theme: buildRillTheme(kDefaultAccent),
      builder: (context, child) => FocusRing(child: child!),
      home: Scaffold(
        body: Column(
          children: [
            TextButton(key: const ValueKey('a'), onPressed: () {}, child: const Text('a')),
            TextButton(key: const ValueKey('b'), onPressed: () {}, child: const Text('b')),
          ],
        ),
      ),
    );

    testWidgets('off at the start, on at Tab, off at a mouse click, on again at Tab', (tester) async {
      await tester.pumpWidget(app());
      expect(KeyboardNavigation.active, isFalse, reason: 'nothing selected until the user Tabs');

      await tabThrough(tester, 1);
      expect(KeyboardNavigation.active, isTrue);

      // A real mouse click: Flutter alone would leave "keyboard" highlights on.
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('b'))), kind: PointerDeviceKind.mouse);
      await gesture.up();
      await tester.pump();
      expect(KeyboardNavigation.active, isFalse, reason: 'any click ends keyboard navigation: no ring, no scrolling');

      await tabThrough(tester, 1);
      expect(KeyboardNavigation.active, isTrue, reason: 'and Tab starts it again');
    });

    testWidgets('Escape deselects and ends it; Tab brings it back', (tester) async {
      await tester.pumpWidget(app());
      await tabThrough(tester, 1);
      expect(focused(), 'a');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(KeyboardNavigation.active, isFalse);
      final primary = FocusManager.instance.primaryFocus;
      expect(primary == null || primary is FocusScopeNode, isTrue, reason: 'nothing is left selected: focus sits on a scope, not a control');

      await tabThrough(tester, 1);
      expect(KeyboardNavigation.active, isTrue);
    });

    testWidgets('Escape closes an open menu first and only the next one deselects', (tester) async {
      final controller = MenuController();
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => FocusRing(child: child!),
        home: Scaffold(
          body: MenuAnchor(
            controller: controller,
            menuChildren: [MenuItemButton(onPressed: () {}, child: const Text('item'))],
            builder: (context, c, _) => TextButton(onPressed: c.open, child: const Text('open')),
          ),
        ),
      ));
      await tabThrough(tester, 1);
      controller.open();
      await tester.pump(const Duration(milliseconds: 400));
      await tabThrough(tester, 1);
      expect(KeyboardNavigation.active, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.isOpen, isFalse, reason: 'the first Escape closes the menu');
      expect(KeyboardNavigation.active, isTrue, reason: 'and keeps the keyboard navigation');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(KeyboardNavigation.active, isFalse, reason: 'the second one deselects');
    });

    testWidgets('Tab scrolls only a control that is not visible, and only as far as needed', (tester) async {
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => FocusRing(child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < 30; i++) TextButton(onPressed: () {}, child: Text('b$i')),
            ],
          ),
        ),
      ));
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      await tabThrough(tester, 3);
      await tester.pump();
      expect(scrollable.position.pixels, 0, reason: 'already on screen: no scrolling, no recentring');
      await tabThrough(tester, 20);
      await tester.pump();
      expect(scrollable.position.pixels, greaterThan(0), reason: 'off screen: it scrolls');
    });

    testWidgets('a control close to the edge is scrolled to keep 60 px of room', (tester) async {
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => FocusRing(child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < 30; i++) SizedBox(height: 48, child: TextButton(onPressed: () {}, child: Text('b$i'))),
            ],
          ),
        ),
      ));
      final viewport = tester.getRect(find.byType(Scrollable));
      // Tab down until the focused row has been scrolled at least once.
      for (var i = 0; i < 20; i++) {
        await tabThrough(tester, 1);
        await tester.pump();
        await tester.pump();
        final rect = FocusManager.instance.primaryFocus!.rect;
        expect(rect.bottom, lessThanOrEqualTo(viewport.bottom - 59), reason: 'stop $i keeps its room at the bottom');
      }
    });

    testWidgets('a mouse click does not scroll anything into view', (tester) async {
      // A tall page: the button far down is off screen. Clicking it with the mouse
      // must not scroll (the ring's scroll-to-focus is for Tab only).
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => FocusRing(child: child!),
        home: Scaffold(
          body: ListView(
            children: [
              TextButton(key: const ValueKey('top'), onPressed: () {}, child: const Text('top')),
              const SizedBox(height: 2000),
              TextButton(key: const ValueKey('bottom'), onPressed: () {}, child: const Text('bottom')),
            ],
          ),
        ),
      ));
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('top'))), kind: PointerDeviceKind.mouse);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, 0, reason: 'a click leaves the page where it is');
    });
  });

  group('the comment box', () {
    testWidgets('Tab from the field onto Cancel keeps Cancel there, and the next Tab leaves', (tester) async {
      // The buttons used to show only while the *field* had focus, so Tab onto one
      // hid it, focus snapped back to the field, and neither could be reached.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextButton(key: const ValueKey('before'), onPressed: () {}, child: const Text('before')),
              CommentComposer(avatarUrl: null, onPost: (_) async => true),
              TextButton(key: const ValueKey('after'), onPressed: () {}, child: const Text('after')),
            ],
          ),
        ),
      ));

      expect(await tabThrough(tester, 2), ['before', 'field']);
      await tester.pump();
      expect(find.text('Cancel'), findsOneWidget, reason: 'focusing the field opens the buttons');

      await tabThrough(tester, 1);
      await tester.pump();
      expect(find.text('Cancel'), findsOneWidget, reason: 'and Tab onto Cancel does not close them again');
      expect(focused(), 'Cancel');

      // (Comment is disabled while the box is empty, so the next stop is past it.)
      expect(await tabThrough(tester, 1), ['after']);
    });
  });

  group('the search filters dialog', () {
    testWidgets('its options are Tab stops and Enter picks one', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: buildRillTheme(kDefaultAccent),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const ValueKey('opener'),
                onPressed: () => showDialog<void>(context: context, builder: (_) => const SearchFiltersDialog()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      expect(await tabThrough(tester, 1), ['opener']);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Search filters'), findsOneWidget);

      // Close button first, then the options, in reading order — not just the X.
      final walk = await tabThrough(tester, 6);
      expect(walk.where((stop) => stop == 'Videos' || stop == 'Channels' || stop == 'Playlists' || stop == 'Movies').length,
          greaterThanOrEqualTo(1),
          reason: 'the type options are reachable by Tab: $walk');
      expect(walk, isNot(contains('opener')));

      // Walk to "Videos" and press it: the dialog applies the filter and closes.
      for (var i = 0; i < 30 && focused() != 'Videos'; i++) {
        await tabThrough(tester, 1);
      }
      expect(focused(), 'Videos');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Search filters'), findsNothing, reason: 'Enter pressed the option');
    });
  });

  group('opening a page from the keyboard', () {
    testWidgets('lands on the page content, not back at the title bar', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: buildRillTheme(kDefaultAccent),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey('opener'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => PageWrapper(
                        title: const Text('Page'),
                        body: Column(
                          children: [
                            TextButton(key: const ValueKey('page-first'), onPressed: () {}, child: const Text('first')),
                            TextButton(key: const ValueKey('page-second'), onPressed: () {}, child: const Text('second')),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));

      expect(await tabThrough(tester, 1), ['opener']);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));

      expect(focused(), 'page-first', reason: 'focus starts in the new page\'s content');
      expect(await tabThrough(tester, 1), ['page-second'], reason: 'and Tab carries on from there');
    });

    testWidgets('but not after a click: nothing is focused until the user Tabs', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: buildRillTheme(kDefaultAccent),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => PageWrapper(
                        title: const Text('Page'),
                        body: TextButton(key: const ValueKey('page-first'), onPressed: () {}, child: const Text('first')),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(focused(), isNot('page-first'));
    });
  });

  group('voting on a comment', () {
    testWidgets('the vote button keeps keyboard focus while the vote is in flight', (tester) async {
      // Both buttons used to be disabled while a vote was out, and a disabled
      // control cannot hold focus: a keyboard user who had just voted was thrown
      // to the previous comment.
      Widget tile({required bool rating}) => ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: CommentTile(
              comment: Comment(
                id: 'c1',
                authorName: 'Author',
                authorAvatarUrl: '',
                text: const CommentText(content: 'text'),
                replyCount: 0,
                likeParams: 'LIKE',
                unlikeParams: 'UNLIKE',
                dislikeParams: 'DISLIKE',
                undislikeParams: 'UNDISLIKE',
              ),
              rating: rating,
              onRate: (_) {},
            ),
          ),
        ),
      );

      await tester.pumpWidget(tile(rating: false));
      var seen = <String>[];
      while (seen.length < 6 && (seen.isEmpty || seen.last != 'Like')) {
        seen += await tabThrough(tester, 1);
      }
      expect(seen.last, 'Like');

      await tester.pumpWidget(tile(rating: true));
      await tester.pump();
      expect(focused(), 'Like', reason: 'focus stays on the button through the round trip');
    });
  });

  group('the focus ring takes the shape of the control', () {
    /// Tab to the first stop and read the ring's style off it.
    Future<({ShapeBorder shape, double inflate})> styleOf(WidgetTester tester, Widget control) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildRillTheme(kDefaultAccent),
        home: Scaffold(body: Center(child: control)),
      ));
      await tabThrough(tester, 1);
      return ringStyleFor(FocusManager.instance.primaryFocus!.context!);
    }

    /// Whether [shape] draws a circle in a [size] box (a stadium in a square is one).
    bool isRound(ShapeBorder shape, double size) {
      final bounds = shape.getOuterPath(Rect.fromLTWH(0, 0, size, size)).getBounds();
      // A circle touches the middle of every side and not the corners.
      final path = shape.getOuterPath(Rect.fromLTWH(0, 0, size, size));
      return bounds.width == size && !path.contains(const Offset(1, 1)) && path.contains(Offset(size / 2, 1));
    }

    testWidgets('an icon button is a circle, a text button and a chip are pills', (tester) async {
      final icon = await styleOf(tester, IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)));
      expect(isRound(icon.shape, 40), isTrue, reason: 'the 3-dot button gets a circle, not a rounded square');

      final filled = await styleOf(tester, FilledButton(onPressed: () {}, child: const Text('Subscribe')));
      expect(filled.shape, isA<StadiumBorder>(), reason: 'Subscribe, Copy and Comment are pills');

      final chip = await styleOf(tester, ChoiceChip(label: const Text('Music'), selected: false, onSelected: (_) {}));
      // A chip is the chip's own shape (a rounded rectangle), read off its InkWell.
      expect(chip.shape, isA<RoundedRectangleBorder>());
      expect(((chip.shape as RoundedRectangleBorder).borderRadius as BorderRadius).topLeft.x, greaterThan(0));
    });

    testWidgets('an InkWell with a one-sided radius gets that one-sided radius', (tester) async {
      // The search button: square on the left, round on the right.
      final style = await styleOf(
        tester,
        InkWell(
          onTap: () {},
          borderRadius: const BorderRadius.only(topRight: Radius.circular(20), bottomRight: Radius.circular(20)),
          child: const SizedBox(width: 48, height: 34),
        ),
      );
      final shape = style.shape as RoundedRectangleBorder;
      final radius = shape.borderRadius as BorderRadius;
      expect(radius.topLeft, Radius.zero);
      expect(radius.topRight, const Radius.circular(20));
    });

    testWidgets('a bare InkWell is a rectangle, and KeyboardTap and FocusRingShape say their own', (tester) async {
      final bare = await styleOf(tester, InkWell(onTap: () {}, child: const SizedBox(width: 40, height: 40)));
      expect(bare.shape, isA<RoundedRectangleBorder>());
      expect((bare.shape as RoundedRectangleBorder).borderRadius, BorderRadius.zero);

      final tap = await styleOf(tester, KeyboardTap(onTap: () {}, borderRadius: 14, child: const SizedBox(width: 40, height: 40)));
      expect((tap.shape as RoundedRectangleBorder).borderRadius, BorderRadius.circular(14));

      final inset = await styleOf(
        tester,
        FocusRingShape(inflate: -1, child: InkWell(onTap: () {}, child: const SizedBox(width: 40, height: 40))),
      );
      expect(inset.inflate, -1, reason: 'a full-bleed row pulls the ring in');
      final plain = await styleOf(tester, InkWell(onTap: () {}, child: const SizedBox(width: 40, height: 40)));
      expect(plain.inflate, 1);
    });
  });

  group('a click moves keyboard focus to the closest control, with no ring', () {
    Widget app(Widget body) => MaterialApp(
      theme: buildRillTheme(kDefaultAccent),
      builder: (context, child) => FocusRing(child: child!),
      home: Scaffold(body: body),
    );

    testWidgets('clicking a surface that takes no focus focuses the nearest control', (tester) async {
      bigWindow(tester);
      // A tile-like surface (not focusable) with two buttons below it.
      await tester.pumpWidget(app(Column(
        children: [
          TextButton(key: const ValueKey('top'), onPressed: () {}, child: const Text('top')),
          Expanded(child: GestureDetector(key: const ValueKey('surface'), behavior: HitTestBehavior.opaque, onTap: () {}, child: const SizedBox.expand())),
          TextButton(key: const ValueKey('near'), onPressed: () {}, child: const Text('near')),
          TextButton(key: const ValueKey('far'), onPressed: () {}, child: const Text('far')),
        ],
      )));

      // The keyboard has been used: focus is on the top button, ring showing.
      expect(await tabThrough(tester, 1), ['top']);
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);

      // A click low on the surface, just above the "near" button.
      final surface = tester.getRect(find.byKey(const ValueKey('surface')));
      await tester.tapAt(Offset(surface.center.dx, surface.bottom - 4));
      await tester.pump();
      await tester.pump();

      expect(focused(), 'near', reason: 'focus went to the closest control, not left on "top"');
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch, reason: 'a pointer did it, so no ring');

      // The next Tab carries on from there.
      expect(await tabThrough(tester, 1), ['far']);
    });

    testWidgets('clicking a control itself leaves focus on it', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(app(Column(
        children: [
          TextButton(key: const ValueKey('a'), onPressed: () {}, child: const Text('a')),
          TextButton(key: const ValueKey('b'), onPressed: () {}, child: const Text('b')),
        ],
      )));
      await tabThrough(tester, 1);
      await tester.tap(find.byKey(const ValueKey('b')));
      await tester.pump();
      await tester.pump();
      expect(focused(), 'b');
    });
  });

  group('description links', () {
    const url1 = 'https://example.com/one';
    const url2 = 'https://example.com/two';

    Widget text({int? maxLines, required String body}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: LinkifiedText(
            text: body,
            baseStyle: const TextStyle(fontSize: 13, height: 1.4),
            linkStyle: const TextStyle(fontSize: 13, height: 1.4, color: Colors.blue),
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
          ),
        ),
      ),
    );

    testWidgets('every link in the text is a Tab stop when it is expanded', (tester) async {
      await tester.pumpWidget(text(body: 'intro\n$url1\nmiddle\n\n\n\n$url2\nend'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(KeyboardTap), findsNWidgets(2));

      final first = await tabThrough(tester, 1);
      final firstRect = FocusManager.instance.primaryFocus!.rect;
      await tabThrough(tester, 1);
      final secondRect = FocusManager.instance.primaryFocus!.rect;
      expect(first, isNotEmpty);
      expect(secondRect.top, greaterThan(firstRect.top), reason: 'in reading order, top to bottom');
    });

    testWidgets('collapsed to three lines, only the links still showing are stops', (tester) async {
      await tester.pumpWidget(text(maxLines: 3, body: '$url1\nline two\nline three\nline four\n$url2'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(KeyboardTap), findsNWidgets(1), reason: 'the second link is clipped away, so it is not a stop');
    });
  });

  group('a tile with keyboard focus', () {
    testWidgets('lifts the way hover does, without drawing the hover-only buttons', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 340,
                child: MediaTile(
                  spec: const TileSpec(
                    title: 'A video',
                    thumbnailUrl: '',
                    isStackedCards: false,
                    durationText: '4:20',
                    durationTone: DurationBadgeTone.normal,
                    badges: [],
                    canWatchLater: true,
                    canAddToQueue: true,
                    primaryLine: 'Channel',
                  ),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      double? lift() {
        for (final positioned in tester.widgetList<AnimatedPositioned>(find.byType(AnimatedPositioned))) {
          if (positioned.top != null && positioned.top! < 0 && positioned.left != null && positioned.left! < 0) return positioned.top;
        }
        return null;
      }

      expect(lift(), isNull, reason: 'resting: not lifted');
      await tabThrough(tester, 1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(lift(), isNotNull, reason: 'focused by keyboard: lifted, like hover');

      // The hover buttons stay hidden (and out of the Tab walk).
      final opacity = tester.widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity)).map((o) => o.opacity);
      expect(opacity.every((o) => o == 0), isTrue, reason: 'Watch Later / Add to queue are not drawn');
    });
  });
}
