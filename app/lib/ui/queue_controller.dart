import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../data/rpc/client.dart';
import '../domain/feed_item.dart';

/// The mix a queue is playing, when it is playing one (Task 26 §3).
///
/// **The queue has to know it is a mix**, because the end-of-queue behaviour
/// differs: a hand-built queue stops (Task 14, verified and unchanged), a mix
/// extends. Carrying that as a field on the state rather than a flag somewhere
/// else means every mutation either preserves it or drops it deliberately, and
/// the panel can name the mix without asking anyone.
@immutable
class MixQueue {
  const MixQueue({required this.playlistId, this.title, this.exhausted = false});

  /// The `RD…` id. What `mix.extend` is keyed on.
  final String playlistId;

  /// "My Mix", "Mix - <video>", "Chroma: Today's Dance Hits". Null if absent.
  final String? title;

  /// The sidecar has said there is no more of this radio.
  ///
  /// Sticky: once set, nothing asks again. `mix.extend` reports this for two
  /// different upstream endings (an empty tail, or an anchor the server no
  /// longer places in the sequence) and both mean the same thing here.
  final bool exhausted;

  MixQueue copyWith({bool? exhausted}) => MixQueue(
        playlistId: playlistId,
        title: title,
        exhausted: exhausted ?? this.exhausted,
      );

  @override
  bool operator ==(Object other) =>
      other is MixQueue &&
      other.playlistId == playlistId &&
      other.title == title &&
      other.exhausted == exhausted;

  @override
  int get hashCode => Object.hash(playlistId, title, exhausted);

  @override
  String toString() => 'MixQueue($playlistId, exhausted: $exhausted)';
}

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
    MixQueue? mix,
    String? startingMixId,
  }) => QueueState._(
    [for (final item in items) QueueEntry(item)],
    currentIndex: currentIndex,
    version: version,
    mix: mix,
    startingMixId: startingMixId,
  );

  QueueState._(
    this.entries, {
    this.currentIndex,
    this.version = 0,
    this.mix,
    this.startingMixId,
  });

  /// The queue itself. Order is position; each element is an identity
  final List<QueueEntry> entries;

  final int? currentIndex;

  /// Incremented whenever the playhead moves to a different track in the queue,
  /// but NOT when the queue is merely reshuffled around the current track
  /// (e.g. reordering or clearing).
  final int version;

  /// The mix this queue is playing, or null for an ordinary/hand-built one.
  ///
  /// Preserved by every ordinary mutation — adding a video by hand to a mix
  /// does not stop it being a mix, the same way it does not on youtube.com —
  /// and dropped only by [cleared] and by starting a different mix.
  final MixQueue? mix;

  bool get isMix => mix != null;

  /// The `RD…` id of a mix whose `mix.start` is on the wire, or null.
  ///
  /// **On the state rather than on the controller, because the watch page has
  /// to rebuild when it changes.** The route is pushed before the round trip
  /// finishes (a click that does nothing for a second reads as a dead click),
  /// so something has to tell the page to draw a skeleton instead of "Nothing
  /// playing." — and a plain field on the `Notifier` would never notify.
  final String? startingMixId;

  /// How many items sit after the current one. What the extension threshold
  /// reads, and `null` when nothing is playing.
  int? get remainingAfterCurrent {
    final index = currentIndex;
    if (index == null) return null;
    return entries.length - index - 1;
  }

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
    mix: mix,
    startingMixId: startingMixId,
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
  /// empties, stop" (Task 14 §5), which is still exactly right for a
  /// hand-built queue and must not regress.
  ///
  /// A **mix** does not reach that point by a different rule, it reaches it
  /// later: [QueueController] tops the list up well before the end (§4), so
  /// there is normally something to advance to. When there genuinely is not —
  /// the radio is exhausted, or an extension failed — a mix stops here too,
  /// through this same no-op. There is deliberately no "fetch on empty" path:
  /// stalling at the end of a video waiting for a round trip is the thing
  /// auto-extension exists to avoid.
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

  /// Empty, and no longer a mix — clearing is the one mutation that ends one.
  QueueState cleared() => QueueState._(const []);

  /// Replace everything with a mix (§3: "starting a mix replaces the queue").
  ///
  /// The playhead moves by construction, so `version` increments and playback
  /// opens `items.first`. Entries are minted fresh because none of them
  /// survived — this is the one mutation where that is correct.
  QueueState startedMix(List<VideoItem> items, MixQueue mix) {
    if (items.isEmpty) return this;
    return QueueState._(
      [for (final item in items) QueueEntry(item)],
      currentIndex: 0,
      version: version + 1,
      mix: mix,
    );
  }

  /// Append more of the mix. **Never moves the playhead** — this runs while
  /// the user is watching, and a version bump here would reopen the video
  /// they are in the middle of.
  QueueState extendedWith(List<VideoItem> items) {
    if (items.isEmpty) return this;
    return _with([...entries, for (final item in items) QueueEntry(item)], currentIndex);
  }

  /// This queue put back as the live one, after [sinceVersion] (§3's undo).
  ///
  /// Entries are carried forward, not re-minted, so the panel reads the
  /// restored rows as the ones it already knew rather than as arrivals and
  /// they do not all play their entrance animation. The version is taken from
  /// whatever the *current* state reached and bumped, not from this snapshot's
  /// own — it has to be higher than what the playback controller last saw, or
  /// the restore does not reopen the video the user was on.
  QueueState restoredAfter(int sinceVersion) => QueueState._(
        entries,
        currentIndex: currentIndex,
        version: sinceVersion + 1,
        mix: mix,
      );

  /// The radio has run out. Sticky, so nothing asks again.
  ///
  /// Entries are carried forward rather than re-minted, and `version` does not
  /// move: nothing about the queue the user is watching has changed, only what
  /// we know about whether it can grow.
  QueueState mixExhausted() {
    final current = mix;
    if (current == null || current.exhausted) return this;
    return QueueState._(
      entries,
      currentIndex: currentIndex,
      version: version,
      mix: current.copyWith(exhausted: true),
    );
  }

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

/// What `mix.start` answers — `protocol.md` §3.3.
@immutable
class MixStart {
  const MixStart({required this.playlistId, this.title, required this.items});
  final String playlistId;
  final String? title;
  final List<VideoItem> items;
}

/// What `mix.extend` answers.
@immutable
class MixExtension {
  const MixExtension({required this.items, required this.exhausted});
  final List<VideoItem> items;
  final bool exhausted;
}

/// The two mix calls, behind a seam.
///
/// A `Provider` rather than a direct `RpcClient.instance.call`, for the same
/// reason `playbackEngineProvider` is one: the extension *policy* — when to
/// fetch, and how many times — is the part worth testing, and testing it
/// through a real sidecar process would make counting fetches slow and flaky.
/// `queue_test.dart` overrides this with a counter.
abstract class MixService {
  Future<MixStart> start(String playlistId, {String? videoId});
  Future<MixExtension> extend(String playlistId, String afterVideoId);
}

class RpcMixService implements MixService {
  const RpcMixService();

  @override
  Future<MixStart> start(String playlistId, {String? videoId}) async {
    final response = await RpcClient.instance.call('mix.start', {
      'playlistId': playlistId,
      'videoId': ?videoId,
    }) as Map<String, dynamic>;
    return MixStart(
      playlistId: response['playlistId'] as String? ?? playlistId,
      title: response['title'] as String?,
      items: _videosFrom(response['items']),
    );
  }

  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) async {
    final response = await RpcClient.instance.call('mix.extend', {
      'playlistId': playlistId,
      'afterVideoId': afterVideoId,
    }) as Map<String, dynamic>;
    return MixExtension(
      items: _videosFrom(response['items']),
      // Absent reads as "not exhausted": an older sidecar that does not send
      // the field must not silently stop a radio that is still going.
      exhausted: response['exhausted'] as bool? ?? false,
    );
  }

  /// A mix panel is videos by construction, but the wire type is `FeedItem[]`
  /// like every other list method. Anything that is not a video is dropped
  /// rather than queued as something unplayable.
  static List<VideoItem> _videosFrom(Object? raw) {
    final out = <VideoItem>[];
    for (final entry in (raw as List<dynamic>? ?? const <dynamic>[])) {
      final item = FeedItem.fromJson(entry as Map<String, dynamic>);
      if (item is VideoItem) out.add(item);
    }
    return out;
  }
}

final mixServiceProvider = Provider<MixService>((ref) => const RpcMixService());

class QueueController extends Notifier<QueueState> {
  @override
  QueueState build() => QueueState();

  /// **Fetch when five items remain after the current one.**
  ///
  /// `mix.extend` returns 24 at a time, so the threshold only decides *when*
  /// the round trip happens, never how much arrives. Five comes from the two
  /// ways a user reaches the end: watching (five videos is many minutes, far
  /// more than the ~1 s the call takes) and skipping (five skips is about two
  /// seconds of held-down Next, which is the case that actually races). Lower
  /// and a fast skipper outruns the fetch; higher and a mix opened, sampled
  /// for one video and abandoned still pays for an extension it never used.
  static const int extendThreshold = 5;

  /// One extension in flight at a time.
  ///
  /// Every mutation re-evaluates the threshold, so without this a user holding
  /// Next fires a fetch per keypress — each returning the same 24 items, each
  /// appending them again. The guard is the difference between one round trip
  /// and a queue with everything in it twice.
  bool _extending = false;

  /// The queue a mix replaced, for undo (§3). Null once there is nothing to
  /// put back.
  QueueState? _replaced;

  /// Whether [undoStartMix] has anything to restore.
  bool get canUndoStartMix => _replaced != null;

  /// A `mix.start` is on the wire.
  ///
  /// `mix.start` is a real round trip (~0.5-1 s measured), and until it
  /// returns there is nothing on screen to show the tap registered — so it
  /// reads as a dead click and gets repeated. Without a guard the second tap
  /// starts a second mix, and the two land in sequence: the queue fills, then
  /// is immediately replaced again, and the undo snapshot taken by the second
  /// call is *the first mix* rather than what the user actually had.
  bool get isStartingMix => state.startingMixId != null;

  /// The last extension failure, or null.
  ///
  /// Read by the queue panel so a mix that stopped early can say why rather
  /// than just ending — §4: "with the user told if it stopped".
  String? get mixError => _mixError;
  String? _mixError;

  int get queueSize => state.entries.length;

  /// The queue as identities
  List<QueueEntry> get entries => state.entries;

  /// Every mutation goes through here so the extension check has exactly one
  /// place to live. A mutation that assigns `state` directly is how the top-up
  /// silently stops happening for that one path.
  void _set(QueueState next) {
    state = next;
    _maybeExtend();
  }

  /// Open a video now. The one the feed and the related rail both call.
  void play(VideoItem item) => _edit(state.playingNow(item));

  void addToQueue(VideoItem item) => _edit(state.appended(item));

  void playNext(VideoItem item) => _edit(state.insertedNext(item));

  /// Not an edit: moving through the mix is not committing to it or away from
  /// it, so the undo survives.
  void jumpTo(int index) => _set(state.jumpedTo(index));

  void removeAt(int index) => _edit(state.removedAt(index));

  /// Remove by identity. Idempotent
  void remove(QueueEntry entry) => _edit(state.removedEntry(entry));

  void reorder(int oldIndex, int newIndex) => _edit(state.reordered(oldIndex, newIndex));

  /// A change the user made to the queue.
  ///
  /// **Editing the queue a mix installed commits to it**, so the offer to put
  /// the old one back goes away: an undo that would silently throw away the
  /// video they just added is not an undo anyone wants. Only real edits come
  /// through here — autoplay advancing, the previous button, jumping to a row
  /// and the mix topping itself up all go straight to [_set] and leave the
  /// offer standing.
  void _edit(QueueState next) {
    _replaced = null;
    _set(next);
  }

  /// Forget the replaced queue without restoring it — the undo was offered and
  /// the offer went away (its snackbar timed out or was replaced).
  void discardStartMixUndo() => _replaced = null;

  /// Advance to the next item. Returns false when there was none, which is what
  /// tells the playback controller to stop rather than loop.
  bool advance() {
    final before = state.currentIndex;
    _set(state.advanced());
    return state.currentIndex != before;
  }

  /// Step back one. Returns false at the front of the queue, where the button
  /// is disabled anyway — both halves so neither is the only guard.
  bool back() {
    final before = state.currentIndex;
    _set(state.reversed());
    return state.currentIndex != before;
  }

  void clear() {
    _replaced = null;
    _mixError = null;
    _set(state.cleared());
  }

  void clearUpcoming({Set<QueueEntry> keep = const {}}) =>
      _edit(state.clearUpcoming(keep: keep));

  // -------------------------------------------------------------------------
  // Mixes (Task 26)
  // -------------------------------------------------------------------------

  /// Start a mix, replacing whatever was queued (§3).
  ///
  /// **Replace, with an undo** — the option the task calls "probably right",
  /// and the one youtube.com implements. A confirmation would put a modal
  /// between one click on a mix tile and playback, which is the whole
  /// interaction; discarding silently is the option the task names as worst.
  /// The queue that was replaced is held for [undoStartMix], and the caller
  /// shows the snackbar.
  ///
  /// Throws whatever `mix.start` throws, for the caller to report. Nothing is
  /// replaced when the call fails, so a failed mix leaves the existing queue
  /// playing rather than emptying it.
  Future<void> startMix(String playlistId, {String? videoId}) async {
    // A second tap while the first is still in flight is the same tap. See
    // [isStartingMix] for what it used to cost.
    if (isStartingMix) return;

    // **The old queue goes the moment the tap lands, not when the mix does.**
    // Keeping it until the items arrived left the old video playing, and the
    // old queue on screen, for the second `mix.start` takes — on a page that
    // was supposed to be opening something else. Emptying it moves the
    // playhead, which is what makes the playback controller stop the video,
    // and `startingMixId` is what puts the skeleton up in its place.
    //
    // It is held rather than dropped: the snapshot is the undo on success and
    // the rollback on failure.
    final previous = state.isEmpty ? null : state;
    _replaced = null;
    _mixError = null;
    _extending = false;
    state = QueueState._(const [], version: state.version + 1, startingMixId: playlistId);

    final MixStart result;
    try {
      result = await ref.read(mixServiceProvider).start(playlistId, videoId: videoId);
    } catch (_) {
      _rollBack(previous);
      rethrow;
    }

    if (result.items.isEmpty) {
      _rollBack(previous);
      throw StateError('mix.start returned no items for $playlistId');
    }

    _replaced = previous;
    // One write that clears the loading flag *and* installs the mix —
    // `startedMix` builds a fresh state with no `startingMixId`. Two writes
    // would put a frame of "not loading, nothing playing" between them: the
    // empty watch page flashing up just before the video arrives.
    _set(state.startedMix(
      result.items,
      MixQueue(playlistId: result.playlistId, title: result.title),
    ));
  }

  /// A start that failed puts back what it cleared.
  ///
  /// The queue was emptied when the tap landed, so leaving it empty here would
  /// turn a network hiccup into losing the user's queue. The caller shows the
  /// error and re-seeks the restored video.
  void _rollBack(QueueState? previous) {
    state = previous == null
        ? QueueState._(const [], version: state.version)
        : previous.restoredAfter(state.version);
  }

  /// Put back the queue a mix replaced. Idempotent — a second Undo does
  /// nothing rather than replacing the restored queue with itself.
  void undoStartMix() {
    final previous = _replaced;
    if (previous == null) return;
    _replaced = null;
    _mixError = null;
    _extending = false;
    // `version` must move or the playback controller will not reopen the video
    // the user was on: it listens for a playhead change, and restoring a
    // snapshot is one. Entries are carried forward, so the panel reads the
    // restored rows as the same ones rather than as arrivals.
    _set(previous.restoredAfter(state.version));
  }

  /// Top the mix up before the user can see it run out (§4).
  ///
  /// Deliberately fire-and-forget: this runs off an ordinary queue mutation
  /// and nothing waits for it. A failure leaves the queue exactly as playable
  /// as it was.
  void _maybeExtend() {
    final mix = state.mix;
    if (mix == null || mix.exhausted || _extending) return;
    final remaining = state.remainingAfterCurrent;
    if (remaining == null || remaining > extendThreshold) return;
    if (state.entries.isEmpty) return;

    _extending = true;
    unawaited(_extend(mix.playlistId, state.entries.last.item.id));
  }

  Future<void> _extend(String playlistId, String anchor) async {
    try {
      final result = await ref.read(mixServiceProvider).extend(playlistId, anchor);
      // The mix may have been replaced or cleared while this was in flight.
      // Appending to a queue that is no longer this mix is the one genuinely
      // wrong outcome available here.
      if (state.mix?.playlistId != playlistId) return;
      _mixError = null;
      if (result.items.isNotEmpty) state = state.extendedWith(result.items);
      if (result.exhausted) state = state.mixExhausted();
    } on Object catch (e) {
      // Not fatal (§4): the queue plays what it has. Not marked exhausted
      // either, so the next advance retries — a natural backoff of one attempt
      // per playhead move rather than a timer nobody would remember to cancel.
      if (state.mix?.playlistId == playlistId) _mixError = '$e';
    } finally {
      _extending = false;
    }
  }
}

final queueProvider = NotifierProvider<QueueController, QueueState>(QueueController.new);
