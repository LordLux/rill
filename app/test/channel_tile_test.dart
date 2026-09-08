/// `ChannelTile` — never exercised before Task 20, because the home feed does
/// not return channels and search does (§5). The sidecar side of this is
/// pinned by `corpus/search.json` now carrying a real `ChannelItem` (see the
/// Task 20 report); this is the Flutter side, that the DTO actually renders.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/domain/feed_item.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/widgets/feed_view.dart';

void main() {
  testWidgets('renders the name and subscriber count, no crash on an empty avatar', (tester) async {
    const channel = ChannelItem(
      kind: 'channel',
      id: 'chan_014',
      name: 'Sanitised Channel 14',
      avatarUrl: '',
      subscriberText: 'Sanitised Subscribers 14',
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildRillTheme(kDefaultAccent),
          home: const Scaffold(body: ChannelTile(channel: channel)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Sanitised Channel 14'), findsOneWidget);
    expect(find.text('Sanitised Subscribers 14'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsOneWidget, reason: 'an empty avatarUrl falls back to a placeholder icon');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a null subscriberText renders no second line rather than "null"', (tester) async {
    const channel = ChannelItem(
      kind: 'channel',
      id: 'chan_015',
      name: 'No Subscriber Count',
      avatarUrl: 'https://fake.url/avatar15.jpg',
      subscriberText: null,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildRillTheme(kDefaultAccent),
          home: const Scaffold(body: ChannelTile(channel: channel)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('No Subscriber Count'), findsOneWidget);
    expect(find.textContaining('null'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
