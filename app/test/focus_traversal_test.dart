/// Tab order and focus handling — Task 32 §3 (`docs/todo.md` 38).
///
/// Everything here asserts what `FocusManager.instance.primaryFocus` *is* after a
/// Tab, never that a widget exists: the bug class is a tree that is fine to look
/// at and walked in the wrong order, or one that lets focus escape an overlay.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart' as domain;
import 'package:rill/domain/feed_item.dart' show VideoItem;
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/feed_controller.dart';
import 'package:rill/ui/open_video.dart' show TileMenuItem;
import 'package:rill/ui/pages/feed.dart';
import 'package:rill/ui/page_wrapper.dart';
import 'package:rill/ui/pages/login_page.dart';
import 'package:rill/ui/search_suggest_controller.dart';
import 'package:rill/ui/widgets/media_tile.dart';
import 'package:rill/ui/widgets/account_button.dart';
import 'package:rill/ui/widgets/save_dialog.dart';
import 'package:rill/ui/widgets/share_dialog.dart';
import 'package:rill/ui/widgets/subscribe_button.dart';

/// A name for whatever has primary focus: its tooltip, its string key, or
/// `field` for a text field. Names, not widgets, so a failure reads as an order.
String focused() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return 'none';
  var name = 'unnamed';
  var found = false;
  void check(Widget widget) {
    if (found) return;
    if (widget is EditableText) {
      name = 'field';
      found = true;
    } else if (widget is Tooltip && widget.message != null) {
      name = widget.message!;
      found = true;
    } else if (widget is Semantics && (widget.properties.tooltip ?? '').isNotEmpty) {
      // The player controls' own tooltip, which has no Material `Tooltip` around it (F51).
      name = widget.properties.tooltip!;
      found = true;
    } else if (widget.key is ValueKey<String>) {
      name = (widget.key! as ValueKey<String>).value;
      found = true;
    }
  }

  check(context.widget);
  String? tile;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    check(widget);
    if (widget is MediaTile) tile ??= widget.spec.title;
    // Keep walking past the name: the tile it belongs to is further up.
    return tile == null;
  });
  if (!found) {
    // A chip or a tile: its own first text.
    String? text;
    void visit(Element element) {
      final widget = element.widget;
      if (text == null && widget is Text && widget.data != null) text = widget.data;
      if (text == null && widget is Icon && widget.semanticLabel != null) text = widget.semanticLabel;
      if (text == null) element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    name = tile != null ? '' : (text ?? 'unnamed');
  }
  if (tile == null) return name;
  return name.isEmpty ? tile! : '$tile/$name';
}

/// Tab [count] times, returning what had focus after each.
Future<List<String>> tabThrough(WidgetTester tester, int count, {bool shift = false}) async {
  final seen = <String>[];
  for (var i = 0; i < count; i++) {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    seen.add(focused());
  }
  return seen;
}

Widget shell({required Widget body}) => ProviderScope(
      child: MaterialApp(
        theme: buildRillTheme(kDefaultAccent),
        home: PageWrapper(title: const Text('Rill'), body: body),
      ),
    );

/// An [AuthController] parked in one state.
class _FixedAuth extends AuthController {
  _FixedAuth(this.initial);

  final AuthState initial;

  @override
  AuthState build() => initial;
}

const TileSpec _tileSpec = TileSpec(
  title: 'A video',
  thumbnailUrl: '',
  isStackedCards: false,
  durationText: '4:20',
  durationTone: DurationBadgeTone.normal,
  badges: [],
  canWatchLater: false,
  canAddToQueue: false,
  primaryLine: 'Channel',
);

/// A feed that never talks to the transport (`feed_footer_widget_test.dart`).
class _StubFeed extends FeedController {
  _StubFeed(this.initial);

  final FeedState initial;

  @override
  FeedState build() => initial;
}

final FeedState _feedState = FeedState(
  surface: FeedController.surface,
  items: [
    for (var i = 0; i < 4; i++)
      VideoItem(
        kind: 'video',
        id: 'vid_$i',
        title: 'Video $i',
        channelName: 'Channel $i',
        channelId: 'chan_$i',
        thumbnailUrl: '',
        durationSeconds: 60,
        isLive: false,
        canWatchLater: true,
        canAddToQueue: true,
      ),
  ],
  chipBars: {
    FeedController.surface: [
      const domain.Chip(label: 'All', token: '', selected: true, scope: 'feed'),
      const domain.Chip(label: 'Music', token: 'T1', selected: false, scope: 'feed'),
    ],
  },
);

/// A suggestions controller with the dropdown already open and nothing on the
/// wire: typing must not reach the sidecar.
class _OpenSuggestions extends SearchSuggestController {
  @override
  SearchSuggestState build() =>
      const SearchSuggestState(query: 'a', isOpen: true, suggestions: ['a one', 'a two', 'a three']);

  @override
  void onTextChanged(String text) {}
}

/// Whether the node with primary focus sits inside a scope or route labelled
/// [label] — "inside the overlay" without naming a widget.
bool focusIsUnder(String label) {
  final node = FocusManager.instance.primaryFocus;
  if (node == null) return false;
  // The scope itself counts: a menu whose rows are not focusable leaves the
  // scope as the primary focus, which is still "inside".
  return node.debugLabel == label || node.ancestors.any((ancestor) => ancestor.debugLabel == label);
}

void main() {
  void bigWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('the shell', () {
    testWidgets('Tab walks title bar, rail, search, top-bar actions, then the page', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(shell(
        body: Column(
          children: [
            TextButton(key: const ValueKey('page-first'), onPressed: () {}, child: const Text('first')),
            TextButton(key: const ValueKey('page-second'), onPressed: () {}, child: const Text('second')),
          ],
        ),
      ));
      await tester.pump();

      expect(
        await tabThrough(tester, 11),
        [
          'Toggle menu', // title bar (the back arrow is excluded on Home)
          'home', 'subscriptions', 'playlists', 'history', // rail
          'field', 'Search', // search: the field, then its button
          'Log in', // top-bar actions: notifications is disabled, so the account button
          'page-first', 'page-second', // page content
          'Toggle menu', // and round again
        ],
      );
    });
  });

  group('the feed', () {
    testWidgets('Tab goes shell, then the chips, then tile by tile', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [feedProvider.overrideWith(() => _StubFeed(_feedState))],
          child: MaterialApp(theme: buildRillTheme(kDefaultAccent), home: const FeedPage()),
        ),
      );
      await tester.pump();

      expect(
        await tabThrough(tester, 19),
        [
          'Toggle menu', 'home', 'subscriptions', 'playlists', 'history', 'field', 'Search', 'Log in',
          'All', 'Music', // the filter chips
          // Each tile is a group: the tile, then its 3-dot menu — not every
          // button in a row of the grid, which is what one flat reading order did.
          // The hover-only Watch Later / Add to queue buttons are not stops: the
          // menu has the same actions, and a stop on a button that is only drawn
          // under the pointer is a ghost.
          'Video 0', 'Video 0/tile-more',
          'Video 1', 'Video 1/tile-more',
          'Video 2', 'Video 2/tile-more',
          'Video 3', 'Video 3/tile-more',
          'Toggle menu', // and round again
        ],
      );
    });

    testWidgets('every tap target on the feed has a label', (tester) async {
      final semantics = tester.ensureSemantics();
      bigWindow(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [feedProvider.overrideWith(() => _StubFeed(_feedState))],
          child: MaterialApp(theme: buildRillTheme(kDefaultAccent), home: const FeedPage()),
        ),
      );
      await tester.pump();
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
    });

    testWidgets('Shift+Tab walks it backwards', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [feedProvider.overrideWith(() => _StubFeed(_feedState))],
          child: MaterialApp(theme: buildRillTheme(kDefaultAccent), home: const FeedPage()),
        ),
      );
      await tester.pump();

      expect(
        await tabThrough(tester, 4, shift: true),
        ['Video 3/tile-more', 'Video 3', 'Video 2/tile-more', 'Video 2'],
      );
    });

    testWidgets('Enter on a focused tile opens it', (tester) async {
      bigWindow(tester);
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MediaTile(
                spec: _tileSpec,
                onTap: () => opened++,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(await tabThrough(tester, 1), ['A video']);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, 1, reason: 'a tile reachable by Tab has to be openable from the keyboard too');
    });
  });

  group('overlays trap focus, close on Escape, and give focus back', () {
    // The brief's four claims, per overlay: focus moves in when it opens, Tab
    // stays inside, Escape closes it, and focus returns to what opened it.

    // Outside `testWidgets`: a real subprocess talks over real pipes, which the
    // fake clock a test body runs under never advances.
    setUpAll(() async {
      await RpcClient.instance.killForTestAndWait();
      RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
      await RpcClient.instance.start();
    });

    tearDownAll(() => RpcClient.instance.killForTestAndWait());

    setUp(() => RpcClient.instance.call('test.reset', {}));

    testWidgets('the account menu', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(
              () => _FixedAuth(
                const AuthState(status: AuthStatus.authenticated, accountName: 'Ada Lovelace', accountHandle: '@ada'),
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  TextButton(key: const ValueKey('before'), onPressed: () {}, child: const Text('before')),
                  const AccountButton(),
                  TextButton(key: const ValueKey('after'), onPressed: () {}, child: const Text('after')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(await tabThrough(tester, 2), ['before', 'Ada Lovelace']);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Sign out'), findsOneWidget, reason: 'Enter on the button opens the menu');

      // In: autofocus puts the primary focus inside the menu's scope.
      expect(focusIsUnder('account menu'), isTrue, reason: 'opening moves focus into the menu');

      // Stays in: more Tabs than there are rows, and none of them reaches the page.
      final walk = await tabThrough(tester, 12);
      expect(walk, isNot(contains('before')));
      expect(walk, isNot(contains('after')));
      expect(walk, isNot(contains('Ada Lovelace')), reason: 'the button behind the menu is not a stop either');
      expect(focusIsUnder('account menu'), isTrue);

      // Closes and returns.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Sign out'), findsNothing);
      expect(focused(), 'Ada Lovelace', reason: 'focus goes back to the button that opened it');
    });

    testWidgets('search suggestions leave focus on the field and never take it', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [searchSuggestProvider.overrideWith(_OpenSuggestions.new)],
          child: MaterialApp(
            theme: buildRillTheme(kDefaultAccent),
            home: const PageWrapper(title: Text('Rill'), body: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();

      // Tab to the field; focus opens the dropdown.
      var seen = <String>[];
      while (seen.length < 12 && (seen.isEmpty || seen.last != 'field')) {
        seen += await tabThrough(tester, 1);
      }
      expect(seen.last, 'field');
      await tester.pumpAndSettle();
      expect(find.text('a one'), findsOneWidget, reason: 'focus opens the dropdown');
      expect(focused(), 'field', reason: 'and the field keeps it');

      // Arrow keys move a highlight; focus does not leave the field.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focused(), 'field');

      // First Escape closes the dropdown and the field keeps focus ...
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('a one'), findsNothing);
      expect(focused(), 'field', reason: 'focus returns to what opened the dropdown: the field');

      // ... and a second lets go.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focused(), isNot('field'));
    });

    testWidgets('a tile menu', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authProvider.overrideWith(() => _FixedAuth(const AuthState(status: AuthStatus.authenticated)))],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
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
                    menu: [
                      TileMenuItem(icon: Icons.share, label: 'First entry', onPressed: () {}),
                      TileMenuItem(icon: Icons.queue, label: 'Second entry', onPressed: () {}),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      var seen = <String>[];
      while (seen.length < 8 && (seen.isEmpty || seen.last != 'A video/tile-more')) {
        seen += await tabThrough(tester, 1);
      }
      expect(seen.last, 'A video/tile-more', reason: 'the 3-dot button is a Tab stop');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('First entry'), findsOneWidget, reason: 'Enter on the button opens the menu');

      expect(focused(), isNot('A video/tile-more'), reason: 'opening moves focus into the menu');
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tile menu first entry');

      // Stays in.
      final walk = await tabThrough(tester, 6);
      expect(walk, isNot(contains('A video/tile-more')), reason: 'the button behind the menu is not a stop');
      expect(find.text('First entry'), findsOneWidget, reason: 'and Tab does not walk off and close it');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('First entry'), findsNothing);
      expect(focused(), 'A video/tile-more', reason: 'focus goes back to the button that opened it');
    });

    testWidgets('the subscribed button menu', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authProvider.overrideWith(() => _FixedAuth(const AuthState(status: AuthStatus.authenticated)))],
          child: MaterialApp(
            theme: buildRillTheme(kDefaultAccent),
            home: const Scaffold(
              body: Center(child: SubscribeButton(channelId: 'chan_1', initiallySubscribed: true)),
            ),
          ),
        ),
      );
      await tester.pump();

      String? label() => FocusManager.instance.primaryFocus?.debugLabel;

      await tabThrough(tester, 1);
      expect(label(), 'subscribed button');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('All'), findsOneWidget, reason: 'Enter on the button opens the menu');
      expect(label(), 'subscribed menu first entry', reason: 'opening moves focus into the menu');

      await tabThrough(tester, 6);
      expect(label(), isNot('subscribed button'), reason: 'Tab does not walk back out to the page behind it');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('All'), findsNothing);
      expect(label(), 'subscribed button', reason: 'focus goes back to the button that opened it');
    });

    testWidgets('the login page', (tester) async {
      bigWindow(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authProvider.overrideWith(() => _FixedAuth(const AuthState(status: AuthStatus.anonymous)))],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => TextButton(
                    key: const ValueKey('opener'),
                    onPressed: () => Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        fullscreenDialog: true,
                        builder: (_) => LoginPage(webViewBuilder: (_, _) => const SizedBox.expand()),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(await tabThrough(tester, 1), ['opener']);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);

      final walk = await tabThrough(tester, 8);
      expect(walk, isNot(contains('opener')), reason: 'the page underneath is not reachable');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsNothing, reason: 'Escape cancels, like the Cancel button');
      expect(focused(), 'opener', reason: 'focus goes back to the button that opened it');
    });

    for (final dialog in <(String, Future<void> Function(BuildContext))>[
      ('the save dialog', (context) => showSaveDialog(context, 'vid_save_1')),
      (
        'the share dialog',
        (context) => showShareDialog(
              context,
              VideoItem(
                kind: 'video',
                id: 'aaaaaaaaaaa',
                title: 'A video',
                channelName: 'Channel',
                thumbnailUrl: '',
                isLive: false,
                canWatchLater: true,
                canAddToQueue: true,
              ),
            ),
      ),
    ]) {
      testWidgets(dialog.$1, (tester) async {
        bigWindow(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => TextButton(
                    key: const ValueKey('opener'),
                    onPressed: () => dialog.$2(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(await tabThrough(tester, 1), ['opener']);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(Dialog), findsOneWidget, reason: 'Enter on the opener shows the dialog');

        // Stays in: the opener is behind a modal barrier and is never a stop.
        final walk = await tabThrough(tester, 10);
        expect(walk, isNot(contains('opener')));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(Dialog), findsNothing);
        expect(focused(), 'opener', reason: 'focus goes back to the button that opened it');
      });
    }
  });
}
