/// Mixes in the queue — Task 26 §3 and §4.
///
/// The extension policy is the part worth testing and the part easiest to get
/// silently wrong. The task names the specific trap: *"a test that advances to
/// the end and asserts more items arrived passes if the fetch fires on every
/// advance."* So every test here asserts the **fetch count**, not just that the
/// queue grew.
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

/// A counting stand-in for the two RPCs.
class FakeMixService implements MixService {
  FakeMixService({this.pageSize = 24, this.pages = 1000, this.failExtends = false});

  int startCalls = 0;
  int extendCalls = 0;

  /// Every `afterVideoId` this was asked for, in order — the anchor arithmetic.
  final List<String> anchors = [];

  final int pageSize;

  /// How many extensions yield items before the mix reports itself exhausted.
  final int pages;

  bool failExtends;
  int _issued = 0;
  int _pagesServed = 0;

  /// Completers so a test can hold an extension in flight and fire more
  /// advances underneath it — which is the only way to see the single-flight
  /// guard actually do something.
  Completer<MixExtension>? pending;

  /// The same, for `start` — a real `mix.start` takes ~0.5-1 s, which is the
  /// whole window the double-tap bug lived in.
  Completer<void>? pendingStart;

  @override
  Future<MixStart> start(String playlistId, {String? videoId}) async {
    startCalls++;
    if (pendingStart != null) await pendingStart!.future;
    final items = videos(25, from: _issued);
    _issued += 25;
    return MixStart(playlistId: playlistId, title: 'My Mix', items: items);
  }

  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) {
    extendCalls++;
    anchors.add(afterVideoId);
    if (pending != null) return pending!.future;
    if (failExtends) return Future.error(StateError('network is down'));
    if (_pagesServed >= pages) {
      return Future.value(const MixExtension(items: [], exhausted: true));
    }
    _pagesServed++;
    final items = videos(pageSize, from: _issued);
    _issued += pageSize;
    return Future.value(MixExtension(items: items, exhausted: false));
  }
}

ProviderContainer containerWith(MixService service) {
  final container = ProviderContainer(
    overrides: [mixServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  return container;
}

QueueController controllerOf(ProviderContainer c) => c.read(queueProvider.notifier);
QueueState stateOf(ProviderContainer c) => c.read(queueProvider);

void main() {
  group('starting a mix', () {
    test('fills the queue and begins playback', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      await controllerOf(c).startMix('RDxyz');

      final state = stateOf(c);
      expect(state.items, hasLength(25));
      expect(state.currentIndex, 0, reason: 'something current is what starts playback');
      expect(state.isMix, isTrue);
      expect(state.mix!.playlistId, 'RDxyz');
      expect(state.mix!.title, 'My Mix');
      expect(service.startCalls, 1);
    });

    test('replaces a hand-built queue rather than appending to it', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);
      queue.addToQueue(video('mine1'));
      queue.addToQueue(video('mine2'));

      await queue.startMix('RDxyz');

      expect(stateOf(c).items.map((v) => v.id), isNot(contains('mine1')));
      expect(stateOf(c).items, hasLength(25));
    });

    test('the replaced queue can be undone, playhead included', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);
      queue.addToQueue(video('mine1'));
      queue.addToQueue(video('mine2'));
      queue.advance(); // playing mine2
      final before = stateOf(c);

      await queue.startMix('RDxyz');
      expect(queue.canUndoStartMix, isTrue);

      queue.undoStartMix();
      final after = stateOf(c);
      expect(after.items.map((v) => v.id), ['mine1', 'mine2']);
      expect(after.currentIndex, before.currentIndex);
      expect(after.isMix, isFalse);
      expect(
        after.version,
        greaterThan(before.version),
        reason: 'the playback controller reopens on a version change; without one the undo is invisible',
      );
    });

    test('undo is idempotent', () async {
      final c = containerWith(FakeMixService());
      final queue = controllerOf(c);
      queue.addToQueue(video('mine1'));
      await queue.startMix('RDxyz');

      queue.undoStartMix();
      final after = stateOf(c);
      queue.undoStartMix();
      expect(stateOf(c).items.map((v) => v.id), after.items.map((v) => v.id));
      expect(queue.canUndoStartMix, isFalse);
    });

    test('a second tap while the first is in flight is ignored', () async {
      // Reported from the app: `mix.start` is a ~1 s round trip with nothing on
      // screen to show the tap registered, so it reads as a dead click and gets
      // repeated. Both starts used to land, one after the other — the queue
      // filled and was then immediately replaced again.
      final service = FakeMixService();
      service.pendingStart = Completer<void>();
      final c = containerWith(service);
      final queue = controllerOf(c);
      queue.addToQueue(video('mine1'));

      final first = queue.startMix('RDxyz');
      expect(queue.isStartingMix, isTrue);
      final second = queue.startMix('RDxyz');

      service.pendingStart!.complete();
      await first;
      await second;

      expect(service.startCalls, 1, reason: 'the second tap never reached the wire');
      expect(stateOf(c).items, hasLength(25));
    });

    test('and the undo still restores the hand-built queue, not the mix', () async {
      // The sharp edge of the double-start: the second call captured the
      // *first mix* as the queue to restore, so Undo put back a mix the user
      // never built.
      final service = FakeMixService();
      service.pendingStart = Completer<void>();
      final c = containerWith(service);
      final queue = controllerOf(c);
      queue.addToQueue(video('mine1'));
      queue.addToQueue(video('mine2'));

      final first = queue.startMix('RDxyz');
      final second = queue.startMix('RDxyz');
      service.pendingStart!.complete();
      await first;
      await second;

      queue.undoStartMix();
      expect(stateOf(c).items.map((v) => v.id), ['mine1', 'mine2']);
      expect(stateOf(c).isMix, isFalse);
    });

    test('the loading flag is up while the round trip is out', () async {
      // The watch route is pushed before `mix.start` returns, so this flag is
      // what tells the page to draw a skeleton rather than "Nothing playing."
      final service = FakeMixService();
      service.pendingStart = Completer<void>();
      final c = containerWith(service);
      final queue = controllerOf(c);

      expect(stateOf(c).startingMixId, isNull);
      final started = queue.startMix('RDxyz');
      expect(stateOf(c).startingMixId, 'RDxyz');

      service.pendingStart!.complete();
      await started;
      expect(stateOf(c).startingMixId, isNull);
    });

    test('the flag never clears a frame before the items land', () async {
      // Both halves in one state write. Two writes would put a frame of
      // "not loading, nothing playing" between them — the empty watch page
      // flashing up just as the video arrives.
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);

      final seen = <(String?, int)>[];
      c.listen(queueProvider, (_, next) => seen.add((next.startingMixId, next.items.length)));

      await queue.startMix('RDxyz');

      // No observed state may be "not loading" with an empty queue.
      expect(
        seen.where((s) => s.$1 == null && s.$2 == 0),
        isEmpty,
        reason: 'that combination is the empty watch page flashing up',
      );
    });

    test('a failed start clears the flag, so the page stops waiting', () async {
      final service = FailingStartService();
      final c = containerWith(service);
      final queue = controllerOf(c);

      await expectLater(queue.startMix('RDxyz'), throwsA(isA<StateError>()));
      expect(stateOf(c).startingMixId, isNull);
    });

    test('a failed start does not wedge later attempts', () async {
      // The guard is cleared in a `finally`, or one network blip would make
      // every mix tile inert for the rest of the session.
      final service = FailingStartService();
      final c = containerWith(service);
      final queue = controllerOf(c);

      await expectLater(queue.startMix('RDxyz'), throwsA(isA<StateError>()));
      expect(queue.isStartingMix, isFalse);

      service.fail = false;
      await queue.startMix('RDxyz');
      expect(stateOf(c).items, hasLength(25));
    });

    test('there is nothing to undo when the queue was empty', () async {
      final c = containerWith(FakeMixService());
      await controllerOf(c).startMix('RDxyz');
      expect(controllerOf(c).canUndoStartMix, isFalse);
    });

    test('the old queue is gone the moment the tap lands, not when the mix does', () async {
      // Reported: the watch page opened at once but kept showing — and
      // playing — the old video for the second `mix.start` took. Emptying the
      // queue moves the playhead, which is what stops playback.
      final service = FakeMixService();
      service.pendingStart = Completer<void>();
      final c = containerWith(service);
      final queue = controllerOf(c);
      queue.addToQueue(video('mine1'));
      queue.addToQueue(video('mine2'));
      final before = stateOf(c);

      final started = queue.startMix('RDxyz');

      final loading = stateOf(c);
      expect(loading.items, isEmpty);
      expect(loading.current, isNull, reason: 'nothing current is what stops playback');
      expect(loading.version, greaterThan(before.version), reason: 'the playback controller acts on a version change');
      expect(loading.startingMixId, 'RDxyz', reason: 'what puts the skeleton up');
      expect(loading.isMix, isFalse);

      service.pendingStart!.complete();
      await started;
      expect(stateOf(c).items, hasLength(25));
    });

    test('a failed start puts the old queue back, cursor included', () async {
      // The queue is emptied up front now, so without a rollback a network
      // blip would cost the user their queue.
      final c = containerWith(FailingStartService());
      final queue = controllerOf(c);
      queue.addToQueue(video('mine1'));
      queue.addToQueue(video('mine2'));
      queue.advance(); // on mine2
      final versionBefore = stateOf(c).version;

      await expectLater(queue.startMix('RDxyz'), throwsA(isA<StateError>()));

      final after = stateOf(c);
      expect(after.items.map((v) => v.id), ['mine1', 'mine2']);
      expect(after.current?.id, 'mine2');
      expect(after.startingMixId, isNull);
      expect(after.version, greaterThan(versionBefore), reason: 'it has to reopen the restored video');
      expect(queue.canUndoStartMix, isFalse, reason: 'nothing was replaced');
    });

    test('a failed start from an empty queue ends empty, not stuck loading', () async {
      final c = containerWith(FailingStartService());
      await expectLater(controllerOf(c).startMix('RDxyz'), throwsA(isA<StateError>()));
      expect(stateOf(c).items, isEmpty);
      expect(stateOf(c).startingMixId, isNull);
    });
  });

  group('the undo offer', () {
    Future<(ProviderContainer, QueueController)> replaced() async {
      final c = containerWith(FakeMixService());
      final queue = controllerOf(c);
      queue.addToQueue(video('mine1'));
      await queue.startMix('RDxyz');
      expect(queue.canUndoStartMix, isTrue);
      return (c, queue);
    }

    // Editing the mix commits to it: an undo that silently threw away the video
    // just added is not one anyone wants.
    for (final (label, edit) in <(String, void Function(QueueController))>[
      ('adding to the queue', (q) => q.addToQueue(video('added'))),
      ('play next', (q) => q.playNext(video('next'))),
      ('play now', (q) => q.play(video('now'))),
      ('removing an entry', (q) => q.remove(q.entries.last)),
      ('removing by index', (q) => q.removeAt(3)),
      ('reordering', (q) => q.reorder(4, 1)),
      ('clearing upcoming', (q) => q.clearUpcoming()),
      ('clearing', (q) => q.clear()),
    ]) {
      test('goes when the user edits: $label', () async {
        final (_, queue) = await replaced();
        edit(queue);
        expect(queue.canUndoStartMix, isFalse);
      });
    }

    // Not edits — the user has not committed to anything by these.
    for (final (label, move) in <(String, void Function(QueueController))>[
      ('autoplay advancing', (q) => q.advance()),
      ('the previous button', (q) {
        q.advance();
        q.back();
      }),
      ('jumping to a row', (q) => q.jumpTo(5)),
    ]) {
      test('stays for: $label', () async {
        final (_, queue) = await replaced();
        move(queue);
        expect(queue.canUndoStartMix, isTrue);
      });
    }

    test('stays while the mix extends itself', () async {
      final (c, queue) = await replaced();
      for (var i = 0; i < 19; i++) {
        queue.advance();
      }
      await pumpMicrotasks();
      expect(stateOf(c).items.length, greaterThan(25), reason: 'the extension landed');
      expect(queue.canUndoStartMix, isTrue);
    });

    test('can be discarded without restoring, when its snackbar goes away', () async {
      final (c, queue) = await replaced();
      queue.discardStartMixUndo();
      expect(queue.canUndoStartMix, isFalse);
      expect(stateOf(c).isMix, isTrue, reason: 'discarding is not undoing');
    });
  });

  group('auto-extension', () {
    test('does not fetch while the end is far away', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      await controllerOf(c).startMix('RDxyz');
      await pumpMicrotasks();

      expect(service.extendCalls, 0, reason: '24 items remain after the current one');
    });

    test('fetches exactly once when the threshold is crossed', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');
      await pumpMicrotasks();

      // 25 items, current at 0. Advance until 5 remain after current: index 19.
      for (var i = 0; i < 19; i++) {
        queue.advance();
      }
      await pumpMicrotasks();

      expect(stateOf(c).currentIndex, 19);
      expect(service.extendCalls, 1, reason: 'one crossing, one fetch');
      expect(stateOf(c).items, hasLength(49));
    });

    test('the anchor is the last item held, not the current one', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');
      for (var i = 0; i < 19; i++) {
        queue.advance();
      }
      await pumpMicrotasks();

      expect(service.anchors, ['v24'], reason: 'the sidecar slices the tail after this');
    });

    test('a second advance under an in-flight fetch does not fire a duplicate', () async {
      // The single-flight guard, seen doing something. Without it every advance
      // past the threshold starts its own fetch and each appends the same page.
      final service = FakeMixService();
      service.pending = Completer<MixExtension>();
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');

      for (var i = 0; i < 19; i++) {
        queue.advance();
      }
      await pumpMicrotasks();
      expect(service.extendCalls, 1);

      // Four more advances while the first is still out.
      for (var i = 0; i < 4; i++) {
        queue.advance();
      }
      await pumpMicrotasks();
      expect(service.extendCalls, 1, reason: 'still exactly one — this is the guard');

      service.pending!.complete(MixExtension(items: videos(24, from: 100), exhausted: false));
      service.pending = null;
      await pumpMicrotasks();
      expect(stateOf(c).items, hasLength(49), reason: 'the page landed once, not five times');
    });

    test('extension does not move the playhead', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');
      for (var i = 0; i < 19; i++) {
        queue.advance();
      }
      final versionBefore = stateOf(c).version;
      final currentBefore = stateOf(c).current!.id;
      await pumpMicrotasks();

      expect(stateOf(c).current!.id, currentBefore);
      expect(stateOf(c).version, versionBefore,
          reason: 'a version bump here would reopen the video being watched');
    });

    test('running past the initial length keeps going', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');

      for (var i = 0; i < 60; i++) {
        queue.advance();
        await pumpMicrotasks();
      }

      expect(stateOf(c).items.length, greaterThan(60));
      expect(queue.advance(), isTrue, reason: 'still something to advance to');
    });

    test('an exhausted mix stops asking', () async {
      final service = FakeMixService(pages: 1);
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');

      for (var i = 0; i < 60; i++) {
        queue.advance();
        await pumpMicrotasks();
      }

      expect(stateOf(c).mix!.exhausted, isTrue);
      // One fetch that yielded, one that reported exhaustion, then silence.
      expect(service.extendCalls, 2);
    });

    test('a failed extension leaves the queue playable and is reported', () async {
      final service = FakeMixService(failExtends: true);
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');

      for (var i = 0; i < 19; i++) {
        queue.advance();
      }
      await pumpMicrotasks();

      expect(queue.mixError, isNotNull, reason: '§4: the user is told if it stopped');
      expect(stateOf(c).items, hasLength(25), reason: 'still playable, just not longer');
      expect(stateOf(c).mix!.exhausted, isFalse, reason: 'a failure is not an ending');
      expect(queue.advance(), isTrue, reason: 'the rest of the queue still plays');
    });

    test('a failed extension retries on the next advance, once per advance', () async {
      final service = FakeMixService(failExtends: true);
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');
      for (var i = 0; i < 19; i++) {
        queue.advance();
      }
      await pumpMicrotasks();
      expect(service.extendCalls, 1);

      queue.advance();
      await pumpMicrotasks();
      expect(service.extendCalls, 2, reason: 'one retry per playhead move, not a spin');
    });

    test('a late extension is dropped when the mix has been replaced', () async {
      final service = FakeMixService();
      service.pending = Completer<MixExtension>();
      final c = containerWith(service);
      final queue = controllerOf(c);
      await queue.startMix('RDone');
      for (var i = 0; i < 19; i++) {
        queue.advance();
      }
      await pumpMicrotasks();
      expect(service.extendCalls, 1);

      // A different mix starts while the first extension is still out.
      service.pending = null;
      await queue.startMix('RDtwo');
      final lengthAfterSwitch = stateOf(c).items.length;

      // The stale page arrives.
      // (The completer captured by the in-flight call is the one held here.)
      await pumpMicrotasks();
      expect(stateOf(c).items, hasLength(lengthAfterSwitch),
          reason: 'a page from the old radio must not land in the new one');
      expect(stateOf(c).mix!.playlistId, 'RDtwo');
    });
  });

  group('the Task 14 behaviour must not regress', () {
    test('a hand-built queue still stops at its end', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);
      queue.addToQueue(video('a'));
      queue.addToQueue(video('b'));

      expect(queue.advance(), isTrue);
      expect(queue.advance(), isFalse, reason: 'when the queue empties, stop');
      await pumpMicrotasks();
      expect(service.extendCalls, 0, reason: 'nothing fetches for a queue that is not a mix');
    });

    test('an ordinary queue never grows by itself', () async {
      final service = FakeMixService();
      final c = containerWith(service);
      final queue = controllerOf(c);
      for (final v in videos(3)) {
        queue.addToQueue(v);
      }
      for (var i = 0; i < 5; i++) {
        queue.advance();
        await pumpMicrotasks();
      }
      expect(stateOf(c).items, hasLength(3));
      expect(service.extendCalls, 0);
    });
  });

  group('the mix survives ordinary edits', () {
    test('adding a video by hand does not stop it being a mix', () async {
      final c = containerWith(FakeMixService());
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');
      queue.addToQueue(video('mine'));
      expect(stateOf(c).isMix, isTrue);
    });

    test('clearing ends it', () async {
      final c = containerWith(FakeMixService());
      final queue = controllerOf(c);
      await queue.startMix('RDxyz');
      queue.clear();
      expect(stateOf(c).isMix, isFalse);
      expect(queue.canUndoStartMix, isFalse);
    });
  });
}

/// A service whose `start` throws until `fail` is cleared.
class FailingStartService implements MixService {
  bool fail = true;

  @override
  Future<MixStart> start(String playlistId, {String? videoId}) async {
    if (fail) throw StateError('mix.start blew up');
    return MixStart(playlistId: playlistId, title: 'My Mix', items: videos(25));
  }

  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) async =>
      const MixExtension(items: [], exhausted: true);
}

/// Let every pending microtask settle — the extensions are fire-and-forget, so
/// there is no future to await.
Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);
