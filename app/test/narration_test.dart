import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/spoken.dart';
import 'package:rill/ui/widgets/media_tile.dart';

/// What a screen reader says (Windows Narrator), checked against the semantics tree:
/// each thing once, in the order that matters, durations as durations.
void main() {
  group('spoken durations', () {
    test('a clock is said as a length', () {
      expect(spokenClock('12:50'), '12 minutes and 50 seconds');
      expect(spokenClock('1:05:03'), '1 hour, 5 minutes and 3 seconds');
      expect(spokenClock('3:00'), '3 minutes');
      expect(spokenClock('0:01'), '1 second');
      expect(spokenClock('1:00:00'), '1 hour');
      expect(spokenClock('24 videos'), isNull);
    });
  });

  Future<void> pumpTile(WidgetTester tester, FeedItem item, {MediaTileLayout layout = MediaTileLayout.standard, MediaTileSize size = MediaTileSize.standard}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 520, child: layout == MediaTileLayout.wide ? MediaTile.wide(spec: specFor(item)!, size: size, onTap: () {}) : MediaTile(spec: specFor(item)!, onTap: () {})),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  VideoItem video({int? seconds = 770, bool live = false, bool station = false, bool music = false}) => FeedItem.video(
        kind: 'video',
        id: 'v1',
        title: 'The Title',
        channelName: 'The Channel',
        thumbnailUrl: 'https://example.com/t.jpg',
        durationSeconds: seconds,
        isLive: live || station,
        isStation: station,
        isMusic: music,
        viewCountText: '1M views',
        publishedText: '3y ago',
        canWatchLater: true,
        canAddToQueue: true,
      ) as VideoItem;

  /// The one node whose whole label is exactly [text].
  Finder said(String text) => find.bySemanticsLabel(RegExp('^${RegExp.escape(text)}\$'));

  for (final layout in [MediaTileLayout.standard, MediaTileLayout.wide]) {
    group('a ${layout.name} tile', () {
      testWidgets('an ordinary video: kind, title, author, then the length', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTile(tester, video(), layout: layout);
        expect(said('Video, The Title, The Channel, 12 minutes and 50 seconds long'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('a music video says so', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTile(tester, video(music: true), layout: layout);
        expect(said('Music Video, The Title, The Channel, 12 minutes and 50 seconds long'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('live and station say what they are, with no length', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTile(tester, video(seconds: null, live: true), layout: layout);
        expect(said('Live, The Title, The Channel'), findsOneWidget);
        await pumpTile(tester, video(seconds: null, station: true), layout: layout);
        expect(said('Station, The Title, The Channel'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('a mix is not announced twice: its title already says Mix', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTile(
          tester,
          const FeedItem.mix(kind: 'mix', id: 'RDabc', title: 'Mix - Some Artist', subtitle: 'Some Artist, Another', thumbnailUrl: 'https://example.com/t.jpg'),
          layout: layout,
        );
        expect(said('Mix - Some Artist, Some Artist, Another'), findsOneWidget);
        handle.dispose();
      });
    });
  }
}
