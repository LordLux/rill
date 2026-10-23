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

    test('a position is said as an ordinal', () {
      expect([for (final n in [1, 2, 3, 4, 11, 12, 13, 21, 22, 101, 111, 112, 113, 122]) spokenOrdinal(n)], [
        '1st', '2nd', '3rd', '4th', '11th', '12th', '13th', '21st', '22nd', '101st', '111th', '112th', '113th', '122nd', //
      ]);
    });

    test('a number is said in words', () {
      expect([for (final n in [0, 5, 13, 20, 21, 99, 100, 220, 305, 999, 1000, 1234, 20000, 622000]) spokenNumber(n)], [
        'zero', 'five', 'thirteen', 'twenty', 'twenty-one', 'ninety-nine', 'one hundred', 'two hundred twenty', //
        'three hundred five', 'nine hundred ninety-nine', 'one thousand', 'one thousand two hundred thirty-four',
        'twenty thousand', 'six hundred twenty-two thousand',
      ]);
      expect(spokenNumber(1000000), '1000000');
    });

    test('a count is spelled out', () {
      expect(spokenCount('220M views'), 'two hundred twenty million views');
      expect(spokenCount('7.7M views'), 'seven point seven million views');
      expect(spokenCount('622K views'), 'six hundred twenty-two thousand views');
      expect(spokenCount('1.2B views'), 'one point two billion views');
      expect(spokenCount('1.2K watching'), 'one point two thousand watching');
      expect(spokenCount('123 views'), 'one hundred twenty-three views');
      expect(spokenCount('1,234 views'), 'one thousand two hundred thirty-four views');
      expect(spokenCount('No views'), 'No views');
    });

    test('a short age is spelled out, and a long one is left alone', () {
      expect(spokenAge('1y ago'), 'one year ago');
      expect(spokenAge('5y ago'), 'five years ago');
      expect(spokenAge('2mo ago'), 'two months ago');
      expect(spokenAge('4w ago'), 'four weeks ago');
      expect(spokenAge('5d ago'), 'five days ago');
      expect(spokenAge('1h ago'), 'one hour ago');
      expect(spokenAge('4m ago'), 'four minutes ago');
      expect(spokenAge('Streamed 2w ago'), 'Streamed two weeks ago');
      expect(spokenAge('Streamed 2 weeks ago'), 'Streamed 2 weeks ago');
    });

    test('a views-and-age line drops the bullet for a pause', () {
      expect(spokenStats('220M views • 5y ago'), 'two hundred twenty million views, five years ago');
      expect(spokenStats('7.7M views • 1y ago'), 'seven point seven million views, one year ago');
      expect(spokenStats('7.7M views'), 'seven point seven million views');
      expect(spokenStats('1.2M views • 3 years ago'), 'one point two million views, three years ago');
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
        expect(said('Video, The Title, The Channel, one million views, three years ago, 12 minutes and 50 seconds long'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('the hover buttons are not in the semantics tree; the 3-dot menu has the same actions', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTile(tester, video(), layout: layout);
        expect(find.bySemanticsLabel('Watch later'), findsNothing);
        expect(find.bySemanticsLabel('Add to queue'), findsNothing);
        handle.dispose();
      });

      testWidgets('a numbered row says its place first, as an ordinal', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(width: 520, child: MediaTile.wide(spec: specFor(video(music: true))!, position: 101, onTap: () {})),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(said('101st, Music Video, The Title, The Channel, one million views, three years ago, 12 minutes and 50 seconds long'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('a tile is a button, not an anonymous group', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTile(tester, video(), layout: layout);
        final node = tester.getSemantics(said('Video, The Title, The Channel, one million views, three years ago, 12 minutes and 50 seconds long'));
        expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
        handle.dispose();
      });

      testWidgets('a music video says so', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTile(tester, video(music: true), layout: layout);
        expect(said('Music Video, The Title, The Channel, one million views, three years ago, 12 minutes and 50 seconds long'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('live and station say what they are, with no length', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTile(tester, video(seconds: null, live: true), layout: layout);
        expect(said('Live, The Title, The Channel, one million views, three years ago'), findsOneWidget);
        await pumpTile(tester, video(seconds: null, station: true), layout: layout);
        expect(said('Station, The Title, The Channel, one million views, three years ago'), findsOneWidget);
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

      testWidgets('a playlist says how many videos, in the singular for one', (tester) async {
        final handle = tester.ensureSemantics();
        FeedItem playlist(int count) =>
            FeedItem.playlist(kind: 'playlist', id: 'PLabc', title: 'The Title', thumbnailUrl: 'https://example.com/t.jpg', videoCount: count, channelName: 'The Channel');
        await pumpTile(tester, playlist(1), layout: layout);
        expect(said('Playlist, The Title, The Channel, 1 video'), findsOneWidget);
        await pumpTile(tester, playlist(24), layout: layout);
        expect(said('Playlist, The Title, The Channel, 24 videos'), findsOneWidget);
        handle.dispose();
      });
    });
  }
}
