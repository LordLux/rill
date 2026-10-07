/// Playlist playback in the queue — Task 34 §3 and §4.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/queue_controller.dart';

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

List<VideoItem> videos(int count, {int from = 0}) =>
    [for (var i = 0; i < count; i++) video('v${i + from}')];

class FakeMixService implements MixService {
  int startCalls = 0;
  int extendCalls = 0;
  int getPlaylistCalls = 0;
  
  String? lastContinuation;

  // For testing paging behavior.
  final int totalPages;
  int _pagesServed = 0;
  int _issued = 0;

  /// When set, the next continuation request waits on it instead of answering.
  Completer<PlaylistResult>? pendingPlaylist;

  FakeMixService({this.totalPages = 3});

  @override
  Future<MixStart> start(String playlistId, {String? videoId, String? params}) async {
    startCalls++;
    return MixStart(playlistId: playlistId, title: 'My Mix', items: videos(25));
  }

  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) async {
    extendCalls++;
    return const MixExtension(items: [], exhausted: true);
  }

  @override
  Future<PlaylistResult> getPlaylist(String playlistId, {String? continuation}) async {
    getPlaylistCalls++;
    lastContinuation = continuation;

    final pending = pendingPlaylist;
    if (pending != null && continuation != null) {
      pendingPlaylist = null;
      return pending.future;
    }
    if (continuation != null && failures > 0) {
      failures--;
      throw StateError('network down');
    }
    if (continuation != null && emptyPages > 0) {
      emptyPages--;
      _pagesServed++;
      return PlaylistResult(items: const [], continuation: 'token_$_pagesServed');
    }

    _pagesServed++;
    final bool isLast = _pagesServed >= totalPages;
    final items = videos(25, from: _issued);
    _issued += 25;

    return PlaylistResult(
      title: title,
      videoCount: videoCount,
      items: items,
      continuation: isLast ? null : 'token_$_pagesServed',
    );
  }

  /// What the sidecar says the playlist is called and how long it is — both
  /// null to stand in for a response that does not say.
  String? title = 'Playlist from the sidecar';
  int? videoCount;

  /// How many continuation requests fail before they start working.
  int failures = 0;

  /// How many continuation requests answer with no videos and a next token.
  int emptyPages = 0;

  /// The page a held continuation request will answer with.
  PlaylistResult lastPage(int count) =>
      PlaylistResult(items: videos(count, from: _issued), continuation: null);
}

ProviderContainer containerWith(MixService service) =>
    ProviderContainer(overrides: [mixServiceProvider.overrideWithValue(service)]);

QueueController controllerOf(ProviderContainer c) => c.read(queueProvider.notifier);
QueueState stateOf(ProviderContainer c) => c.read(queueProvider);

void main() {
  group('Starting a playlist', () {
    test('startPlaylist replaces the queue and marks it as a playlist', () async {
      // The second page is held, so this is the queue as the first one left it.
      final service = FakeMixService()..pendingPlaylist = Completer<PlaylistResult>();
      final c = containerWith(service);
      final queue = controllerOf(c);

      queue.addToQueue(video('old'));
      await queue.startPlaylist('VL123');

      final state = stateOf(c);
      expect(state.items, hasLength(25));
      expect(state.currentIndex, 0, reason: 'it plays from the first video without waiting for the rest');
      expect(state.mix, isNotNull);
      expect(state.mix!.playlistId, 'VL123');
      expect(state.mix!.isPlaylist, isTrue);
      expect(state.mix!.exhausted, isFalse);
      expect(state.mix!.continuation, 'token_1');
    });

    test('undo restores the previous queue', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);

      queue.addToQueue(video('old'));
      await queue.startPlaylist('VL123');
      expect(stateOf(c).items.first.id, isNot('old'));

      expect(queue.canUndoStartMix, isTrue);
      queue.undoStartMix();

      expect(stateOf(c).items, hasLength(1));
      expect(stateOf(c).items.first.id, 'old');
      expect(stateOf(c).mix, isNull);
    });
  });

  group('Playlist continuation', () {
    test('the next page is asked for at once, with the first page\'s token', () async {
      final service = FakeMixService()..pendingPlaylist = Completer<PlaylistResult>();
      final c = containerWith(service);

      await controllerOf(c).startPlaylist('VL123');

      expect(stateOf(c).currentIndex, 0, reason: 'nobody advanced: the playhead is not what asks');
      expect(service.getPlaylistCalls, 2);
      expect(service.lastContinuation, 'token_1');
    });

    test('every page loads, one after another, without the playhead moving', () async {
      final service = FakeMixService(totalPages: 4);
      final c = containerWith(service);

      await controllerOf(c).startPlaylist('VL123');
      await Future<void>.delayed(Duration.zero);

      expect(service.getPlaylistCalls, 4);
      expect(service.lastContinuation, 'token_3', reason: 'each page is asked for with the token before it');
      expect(stateOf(c).items.map((v) => v.id), [for (var i = 0; i < 100; i++) 'v$i'], reason: 'in order, nothing twice');
      expect(stateOf(c).currentIndex, 0);
      expect(stateOf(c).mix!.exhausted, isTrue);
    });

    test('a long playlist loads two hundred ahead of the playhead and stops', () async {
      final service = FakeMixService(totalPages: 40); // 1,000 videos, 25 a page
      final c = containerWith(service);
      final queue = controllerOf(c);

      await queue.startPlaylist('VL123');
      await Future<void>.delayed(Duration.zero);

      // 225: the first count at which 200 or more follow the one playing.
      expect(stateOf(c).items, hasLength(225));
      expect(service.getPlaylistCalls, 9);
      expect(stateOf(c).mix!.exhausted, isFalse);

      // The margin follows the playhead: one more page once it is eaten into.
      for (var i = 0; i < 25; i++) { queue.advance(); }
      await Future<void>.delayed(Duration.zero);
      expect(stateOf(c).items, hasLength(250));
      expect(stateOf(c).remainingAfterCurrent, greaterThanOrEqualTo(QueueController.playlistLookahead));
    });

    test('scrolling to the end of what is loaded fetches one more page, and only one', () async {
      final service = FakeMixService(totalPages: 40);
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startPlaylist('VL123');
      await Future<void>.delayed(Duration.zero);
      final calls = service.getPlaylistCalls;

      // A scroll reports on every frame; that is still one request.
      queue.loadMoreOfPlaylist();
      queue.loadMoreOfPlaylist();
      queue.loadMoreOfPlaylist();
      await Future<void>.delayed(Duration.zero);

      expect(service.getPlaylistCalls, calls + 1);
      expect(stateOf(c).items, hasLength(250));
      expect(stateOf(c).currentIndex, 0);
    });

    test('scrolling asks for nothing from a mix or a finished playlist', () async {
      final service = FakeMixService(totalPages: 2);
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startPlaylist('VL123');
      await Future<void>.delayed(Duration.zero);
      expect(stateOf(c).mix!.exhausted, isTrue);
      queue.loadMoreOfPlaylist();
      await Future<void>.delayed(Duration.zero);
      expect(service.getPlaylistCalls, 2);

      await queue.startMix('RD123');
      queue.loadMoreOfPlaylist();
      await Future<void>.delayed(Duration.zero);
      expect(service.extendCalls, 0, reason: 'a mix keeps its own threshold');
      expect(service.getPlaylistCalls, 2);
    });

    test('one page at a time: a mutation while one is out does not ask again', () async {
      final service = FakeMixService()..pendingPlaylist = Completer<PlaylistResult>();
      final c = containerWith(service);
      final queue = controllerOf(c);

      await queue.startPlaylist('VL123');
      for (var i = 0; i < 10; i++) { queue.advance(); }
      await Future<void>.delayed(Duration.zero);

      expect(service.getPlaylistCalls, 2, reason: 'the held page is still the only one out');
    });

    test('it stops fetching when continuation is null', () async {
      final service = FakeMixService(totalPages: 2);
      final c = containerWith(service);
      final queue = controllerOf(c);

      await queue.startPlaylist('VL123');
      await Future<void>.delayed(Duration.zero);
      expect(service.getPlaylistCalls, 2);
      expect(stateOf(c).items, hasLength(50));
      expect(stateOf(c).mix!.exhausted, isTrue, reason: 'a null continuation exhausts the list source');

      // Every one of these re-evaluates the top-up. None may ask again.
      for (var i = 0; i < 49; i++) { queue.advance(); }
      await Future<void>.delayed(Duration.zero);

      expect(service.getPlaylistCalls, 2, reason: 'no fetch should happen because continuation is null');
      expect(service.extendCalls, 0, reason: 'should not extend a playlist like a mix');
    });

    test('a mix still extends by re-anchoring, playlists do not use extend', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);

      await queue.startMix('RD123');
      expect(service.startCalls, 1);
      expect(stateOf(c).mix!.isPlaylist, isFalse);

      for (var i = 0; i < 19; i++) { queue.advance(); }
      await Future<void>.delayed(Duration.zero);
      
      expect(service.extendCalls, 1, reason: 'mixes must use extend');
      expect(service.getPlaylistCalls, 0, reason: 'mixes must not use getPlaylist');
    });
  });

  group('When paging goes wrong', () {
    test('a page that is put back while its request is out is not appended twice', () async {
      // Playlist A, with its second page held on the wire.
      final service = FakeMixService(totalPages: 2);
      final c = containerWith(service);
      final queue = controllerOf(c);
      final heldA = Completer<PlaylistResult>();
      service.pendingPlaylist = heldA;
      await queue.startPlaylist('PLaaa');
      expect(stateOf(c).items, hasLength(25));

      // Start B over it (one page, so it asks for nothing more), then undo: A
      // is back, and asks for its second page again. That request is held too.
      await queue.startPlaylist('PLbbb');
      final asked = service.getPlaylistCalls;
      final heldAgain = Completer<PlaylistResult>();
      service.pendingPlaylist = heldAgain;
      queue.undoStartMix();
      expect(stateOf(c).mix!.playlistId, 'PLaaa');
      expect(service.getPlaylistCalls, asked + 1, reason: 'the restored queue pages on a request of its own');

      // The first request for that page answers. It is nobody's now.
      heldA.complete(PlaylistResult(items: videos(25, from: 500), continuation: null));
      await Future<void>.delayed(Duration.zero);
      expect(stateOf(c).items.map((v) => v.id), isNot(contains('v500')), reason: 'the abandoned answer is dropped');
      expect(stateOf(c).mix!.exhausted, isFalse, reason: 'and it does not end the list either');

      // The live one answers, and the page is there once.
      heldAgain.complete(PlaylistResult(items: videos(25, from: 500), continuation: null));
      await Future<void>.delayed(Duration.zero);
      final ids = stateOf(c).items.map((v) => v.id).toList();
      expect(ids, hasLength(50));
      expect(ids.toSet(), hasLength(50), reason: 'no video twice');
    });

    test('a page with nothing playable on it does not stop the loader', () async {
      final service = FakeMixService(totalPages: 3)..emptyPages = 1;
      final c = containerWith(service);

      await controllerOf(c).startPlaylist('PL123');
      await Future<void>.delayed(Duration.zero);

      expect(stateOf(c).mix!.exhausted, isTrue, reason: 'it carried on past the empty page to the end');
      expect(stateOf(c).items, hasLength(50));
      expect(stateOf(c).currentIndex, 0);
    });

    test('a failed page keeps the queue, says so, and is retried on the next queue change', () async {
      final service = FakeMixService(totalPages: 2)..failures = 1;
      final c = containerWith(service);
      final queue = controllerOf(c);

      await queue.startPlaylist('PL123');
      await Future<void>.delayed(Duration.zero);

      expect(stateOf(c).items, hasLength(25), reason: 'what loaded is kept');
      expect(stateOf(c).mix!.exhausted, isFalse, reason: 'a failure is not the end');
      expect(queue.mixError, contains('network down'));
      final asked = service.getPlaylistCalls;

      // Autoplay moving on is a queue change, and that is the retry.
      queue.advance();
      await Future<void>.delayed(Duration.zero);

      expect(service.getPlaylistCalls, asked + 1);
      expect(queue.mixError, isNull);
      expect(stateOf(c).items, hasLength(50));
      expect(stateOf(c).mix!.exhausted, isTrue);
    });
  });

  group('What the panel is told', () {
    test('the sidecar names and sizes the playlist; the tile fills in where it does not', () async {
      final service = FakeMixService()..videoCount = 135;
      final c = containerWith(service);
      await controllerOf(c).startPlaylist('PL123', title: 'Tile title', videoCount: 8);

      expect(stateOf(c).mix!.title, 'Playlist from the sidecar');
      expect(stateOf(c).mix!.totalCount, 135);

      final silent = FakeMixService()..title = null;
      final c2 = containerWith(silent);
      await controllerOf(c2).startPlaylist('PL123', title: 'Tile title', videoCount: 135);

      expect(stateOf(c2).mix!.title, 'Tile title');
      expect(stateOf(c2).mix!.totalCount, 135);
    });

    test('the length shown is the playlist\'s until the last page lands, then the queue\'s', () async {
      // 60 claimed, 50 playable: ten unavailable entries never reach the queue.
      final service = FakeMixService(totalPages: 2)..videoCount = 60;
      final c = containerWith(service);
      final queue = controllerOf(c);

      final held = Completer<PlaylistResult>();
      service.pendingPlaylist = held;
      await queue.startPlaylist('PL123');
      expect(stateOf(c).items, hasLength(25));
      expect(stateOf(c).displayLength, 60, reason: 'more pages to come: the first page is not the playlist');

      held.complete(service.lastPage(25));
      await Future<void>.delayed(Duration.zero);

      expect(stateOf(c).mix!.exhausted, isTrue);
      expect(stateOf(c).displayLength, 50, reason: 'everything is here, so the real length is known');
    });

    test('a mix never borrows a total', () async {
      final c = containerWith(FakeMixService());
      await controllerOf(c).startMix('RD123');
      expect(stateOf(c).displayLength, stateOf(c).items.length);
    });
  });

  group('The end of a playlist', () {
    test('exhausted is not played out: the last page landing ends nothing', () async {
      final service = FakeMixService(totalPages: 1);
      final c = containerWith(service);
      await controllerOf(c).startPlaylist('PL123');

      expect(stateOf(c).mix!.exhausted, isTrue, reason: 'one page, no continuation');
      expect(stateOf(c).playedOut, isFalse, reason: '25 videos are still to play');
    });

    test('played out only when the last video finishes', () async {
      final service = FakeMixService(totalPages: 1);
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startPlaylist('PL123');

      // A video that is not the last finishing is just autoplay.
      queue.playedOut();
      expect(stateOf(c).playedOut, isFalse);

      for (var i = 0; i < 24; i++) { queue.advance(); }
      expect(stateOf(c).next, isNull);
      expect(stateOf(c).playedOut, isFalse, reason: 'the last video is playing, not finished');

      // Next on the last video goes nowhere and finishes nothing.
      expect(queue.advance(), isFalse);
      expect(stateOf(c).playedOut, isFalse);

      final version = stateOf(c).version;
      queue.playedOut();
      expect(stateOf(c).playedOut, isTrue);
      expect(stateOf(c).version, version, reason: 'nothing reopens');

      // Going back is a new playhead, and no longer the end.
      queue.back();
      expect(stateOf(c).playedOut, isFalse);
    });

    test('a last page that arrives after playback stalled is played, not skipped', () async {
      final service = FakeMixService(totalPages: 3);
      final c = containerWith(service);
      final queue = controllerOf(c);
      // Hold the next page, then run to the end of the first one.
      final held = Completer<PlaylistResult>();
      service.pendingPlaylist = held;
      await queue.startPlaylist('PL123');
      for (var i = 0; i < 24; i++) { queue.advance(); }
      expect(queue.advance(), isFalse, reason: 'nothing to advance to yet');
      queue.playedOut();
      expect(stateOf(c).playedOut, isFalse, reason: 'a page is still on the wire');

      // It lands as the last page: exhausted, and with videos on it.
      held.complete(service.lastPage(3));
      await Future<void>.delayed(Duration.zero);

      expect(stateOf(c).items, hasLength(28));
      expect(stateOf(c).mix!.exhausted, isTrue);
      expect(stateOf(c).currentIndex, 25, reason: 'playback moves onto what arrived');
      expect(stateOf(c).playedOut, isFalse);
    });

    test('a stalled playlist whose last page is empty is played out', () async {
      final service = FakeMixService(totalPages: 3);
      final c = containerWith(service);
      final queue = controllerOf(c);
      final held = Completer<PlaylistResult>();
      service.pendingPlaylist = held;
      await queue.startPlaylist('PL123');
      for (var i = 0; i < 24; i++) { queue.advance(); }
      queue.advance();
      queue.playedOut();

      held.complete(service.lastPage(0));
      await Future<void>.delayed(Duration.zero);

      expect(stateOf(c).currentIndex, 24);
      expect(stateOf(c).playedOut, isTrue);
    });
  });
}
