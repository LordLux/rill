/// What the session snapshot keeps, and what it refuses to read back (`docs/architecture.md` §2.17).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/session/session_snapshot.dart';

SnapshotVideo video(String id) => SnapshotVideo(id: id, title: 'Video $id', channelName: 'Channel', thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg');

SnapshotState stateAt(DateTime saved, {SnapshotPage page = SnapshotPage.home}) =>
    SnapshotState(positionMs: 42000, page: page, savedAtMs: saved.millisecondsSinceEpoch, volume: 35, preferredHeight: 720);

void main() {
  final now = DateTime(2026, 11, 9, 12);

  SessionSnapshot? read({String? queue, String? state, DateTime? at}) =>
      SessionSnapshot.read(queue: queue, state: state, now: at ?? now);

  test('a queue and its state come back as they went', () {
    final queue = SnapshotQueue(
      videos: [video('a'), video('b'), video('c')],
      currentIndex: 1,
      mix: const SnapshotMix(playlistId: 'PL1', title: 'List', isPlaylist: true, continuation: 'tok', totalCount: 9),
    );
    final state = stateAt(now, page: const SnapshotPage(SnapshotPageKind.search, 'lofi'));

    final back = read(queue: queue.encode(), state: state.encode())!;

    expect(back.queue.videos.map((v) => v.id), ['a', 'b', 'c']);
    expect(back.queue.currentIndex, 1);
    expect(back.queue.videos[1].title, 'Video b');
    expect(back.queue.mix?.playlistId, 'PL1');
    expect(back.queue.mix?.isPlaylist, isTrue);
    expect(back.queue.mix?.continuation, 'tok');
    expect(back.queue.mix?.totalCount, 9);
    expect(back.state.positionMs, 42000);
    expect(back.state.page, const SnapshotPage(SnapshotPageKind.search, 'lofi'));
    expect(back.state.volume, 35);
    expect(back.state.preferredHeight, 720);
  });

  test('it carries ids and display strings, and no URL but the thumbnail', () {
    final text = SnapshotQueue(videos: [video('a')], currentIndex: 0).encode() + stateAt(now).encode();
    expect(text, isNot(contains('cookie')));
    expect(text, isNot(contains('videoUrl')));
    expect(text, isNot(contains('audioUrl')));
    expect(text, isNot(contains('sessionId')));
  });

  group('what is ignored, never retried', () {
    final queue = SnapshotQueue(videos: [video('a')], currentIndex: 0).encode();
    final state = stateAt(now).encode();

    test('nothing at all', () => expect(read(), isNull));
    test('one part missing', () {
      expect(read(queue: queue), isNull);
      expect(read(state: state), isNull);
    });
    test('text that is not JSON', () => expect(read(queue: '{{{', state: state), isNull));
    test('JSON of the wrong shape', () {
      expect(read(queue: '[1,2]', state: state), isNull);
      expect(read(queue: queue, state: '"x"'), isNull);
    });
    test('another format', () {
      final other = (jsonDecode(queue) as Map<String, Object?>)..['v'] = SessionSnapshot.format + 1;
      expect(read(queue: jsonEncode(other), state: state), isNull);
    });
    test('a snapshot older than a week', () {
      final old = now.subtract(sessionSnapshotMaxAge + const Duration(minutes: 1));
      expect(read(queue: queue, state: stateAt(old).encode()), isNull);
      final recent = now.subtract(sessionSnapshotMaxAge - const Duration(minutes: 1));
      expect(read(queue: queue, state: stateAt(recent).encode()), isNotNull);
    });
    test('a current index that points at nothing', () {
      final bad = (jsonDecode(queue) as Map<String, Object?>)..['current'] = 5;
      expect(read(queue: jsonEncode(bad), state: state), isNull);
    });
  });

  test('a row that is not a video is dropped, and the playing one is still the one that plays', () {
    final json = {
      'v': SessionSnapshot.format,
      'videos': [
        {'id': 'a', 'title': 'A'},
        'garbage',
        {'id': 'c', 'title': 'C'},
        {'title': 'no id'},
        {'id': 'e', 'title': 'E'},
      ],
      'current': 4,
    };
    final back = SnapshotQueue.tryDecode(jsonEncode(json))!;
    expect(back.videos.map((v) => v.id), ['a', 'c', 'e']);
    expect(back.videos[back.currentIndex].id, 'e');
  });

  test('a page that needs its argument and has none is the home page', () {
    final json = jsonDecode(stateAt(now).encode()) as Map<String, Object?>
      ..['page'] = 'playlist'
      ..['pageArgument'] = null;
    expect(SnapshotState.tryDecode(jsonEncode(json))!.page, SnapshotPage.home);
    json['page'] = 'nonsense';
    expect(SnapshotState.tryDecode(jsonEncode(json))!.page, SnapshotPage.home);
  });

  test('a volume outside 0 to 100 is clamped and a height of zero is dropped', () {
    final json = jsonDecode(stateAt(now).encode()) as Map<String, Object?>
      ..['volume'] = 400
      ..['preferredHeight'] = 0;
    final back = SnapshotState.tryDecode(jsonEncode(json))!;
    expect(back.volume, 100);
    expect(back.preferredHeight, isNull);
  });

  group('a long list is cut to a window', () {
    final all = [for (var i = 0; i < 1200; i++) video('v$i')];

    test('around the playing row, with the index following it', () {
      final cut = SnapshotQueue.windowed(all, 700, null);
      expect(cut.videos, hasLength(sessionSnapshotMaxEntries));
      expect(cut.videos[cut.currentIndex].id, 'v700');
    });

    test('at the front, and at the back', () {
      expect(SnapshotQueue.windowed(all, 3, null).videos.first.id, 'v0');
      final end = SnapshotQueue.windowed(all, 1199, null);
      expect(end.videos.last.id, 'v1199');
      expect(end.videos[end.currentIndex].id, 'v1199');
    });

    test('a playlist that lost its tail stops there: its token no longer follows the rows kept', () {
      const mix = SnapshotMix(playlistId: 'PL', isPlaylist: true, continuation: 'tok');
      final cut = SnapshotQueue.windowed(all, 10, mix);
      expect(cut.mix!.continuation, isNull);
      expect(cut.mix!.exhausted, isTrue);
      // Cut at the front only, the tail is whole and the token still follows it.
      final tail = SnapshotQueue.windowed(all, 1199, mix);
      expect(tail.mix!.continuation, 'tok');
    });

    test('a list under the limit is left alone', () {
      final small = SnapshotQueue.windowed(all.take(20).toList(), 5, null);
      expect(small.videos, hasLength(20));
      expect(small.currentIndex, 5);
    });
  });
}
