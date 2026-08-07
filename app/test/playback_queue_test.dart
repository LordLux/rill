/// The queue driving the player, against a real sidecar process.
///
/// `fake_sidecar.ts` answers `playback.open`, `playback.report` and
/// `playback.close` and records every one of them, so these assert what the app
/// actually put on the wire rather than what a mock was told to expect. The
/// player is a [FakeEngine] — `flutter test` has no libmpv — which is also what
/// makes "the media ended" a thing a test can cause.
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

/// Start a fresh sidecar and container.
///
/// The 150 ms pause is the same one `feed_supersede_test.dart` needs: a killed
/// process's stdout `onDone` arrives asynchronously, and a stale callback landing
/// after the next test has spawned its replacement tears the new one down.
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
  // Construct the controller: its queue listener is registered in `build`, so
  // nothing plays until something has read it.
  container.read(playbackProvider);
}

Future<void> settle([int millis = 200]) => Future<void>.delayed(Duration(milliseconds: millis));

/// What the fake sidecar saw.
Future<({List<dynamic> opens, List<dynamic> reports, List<dynamic> closes})> log() async {
  final response = await RpcClient.instance.call('test.playbackLog', {}) as Map<String, dynamic>;
  return (
    opens: response['opens'] as List<dynamic>,
    reports: response['reports'] as List<dynamic>,
    closes: response['closes'] as List<dynamic>,
  );
}

List<String> reportedStates(List<dynamic> reports) =>
    reports.map((r) => (r as Map<String, dynamic>)['state'] as String).toList();

void main() {
  setUp(() async => boot());

  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('adding to an empty queue while nothing plays starts playback', () async {
    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle();

    expect(engine.opened, hasLength(1));
    expect(engine.opened.single.videoUrl, contains('aaa'));
    expect(container.read(playbackProvider).item?.id, 'aaa');
  });

  test('adding while something plays does not interrupt it', () async {
    final queue = container.read(queueProvider.notifier);
    queue.addToQueue(video('aaa'));
    await settle();

    queue.addToQueue(video('bbb'));
    await settle();

    // Two in the queue, one opened. The second must not have taken over.
    expect(container.read(queueProvider).items, hasLength(2));
    expect(engine.opened, hasLength(1));
    expect(container.read(playbackProvider).item?.id, 'aaa');
  });

  test('play next does not interrupt either — only its position in line changes', () async {
    final queue = container.read(queueProvider.notifier);
    queue.addToQueue(video('aaa'));
    await settle();
    queue.addToQueue(video('bbb'));
    queue.playNext(video('ccc'));
    await settle();

    expect(container.read(queueProvider).items.map((i) => i.id), ['aaa', 'ccc', 'bbb']);
    expect(engine.opened, hasLength(1));
  });

  test('autoplay advances when the media ends', () async {
    final queue = container.read(queueProvider.notifier);
    queue.addToQueue(video('aaa'));
    queue.addToQueue(video('bbb'));
    await settle();
    expect(engine.opened, hasLength(1));

    engine.complete();
    await settle();

    expect(engine.opened, hasLength(2));
    expect(engine.opened.last.videoUrl, contains('bbb'));
    expect(container.read(queueProvider).currentIndex, 1);
  });

  test('a queue that runs out stops rather than looping', () async {
    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle();

    engine.complete();
    await settle();

    // Nothing else opened, and the cursor did not move or wrap.
    expect(engine.opened, hasLength(1));
    expect(container.read(queueProvider).currentIndex, 0);
  });

  test('the item after the current one is preloaded, without opening a session', () async {
    final queue = container.read(queueProvider.notifier);
    queue.addToQueue(video('aaa'));
    queue.addToQueue(video('bbb'));
    await settle();

    final opens = (await log()).opens.cast<Map<String, dynamic>>();
    expect(
      opens.where((o) => o['videoId'] == 'bbb' && o['preload'] == true),
      hasLength(1),
      reason: 'the next item is resolved ahead of time (§3.6)',
    );
    expect(
      opens.where((o) => o['videoId'] == 'aaa' && o['preload'] == false),
      hasLength(1),
      reason: 'and the one actually playing opens for real',
    );
  });

  test('ending a video reports it as ended and closes its session', () async {
    container.read(queueProvider.notifier).addToQueue(video('aaa'));
    await settle();
    engine.emitPosition(const Duration(minutes: 9));
    engine.complete();
    await settle();

    final seen = await log();
    expect(reportedStates(seen.reports), contains('ended'));
    expect(seen.closes, isNotEmpty);
  });

  test('switching videos closes the old session before the new one reports', () async {
    final queue = container.read(queueProvider.notifier);
    queue.play(video('aaa'));
    await settle();
    queue.play(video('bbb'));
    await settle();

    final seen = await log();
    expect(seen.closes, hasLength(1));
    // Two sessions, and the reports name both — a report against a closed
    // session is BAD_REQUEST on the sidecar side, so these must not be mixed up.
    final sessions =
        seen.reports.map((r) => (r as Map<String, dynamic>)['sessionId']).toSet();
    expect(sessions, hasLength(2));
  });

  test('jumping to a queue entry plays it', () async {
    final queue = container.read(queueProvider.notifier);
    queue.addToQueue(video('aaa'));
    queue.addToQueue(video('bbb'));
    await settle();

    queue.jumpTo(1);
    await settle();

    expect(engine.opened.last.videoUrl, contains('bbb'));
  });

  test('removing an earlier entry does not restart the video that is playing', () async {
    final queue = container.read(queueProvider.notifier);
    queue.addToQueue(video('aaa'));
    queue.addToQueue(video('bbb'));
    await settle();
    queue.jumpTo(1);
    await settle();
    expect(engine.opened, hasLength(2));

    // The cursor shifts from 1 to 0 while still pointing at the same video.
    queue.removeAt(0);
    await settle();

    expect(engine.opened, hasLength(2), reason: 'an index shift is not a new video');
    expect(container.read(queueProvider).current?.id, 'bbb');
  });
}
