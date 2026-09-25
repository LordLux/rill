import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/video_detail.dart';
import 'package:rill/ui/audio_mode_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/audio_mode_view.dart';
import 'package:rill/ui/video_info.dart';

import 'fake_engine.dart';

VideoItem video(String id, {String title = 'Video Title', bool isMusic = false}) => VideoItem(
      kind: 'video',
      id: id,
      title: title,
      channelName: 'Video Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      isMusic: isMusic,
      canWatchLater: true,
      canAddToQueue: true,
    );

VideoDetail detailWithMusic(String id, {String title = 'Video Title'}) => VideoDetail(
      id: id,
      title: title,
      channelName: 'Video Channel',
      isLive: false,
      myRating: VideoRating.none,
      isSubscribed: false,
      music: [
        const MusicTrack(
          title: 'Music Title',
          artist: 'Music Artist',
          album: 'Music Album',
          coverUrl: 'https://example.com/cover.jpg',
        ),
      ],
    );

VideoDetail detailWithoutMusic(String id) => VideoDetail(
      id: id,
      title: 'Video Title',
      channelName: 'Video Channel',
      isLive: false,
      myRating: VideoRating.none,
      isSubscribed: false,
      music: [],
    );

class FakePlaybackController extends PlaybackController {
  FakePlaybackController(this._item);
  final VideoItem _item;
  
  @override
  PlaybackState build() => PlaybackState(item: _item);
}

void main() {
  late FakeEngine engine;

  setUp(() {
    engine = FakeEngine();
  });

  Widget wrap(ProviderContainer container, Widget child, {double width = 800, double height = 600}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders with music metadata', (tester) async {
    final container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        // A music video, so the credit is believed with no word in common —
        // this used to pass only because "Video Title" and "Music Title" share
        // the word "title".
        playbackProvider.overrideWith(() => FakePlaybackController(video('123', isMusic: true))),
        videoInfoProvider.overrideWith((ref, arg) async => detailWithMusic(arg)),
      ],
    );
    addTearDown(container.dispose);

    container.read(audioModeProvider.notifier).setMode(true);
    await tester.pumpAndSettle();

    await tester.pumpWidget(wrap(container, const AudioModeView()));
    await tester.pumpAndSettle();

    expect(find.text('Music Title'), findsOneWidget);
    expect(find.text('Music Artist • Music Album'), findsOneWidget);
  });

  testWidgets('renders with empty music falling back to title/channel', (tester) async {
    final container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        playbackProvider.overrideWith(() => FakePlaybackController(video('123'))),
        videoInfoProvider.overrideWith((ref, arg) async => detailWithoutMusic(arg)),
      ],
    );
    addTearDown(container.dispose);

    container.read(audioModeProvider.notifier).setMode(true);
    await tester.pumpAndSettle();

    await tester.pumpWidget(wrap(container, const AudioModeView()));
    await tester.pumpAndSettle();

    expect(find.text('Video Title'), findsOneWidget);
    expect(find.text('Video Channel'), findsOneWidget);
  });

  testWidgets('a credit on a video that is not about it is not shown as the song', (tester) async {
    // Background music under a walkthrough — and, before the structural filter in
    // the sidecar, a game's own card.
    final container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        playbackProvider.overrideWith(() => FakePlaybackController(video('123', title: 'Co-op walkthrough'))),
        videoInfoProvider.overrideWith((ref, arg) async => detailWithMusic(arg, title: 'Co-op walkthrough')),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container, const AudioModeView()));
    await tester.pumpAndSettle();

    expect(find.text('Co-op walkthrough'), findsOneWidget);
    expect(find.text('Music Title'), findsNothing);
  });

  testWidgets('follows the chapters as the position moves', (tester) async {
    final chapters = [
      const Chapter(title: 'Artist One – Song One', startSeconds: 0),
      const Chapter(title: 'Artist Two – Song Two', startSeconds: 200),
      const Chapter(title: 'Artist Three – Song Three', startSeconds: 400),
    ];
    final container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        playbackProvider.overrideWith(() => FakePlaybackController(video('123', title: 'The Mix', isMusic: true))),
        videoInfoProvider.overrideWith(
          (ref, arg) async => detailWithoutMusic(arg).copyWith(chapters: chapters),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container, const AudioModeView()));
    await tester.pumpAndSettle();
    expect(find.text('Song One'), findsOneWidget);
    expect(find.text('Artist One'), findsOneWidget);

    engine.emitPosition(const Duration(seconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('Song Two'), findsOneWidget);
    expect(find.text('Song One'), findsNothing);

    // A seek back lands in the earlier chapter, not in a stale one.
    engine.emitPosition(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('Song One'), findsOneWidget);
  });

  testWidgets('does not overflow at a narrow width', (tester) async {
    final container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        playbackProvider.overrideWith(() => FakePlaybackController(video('123'))),
        videoInfoProvider.overrideWith((ref, arg) async => detailWithoutMusic(arg)),
      ],
    );
    addTearDown(container.dispose);

    container.read(audioModeProvider.notifier).setMode(true);
    await tester.pumpAndSettle();

    await tester.pumpWidget(wrap(container, const AudioModeView(showQueue: true), width: 200, height: 600));

    expect(tester.takeException(), isNull, reason: 'Layout must not throw RenderFlex overflow');
  });
}
