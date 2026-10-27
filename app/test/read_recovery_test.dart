/// A read that fails is not the video ending (`docs/todo.md` 107).
///
/// A dropped connection is an end of file to mpv, and a seek into a region whose URL has expired
/// never finishes. The app used to report the first as the video finishing and play the next
/// one, and to wait for ever on the second. Both now resolve the video again and reopen it where
/// the viewer was. Against a real fake-sidecar process and a [FakeEngine]; what mpv really does
/// is measured in `sidecar/scratch/measure-expiry.ts` and the app's `RILL_VIDEO_ADD_PROBE_EXPIRY`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

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

late FakeEngine engine;
late ProviderContainer container;

Future<void> boot() async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  await RpcClient.instance.start();
  PlaybackController.seekStuckAfter = const Duration(milliseconds: 150);
  engine = FakeEngine();
  container = ProviderContainer(overrides: [playbackEngineProvider.overrideWithValue(engine)]);
  container.read(playbackProvider);
}

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

Future<List<Map<String, dynamic>>> log(String key) async {
  final response = await RpcClient.instance.call('test.playbackLog', {}) as Map<String, dynamic>;
  return (response[key] as List<dynamic>).cast<Map<String, dynamic>>();
}

PlaybackState get playback => container.read(playbackProvider);
PlaybackController get controller => container.read(playbackProvider.notifier);

/// Opens `aaa` and puts the clock at [at].
Future<void> playUntil(Duration at) async {
  container.read(queueProvider.notifier).play(video('aaa'));
  await settle();
  engine.emitPosition(at);
}

void main() {
  setUp(boot);

  tearDown(() async {
    PlaybackController.seekStuckAfter = const Duration(seconds: 20);
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  group('a file that ends well short of its duration', () {
    test('is a failed read: resolved again and reopened where it was, no ending, no next video', () async {
      final queue = container.read(queueProvider.notifier);
      queue.addToQueue(video('aaa'));
      queue.addToQueue(video('bbb'));
      await settle();
      engine.emitPosition(const Duration(minutes: 2));

      // MUTATION: drop the `_endedShort()` check at the top of `_onCompleted` and this fails: the
      // watch is reported as ended and `bbb` starts over a video the viewer was in the middle of.
      engine.cutOff();
      await settle(500);

      expect(playback.item?.id, 'aaa', reason: 'the queue did not advance');
      expect(container.read(queueProvider).currentIndex, 0);
      expect(engine.opened, hasLength(2), reason: 'reopened');
      expect(engine.opened.every((v) => v.videoUrl.contains('/aaa/')), isTrue);
      expect(engine.seeks, contains(const Duration(minutes: 2)), reason: 'at the position it was cut off');
      expect(engine.playing, isTrue);

      final states = (await log('reports')).map((r) => r['state']).toList();
      expect(states, isNot(contains('ended')));
      final opens = (await log('opens')).where((o) => o['videoId'] == 'aaa' && o['preload'] == false);
      expect(opens, hasLength(2), reason: 'resolved again through playback.open');
    });

    test('keeps the real clock showing while it reopens', () async {
      await playUntil(const Duration(minutes: 2));
      final gate = Completer<void>();
      engine.openGate = gate.future;
      engine.cutOff();
      await settle(150);
      expect(playback.isLoading, isTrue);
      expect(playback.hold?.position, const Duration(minutes: 2));
      gate.complete();
      await settle(400);
      expect(playback.hold, isNull);
    });

    test('a file that ends where it should (within the slack of its duration) is an ending', () async {
      final queue = container.read(queueProvider.notifier);
      queue.addToQueue(video('aaa'));
      queue.addToQueue(video('bbb'));
      await settle();
      engine.emitPosition(const Duration(minutes: 9, seconds: 58));
      engine.cutOff();
      await settle();
      expect(playback.item?.id, 'bbb');
    });

    test('ending at the same place after being reopened there is its real end', () async {
      // A file whose stream is shorter than the duration YouTube gave must not loop.
      final queue = container.read(queueProvider.notifier);
      queue.addToQueue(video('aaa'));
      queue.addToQueue(video('bbb'));
      await settle();
      engine.emitPosition(const Duration(minutes: 2));
      engine.cutOff();
      await settle(500);
      expect(playback.item?.id, 'aaa');

      engine.emitPosition(const Duration(minutes: 2, seconds: 1));
      engine.cutOff();
      await settle(500);
      expect(playback.item?.id, 'bbb', reason: 'the second end in the same place is taken as the end');
    });

    test('cut off at three different places in a minute becomes an error with a retry, not a loop', () async {
      await playUntil(const Duration(minutes: 1));
      for (final minutes in [1, 3, 5]) {
        engine.emitPosition(Duration(minutes: minutes));
        engine.cutOff();
        await settle(500);
      }
      expect(playback.error, isNull, reason: 'three reopens were allowed');
      expect(engine.opened, hasLength(4));

      engine.emitPosition(const Duration(minutes: 7));
      engine.cutOff();
      await settle(500);
      expect(playback.isUnplayable, isTrue);
      expect(playback.canRetry, isTrue);
      expect(engine.opened, hasLength(4), reason: 'and no fourth reopen');
    });

    test('a live stream has no end to fall short of', () async {
      // The fake sidecar answers a live video with no duration.
      final queue = container.read(queueProvider.notifier);
      queue.addToQueue(video('live1'));
      queue.addToQueue(video('bbb'));
      await settle();
      engine.cutOff();
      await settle();
      expect(playback.item?.id, 'bbb');
    });
  });

  group('a seek that never finishes', () {
    test('is a failed read: resolved again and reopened at the seek\'s target', () async {
      await playUntil(const Duration(minutes: 1));
      engine.emitPosition(const Duration(minutes: 4)); // mpv reports the target while it seeks
      engine.setSeeking(true);

      // MUTATION: drop the `seekingStream` listener in the controller and this fails: the viewer
      // waits for ever on a seek an expired URL will never answer.
      await settle(700);

      expect(engine.opened, hasLength(2));
      expect(engine.seeks, contains(const Duration(minutes: 4)));
      expect(playback.item?.id, 'aaa');
    });

    test('that finishes in time is left alone', () async {
      await playUntil(const Duration(minutes: 1));
      engine.setSeeking(true);
      await settle(50);
      engine.setSeeking(false);
      await settle(400);
      expect(engine.opened, hasLength(1));
    });

    test('recovers paused if it was paused', () async {
      await playUntil(const Duration(minutes: 1));
      await engine.pause();
      engine.setSeeking(true);
      await settle(700);
      expect(engine.opened, hasLength(2));
      expect(engine.playing, isFalse);
    });

    test('during a load, or a switch, is not this: those have their own deadlines', () async {
      final gate = Completer<void>();
      engine.openGate = gate.future;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle(100);
      engine.setSeeking(true);
      await settle(500);
      expect(playback.isLoading, isTrue);
      expect(engine.opened, hasLength(1));
      gate.complete();
      engine.setSeeking(false);
      await settle();
    });
  });
}
