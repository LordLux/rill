import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/feed_item.dart';

/// The queue: an ordered list plus a current index (task §5).
///
/// Immutable, and every mutation is a pure method returning a new state. The
/// controller below is a thin shell over these, so the ordering rules can be
/// tested as arithmetic rather than through a widget tree — which is what they
/// are, and where all the interesting mistakes live.
///
/// `currentIndex` is `null` when nothing is playing. It is *not* a separate
/// "playing" flag: something being current is what starts playback, because the
/// playback controller opens whatever `current` becomes. That is the whole
/// mechanism behind "adding to an empty queue while nothing plays starts
/// playback, adding while something plays does not interrupt it" — the first
/// case moves `currentIndex` off `null`, the second cannot.
class QueueState {
  const QueueState({this.items = const [], this.currentIndex});

  final List<VideoItem> items;
  final int? currentIndex;

  bool get isEmpty => items.isEmpty;

  VideoItem? get current {
    final index = currentIndex;
    if (index == null || index < 0 || index >= items.length) return null;
    return items[index];
  }

  /// What autoplay would advance to, or null at the end of the queue.
  VideoItem? get next {
    final index = currentIndex;
    if (index == null) return null;
    return index + 1 < items.length ? items[index + 1] : null;
  }

  bool get hasNext => next != null;

  QueueState _with(List<VideoItem> items, int? currentIndex) =>
      QueueState(items: items, currentIndex: currentIndex);

  /// Append. Starts playback only if nothing was playing.
  QueueState appended(VideoItem item) {
    final next = [...items, item];
    return _with(next, currentIndex ?? next.length - 1);
  }

  /// Insert directly after the current item — "play next".
  ///
  /// The distinction from [appended] is the whole reason both exist: with three
  /// videos queued, "play next" has to land at position current+1 and not at the
  /// back of the line.
  QueueState insertedNext(VideoItem item) {
    final index = currentIndex;
    if (index == null) return appended(item);
    final next = [...items]..insert(index + 1, item);
    return _with(next, index);
  }

  /// Play [item] now, keeping whatever was queued behind it.
  ///
  /// Inserts after current rather than replacing the list, so opening something
  /// from the feed — or tapping a related tile on the watch page — does not
  /// silently throw away a queue the user built.
  QueueState playingNow(VideoItem item) {
    final index = currentIndex;
    if (index == null) return appended(item);
    final next = [...items]..insert(index + 1, item);
    return _with(next, index + 1);
  }

  /// Move the cursor to an existing entry.
  QueueState jumpedTo(int index) {
    if (index < 0 || index >= items.length) return this;
    return _with(items, index);
  }

  /// Remove one entry, keeping the cursor on the same *item* wherever possible.
  ///
  /// Removing the current entry moves the cursor to whatever slides into its
  /// place — the next video — because that is what "remove the thing I am
  /// watching" means. Removing the last item while it is current stops:
  /// `currentIndex` becomes null rather than pointing past the end.
  QueueState removedAt(int index) {
    if (index < 0 || index >= items.length) return this;
    final next = [...items]..removeAt(index);
    final cursor = currentIndex;

    if (cursor == null) return _with(next, null);
    if (next.isEmpty) return _with(next, null);
    if (index < cursor) return _with(next, cursor - 1);
    if (index > cursor) return _with(next, cursor);
    // The current entry went. Whatever took its slot is now current; if nothing
    // did, the queue has run out and playback stops.
    return _with(next, cursor < next.length ? cursor : null);
  }

  /// Reorder, with the cursor following the item it was on.
  ///
  /// Tracked by position rather than by identity: the same video can legitimately
  /// appear in a queue twice, and following "the item equal to the current one"
  /// would jump the cursor to the wrong copy.
  QueueState reordered(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= items.length) return this;
    final target = newIndex.clamp(0, items.length - 1);
    if (oldIndex == target) return this;

    final next = [...items];
    final moved = next.removeAt(oldIndex);
    next.insert(target, moved);

    final cursor = currentIndex;
    if (cursor == null) return _with(next, null);

    int updated = cursor;
    if (cursor == oldIndex) {
      updated = target;
    } else {
      if (oldIndex < cursor) updated -= 1;
      if (target <= updated) updated += 1;
    }
    return _with(next, updated);
  }

  /// Autoplay. At the end of the queue this is a no-op — "when the queue
  /// empties, stop" (task §5); pulling from related or a mix is a later task.
  QueueState advanced() {
    final index = currentIndex;
    if (index == null || index + 1 >= items.length) return this;
    return _with(items, index + 1);
  }

  QueueState cleared() => const QueueState();
}

class QueueController extends Notifier<QueueState> {
  @override
  QueueState build() => const QueueState();

  /// Open a video now. The one the feed and the related rail both call.
  void play(VideoItem item) => state = state.playingNow(item);

  void addToQueue(VideoItem item) => state = state.appended(item);

  void playNext(VideoItem item) => state = state.insertedNext(item);

  void jumpTo(int index) => state = state.jumpedTo(index);

  void removeAt(int index) => state = state.removedAt(index);

  void reorder(int oldIndex, int newIndex) => state = state.reordered(oldIndex, newIndex);

  /// Advance to the next item. Returns false when there was none, which is what
  /// tells the playback controller to stop rather than loop.
  bool advance() {
    final before = state.currentIndex;
    state = state.advanced();
    return state.currentIndex != before;
  }

  void clear() => state = state.cleared();
}

final queueProvider = NotifierProvider<QueueController, QueueState>(QueueController.new);
