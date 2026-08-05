import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_youtube/domain/feed_item.dart';
import 'package:native_youtube/ui/widgets/media_tile.dart';

void main() {
  Widget buildTile(TileSpec spec) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 340, // maxCrossAxisExtent from feed.dart (430 max, but ~340 is a realistic tile size)
            child: MediaTile(spec: spec),
          ),
        ),
      ),
    );
  }

  testWidgets('MediaTile smoke test - VideoItem', (WidgetTester tester) async {
    final item = const FeedItem.video(
      kind: 'video',
      id: 'vid1',
      title: 'A very long title that might wrap to two lines in the tile and should not overflow the bottom metadata area',
      channelName: 'Channel Name',
      channelId: 'chan1',
      channelAvatarUrl: 'https://example.com/avatar.jpg',
      thumbnailUrl: 'https://example.com/thumb.jpg',
      durationSeconds: 3600,
      isLive: false,
      viewCountText: '1M views',
      publishedText: '1 day ago',
      badges: ['4K', 'New', 'Members only'],
      canWatchLater: true,
      canAddToQueue: true,
    );

    final spec = specFor(item)!;
    await tester.pumpWidget(buildTile(spec));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('hover flipping faster than the reveal animation does not throw', (WidgetTester tester) async {
    // The hover-revealed action buttons were built with an AnimatedSwitcher
    // keyed on a bool. A switcher keeps its outgoing child mounted for the full
    // duration, so a pointer crossing a grid of tiles — in and out inside
    // 100ms — left two children with the same ValueKey(false) in its internal
    // Stack: "Duplicate keys found". None of the other smoke tests hover, which
    // is why they never saw it.
    final item = const FeedItem.video(
      kind: 'video',
      id: 'vid1',
      title: 'Hovered',
      channelName: 'Channel Name',
      channelId: 'chan1',
      channelAvatarUrl: 'https://example.com/avatar.jpg',
      thumbnailUrl: 'https://example.com/thumb.jpg',
      durationSeconds: 238,
      isLive: false,
      viewCountText: '11M views',
      publishedText: '7 months ago',
      badges: [],
      canWatchLater: true,
      canAddToQueue: true,
    );

    await tester.pumpWidget(buildTile(specFor(item)!));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    final centre = tester.getCenter(find.byType(MediaTile));
    for (var i = 0; i < 4; i++) {
      await gesture.moveTo(centre);
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('MediaTile smoke test - MixItem', (WidgetTester tester) async {
    final item = const FeedItem.mix(
      kind: 'mix',
      id: 'mix1',
      title: 'My Mix',
      subtitle: 'Artist 1, Artist 2',
      thumbnailUrl: 'https://example.com/thumb.jpg',
      videoCount: 50,
    );

    final spec = specFor(item)!;
    await tester.pumpWidget(buildTile(spec));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('MediaTile smoke test - PlaylistItem', (WidgetTester tester) async {
    final item = const FeedItem.playlist(
      kind: 'playlist',
      id: 'pl1',
      title: 'My Playlist',
      channelName: 'Channel Name',
      thumbnailUrl: 'https://example.com/thumb.jpg',
      videoCount: 10,
    );

    final spec = specFor(item)!;
    await tester.pumpWidget(buildTile(spec));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
