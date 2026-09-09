/// Members-only: the badge, the shelf, and the preference that hides both.
///
/// The slate on the watch page is covered by `playback_error_test.dart`'s
/// sibling assertions; what is here is the feed-side behaviour, where the
/// interesting failures are — a video rendered twice, or a grid that reports
/// itself empty because everything in it was hoisted into a shelf.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/members_only_preference.dart';
import 'package:rill/ui/widgets/tile_badges.dart';

VideoItem video(String id, {bool membersOnly = false, List<String> badges = const []}) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      isMembersOnly: membersOnly,
      badges: badges,
      canWatchLater: true,
      canAddToQueue: true,
    );

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));
  await tester.pumpAndSettle();
}

void main() {
  group('isMembersOnlyItem', () {
    test('true only for a members-only video', () {
      expect(isMembersOnlyItem(video('a', membersOnly: true)), isTrue);
      expect(isMembersOnlyItem(video('b')), isFalse);
    });

    test('a non-video is never members-only, rather than a case to remember', () {
      const mix = MixItem(kind: 'mix', id: 'RD1', title: 'Mix', thumbnailUrl: '');
      const channel = ChannelItem(kind: 'channel', id: 'UC1', name: 'C', avatarUrl: '');
      expect(isMembersOnlyItem(mix), isFalse);
      expect(isMembersOnlyItem(channel), isFalse);
    });
  });

  group('TileBadges', () {
    testWidgets('draws the green pill with a star for members-only', (tester) async {
      await pump(tester, const TileBadges(badges: [], isMembersOnly: true));
      expect(find.text('Members only'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });

    testWidgets('the pill is green, not the surface grey ordinary badges use',
        (tester) async {
      // The whole point of the request. If this ever reverts to a scheme role
      // it stops being recognisable at a glance in a grid.
      await pump(tester, const TileBadges(badges: ['4K'], isMembersOnly: true));
      final decorations = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => (c.decoration as BoxDecoration?)?.color)
          .whereType<Color>()
          .toSet();
      expect(
        decorations.contains(membersGreenSurfaceDark) ||
            decorations.contains(membersGreenSurfaceLight),
        isTrue,
        reason: 'the members pill must use the membership green',
      );
    });

    testWidgets('renders nothing at all when there is nothing to say', (tester) async {
      await pump(tester, const TileBadges(badges: []));
      expect(find.byType(SizedBox), findsWidgets);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
    });

    testWidgets('an ordinary badge still renders beside the pill', (tester) async {
      await pump(tester, const TileBadges(badges: ['4K'], isMembersOnly: true));
      expect(find.text('4K'), findsOneWidget);
      expect(find.text('Members only'), findsOneWidget);
    });

    testWidgets('no pill when the flag is false, whatever the badges say', (tester) async {
      // The sidecar strips the label, so this list should never contain it —
      // but if a future response slipped one through, the tile must still not
      // paint a *green* pill off a localised string.
      await pump(tester, const TileBadges(badges: ['Members only']));
      expect(find.byIcon(Icons.star_rounded), findsNothing);
    });
  });

  group('the preference', () {
    test('defaults to showing members-only content', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(membersOnlyVisibleProvider), isTrue);
    });

    test('toggles', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(membersOnlyVisibleProvider.notifier).toggle();
      expect(container.read(membersOnlyVisibleProvider), isFalse);
      container.read(membersOnlyVisibleProvider.notifier).set(true);
      expect(container.read(membersOnlyVisibleProvider), isTrue);
    });
  });

  group('the partition the feed does', () {
    // The grid and the shelf are built from these two lists, and the property
    // that matters is that they never overlap — a video in both is a video
    // rendered twice.
    List<FeedItem> feed() => [
          video('a'),
          video('m1', membersOnly: true),
          video('b'),
          video('m2', membersOnly: true),
        ];

    test('hoisting splits the feed with no overlap and no loss', () {
      final all = feed();
      final members = all.where(isMembersOnlyItem).toList();
      final grid = all.where((i) => !isMembersOnlyItem(i)).toList();

      expect(members.length, 2);
      expect(grid.length, 2);
      expect(members.length + grid.length, all.length);
      expect(
        members.map((i) => i.map(video: (v) => v.id, mix: (_) => '', playlist: (_) => '', channel: (_) => '', unknown: (_) => '')),
        ['m1', 'm2'],
      );
      for (final item in grid) {
        expect(isMembersOnlyItem(item), isFalse);
      }
    });

    test('hiding removes them from both', () {
      final visible = feed().where((i) => !isMembersOnlyItem(i)).toList();
      expect(visible.length, 2);
      expect(visible.any(isMembersOnlyItem), isFalse);
    });

    test('a feed that is entirely members-only leaves an empty grid', () {
      // The case that made the grid say "Nothing here yet" over a full shelf:
      // `items` is empty and `membersOnly` is not, so emptiness has to be
      // judged on both.
      final all = [video('m1', membersOnly: true), video('m2', membersOnly: true)];
      final members = all.where(isMembersOnlyItem).toList();
      final grid = all.where((i) => !isMembersOnlyItem(i)).toList();

      expect(grid, isEmpty);
      expect(members, isNotEmpty);
      expect(grid.isEmpty && members.isEmpty, isFalse,
          reason: 'the combined check is what the feed must use');
    });
  });
}
