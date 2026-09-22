/// Leaving audio-only is a cold restart of the video, and it must say so.
///
/// `vid=no` is not a pause. Measured 2026-09-22 against the shipped libmpv: it
/// drops the demuxer cache to zero — 36 MB and ~30 minutes of read-ahead, to
/// `total-bytes: 0` — and stops reading the video stream entirely. So coming
/// back is a refetch and a re-decode, observed between half a second and ten,
/// and for that whole time the surface has nothing on it.
///
/// `architecture.md` §2.4 used to claim both directions were instant. Only one
/// of them is, which is why only one of them raises a spinner.
library;

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
  container = ProviderContainer(
    overrides: [playbackEngineProvider.overrideWithValue(engine)],
  );
  container.read(playbackProvider);
}

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

Future<void> playSomething() async {
  container.read(queueProvider.notifier).play(video('aaa'));
  await settle();
  expect(container.read(playbackProvider).source, isNotNull, reason: 'nothing opened');
  expect(engine.width, isNotNull, reason: 'a picture should be decoding before we start');
}

void main() {
  setUp(boot);

  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('entering audio-only waits for nothing', () async {
    await playSomething();

    await container.read(audioModeProvider.notifier).setMode(true);
    await settle();

    expect(engine.videoTrackEnabled, isFalse);
    expect(
      container.read(playbackProvider).isRestoringVideo,
      isFalse,
      reason: 'dropping the track is immediate — a spinner here would be a lie',
    );
  });

  test('leaving it holds the flag until a frame is actually decoded', () async {
    await playSomething();
    await container.read(audioModeProvider.notifier).setMode(true);
    await settle();
    expect(engine.width, isNull, reason: 'vid=no takes the dimensions away');

    await container.read(audioModeProvider.notifier).setMode(false);
    await settle();

    expect(engine.videoTrackEnabled, isTrue);
    expect(
      container.read(playbackProvider).isRestoringVideo,
      isTrue,
      reason: 'the call returning is not the picture arriving — this is the wait',
    );

    // The first decoded frame.
    engine.setWidth(1280);
    await settle();

    expect(container.read(playbackProvider).isRestoringVideo, isFalse);
  });

  test('toggling back into audio-only mid-restore does not strand the spinner', () async {
    await playSomething();
    await container.read(audioModeProvider.notifier).setMode(true);
    await settle();

    await container.read(audioModeProvider.notifier).setMode(false);
    await settle();
    expect(container.read(playbackProvider).isRestoringVideo, isTrue);

    // Changed their mind before any picture arrived. Without the toggle token
    // the abandoned wait would sit on `widthStream` until its 25 s timeout,
    // holding a spinner over artwork that is already back.
    await container.read(audioModeProvider.notifier).setMode(true);
    await settle();

    expect(engine.videoTrackEnabled, isFalse);
    expect(
      container.read(playbackProvider).isRestoringVideo,
      isFalse,
      reason: 'the newer toggle owns the flag',
    );
  });
}
