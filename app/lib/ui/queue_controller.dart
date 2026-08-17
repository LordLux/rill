import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/feed_item.dart';

/// A video plus an identity that outlives its position (architecture §2.8).
///
/// **Never give this an `==` or `hashCode` **
/// The object *is* the identity, so two entries holding the same video stay distinct;
/// value equality would make duplicates interchangeable again. `queue_test.dart` pins the absence.
class QueueEntry {
  QueueEntry(this.item);

  final VideoItem item;

  @override
  String toString() => 'QueueEntry(${item.id})';
}

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
  /// Build a queue from bare videos, minting an identity for each.
  ///
  /// The only constructor outside this file.
  /// Mutations go through [QueueState._] so entries are carried forward rather than re-minted.
  factory QueueState({
    List<VideoItem> items = const [],
    int? currentIndex,
    int version = 0,
  }) => QueueState._(
    [for (final item in items) QueueEntry(item)],
    currentIndex: currentIndex,
    version: version,
  );

  QueueState._(this.entries, {this.currentIndex, this.version = 0});

  /// The queue itself. Order is position; each element is an identity
  final List<QueueEntry> entries;

  final int? currentIndex;

  /// Incremented whenever the playhead moves to a different track in the queue,
  /// but NOT when the queue is merely reshuffled around the current track
  /// (e.g. reordering or clearing).
  final int version;

  /// The videos, in order — for everything that does not care about identity.
  ///
  /// `late final`, not a getter: `select((q) => q.items)` compares list
  /// identity, so rebuilding it per call would report a change on every read.
  late final List<VideoItem> items = [for (final entry in entries) entry.item];

  bool get isEmpty => entries.isEmpty;

  QueueEntry? get currentEntry {
    final index = currentIndex;
    if (index == null || index < 0 || index >= entries.length) return null;
    return entries[index];
  }

  VideoItem? get current => currentEntry?.item;

  /// What autoplay would advance to, or null at the end of the queue.
  VideoItem? get next {
    final index = currentIndex;
    if (index == null) return null;
    return index + 1 < entries.length ? entries[index + 1].item : null;
  }

  bool get hasNext => next != null;

  /// What "previous" would go back to, or null at the front of the queue.
  ///
  /// Null rather than the last item: the queue **stops rather than wrapping**
  /// (task 14 §5), and the previous button has to agree with that or the two
  /// halves of the same rule disagree at the two ends of the same list.
  VideoItem? get previous {
    final index = currentIndex;
    if (index == null) return null;
    return index - 1 >= 0 ? entries[index - 1].item : null;
  }

  bool get hasPrevious => previous != null;

  QueueState _with(List<QueueEntry> entries, int? currentIndex, {bool playheadMoved = false}) => QueueState._(
    entries,
    currentIndex: currentIndex,
    version: playheadMoved ? version + 1 : version,
  );

  /// Append. Starts playback only if nothing was playing.
  QueueState appended(VideoItem item) {
    final next = [...entries, QueueEntry(item)];
    final startingPlayback = currentIndex == null;
    return _with(next, currentIndex ?? next.length - 1, playheadMoved: startingPlayback);
  }

  /// Insert directly after the current item — "play next".
  ///
  /// The distinction from [appended] is the whole reason both exist: with three
  /// videos queued, "play next" has to land at position current+1 and not at the
  /// back of the line.
  QueueState insertedNext(VideoItem item) {
    final index = currentIndex;
    if (index == null) return appended(item);
    final next = [...entries]..insert(index + 1, QueueEntry(item));
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
    final next = [...entries]..insert(index + 1, QueueEntry(item));
    return _with(next, index + 1, playheadMoved: true);
  }

  /// Move the cursor to an existing entry.
  QueueState jumpedTo(int index) {
    if (index < 0 || index >= entries.length) return this;
    if (index == currentIndex) return this;
    return _with(entries, index, playheadMoved: true);
  }

  /// Remove one entry, keeping the cursor on the same *item* wherever possible.
  ///
  /// Removing the current entry moves the cursor to whatever slides into its
  /// place — the next video — because that is what "remove the thing I am
  /// watching" means. Removing the last item while it is current stops:
  /// `currentIndex` becomes null rather than pointing past the end.
  QueueState removedAt(int index) {
    if (index < 0 || index >= entries.length) return this;
    final next = [...entries]..removeAt(index);
    final cursor = currentIndex;

    if (cursor == null) return _with(next, null);
    if (next.isEmpty) return _with(next, null, playheadMoved: true); // Stopped playing
    if (index < cursor) return _with(next, cursor - 1);
    if (index > cursor) return _with(next, cursor);

    // The current entry went. Whatever took its slot is now current; if nothing
    // did, the queue has run out and playback stops.
    return _with(next, cursor < next.length ? cursor : null, playheadMoved: true);
  }

  /// Remove Entry by identity.
  ///
  /// Idempotent: a row's own slide-out and the sweep that overtook it can both ask for the same removal.
  QueueState removedEntry(QueueEntry entry) {
    final index = entries.indexOf(entry);
    if (index < 0) return this;
    return removedAt(index);
  }

  /// Reorder, with the cursor following the item it was on.
  ///
  /// Tracked by position rather than by identity: the same video can legitimately
  /// appear in a queue twice, and following "the item equal to the current one"
  /// would jump the cursor to the wrong copy.
  QueueState reordered(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= entries.length) return this;
    final target = newIndex.clamp(0, entries.length - 1);
    if (oldIndex == target) return this;

    final next = [...entries];
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
    return _with(next, updated); // playheadMoved = false
  }

  /// Autoplay. At the end of the queue this is a no-op — "when the queue
  /// empties, stop" (task §5); pulling from related or a mix is a later task.
  QueueState advanced() {
    final index = currentIndex;
    if (index == null || index + 1 >= entries.length) return this;
    return _with(entries, index + 1, playheadMoved: true);
  }

  /// The previous button.
  /// A no-op at the front, for the same reason [advanced] is one at the back.
  QueueState reversed() {
    final index = currentIndex;
    if (index == null || index - 1 < 0) return this;
    return _with(entries, index - 1, playheadMoved: true);
  }

  QueueState cleared() => QueueState._(const []);

  /// Clears queued upcoming items, keeping the current one and anything in
  /// [keep].
  ///
  /// **[keep] is a set of entries, not a count of them.** A count has to assume
  /// the queue only grew and that the growth is at the end, and neither holds:
  /// a removal alongside an addition nets to zero and discards the new video,
  /// and "play next" lands after the current entry rather than at the back.
  /// Naming the survivors cannot be wrong about either.
  ///
  /// Survivors keep their own entries — re-minting would read to the panel as an
  /// arrival, and rows that never moved would play their entrance.
  QueueState clearUpcoming({Set<QueueEntry> keep = const {}}) {
    final current = currentEntry;
    if (current == null) return QueueState._(const []);

    final kept = [
      for (final entry in entries)
        if (identical(entry, current) || keep.contains(entry)) entry,
    ];

    return QueueState._(
      kept,
      currentIndex: kept.indexOf(current),
      version: version, // Version unchanged; it's the exact same playing track
    );
  }
}

class QueueController extends Notifier<QueueState> {
  @override
  QueueState build() => QueueState();

  int get queueSize => state.entries.length;

  /// The queue as identities
  List<QueueEntry> get entries => state.entries;

  /// Open a video now. The one the feed and the related rail both call.
  void play(VideoItem item) => state = state.playingNow(item);

  void addToQueue(VideoItem item) => state = state.appended(item);

  void playNext(VideoItem item) => state = state.insertedNext(item);

  void jumpTo(int index) => state = state.jumpedTo(index);

  void removeAt(int index) => state = state.removedAt(index);

  /// Remove by identity. Idempotent
  void remove(QueueEntry entry) => state = state.removedEntry(entry);

  void reorder(int oldIndex, int newIndex) => state = state.reordered(oldIndex, newIndex);

  /// Advance to the next item. Returns false when there was none, which is what
  /// tells the playback controller to stop rather than loop.
  bool advance() {
    final before = state.currentIndex;
    state = state.advanced();
    return state.currentIndex != before;
  }

  /// Step back one. Returns false at the front of the queue, where the button
  /// is disabled anyway — both halves so neither is the only guard.
  bool back() {
    final before = state.currentIndex;
    state = state.reversed();
    return state.currentIndex != before;
  }

  void clear() => state = state.cleared();

  void clearUpcoming({Set<QueueEntry> keep = const {}}) => state = state.clearUpcoming(keep: keep);
}

final queueProvider = NotifierProvider<QueueController, QueueState>(QueueController.new);
