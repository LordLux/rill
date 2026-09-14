/// The "Queue replaced" snack bar, driven through the real `startMixFromTile`.
///
/// Two reported bugs, both in widget code the controller tests cannot see:
///
///  - **It never went away.** A `SnackBar` with an action defaults to
///    `persist: true` (`persist ?? action != null` in the SDK), which ignores
///    `duration` — so the 5 s timeout set on it did nothing.
///  - **It outlived the choice it offered.** Editing the mix commits to it, so
///    an undo that would throw the edit away should not still be on screen.
///
/// No sidecar process: the two providers the function touches are overridden,
/// so the snack bar's timer runs on the test's own clock.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/open_video.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/queue_controller.dart';

VideoItem _video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

class _Mixes implements MixService {
  @override
  Future<MixStart> start(String playlistId, {String? videoId}) async => MixStart(
        playlistId: playlistId,
        title: 'My Mix',
        items: [for (var i = 0; i < 25; i++) _video('m$i')],
      );

  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) async =>
      const MixExtension(items: [], exhausted: true);
}

/// Playback that plays nothing — nothing here is about playback, and the real
/// controller would try to resolve streams the moment the queue moves.
class _SilentPlayback extends PlaybackController {
  @override
  PlaybackState build() => const PlaybackState();
}

late ProviderContainer _container;

Future<void> _tapStartMix(WidgetTester tester) async {
  _container = ProviderContainer(
    overrides: [
      mixServiceProvider.overrideWithValue(_Mixes()),
      playbackProvider.overrideWith(_SilentPlayback.new),
    ],
  );
  addTearDown(_container.dispose);

  // A hand-built queue, so there is something to offer back.
  _container.read(queueProvider.notifier)
    ..addToQueue(_video('mine1'))
    ..addToQueue(_video('mine2'));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => startMixFromTile(context, ref, 'RDxyz', title: 'My Mix'),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('start'));
  await tester.pump(); // the start resolves
  await tester.pump(const Duration(milliseconds: 750)); // the snack bar animates in
  expect(find.text('Queue replaced by My Mix'), findsOneWidget);
}

QueueController get _queue => _container.read(queueProvider.notifier);

void main() {
  testWidgets('dismisses itself after five seconds', (tester) async {
    await _tapStartMix(tester);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 750)); // exit animation

    expect(find.text('Queue replaced by My Mix'), findsNothing);
    expect(_queue.canUndoStartMix, isFalse, reason: 'no undo left behind with no way to press it');
  });

  testWidgets('dismisses as soon as the user edits the mix', (tester) async {
    await _tapStartMix(tester);

    _queue.addToQueue(_video('added'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(find.text('Queue replaced by My Mix'), findsNothing);
  });

  testWidgets('stays up through autoplay', (tester) async {
    await _tapStartMix(tester);

    _queue.advance();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(find.text('Queue replaced by My Mix'), findsOneWidget);
    expect(_queue.canUndoStartMix, isTrue);
  });

  testWidgets('Undo puts the hand-built queue back', (tester) async {
    await _tapStartMix(tester);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(_container.read(queueProvider).items.map((v) => v.id), ['mine1', 'mine2']);
    expect(find.text('Queue replaced by My Mix'), findsNothing);
  });
}
