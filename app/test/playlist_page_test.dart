import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/queue_controller.dart';
import 'package:rill/ui/playlist_controller.dart';
import 'package:rill/ui/pages/playlist.dart';

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

class FakeMixService implements MixService {
  @override
  Future<MixStart> start(String playlistId, {String? videoId, String? params}) async => MixStart(playlistId: playlistId, items: []);
  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) async => MixExtension(items: [], exhausted: true);
  @override
  Future<PlaylistResult> getPlaylist(String playlistId, {String? continuation}) async {
    print('FakeMixService.getPlaylist called for $playlistId');
    return PlaylistResult(
      title: 'My Playlist',
      items: [video('v0'), video('v1'), video('v2')],
    );
  }
}

void main() {
  testWidgets('clicking row N in the playlist detail page starts the playlist at N', (tester) async {
    final container = ProviderContainer(
      overrides: [
        mixServiceProvider.overrideWithValue(FakeMixService()),
      ],
    );
    addTearDown(container.dispose);


    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.exceptionAsString().contains('A RenderFlex overflowed')) return;
      FlutterError.presentError(details);
    };

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.view.reset());

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: PlaylistPage(playlistId: 'PL123')),
      ),
    ));

    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    
    final state = container.read(playlistProvider('PL123'));
    print('State value: ${state.value?.items.length}, loading: ${state.isLoading}, error: ${state.error}');

    for (final w in tester.widgetList<Text>(find.byType(Text))) {
      print('Found text: ${w.data}');
    }

    // Click on row 1 (Video v1)
    await tester.tap(find.text('Video v1'));
    await tester.pump(const Duration(seconds: 1));

    final queueState = container.read(queueProvider);
    // Assert that the queue now contains the playlist items, and the current index is 1.
    expect(queueState.mix?.isPlaylist, true, reason: 'should start as a playlist mix');
    expect(queueState.currentIndex, 1, reason: 'should start at row N');
  });
}
