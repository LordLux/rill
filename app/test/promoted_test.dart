/// Promoted tiles (`architecture.md` F63): `VideoItem.isPromoted` is shipped by the
/// sidecar, and the app hides such tiles unless the "Promoted videos" switch is on.
library;

import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/shelf.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/feed_controller.dart';
import 'package:rill/ui/promoted_preference.dart';
import 'package:rill/ui/shelf_visibility.dart';
import 'package:rill/ui/widgets/feed_view.dart';
import 'package:rill/ui/widgets/home_feed_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

VideoItem _video(String id, {bool promoted = false}) => VideoItem(
      kind: 'video',
      id: id,
      title: id,
      channelName: 'Fake Channel',
      thumbnailUrl: '',
      isLive: false,
      isPromoted: promoted,
      canWatchLater: false,
      canAddToQueue: false,
    );

class _Stub extends FeedController {
  _Stub(this.initial);
  final FeedState initial;
  @override
  FeedState build() => initial;
}

class _Shown extends PromotedVisible {
  _Shown() : super(initial: true);
}

Future<void> _pump(
  WidgetTester tester, {
  required List<FeedItem> items,
  List<Shelf> shelves = const [],
  bool promotedShown = false,
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        feedProvider.overrideWith(
          () => _Stub(FeedState(surface: FeedController.surface, isLoading: false, items: items, shelves: shelves)),
        ),
        shelfVisibilityProvider.overrideWith(
          () => ShelfVisibility(initial: {for (final c in ShelfCategory.values) c: true}),
        ),
        if (promotedShown) promotedVisibleProvider.overrideWith(_Shown.new),
      ],
      child: MaterialApp(
        theme: buildRillTheme(kDefaultAccent),
        home: Scaffold(body: FeedView(provider: feedProvider)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the flag', () {
    test('is read from the wire, and absent means false', () {
      final base = {
        'kind': 'video',
        'id': 'a',
        'title': 't',
        'channelName': 'c',
        'thumbnailUrl': '',
        'isLive': false,
        'canWatchLater': false,
        'canAddToQueue': false,
      };
      expect(isPromotedItem(FeedItem.fromJson({...base, 'isPromoted': true})), isTrue);
      expect(isPromotedItem(FeedItem.fromJson({...base, 'isPromoted': false})), isFalse);
      expect(isPromotedItem(FeedItem.fromJson(base)), isFalse);
    });

    test('only a video can be promoted', () {
      expect(isPromotedItem(const FeedItem.playlist(kind: 'playlist', id: 'p', title: 't', thumbnailUrl: '')), isFalse);
    });
  });

  group('the feed', () {
    testWidgets('hides a promoted tile by default and keeps the others', (tester) async {
      await _pump(tester, items: [_video('keep-a'), _video('ad-tile', promoted: true), _video('keep-b')]);
      expect(find.text('keep-a'), findsOneWidget);
      expect(find.text('keep-b'), findsOneWidget);
      expect(find.text('ad-tile'), findsNothing);
    });

    testWidgets('shows it when the switch is on', (tester) async {
      await _pump(tester, items: [_video('keep-a'), _video('ad-tile', promoted: true)], promotedShown: true);
      expect(find.text('ad-tile'), findsOneWidget);
    });

    testWidgets('hides it inside a row, and a row of nothing else is not drawn', (tester) async {
      await _pump(
        tester,
        items: [_video('grid-a'), _video('grid-b')],
        shelves: [
          Shelf(
            category: ShelfCategory.other,
            title: 'Mixed row',
            index: 1,
            items: [ShelfTile(_video('row-keep')), ShelfTile(_video('row-ad', promoted: true))],
          ),
          Shelf(
            category: ShelfCategory.other,
            title: 'All ads row',
            index: 2,
            items: [ShelfTile(_video('only-ad', promoted: true))],
          ),
        ],
      );
      expect(find.text('Mixed row'), findsOneWidget);
      expect(find.text('row-keep'), findsOneWidget);
      expect(find.text('row-ad'), findsNothing);
      expect(find.text('All ads row'), findsNothing, reason: 'a row with every tile hidden still drew its header');
    });
  });

  group('the switch', () {
    testWidgets('is off by default, flips the state, and is remembered', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: HomeFeedSettingsPanel())),
        ),
      );
      expect(tester.widget<Switch>(find.byKey(promotedSwitchKey)).value, isFalse);
      expect(container.read(promotedVisibleProvider), isFalse);

      await tester.tap(find.byKey(promotedSwitchKey));
      await tester.pump();
      expect(container.read(promotedVisibleProvider), isTrue);
      expect(tester.widget<Switch>(find.byKey(promotedSwitchKey)).value, isTrue);
      expect(await readPromotedVisible(), isTrue, reason: 'the choice was not saved');
    });
  });
}
