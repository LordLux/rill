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
///
/// **The signal is `vo-configured`, and the obvious candidates are all wrong.**
/// Measured 2026-09-23 on a 96-minute 1080p video: media_kit's cached `width`
/// and the `VideoController`'s `rect` both survive `vid=no` untouched, and
/// mpv's own `width` returns the instant the track is re-enabled — 5 seconds
/// before there is anything on screen. The first version of this shipped
/// against `width` and the spinner never appeared once.
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
  expect(engine.videoOutputReady, isTrue, reason: 'a picture before we start');
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
    expect(engine.videoOutputReady, isFalse, reason: 'vid=no tears the video output down');

    await container.read(audioModeProvider.notifier).setMode(false);
    await settle();

    expect(engine.videoTrackEnabled, isTrue);
    expect(
      container.read(playbackProvider).isRestoringVideo,
      isTrue,
      reason: 'the call returning is not the picture arriving — this is the wait',
    );

    // The picture actually arriving — on the real engine, ~5 s after the call.
    engine.setVideoOutputReady(true);
    await settle();

    expect(container.read(playbackProvider).isRestoringVideo, isFalse);
  });

  test('opening another video clears a restore that never finished', () async {
    await playSomething();
    await container.read(audioModeProvider.notifier).setMode(true);
    await settle();
    await container.read(audioModeProvider.notifier).setMode(false);
    await settle();
    expect(container.read(playbackProvider).isRestoringVideo, isTrue);

    // No picture ever arrives — the case where the stream is wedged. The user
    // gives up and plays something else.
    container.read(queueProvider.notifier).play(video('bbb'));
    await settle();

    expect(container.read(playbackProvider).item?.id, 'bbb');
    expect(
      container.read(playbackProvider).isRestoringVideo,
      isFalse,
      reason: 'a restore belongs to the media it started on — otherwise the '
          'artwork sits over the new video with the switch off',
    );
  });

  test('toggling back into audio-only mid-restore does not strand the spinner', () async {
    await playSomething();
    await container.read(audioModeProvider.notifier).setMode(true);
    await settle();

    await container.read(audioModeProvider.notifier).setMode(false);
    await settle();
    expect(container.read(playbackProvider).isRestoringVideo, isTrue);

    // Changed their mind before any picture arrived. Without the toggle token
    // the abandoned wait would sit on `videoOutputStream` until its 30 s
    // timeout, holding a spinner over artwork that is already back.
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
