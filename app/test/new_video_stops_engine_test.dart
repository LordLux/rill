/// Opening a different video stops the one before it, and the audio that did not load (todo 105,
/// issue #22).
///
/// Against a real fake-sidecar process and a [FakeEngine], like `playback_queue_test.dart`: what
/// the app put on the wire is read back from `test.playbackLog`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/audio_mode_controller.dart';
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

  engine = FakeEngine();
  container = ProviderContainer(overrides: [playbackEngineProvider.overrideWithValue(engine)]);
  container.read(playbackProvider);
}

Future<void> settle([int millis = 200]) => Future<void>.delayed(Duration(milliseconds: millis));

Future<({List<dynamic> opens, List<dynamic> reports, List<dynamic> closes})> log() async {
  final response = await RpcClient.instance.call('test.playbackLog', {}) as Map<String, dynamic>;
  return (
    opens: response['opens'] as List<dynamic>,
    reports: response['reports'] as List<dynamic>,
    closes: response['closes'] as List<dynamic>,
  );
}

PlaybackState get playback => container.read(playbackProvider);
PlaybackController get controller => container.read(playbackProvider.notifier);

void main() {
  setUp(boot);

  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  group('a different video stops the engine when it starts opening', () {
    test('before playback.open has answered, not after', () async {
      final queue = container.read(queueProvider.notifier);
      queue.play(video('aaa'));
      await settle();
      expect(engine.playing, isTrue);
      final stops = engine.stopCount;

      // MUTATION: drop the `_engine.stop()` in `open()` and this fails: the first video would
      // play on, showing its last frame, until the answer arrived.
      queue.play(video('bbb'));
      expect(engine.stopCount, stops + 1, reason: 'stopped on the same turn the new video is asked for');
      expect(engine.playing, isFalse);
      expect(playback.isLoading, isTrue, reason: 'and the answer has not arrived');

      await settle();
      expect(playback.item?.id, 'bbb');
      expect(engine.playing, isTrue);
    });

    test('and the first video of all has nothing to stop', () async {
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();
      expect(engine.stopCount, 0);
    });

    test('but a retry of the same video keeps what it has', () async {
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();

      await controller.retry();
      await settle();

      expect(engine.stopCount, 0, reason: 'the same video, so the stale frame is its own');
      expect(engine.opened, hasLength(2));
    });

    test('a quality switch is not a new video', () async {
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();

      await controller.switchQuality(playback.source!.variants.last);
      expect(engine.stopCount, 0);
    });

    test('is not an ending: no autoplay, no ended report, the old session closed with its position', () async {
      final queue = container.read(queueProvider.notifier);
      queue.addToQueue(video('aaa'));
      queue.addToQueue(video('bbb'));
      queue.addToQueue(video('ccc'));
      await settle();
      engine.emitPosition(const Duration(seconds: 42));

      // Picks `ccc` out of order; `bbb` must not be played in between.
      queue.play(video('ccc'));
      await settle();

      expect(playback.item?.id, 'ccc');
      expect(engine.opened.map((variant) => variant.videoUrl.split('/')[3]), ['aaa', 'ccc'],
          reason: 'the stop did not read as the end of aaa and advance the queue');

      final seen = await log();
      final states = seen.reports.cast<Map<String, dynamic>>().map((r) => r['state']).toList();
      expect(states, isNot(contains('ended')));
      expect(seen.closes, ['session_1'], reason: 'the old session is still closed');
      final finalReport = seen.reports.cast<Map<String, dynamic>>().firstWhere(
            (r) => r['sessionId'] == 'session_1' && r['state'] == 'paused' && r['positionMs'] == 42000,
            orElse: () => const {},
          );
      expect(finalReport, isNotEmpty,
          reason: 'its last report still carries where it was: the stop zeroes the clock, so '
              'reading it after the stop would have sent 0');
    });
  });

  group('a new open that fails after the old video is already stopped', () {
    test('leaves nothing playing, the old session closed, and a retry that can fail again', () async {
      final queue = container.read(queueProvider.notifier);
      queue.play(video('aaa'));
      await settle();

      queue.play(video('broken1')); // always answers STREAM_UNAVAILABLE
      await settle();

      expect(playback.isUnplayable, isTrue);
      expect(playback.item?.id, 'broken1');
      expect(playback.canRetry, isTrue);
      expect(engine.playing, isFalse, reason: 'the old video stays stopped, as it did before');
      expect(engine.opened, hasLength(1), reason: 'and the failed video never reached the engine');
      expect((await log()).closes, ['session_1']);

      await controller.retry();
      await settle();
      expect(playback.isUnplayable, isTrue, reason: 'a second try fails the same way, and does not play the old one');
      expect(engine.playing, isFalse);
    });

    test('a premiere in the same position behaves the same', () async {
      final queue = container.read(queueProvider.notifier);
      queue.play(video('aaa'));
      await settle();

      queue.play(video('premiere1'));
      await settle();

      expect(playback.isUpcoming, isTrue);
      expect(engine.playing, isFalse);
    });
  });

  group('audio that did not load', () {
    test('video mode keeps playing and says so', () async {
      engine.audioLoads = false;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();

      // MUTATION: drop `audioMissing: _engine.audioMissing` in `open()` and this fails.
      expect(playback.audioMissing, isTrue);
      expect(playback.error, isNull, reason: 'the picture is fine');
      expect(playback.isLoading, isFalse);
      expect(engine.playing, isTrue);
    });

    test('the notice comes down if the audio turns up after all', () async {
      engine.audioLoads = false;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();
      expect(playback.audioMissing, isTrue);

      // MUTATION: drop the `audioMissingStream` listener in the controller and this fails: the
      // notice would stay up over a video that has sound.
      engine.audioArrivesLate();
      await settle(50);

      expect(playback.audioMissing, isFalse);
      expect(playback.error, isNull);
      expect(engine.playing, isTrue);
    });

    test('a late audio track while nothing is missing changes nothing', () async {
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();
      engine.audioArrivesLate();
      await settle(50);
      expect(playback.audioMissing, isFalse);
    });

    test('a video whose audio loads says nothing', () async {
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();
      expect(playback.audioMissing, isFalse);
    });

    test('audio-only mode fails the open through the normal error path', () async {
      await container.read(audioModeProvider.notifier).setMode(true);
      engine.audioLoads = false;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();

      // MUTATION: drop the `AudioUnavailable` throw in the engine (or the fake) and this fails:
      // the open would end as a success with nothing selected.
      expect(playback.isUnplayable, isTrue);
      expect(playback.error, contains('audio'));
      expect(playback.canRetry, isTrue);
      expect(playback.audioMissing, isFalse);
      expect(engine.playing, isFalse);
    });

    test('Try again resolves the video again and carries on from where it was', () async {
      engine.audioLoads = false;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();
      engine.emitPosition(const Duration(seconds: 90));
      expect(playback.audioMissing, isTrue);

      engine.audioLoads = true;
      await controller.retryAudio();
      await settle();

      expect(playback.audioMissing, isFalse);
      final seen = await log();
      expect(seen.opens.cast<Map<String, dynamic>>().where((o) => o['videoId'] == 'aaa' && o['preload'] == false),
          hasLength(2),
          reason: 're-resolved through playback.open, not a reopen of the URLs it already had');
      expect(engine.seeks, contains(const Duration(seconds: 90)));
      expect(engine.stopCount, 0, reason: 'the same video keeps playing until the new audio is there');
    });

    test('Try again keeps the real clock showing while it reloads, and lets go once it is back', () async {
      engine.audioLoads = false;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();
      engine.emitPosition(const Duration(seconds: 90));

      final gate = Completer<void>();
      engine.openGate = gate.future;
      engine.audioLoads = true;
      unawaited(controller.retryAudio());
      await settle(150);

      // MUTATION: drop `keepClock: true` in `retryAudio` and this fails: the clock would read the
      // engine's 0:00 of 0:00 for as long as the open takes.
      expect(playback.isLoading, isTrue);
      expect(playback.hold?.position, const Duration(seconds: 90));
      expect(playback.hold?.duration, const Duration(minutes: 10));

      gate.complete();
      await settle(300);
      expect(playback.isLoading, isFalse);
      expect(engine.seeks, contains(const Duration(seconds: 90)));
      expect(playback.hold, isNull, reason: 'the engine is back at 90 s, so the held value goes');
    });

    test('a first load has no clock to hold', () async {
      final gate = Completer<void>();
      engine.openGate = gate.future;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle(150);
      expect(playback.isLoading, isTrue);
      expect(playback.hold, isNull);
      gate.complete();
      await settle();
    });

    test('a retry after an error has nothing to hold either', () async {
      container.read(queueProvider.notifier).play(video('broken1'));
      await settle();
      expect(playback.isUnplayable, isTrue);
      final gate = Completer<void>();
      engine.openGate = gate.future;
      unawaited(controller.retry());
      await settle(100);
      expect(playback.hold, isNull);
      gate.complete();
    });

    test('Try again keeps a paused video paused', () async {
      engine.audioLoads = false;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();
      await engine.pause();

      engine.audioLoads = true;
      await controller.retryAudio();
      await settle();

      expect(engine.playing, isFalse);
    });

    test('a quality switch reports it too, and clears it when the audio is there', () async {
      engine.audioLoads = false;
      container.read(queueProvider.notifier).play(video('aaa'));
      await settle();
      expect(playback.audioMissing, isTrue);

      engine.audioLoads = true;
      await controller.switchQuality(playback.source!.variants.last);
      expect(playback.audioMissing, isFalse);

      engine.audioLoads = false;
      await controller.switchQuality(playback.source!.variants.first);
      expect(playback.audioMissing, isTrue);
    });

    test('another video clears it', () async {
      engine.audioLoads = false;
      final queue = container.read(queueProvider.notifier);
      queue.play(video('aaa'));
      await settle();
      expect(playback.audioMissing, isTrue);

      engine.audioLoads = true;
      queue.play(video('bbb'));
      await settle();
      expect(playback.audioMissing, isFalse);
    });
  });
}
