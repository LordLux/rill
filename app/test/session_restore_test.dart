/// Picking up where the viewer left off (`docs/architecture.md` §2.17): what a start does with the last
/// session, what the writer keeps, and what the updater leaves for the start that follows it.
///
/// Against the fake sidecar and a [FakeEngine], like `playback_queue_test.dart`, so "opened paused" is read off
/// what the engine was actually told.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/data/session/session_snapshot.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/pages/playlist.dart' show playlistRouteName;
import 'package:rill/ui/pages/search_results.dart' show searchRouteName;
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player_shell.dart' show currentRouteArgumentProvider, currentRouteProvider, watchRouteName;
import 'package:rill/ui/queue_controller.dart';
import 'package:rill/ui/session_restore.dart';

import 'fake_engine.dart';

VideoItem video(String id, {bool live = false}) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: live,
      canWatchLater: true,
      canAddToQueue: true,
    );

class FakeMixService implements MixService {
  @override
  Future<MixStart> start(String id, {String? videoId, String? params}) async => MixStart(playlistId: id, items: [video('aaa')]);
  @override
  Future<MixExtension> extend(String id, String after) async => const MixExtension(items: [], exhausted: true);
  @override
  Future<PlaylistResult> getPlaylist(String id, {String? continuation}) async => PlaylistResult(items: [video('aaa')]);
}

class MemoryStore implements SessionStore {
  String? queue;
  String? state;
  bool marker = false;
  int clears = 0;
  final List<String> writes = [];

  /// Called as the stored copy is removed, to read what the app had done by then.
  void Function()? onClear;

  @override
  Future<String?> readQueue() async => queue;
  @override
  Future<String?> readState() async => state;
  @override
  Future<void> writeQueue(String value) async {
    queue = value;
    writes.add('queue');
  }

  @override
  Future<void> writeState(String value) async {
    state = value;
    writes.add('state');
  }

  @override
  Future<void> clear() async {
    queue = null;
    state = null;
    clears++;
    onClear?.call();
  }

  @override
  Future<void> setUpdateMarker(bool value) async => marker = value;
  @override
  Future<bool> takeUpdateMarker() async {
    final was = marker;
    marker = false;
    return was;
  }
}

late FakeEngine engine;
late ProviderContainer container;
late MemoryStore store;

Future<void> boot({bool setting = false}) async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  await RpcClient.instance.start();

  engine = FakeEngine();
  store = MemoryStore();
  container = ProviderContainer(
    overrides: [
      playbackEngineProvider.overrideWithValue(engine),
      mixServiceProvider.overrideWithValue(FakeMixService()),
      sessionStoreProvider.overrideWithValue(store),
      restoreSessionProvider.overrideWith(() => RestoreSessionController(initial: setting)),
    ],
  );
  container.read(playbackProvider);
}

Future<void> settle([int millis = 200]) => Future<void>.delayed(Duration(milliseconds: millis));

/// A stored session: three videos, the second playing, 95 s in.
void leaveSession({List<String> ids = const ['aaa', 'bbb', 'ccc'], DateTime? savedAt, SnapshotPage page = const SnapshotPage(SnapshotPageKind.watch), SnapshotMix? mix}) {
  store.queue = SnapshotQueue(
    videos: [for (final id in ids) SnapshotVideo(id: id, title: 'Video $id', channelName: 'Channel', thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg')],
    currentIndex: 1,
    mix: mix,
  ).encode();
  store.state = SnapshotState(
    positionMs: 95000,
    page: page,
    savedAtMs: (savedAt ?? DateTime.now()).millisecondsSinceEpoch,
    volume: 40,
    preferredHeight: 720,
  ).encode();
}

Future<List<SnapshotPage>> start() async {
  final pages = <SnapshotPage>[];
  await restoreSessionOnStart(container, firstFrame: () async {}, openPage: pages.add);
  await settle();
  return pages;
}

void main() {
  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  group('a start', () {
    test('with the setting on puts the queue, the place and the page back, paused', () async {
      await boot(setting: true);
      leaveSession(mix: const SnapshotMix(playlistId: 'PL9', title: 'A list', isPlaylist: true, exhausted: true));

      final pages = await start();

      final queue = container.read(queueProvider);
      expect(queue.items.map((i) => i.id), ['aaa', 'bbb', 'ccc']);
      expect(queue.current?.id, 'bbb');
      expect(queue.items[1].title, 'Video bbb', reason: 'the rows read as themselves before anything is fetched');
      expect(queue.mix?.playlistId, 'PL9');
      expect(queue.mix?.isPlaylist, isTrue);

      expect(engine.opened, hasLength(1));
      expect(engine.opened.single.videoUrl, contains('bbb'));
      expect(engine.playing, isFalse, reason: 'sound starting by itself on launch is a surprise');
      expect(engine.seeks, contains(const Duration(seconds: 95)));
      expect(engine.volumes, contains(40));
      expect(container.read(playbackProvider.notifier).preferredHeight, 720);
      expect(pages, [const SnapshotPage(SnapshotPageKind.watch)]);
    });

    test('with the setting off and no update is a fresh start, and what was kept is removed', () async {
      await boot();
      leaveSession();

      final pages = await start();

      expect(container.read(queueProvider).isEmpty, isTrue);
      expect(engine.opened, isEmpty);
      expect(pages, isEmpty);
      expect(store.queue, isNull);
      expect(store.state, isNull);
    });

    test('after an update restores whatever the setting says, and reads the marker once', () async {
      await boot();
      leaveSession();
      store.marker = true;

      await start();

      expect(container.read(queueProvider).current?.id, 'bbb');
      expect(engine.playing, isFalse);
      expect(store.marker, isFalse, reason: 'it applies to one start');
    });

    test('is applied once: the stored copy goes before anything is applied', () async {
      await boot(setting: true);
      leaveSession();
      bool? queueEmptyWhenRemoved;
      bool? openedWhenRemoved;
      store.onClear = () {
        queueEmptyWhenRemoved ??= container.read(queueProvider).isEmpty;
        openedWhenRemoved ??= engine.opened.isNotEmpty;
      };

      await start();

      expect(queueEmptyWhenRemoved, isTrue, reason: 'a snapshot that crashes the app on the way in must already be gone');
      expect(openedWhenRemoved, isFalse);
      expect(container.read(queueProvider).current?.id, 'bbb');
    });

    test('ignores a snapshot that is corrupt, and does not throw', () async {
      await boot(setting: true);
      store.queue = '{{{ not json';
      store.state = '[]';

      await start();

      expect(container.read(queueProvider).isEmpty, isTrue);
      expect(engine.opened, isEmpty);
      expect(store.queue, isNull, reason: 'removed, not retried');
    });

    test('ignores a snapshot older than a week', () async {
      await boot(setting: true);
      leaveSession(savedAt: DateTime.now().subtract(const Duration(days: 8)));

      await start();

      expect(container.read(queueProvider).isEmpty, isTrue);
      expect(engine.opened, isEmpty);
    });

    test('leaves alone what the viewer started before the store answered', () async {
      await boot(setting: true);
      leaveSession();
      container.read(queueProvider.notifier).addToQueue(video('mine'));

      await start();

      expect(container.read(queueProvider).items.map((i) => i.id), ['mine']);
    });

    test('puts back a playlist page and a search page', () async {
      await boot(setting: true);
      leaveSession(page: const SnapshotPage(SnapshotPageKind.playlist, 'PL42'));
      expect(await start(), [const SnapshotPage(SnapshotPageKind.playlist, 'PL42')]);

      container.dispose();
      await boot(setting: true);
      leaveSession(page: const SnapshotPage(SnapshotPageKind.search, 'lofi beats'));
      expect(await start(), [const SnapshotPage(SnapshotPageKind.search, 'lofi beats')]);
    });

    test('opens the next video it is not about playing, not paused', () async {
      await boot(setting: true);
      leaveSession();
      await start();
      expect(engine.playing, isFalse);

      container.read(queueProvider.notifier).play(video('later'));
      await settle();

      expect(container.read(playbackProvider).item?.id, 'later');
      expect(engine.playing, isTrue, reason: 'the pause was for the restored video, once');
    });

    test('a video that cannot be opened lands on the ordinary error and is not retried', () async {
      await boot(setting: true);
      leaveSession(ids: ['aaa', 'broken1', 'ccc']);

      await start();
      await settle(400);

      expect(engine.opened, isEmpty);
      expect(container.read(playbackProvider).error, isNotNull);
      final log = await RpcClient.instance.call('test.playbackLog', {}) as Map<String, dynamic>;
      final opens = (log['opens'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(opens.where((o) => o['videoId'] == 'broken1' && o['preload'] != true), hasLength(1));
    });
  });

  group('the writer', () {
    setUp(() async => boot(setting: true));

    SessionWriter writer() => container.read(sessionWriterProvider);

    test('writes nothing until it is enabled', () async {
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      await settle();
      expect(store.writes, isEmpty);
    });

    test('writes the queue when it changes, and only what differs', () async {
      writer().enable();
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      container.read(queueProvider.notifier).addToQueue(video('bbb'));
      await settle(300);
      await writer().flush();

      final queue = SnapshotQueue.tryDecode(store.queue)!;
      expect(queue.videos.map((v) => v.id), ['aaa', 'bbb']);
      expect(queue.currentIndex, 0);

      final queueWrites = store.writes.where((w) => w == 'queue').length;
      await writer().flush();
      await writer().flush();
      expect(store.writes.where((w) => w == 'queue').length, queueWrites, reason: 'an unchanged queue is not rewritten');
    });

    test('keeps the place, the page and the volume', () async {
      writer().enable();
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      await settle(300);
      engine.emitPosition(const Duration(seconds: 61));
      await engine.setVolume(55);
      container.read(currentRouteProvider.notifier).set(searchRouteName);
      container.read(currentRouteArgumentProvider.notifier).set('lofi');
      await writer().flush();

      final state = SnapshotState.tryDecode(store.state)!;
      expect(state.positionMs, 61000);
      expect(state.volume, 55);
      expect(state.page, const SnapshotPage(SnapshotPageKind.search, 'lofi'));
    });

    test('names each page the app can come back to, and every other one is home', () async {
      writer().enable();
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      await settle(300);

      Future<SnapshotPage> pageFor(String? route, Object? argument) async {
        container.read(currentRouteProvider.notifier).set(route);
        container.read(currentRouteArgumentProvider.notifier).set(argument);
        await writer().flush();
        return SnapshotState.tryDecode(store.state)!.page;
      }

      expect(await pageFor(watchRouteName, null), const SnapshotPage(SnapshotPageKind.watch));
      expect(await pageFor(playlistRouteName, 'PL1'), const SnapshotPage(SnapshotPageKind.playlist, 'PL1'));
      expect(await pageFor(playlistRouteName, null), SnapshotPage.home, reason: 'no id, nothing to open');
      expect(await pageFor('subscriptions', null), SnapshotPage.home);
      expect(await pageFor('/', null), SnapshotPage.home);
    });

    test('keeps no place for a live stream', () async {
      writer().enable();
      container.read(queueProvider.notifier).addToQueue(video('live1', live: true));
      await settle(300);
      engine.emitPosition(const Duration(seconds: 500));
      await writer().flush();
      expect(SnapshotState.tryDecode(store.state)!.positionMs, 0);
    });

    test('removes what it wrote when the queue is empty', () async {
      writer().enable();
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      await settle(300);
      await writer().flush();
      expect(store.queue, isNotNull);

      container.read(queueProvider.notifier).clear();
      await writer().flush();
      expect(store.queue, isNull);
      expect(store.state, isNull);
    });

    test('turning the setting off removes what was kept, and stops writing', () async {
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      await container.read(restoreSessionProvider.notifier).setEnabled(false);
      await container.read(restoreSessionProvider.notifier).setEnabled(true);
      await settle(300);
      expect(store.queue, isNotNull);

      await container.read(restoreSessionProvider.notifier).setEnabled(false);
      expect(store.queue, isNull);
      container.read(queueProvider.notifier).addToQueue(video('bbb'));
      await settle(1300);
      expect(store.queue, isNull);
    });
  });

  group('the updater', () {
    setUp(() async => boot());

    test('saves the session and leaves the marker, whatever the setting', () async {
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      await settle(300);
      expect(container.read(restoreSessionProvider), isFalse);
      expect(store.queue, isNull);

      await container.read(sessionWriterProvider).prepareForUpdate();

      expect(store.marker, isTrue);
      expect(SnapshotQueue.tryDecode(store.queue)!.videos.single.id, 'aaa');
      expect(SnapshotState.tryDecode(store.state), isNotNull);
    });

    test('a start that follows brings it back, paused', () async {
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      await settle(300);
      engine.emitPosition(const Duration(seconds: 33));
      await container.read(sessionWriterProvider).prepareForUpdate();

      // The next process.
      final saved = (queue: store.queue, state: store.state);
      container.dispose();
      await boot();
      store.queue = saved.queue;
      store.state = saved.state;
      store.marker = true;
      await start();

      expect(container.read(queueProvider).current?.id, 'aaa');
      expect(engine.playing, isFalse);
      expect(engine.seeks, contains(const Duration(seconds: 33)));
    });

    test('an install that did not start takes the marker and the copy back, for a viewer with the setting off', () async {
      container.read(queueProvider.notifier).addToQueue(video('aaa'));
      await settle(300);
      await container.read(sessionWriterProvider).prepareForUpdate();

      await container.read(sessionWriterProvider).cancelUpdate();

      expect(store.marker, isFalse);
      expect(store.queue, isNull);
    });

    test('with nothing playing it still leaves the marker and no snapshot', () async {
      await container.read(sessionWriterProvider).prepareForUpdate();
      expect(store.marker, isTrue);
      expect(store.queue, isNull);
    });
  });
}
