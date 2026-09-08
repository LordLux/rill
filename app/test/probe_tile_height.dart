/// Measurement probe, not a regression test — `test/README.md` explains why
/// these are not `_test.dart` files. Answers one question: how tall is a
/// standard [MediaTile]'s metadata block beneath its thumbnail, which is the
/// constant `artist_panel_card.dart`'s shelf (and `feed_view.dart`'s Shorts
/// shelf) has to carry because a `LayoutBuilder`-rooted widget cannot be
/// asked for an intrinsic height.
///
/// Run: flutter test test/probe_tile_height.dart --reporter expanded
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/domain/feed_item.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/theme/screen_values.dart';
import 'package:rill/ui/widgets/media_tile.dart';

void main() {
  testWidgets('measure the metadata block under a standard tile', (tester) async {
    tester.view.physicalSize = const Size(2000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final badges in <List<String>>[<String>[], <String>['4K', 'New']]) {
      for (final title in <String>[
        'Short title',
        'A title long enough to wrap onto exactly two lines in a narrow shelf tile',
      ]) {
        for (final width in <double>[180.0, 250.0, 320.0]) {
          final item = FeedItem.video(
            kind: 'video',
            id: 'aaaaaaaaaaa',
            title: title,
            channelName: 'A Channel',
            channelAvatarUrl: 'https://fake.url/a.jpg',
            thumbnailUrl: 'https://fake.url/t.jpg',
            durationSeconds: 194,
            isLive: false,
            viewCountText: '4.5M views',
            publishedText: '3 weeks ago',
            badges: badges,
            canWatchLater: true,
            canAddToQueue: true,
          );

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: buildRillTheme(kDefaultAccent),
              home: Scaffold(
                // Unbounded height: the tile's root Column is
                // `mainAxisSize.max`, so under a bounded parent it simply
                // fills and measures nothing. Scrolling gives it the infinite
                // constraint that makes it shrink-wrap its children.
                body: SingleChildScrollView(
                  child: SizedBox(width: width, child: MediaTile(spec: specFor(item)!)),
                ),
              ),
            ),
          ),
        );
          await tester.pump();

          final total = tester.getSize(find.byType(MediaTile)).height;
          final thumbnail = width / ScreenValues.normalAspectRatio;
          debugPrint(
            'badges=${badges.length} '
            'width=${width.toStringAsFixed(0)} '
            'title=${title.length > 20 ? "long" : "short"} '
            'total=${total.toStringAsFixed(1)} '
            'thumb=${thumbnail.toStringAsFixed(1)} '
            'metadata=${(total - thumbnail).toStringAsFixed(1)}',
          );
        }
      }
    }
  });
}
