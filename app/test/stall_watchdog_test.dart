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

  engine = FakeEngine();
  container = ProviderContainer(
    overrides: [playbackEngineProvider.overrideWithValue(engine)],
  );
  container.read(playbackProvider);
}

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

void main() {
  setUp(() async {
    PlaybackController.stallGrace = const Duration(milliseconds: 100);
    await boot();
  });

  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('a stalled stream is reopened once', () async {
    container.read(queueProvider.notifier).play(video('aaa'));
    await settle(150); // wait past grace period
    
    // It should have reopened exactly once.
    expect(engine.opened.length, 2);
  });

  test('a stream that starts normally is NOT reopened', () async {
    container.read(queueProvider.notifier).play(video('aaa'));
    await settle(50);
    
    engine.emitPosition(const Duration(milliseconds: 10)); // started playing
    await settle(150); // wait past grace period
    
    expect(engine.opened.length, 1);
  });

  test('a paused stream is not reopened', () async {
    container.read(queueProvider.notifier).play(video('aaa'));
    await settle(50);
    
    engine.setPlaying(false);
    await settle(150);
    
    expect(engine.opened.length, 1);
  });

  test('it never reopens twice', () async {
    container.read(queueProvider.notifier).play(video('aaa'));
    await settle(50); // first open finishes
    
    // Wait for the first grace period to trigger the reopen.
    await settle(150);
    expect(engine.opened.length, 2);
    
    // Wait for the second grace period to trigger the give-up logic.
    await settle(150);
    
    expect(engine.opened.length, 2, reason: 'should give up, not reopen again');
    final state = container.read(playbackProvider);
    expect(state.error, isNotNull);
  });
}
