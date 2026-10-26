/// A quality switch as an added video track (`docs/todo.md` 103): no reopen, no cover, one at
/// a time with the latest pick winning, and the reopen as the fallback.
///
/// Against a real fake-sidecar process and a [FakeEngine] with [FakeEngine.inPlaceSwitch] on, like
/// `new_video_stops_engine_test.dart`. What `video-add` really does is measured in the app
/// (`RILL_VIDEO_ADD_PROBE`), not here.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/playback/engine.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/domain/playback_source.dart';
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

  engine = FakeEngine()..inPlaceSwitch = true;
  container = ProviderContainer(overrides: [playbackEngineProvider.overrideWithValue(engine)]);
  container.read(playbackProvider);
}

Future<void> settle([int millis = 200]) => Future<void>.delayed(Duration(milliseconds: millis));

PlaybackState get playback => container.read(playbackProvider);
PlaybackController get controller => container.read(playbackProvider.notifier);

/// The ladder the fake sidecar answers: 2160, 1080, 720, 360 (index 0 to 3).
PlaybackVariant rung(int index) => playback.source!.variants[index];

Future<void> open() async {
  container.read(queueProvider.notifier).play(video('aaa'));
  await settle();
  expect(playback.variant?.height, 2160, reason: 'it opened at the best rung');
}

void main() {
  setUp(boot);

  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  group('in place', () {
    test('switches without reopening, without a cover, and the menu moves at once', () async {
      await open();
      final gate = Completer<void>();
      engine.switchGate = gate.future;

      final covers = <bool>[];
      container.listen(playbackProvider, (_, next) => covers.add(next.isSwitchingQuality), fireImmediately: false);

      final done = controller.switchQuality(rung(3));
      await settle(50);
      expect(playback.variant?.height, 360, reason: 'the tick is on the new rung before it has loaded');
      expect(playback.isSwitchingTrack, isTrue);
      expect(playback.isChangingQuality, isTrue, reason: 'the button and the menu show it busy');
      expect(playback.isSwitchingQuality, isFalse, reason: 'and the picture is not covered');

      gate.complete();
      await done;

      // MUTATION: drop the `canSwitchVideo` branch at the top of `switchQuality` and this fails:
      // the media would be reopened, with the cover.
      expect(engine.switched.map((v) => v.height), [360]);
      expect(engine.opened, hasLength(1), reason: 'no reopen');
      expect(covers, everyElement(isFalse), reason: 'the cover was never up');
      expect(playback.isSwitchingTrack, isFalse);
      expect(playback.hold, isNull);
      expect(playback.variant?.height, 360);
      expect(playback.preferredHeight, 360);
    });

    test('the same pick again does nothing', () async {
      await open();
      await controller.switchQuality(rung(3));
      await controller.switchQuality(rung(3));
      expect(engine.switched, hasLength(1));
    });
  });

  group('one at a time, the latest pick wins', () {
    test('picks made while a switch is in flight are dropped but the last', () async {
      await open();
      final gate = Completer<void>();
      engine.switchGate = gate.future;

      final first = controller.switchQuality(rung(1)); // 1080
      await settle(30);
      unawaited(controller.switchQuality(rung(2))); // 720: dropped
      unawaited(controller.switchQuality(rung(3))); // 360: dropped
      await controller.switchQuality(rung(2)); // 720: the last pick
      expect(playback.variant?.height, 720, reason: 'the menu follows the latest pick');
      expect(engine.switched, isEmpty, reason: 'nothing has finished yet');

      engine.switchGate = null;
      gate.complete();
      await first;
      await settle(50);

      // MUTATION: make a queued pick start its own `switchVideo` at once (skip the `_inPlaceBusy`
      // branch) and `maxSwitchesInFlight` goes to 2, and the dropped picks run.
      expect(engine.switched.map((v) => v.height), [1080, 720]);
      expect(engine.maxSwitchesInFlight, 1);
      expect(playback.variant?.height, 720);
      expect(playback.isSwitchingTrack, isFalse);
    });

    test('a queued pick back to the one that is showing is still run, the engine decides', () async {
      await open();
      final gate = Completer<void>();
      engine.switchGate = gate.future;
      final first = controller.switchQuality(rung(1));
      await settle(30);
      unawaited(controller.switchQuality(rung(0)));
      engine.switchGate = null;
      gate.complete();
      await first;
      await settle(50);
      expect(engine.switched.map((v) => v.height), [1080, 2160]);
    });
  });

  group('the reopen is the fallback', () {
    test('a refused switch reopens the media, with the cover, at the picked quality', () async {
      await open();
      engine.nextSwitchResult = VideoSwitch.refused;

      await controller.switchQuality(rung(3));
      await settle();

      expect(engine.switched, isEmpty);
      expect(engine.opened.map((v) => v.height), [2160, 360], reason: 'reopened at the pick');
      expect(playback.variant?.height, 360);
      expect(playback.isSwitchingTrack, isFalse);
      expect(playback.isSwitchingQuality, isFalse, reason: 'and the cover came down again');
      expect(playback.error, isNull);
    });

    test('a refused switch with a newer pick queued behind it reopens at the newer one', () async {
      await open();
      final gate = Completer<void>();
      engine.switchGate = gate.future;
      engine.nextSwitchResult = VideoSwitch.refused;
      final first = controller.switchQuality(rung(1));
      await settle(30);
      unawaited(controller.switchQuality(rung(3)));
      engine.switchGate = null;
      gate.complete();
      await first;
      await settle();

      expect(engine.opened.map((v) => v.height), [2160, 360]);
    });

    test('an engine that cannot (a muxed rung, another audio, a live stream) is reopened', () async {
      await open();
      engine.inPlaceSwitch = false;

      await controller.switchQuality(rung(3));
      await settle();

      expect(engine.switched, isEmpty);
      expect(engine.opened.map((v) => v.height), [2160, 360]);
    });

    test('force reopens even when it could switch', () async {
      await open();
      await controller.switchQuality(rung(0), force: true);
      await settle();
      expect(engine.opened, hasLength(2));
      expect(engine.switched, isEmpty);
    });
  });

  group('another video', () {
    test('opening while a switch is in flight leaves nothing busy and the new video at its own rung', () async {
      await open();
      final gate = Completer<void>();
      engine.switchGate = gate.future;
      unawaited(controller.switchQuality(rung(3)));
      await settle(30);

      container.read(queueProvider.notifier).play(video('bbb'));
      await settle();
      engine.switchGate = null;
      gate.complete();
      await settle(100);

      expect(playback.item?.id, 'bbb');
      expect(playback.isSwitchingTrack, isFalse);
      expect(playback.isLoading, isFalse);
      expect(playback.variant?.height, 360, reason: 'the viewer\'s 360p preference carries to the next video');
    });
  });
}
