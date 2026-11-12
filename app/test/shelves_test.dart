/// Home shelves (`todo.md` 111): the titled rows between the grid's tiles, and the
/// per-category switches that decide which of them are shown.
///
/// Over a stubbed [FeedState] for layout, and the fake sidecar's `shelves` mode for the
/// controller — the claims about layout have no use for a process, the claim about
/// paging (a continuation's page-relative `index`) has no use for a widget.
library;

import 'package:flutter/material.dart' hide Chip;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/shelf.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/feed_controller.dart';
import 'package:rill/ui/members_only_preference.dart';
import 'package:rill/ui/shelf_visibility.dart';
import 'package:rill/ui/widgets/feed_view.dart';
import 'package:rill/ui/widgets/home_feed_settings.dart';
import 'package:rill/ui/widgets/shelf_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

VideoItem _video(String id, {bool members = false, bool short = false}) => VideoItem(
      kind: 'video',
      id: id,
      title: id,
      channelName: 'Fake Channel',
      thumbnailUrl: '',
      isLive: false,
      isMembersOnly: members,
      isShort: short,
      canWatchLater: false,
      canAddToQueue: false,
    );

PostItem _post(String id, {String text = 'post text'}) =>
    PostItem(id: id, authorName: 'Poster $id', text: text, publishedText: '2 days ago');

Shelf _shelf(ShelfCategory category, String title, int index, List<ShelfItem> items) =>
    Shelf(category: category, title: title, index: index, items: items);

class _Stub extends FeedController {
  _Stub(this.initial);
  final FeedState initial;
  @override
  FeedState build() => initial;
}

class _MembersHidden extends MembersOnlyVisible {
  @override
  bool build() => false;
}

class _Switches extends ShelfVisibility {
  _Switches(Map<ShelfCategory, bool> initial) : super(initial: initial);
}

final _all = {for (final c in ShelfCategory.values) c: true};

List<FeedItem> _grid([int count = 12]) => [for (var i = 0; i < count; i++) _video('grid-$i')];

List<Shelf> _fourShelves() => [
      _shelf(ShelfCategory.members, 'Members row', 1, [ShelfTile(_video('member-a', members: true))]),
      _shelf(ShelfCategory.shorts, 'Shorts row', 1, [ShelfTile(_video('short-a', short: true))]),
      _shelf(ShelfCategory.posts, 'Posts row', 1, [ShelfPost(_post('post-a'))]),
      _shelf(ShelfCategory.other, 'Other row', 1, [ShelfTile(_video('other-a'))]),
    ];

Future<void> _pump(
  WidgetTester tester, {
  required List<FeedItem> items,
  required List<Shelf> shelves,
  Map<ShelfCategory, bool>? switches,
  bool membersVisible = true,
  bool groupMembersOnly = false,
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      // A new scope per call: a scope keeps the overrides it was built with.
      key: UniqueKey(),
      overrides: [
        feedProvider.overrideWith(
          () => _Stub(FeedState(surface: FeedController.surface, isLoading: false, items: items, shelves: shelves)),
        ),
        if (switches != null) shelfVisibilityProvider.overrideWith(() => _Switches(switches)),
        if (!membersVisible) membersOnlyVisibleProvider.overrideWith(_MembersHidden.new),
      ],
      child: MaterialApp(
        theme: buildRillTheme(kDefaultAccent),
        home: Scaffold(body: FeedView(provider: feedProvider, groupMembersOnly: groupMembersOnly)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('which shelves are shown', () {
    testWidgets('the defaults match what the app did before: members and other shown, Shorts and posts not', (tester) async {
      await _pump(tester, items: _grid(), shelves: _fourShelves());
      expect(find.text('Members row'), findsOneWidget);
      expect(find.text('Other row'), findsOneWidget);
      expect(find.text('Shorts row'), findsNothing);
      expect(find.text('Posts row'), findsNothing);
      // Hidden means hidden: nothing of the shelf is built, not merely drawn over.
      expect(find.text('short-a'), findsNothing);
      expect(find.text('post-a text'), findsNothing);
    });

    testWidgets('every category has its own switch', (tester) async {
      const titles = {
        ShelfCategory.members: 'Members row',
        ShelfCategory.shorts: 'Shorts row',
        ShelfCategory.posts: 'Posts row',
        ShelfCategory.other: 'Other row',
      };
      for (final category in ShelfCategory.values) {
        final only = {for (final c in ShelfCategory.values) c: c == category};
        await _pump(tester, items: _grid(), shelves: _fourShelves(), switches: only);
        for (final entry in titles.entries) {
          expect(find.text(entry.value), entry.key == category ? findsOneWidget : findsNothing,
              reason: 'with only ${category.name} on, "${entry.value}" is wrong');
        }
      }
    });

    testWidgets('a shelf is never also left in the grid', (tester) async {
      await _pump(tester, items: _grid(), shelves: _fourShelves(), switches: _all);
      // Each shelf tile is on the page once, and the grid keeps its own twelve.
      for (final id in ['member-a', 'short-a', 'other-a']) {
        expect(find.text(id), findsOneWidget);
      }
      expect(find.text('grid-0'), findsOneWidget);
    });

    testWidgets('the members shelf also obeys the members-only preference', (tester) async {
      await _pump(tester, items: _grid(), shelves: _fourShelves(), switches: _all, membersVisible: false);
      expect(find.text('Members row'), findsNothing);
      expect(find.text('member-a'), findsNothing);
      expect(find.text('Other row'), findsOneWidget);
    });

    testWidgets('a shelf with no title is called what its category is', (tester) async {
      await _pump(tester, items: _grid(), shelves: [
        Shelf(category: ShelfCategory.other, title: null, index: 0, items: [ShelfTile(_video('other-a'))]),
      ]);
      expect(find.text(shelfFallbackTitle(ShelfCategory.other)), findsOneWidget);
    });

    testWidgets('a page of nothing but shelves is a page, not "Nothing here yet"', (tester) async {
      await _pump(tester, items: const [], shelves: _fourShelves());
      expect(find.text('Nothing here yet.'), findsNothing);
      expect(find.text('Members row'), findsOneWidget);
    });
  });

  group('where a shelf goes', () {
    testWidgets('after the row it follows, before the rows that come later', (tester) async {
      await _pump(tester, items: _grid(), shelves: [
        _shelf(ShelfCategory.other, 'Other row', 1, [ShelfTile(_video('other-a'))]),
      ]);
      final first = tester.getTopLeft(find.text('grid-0')).dy;
      final shelf = tester.getTopLeft(find.text('Other row')).dy;
      final last = tester.getTopLeft(find.text('grid-11')).dy;
      expect(shelf, greaterThan(first));
      expect(shelf, lessThan(last));
    });

    testWidgets('index 0 is above the grid, and an index past the end is below it', (tester) async {
      await _pump(tester, items: _grid(), shelves: [
        _shelf(ShelfCategory.other, 'Top row', 0, [ShelfTile(_video('top-a'))]),
        _shelf(ShelfCategory.other, 'Bottom row', 12, [ShelfTile(_video('bottom-a'))]),
      ]);
      expect(tester.getTopLeft(find.text('Top row')).dy, lessThan(tester.getTopLeft(find.text('grid-0')).dy));
      expect(tester.getTopLeft(find.text('Bottom row')).dy, greaterThan(tester.getTopLeft(find.text('grid-11')).dy));
    });

    test('hiding tiles before a shelf does not carry it down the page', () {
      final all = [_video('a'), _video('b', members: true), _video('c'), _video('d')];
      final placed = placeShelves(
        [_shelf(ShelfCategory.other, 'row', 3, [ShelfTile(_video('x'))])],
        all,
        isShown: (_) => true,
        inGrid: (item) => !isMembersOnlyItem(item),
      );
      // Three tiles come before it in the response; one of them is not displayed.
      expect(placed.single.position, 2);
    });

    test('a shelf the switches hide, or with nothing in it, is not placed', () {
      final all = [_video('a')];
      final shelves = [
        _shelf(ShelfCategory.shorts, 'hidden', 0, [ShelfTile(_video('x'))]),
        _shelf(ShelfCategory.other, 'empty', 0, const []),
        _shelf(ShelfCategory.other, 'shown', 0, [ShelfTile(_video('y'))]),
      ];
      final placed = placeShelves(shelves, all, isShown: (s) => s.category != ShelfCategory.shorts, inGrid: (_) => true);
      expect(placed.map((p) => p.shelf.title), ['shown']);
    });
  });

  group('the keyboard', () {
    /// Which of [ids] has keyboard focus, by the title text inside the focused tile.
    String? holding(WidgetTester tester, Iterable<String> ids) {
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus == null) return null;
      for (final id in ids) {
        for (final element in tester.elementList(find.text(id))) {
          var inside = false;
          element.visitAncestorElements((ancestor) {
            if (identical(ancestor, focus)) inside = true;
            return !inside;
          });
          if (inside) return id;
        }
      }
      return null;
    }

    testWidgets('Tab walks a row tile by tile, left to right, and then moves on; Shift+Tab walks it back', (tester) async {
      const row = ['row-a', 'row-b', 'row-c'];
      final ids = [for (var i = 0; i < 12; i++) 'grid-$i', ...row];
      await _pump(
        tester,
        items: _grid(),
        shelves: [_shelf(ShelfCategory.other, 'Other row', 4, [for (final id in row) ShelfTile(_video(id))])],
      );

      var reached = <String>[];
      for (var press = 0; press < 60 && !reached.contains('row-c'); press++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final now = holding(tester, ids);
        if (now != null && (reached.isEmpty || reached.last != now)) reached.add(now);
      }
      final inRow = reached.where(row.contains).toList();
      expect(inRow, row, reason: 'the row was not walked in order: $reached');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(row.contains(holding(tester, ids)), isFalse, reason: 'Tab stayed in the row after its last tile');

      reached = [];
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      for (var press = 0; press < 8; press++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final now = holding(tester, ids);
        if (now != null && (reached.isEmpty || reached.last != now)) reached.add(now);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      expect(reached.where(row.contains).toList(), row.reversed.toList());
    });
  });

  group('a post', () {
    testWidgets('shows its author, age and text, and is a labelled stop', (tester) async {
      await _pump(
        tester,
        items: _grid(),
        shelves: [
          _shelf(ShelfCategory.posts, 'Posts row', 1, [ShelfPost(_post('post-a', text: 'hello there'))]),
        ],
        switches: _all,
      );
      expect(find.text('Poster post-a'), findsOneWidget);
      expect(find.text('hello there'), findsOneWidget);
      expect(find.text('2 days ago'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Post by Poster post-a, 2 days ago, hello there')), findsOneWidget);
    });
  });

  group('the shelves in the feed state', () {
    late ProviderContainer container;

    Future<void> settle() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (!container.read(feedProvider).isLoading) return;
      }
      fail('feed never settled');
    }

    setUp(() async {
      await RpcClient.instance.killForTestAndWait();
      RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1', 'shelves'];
      await RpcClient.instance.start();
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
      RpcClient.instance.killForTest();
    });

    test('a first page brings its shelves, a continuation moves its own past the tiles already loaded', () async {
      container.read(feedProvider);
      await settle();
      var state = container.read(feedProvider);
      expect(state.shelves.map((s) => (s.category, s.index)), [(ShelfCategory.members, 1), (ShelfCategory.posts, 2)]);
      expect(state.shelves.last.items.single, isA<ShelfPost>());

      await container.read(feedProvider.notifier).loadMore();
      await settle();
      state = container.read(feedProvider);
      expect(state.items, hasLength(6));
      // Page two's shelf follows 1 of page two's tiles: 3 already loaded + 1.
      expect(state.shelves.map((s) => (s.category, s.index)), [
        (ShelfCategory.members, 1),
        (ShelfCategory.posts, 2),
        (ShelfCategory.shorts, 4),
      ]);
    });

    test('a fresh load clears them, so a shelf is never indexed into a grid it was not part of', () async {
      container.read(feedProvider);
      await settle();
      await container.read(feedProvider.notifier).loadMore();
      await settle();
      expect(container.read(feedProvider).shelves, hasLength(3));

      container.read(feedProvider.notifier).selectChip(const Chip(label: 'Music', token: 'MUSIC', selected: false, scope: 'feed'));
      // Before the answer: until it lands the old shelves would be positions in a grid
      // that is already gone (the answer replaces them, so only now can this be seen).
      expect(container.read(feedProvider).shelves, isEmpty, reason: 'a shelf outlived the grid it was indexed into');
      await settle();
      final state = container.read(feedProvider);
      expect(state.items, hasLength(3));
      expect(state.shelves, hasLength(2), reason: 'the previous filter shelf survived the reset');
    });
  });

  group('the settings page', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('one switch per category, set to the defaults', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: Scaffold(body: HomeFeedSettingsPanel()))),
      );
      for (final category in ShelfCategory.values) {
        final tile = tester.widget<Switch>(find.byKey(ValueKey('shelf-switch-${category.name}')));
        expect(tile.value, shelfVisibilityDefaults[category], reason: category.name);
      }
      expect(shelfVisibilityDefaults, {
        ShelfCategory.members: true,
        ShelfCategory.shorts: false,
        ShelfCategory.posts: false,
        ShelfCategory.other: true,
      });
    });

    testWidgets('a switch changes the state, and is remembered', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: HomeFeedSettingsPanel())),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('shelf-switch-shorts')));
      await tester.pump();
      expect(container.read(shelfVisibilityProvider)[ShelfCategory.shorts], isTrue);
      expect(container.read(shelfVisibilityProvider)[ShelfCategory.posts], isFalse, reason: 'one switch moved another');

      final stored = await readShelfVisibility();
      expect(stored[ShelfCategory.shorts], isTrue);
      expect(stored[ShelfCategory.members], isTrue);
    });

    testWidgets('each switch is one labelled node, its state read once', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: Scaffold(body: HomeFeedSettingsPanel()))),
      );
      expect(find.bySemanticsLabel(RegExp('^Shorts')), findsOneWidget);
      handle.dispose();
    });
  });
}
