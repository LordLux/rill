/// The queue's ordering rules (task §5), as arithmetic.
///
/// Every one of these is a pure state transition, so none of it needs a widget
/// tree or a player. What they pin is the cursor: nearly every queue bug is the
/// cursor pointing at the wrong item after the list moved under it, and none of
/// those bugs throw — the wrong video simply plays next.
library;

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

/// The ids in order, with the current one marked — the whole state in one line.
String describe(QueueState state) {
  return state.items
      .asMap()
      .entries
      .map((e) => e.key == state.currentIndex ? '[${e.value.id}]' : e.value.id)
      .join(' ');
}

QueueState queueOf(List<String> ids, {int? current}) =>
    QueueState(items: ids.map(video).toList(), currentIndex: current);

void main() {
  group('append', () {
    test('adding to an empty queue makes it current — that is what starts playback', () {
      final state = const QueueState().appended(video('a'));
      expect(describe(state), '[a]');
      expect(state.currentIndex, 0);
    });

    test('adding while something plays goes to the back and moves nothing', () {
      final state = queueOf(['a', 'b'], current: 0).appended(video('c'));
      expect(describe(state), '[a] b c');
    });
  });

  group('play next', () {
    test('inserts after the current item rather than at the back', () {
      final state = queueOf(['a', 'b', 'c'], current: 0).insertedNext(video('x'));
      expect(describe(state), '[a] x b c');
    });

    test('on an empty queue it is just an append, and starts playback', () {
      expect(describe(const QueueState().insertedNext(video('x'))), '[x]');
    });

    test('is not the same as appending — the distinction is the point', () {
      final base = queueOf(['a', 'b', 'c'], current: 0);
      expect(describe(base.insertedNext(video('x'))), isNot(describe(base.appended(video('x')))));
    });
  });

  group('play now', () {
    test('plays immediately and keeps the rest of the queue behind it', () {
      final state = queueOf(['a', 'b', 'c'], current: 0).playingNow(video('x'));
      expect(describe(state), 'a [x] b c');
    });

    test('on an empty queue it simply starts', () {
      expect(describe(const QueueState().playingNow(video('x'))), '[x]');
    });
  });

  group('remove', () {
    test('removing an earlier entry keeps the cursor on the same video', () {
      final state = queueOf(['a', 'b', 'c'], current: 2).removedAt(0);
      expect(describe(state), 'b [c]');
    });

    test('removing a later entry does not move the cursor', () {
      expect(describe(queueOf(['a', 'b', 'c'], current: 0).removedAt(2)), '[a] b');
    });

    test('removing the current entry moves to whatever took its place', () {
      expect(describe(queueOf(['a', 'b', 'c'], current: 1).removedAt(1)), 'a [c]');
    });

    test('removing the current last entry stops rather than pointing past the end', () {
      final state = queueOf(['a', 'b'], current: 1).removedAt(1);
      expect(state.currentIndex, isNull);
      expect(state.current, isNull);
      expect(describe(state), 'a');
    });

    test('emptying the queue clears the cursor', () {
      final state = queueOf(['a'], current: 0).removedAt(0);
      expect(state.items, isEmpty);
      expect(state.currentIndex, isNull);
    });

    test('an out-of-range index changes nothing', () {
      final base = queueOf(['a', 'b'], current: 0);
      expect(describe(base.removedAt(7)), describe(base));
      expect(describe(base.removedAt(-1)), describe(base));
    });
  });

  group('reorder', () {
    test('dragging an entry from behind the cursor to in front of it', () {
      // a b [c] d  →  move a to the end  →  b [c] d a
      expect(describe(queueOf(['a', 'b', 'c', 'd'], current: 2).reordered(0, 3)), 'b [c] d a');
    });

    test('dragging an entry from in front of the cursor to behind it', () {
      // a b [c] d  →  move d to the front  →  d a b [c]
      expect(describe(queueOf(['a', 'b', 'c', 'd'], current: 2).reordered(3, 0)), 'd a b [c]');
    });

    test('dragging the current entry itself carries the cursor with it', () {
      expect(describe(queueOf(['a', 'b', 'c'], current: 0).reordered(0, 2)), 'b c [a]');
    });

    test('a reorder entirely behind the cursor leaves it alone', () {
      expect(describe(queueOf(['a', 'b', 'c', 'd'], current: 3).reordered(0, 1)), 'b a c [d]');
    });

    test('reordering never loses or duplicates an item', () {
      final base = queueOf(['a', 'b', 'c', 'd'], current: 1);
      for (var from = 0; from < 4; from++) {
        for (var to = 0; to < 4; to++) {
          final after = base.reordered(from, to);
          expect(
            after.items.map((i) => i.id).toSet(),
            {'a', 'b', 'c', 'd'},
            reason: 'moving $from → $to',
          );
          expect(after.items, hasLength(4), reason: 'moving $from → $to');
          // And the cursor still points at the same video it started on.
          expect(after.current?.id, 'b', reason: 'moving $from → $to');
        }
      }
    });
  });

  group('autoplay', () {
    test('advances to the next item', () {
      expect(describe(queueOf(['a', 'b'], current: 0).advanced()), 'a [b]');
    });

    test('at the end of the queue it stops — it does not wrap or clear', () {
      final end = queueOf(['a', 'b'], current: 1);
      final after = end.advanced();
      expect(describe(after), describe(end));
      expect(after.hasNext, isFalse);
    });

    test('advancing an empty queue is a no-op, not a cursor pointing at nothing', () {
      expect(const QueueState().advanced().currentIndex, isNull);
    });
  });

  group('next', () {
    test('is what the preloader watches', () {
      expect(queueOf(['a', 'b', 'c'], current: 0).next?.id, 'b');
      expect(queueOf(['a'], current: 0).next, isNull);
      expect(const QueueState().next, isNull);
    });
  });
}
