/// `playback.report` from the app's side — the cadence, and the failures.
///
/// The sidecar's own tests cover what a report *is*; these cover the half only
/// the app can get wrong. A client that pings once at completion satisfies every
/// assertion about ping shape and still starves the recommender, which is the
/// failure `architecture.md` §2.4 says defeats the point of the product.
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

Future<List<Map<String, dynamic>>> reports() async {
  final response = await RpcClient.instance.call('test.playbackLog', {}) as Map<String, dynamic>;
  return (response['reports'] as List<dynamic>).cast<Map<String, dynamic>>();
}

Future<void> settle([int millis = 200]) => Future<void>.delayed(Duration(milliseconds: millis));

void main() {
  final realInterval = PlaybackController.reportInterval;

  setUp(() async {
    // 120 ms stands in for 15 s. The property under test is that a timer exists
    // and keeps firing, not the specific number of seconds.
    PlaybackController.reportInterval = const Duration(milliseconds: 120);
    await boot();
  });

  tearDown(() async {
    PlaybackController.reportInterval = realInterval;
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('the app reports on a cadence, not only at completion', () async {
    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle();

    for (var second = 1; second <= 4; second++) {
      engine.emitPosition(Duration(seconds: second * 10));
      await settle(130);
    }

    final seen = await reports();
    expect(
      seen.length,
      greaterThanOrEqualTo(4),
      reason: 'one report per interval, plus the one at open: got ${seen.length}',
    );
    expect(
      seen.every((r) => r['state'] != 'ended'),
      isTrue,
      reason: 'nothing has ended — these are all mid-watch reports',
    );

    // And the positions move, which is what makes them a watch rather than four
    // copies of the same ping.
    final positions = seen.map((r) => r['positionMs'] as int).toSet();
    expect(positions.length, greaterThan(1));
  });

  test('the first report goes out immediately — a short watch still counts', () async {
    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle(80);
    expect(await reports(), isNotEmpty);
  });

  test('a pause is reported as a state change, without waiting for the tick', () async {
    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle();
    final before = (await reports()).length;

    engine.setPlaying(false);
    await settle(60);

    final after = await reports();
    expect(after.length, greaterThan(before));
    expect(after.last['state'], 'paused');
  });

  test('reports stop when the session closes', () async {
    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle();
    engine.complete();
    await settle(400);

    final seen = await reports();
    final endedAt = seen.indexWhere((r) => r['state'] == 'ended');
    expect(endedAt, isNot(-1));
    expect(
      seen.sublist(endedAt + 1),
      isEmpty,
      reason: 'a timer left running would report against a closed session forever',
    );
  });

  test('a report that fails is surfaced rather than swallowed', () async {
    // A client that has silently stopped contributing to its own
    // recommendations is the failure this project keeps being bitten by, so the
    // state has to be able to say so.
    container.dispose();
    await boot(mode: 'report-fails');

    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle(400);

    expect(container.read(playbackProvider).reportError, isNotNull);
    expect(container.read(playbackProvider).reportError, contains('403'));
  });

  test('and clears itself once reporting works again', () async {
    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle(400);
    expect(container.read(playbackProvider).reportError, isNull);
  });
}
