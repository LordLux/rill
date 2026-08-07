/// `STREAM_UNAVAILABLE` is a state the user can retry out of (§4).
///
/// Every rung of the ladder can decline for a video that is perfectly fine —
/// observed 2026-08-02, when an `MWEB` response arrived carrying no progressive
/// format at all (F9, amended). That is why the protocol makes this `user` and
/// not `no`, and why "Unavailable" must not be a dead end.
library;

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

Future<void> boot({String mode = ''}) async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = [
    'run',
    'app/test/fake_sidecar.ts',
    '1',
    if (mode.isNotEmpty) mode,
  ];
  await RpcClient.instance.start();

  engine = FakeEngine();
  container = ProviderContainer(
    overrides: [playbackEngineProvider.overrideWithValue(engine)],
  );
  container.read(playbackProvider);
}

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

void main() {
  setUp(() async => boot(mode: 'open-fails-once'));

  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('a STREAM_UNAVAILABLE open surfaces an error with a retry, not a dead end', () async {
    container.read(queueProvider.notifier).play(video('aaa'));
    await settle();

    final state = container.read(playbackProvider);
    expect(state.error, isNotNull);
    expect(state.errorRetry, RpcRetryMode.user);
    expect(state.canRetry, isTrue, reason: 'a `user` failure must offer a way out');
    expect(engine.opened, isEmpty, reason: 'nothing was handed to the player');
    // The video is still what the page is about — the error belongs to the open,
    // not to the identity of what the user asked for.
    expect(state.item?.id, 'aaa');
  });

  test('and the retry actually retries — the same video, from the top', () async {
    container.read(queueProvider.notifier).play(video('aaa'));
    await settle();
    expect(container.read(playbackProvider).canRetry, isTrue);

    await container.read(playbackProvider.notifier).retry();
    await settle();

    final state = container.read(playbackProvider);
    expect(state.error, isNull, reason: 'a successful retry must clear the error');
    expect(state.errorRetry, isNull);
    expect(state.source, isNotNull);
    expect(engine.opened, hasLength(1));
    expect(engine.opened.single.videoUrl, contains('aaa'));
  });

  test('an error does not stop the queue from moving on', () async {
    final queue = container.read(queueProvider.notifier);
    queue.play(video('aaa'));
    await settle();
    expect(container.read(playbackProvider).error, isNotNull);

    queue.play(video('bbb'));
    await settle();

    expect(container.read(playbackProvider).error, isNull);
    expect(engine.opened.single.videoUrl, contains('bbb'));
  });
}
