/// Tile taps (task §6).
///
/// The interesting assertion is the negative one: pressing Watch Later or Add to
/// Queue must not *also* open the video. Flutter's gesture arena gives the inner
/// button the win, so this passes today by construction — which is exactly why
/// it is worth pinning as behaviour. The day someone wraps the buttons in
/// something that defers to its child, every queue click starts a video instead.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/open_video.dart';
import 'package:rill/ui/widgets/media_tile.dart';

const TileSpec spec = TileSpec(
  title: 'A video',
  thumbnailUrl: 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg',
  isStackedCards: false,
  durationText: '4:20',
  durationTone: DurationBadgeTone.normal,
  badges: [],
  canWatchLater: true,
  canAddToQueue: true,
  primaryLine: 'Channel',
);

/// Put the mouse over the tile so the hover actions become hittable.
Future<void> hoverTile(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tapping the tile opens it', (tester) async {
    var taps = 0;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: MediaTile(spec: spec, onTap: () => taps++),
          ),
        ),
      ),
    ));

    await tester.tap(find.byType(MediaTile));
    expect(taps, 1);
  });

  testWidgets('the action buttons do not also navigate', (tester) async {
    var taps = 0;
    var queued = 0;
    var watchLater = 0;

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: MediaTile(
              spec: spec,
              onTap: () => taps++,
              onAddToQueue: () => queued++,
              onWatchLater: () => watchLater++,
            ),
          ),
        ),
      ),
    ));

    await hoverTile(tester);

    await tester.tap(find.byIcon(Icons.playlist_play));
    await tester.pumpAndSettle();
    expect(queued, 1);
    expect(taps, 0, reason: 'adding to the queue must not open the video too');

    await tester.tap(find.byIcon(Icons.schedule));
    await tester.pumpAndSettle();
    expect(watchLater, 1);
    expect(taps, 0);
  });

  group('what a tile opens', () {
    VideoItem videoItem() => const VideoItem(
          kind: 'video',
          id: 'aaaaaaaaaaa',
          title: 'A video',
          channelName: 'Channel',
          thumbnailUrl: 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg',
          isLive: false,
          canWatchLater: true,
          canAddToQueue: true,
        );

    test('a video opens itself', () {
      expect(watchTargetFor(videoItem())?.id, 'aaaaaaaaaaa');
    });

    test('a mix opens its seed video, read from the thumbnail', () {
      const mix = MixItem(
        kind: 'mix',
        id: 'RDCLAK5uy_kLWIr9gv1XLlPbaDS965-Db4TrBoUTxQ8',
        title: 'Mix - something',
        thumbnailUrl: 'https://i.ytimg.com/vi/bbbbbbbbbbb/hqdefault.jpg',
      );
      // The curated case, where the id is nowhere in the playlist id.
      expect(watchTargetFor(mix)?.id, 'bbbbbbbbbbb');
      expect(mixSeedVideoId(mix), 'bbbbbbbbbbb');
    });

    test('a mix falls back to the RD-prefixed playlist id', () {
      const mix = MixItem(
        kind: 'mix',
        id: 'RD3T0NqvdUiWI',
        title: 'Mix',
        thumbnailUrl: 'https://example.invalid/no-video-id-here.jpg',
      );
      expect(mixSeedVideoId(mix), '3T0NqvdUiWI');
    });

    test('a mix with neither stays inert rather than opening a made-up id', () {
      const mix = MixItem(
        kind: 'mix',
        id: 'RDCLAK5uy_not_eleven',
        title: 'Mix',
        thumbnailUrl: 'https://example.invalid/nothing.jpg',
      );
      expect(mixSeedVideoId(mix), isNull);
      expect(watchTargetFor(mix), isNull);
    });

    test('a playlist is out of scope and inert', () {
      expect(
        watchTargetFor(const PlaylistItem(
          kind: 'playlist',
          id: 'PL123',
          title: 'A playlist',
          thumbnailUrl: 'https://i.ytimg.com/vi/ccccccccccc/hq.jpg',
        )),
        isNull,
        reason: 'a playlist tile must not open its thumbnail video by accident',
      );
    });

    test('a channel has nothing to play', () {
      expect(
        watchTargetFor(const ChannelItem(
          kind: 'channel',
          id: 'UC123',
          name: 'A channel',
          avatarUrl: 'https://yt3.ggpht.com/a.jpg',
        )),
        isNull,
      );
    });

    test('an unrecognised item is inert, not a crash', () {
      expect(watchTargetFor(const UnknownItem()), isNull);
    });
  });
}
