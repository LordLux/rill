/// The members-only shelf, rendered.
///
/// Over a stubbed [FeedState] rather than a sidecar — the claims here are about
/// *layout* given a set of items, and a real process only adds wall-clock waits
/// to a question that has none. Same approach as `feed_footer_widget_test.dart`.
///
/// The property that matters is **no double-render**: a video hoisted into the
/// shelf must leave the grid, or every members-only video appears twice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/feed_controller.dart';
import 'package:rill/ui/members_only_preference.dart';
import 'package:rill/ui/widgets/feed_view.dart';

class _StubFeed extends FeedController {
  _StubFeed(this.initial);

  final FeedState initial;

  @override
  FeedState build() => initial;
}

class _Hidden extends MembersOnlyVisible {
  @override
  bool build() => false;
}

/// Four videos, the middle two members-only — scattered rather than adjacent,
/// because that is how they arrive and collecting them is the behaviour here.
FeedState _feed() => FeedState(
      surface: FeedController.surface,
      isLoading: false,
      items: [
        for (final spec in const [
          ('open-0', false),
          ('members-1', true),
          ('open-2', false),
          ('members-3', true),
        ])
          VideoItem(
            kind: 'video',
            id: spec.$1,
            title: spec.$1,
            channelName: 'Fake Channel',
            thumbnailUrl: '',
            isLive: false,
            isMembersOnly: spec.$2,
            canWatchLater: false,
            canAddToQueue: false,
          ),
      ],
    );

Future<void> pumpFeed(
  WidgetTester tester, {
  required bool groupMembersOnly,
  bool showMembersOnly = true,
}) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        feedProvider.overrideWith(() => _StubFeed(_feed())),
        if (!showMembersOnly) membersOnlyVisibleProvider.overrideWith(_Hidden.new),
      ],
      child: MaterialApp(
        theme: buildRillTheme(kDefaultAccent),
        home: Scaffold(
          body: FeedView(provider: feedProvider, groupMembersOnly: groupMembersOnly),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the shelf appears, with its own header', (tester) async {
    await pumpFeed(tester, groupMembersOnly: true);
    expect(find.text('From your memberships'), findsOneWidget);
  });

  testWidgets('a hoisted video is not also left in the grid', (tester) async {
    // The failure this file exists for: each members-only video must appear
    // exactly once on the page.
    await pumpFeed(tester, groupMembersOnly: true);
    expect(find.text('members-1'), findsOneWidget);
    expect(find.text('members-3'), findsOneWidget);
    // And the rest of the grid is untouched.
    expect(find.text('open-0'), findsOneWidget);
    expect(find.text('open-2'), findsOneWidget);
  });

  testWidgets('without grouping there is no shelf and nothing moves', (tester) async {
    // Search's behaviour: a ranked answer must not be reordered by tidying.
    await pumpFeed(tester, groupMembersOnly: false);
    expect(find.text('From your memberships'), findsNothing);
    expect(find.text('members-1'), findsOneWidget);
    expect(find.text('open-0'), findsOneWidget);
  });

  testWidgets('the preference hides them from the grid and the shelf alike', (tester) async {
    await pumpFeed(tester, groupMembersOnly: true, showMembersOnly: false);
    expect(find.text('From your memberships'), findsNothing);
    expect(find.text('members-1'), findsNothing,
        reason: 'hidden means hidden — not merely moved out of the shelf');
    expect(find.text('members-3'), findsNothing);
    expect(find.text('open-0'), findsOneWidget);
    expect(find.text('open-2'), findsOneWidget);
  });

  testWidgets('hiding works without grouping too', (tester) async {
    // Search still has to honour the preference even though it never hoists.
    await pumpFeed(tester, groupMembersOnly: false, showMembersOnly: false);
    expect(find.text('members-1'), findsNothing);
    expect(find.text('open-0'), findsOneWidget);
  });

  testWidgets('the green members pill is on the shelf tiles', (tester) async {
    await pumpFeed(tester, groupMembersOnly: true);
    // Two members-only videos, each carrying its own pill — a tile has to say
    // what it is even when its shelf header is scrolled out of view.
    expect(find.text('Members only'), findsNWidgets(2));
  });
}
