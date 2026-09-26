import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../../domain/comment.dart';
import '../../domain/feed_item.dart' as domain;
import '../../data/comments_source.dart';
import '../../data/rpc/client.dart';
import '../../theme/tokens.dart';
import '../auth_controller.dart';
import '../open_video.dart' show copyToClipboard;
import '../playback_controller.dart';
import 'comment_composer.dart';

class CommentsSection extends ConsumerStatefulWidget {
  final String videoId;
  final String initialContinuation;

  const CommentsSection({
    super.key,
    required this.videoId,
    required this.initialContinuation,
  });

  @override
  ConsumerState<CommentsSection> createState() => _CommentsSectionState();
}

/// Everything one top-level thread holds about its replies.
///
/// **Kept by the section, not by the row that draws the thread.** A row is a
/// child of a `SliverList`, which disposes it when it scrolls out of the viewport,
/// and the expansion, the loaded replies, the "Show more replies" token and a
/// half-typed reply went with it: scroll a thread away and back and it was
/// collapsed with its replies gone (measured 2026-09-19, `architecture.md` F34).
/// State that must outlive a row cannot live in one.
class _CommentState {
  final List<Comment> replies = [];

  /// The "Show more replies" token, or null once the list is complete.
  String? continuation;

  bool expanded = false;
  bool loading = false;
  bool error = false;

  /// Set once the first reply fetch has actually completed (empty or not).
  ///
  /// Once it is set *and no "Show more replies" token remains*, [replies].length
  /// is the ground truth for how many replies exist, in preference to the thread's
  /// own `replyCount`. That count is a display string baked into the page load and
  /// never revised client-side — on youtube.com too. Delete a reply there and the
  /// parent still says "1 reply"; expanding it re-sends the same replies
  /// continuation, which correctly comes back empty (the deletion was real), and
  /// nothing renders — indistinguishable from a stuck load. It also *lags*
  /// removals it never saw: measured 2026-09-18, a signed-in view still advertised
  /// a reply that someone else had removed, while the anonymous view of the same
  /// comment already said 0 (`protocol.md` §3.3). rill has better information once
  /// it has the whole list: use it, and stop re-issuing a fetch that can only ever
  /// repeat that answer.
  bool loadedOnce = false;

  /// The reply page currently out, so a thread that goes away mid-load — a
  /// re-sort drops every one of them — releases the sidecar instead of leaving
  /// the request running for nobody.
  int? request;

  /// True once the list this belonged to is gone (a re-sort, a new video, a
  /// delete): an answer still on its way must not be applied to it.
  bool discarded = false;

  bool replying = false;
  bool posting = false;
  TextEditingController? draft;
  FocusNode? focus;

  void dispose() {
    draft?.dispose();
    focus?.dispose();
    draft = null;
    focus = null;
  }
}

enum _RowKind { thread, reply, footer }

/// One row of the flattened list: a thread, one of its replies, or the
/// spinner / retry / "Show more replies" that follows an expanded thread's replies.
class _Row {
  const _Row(this.kind, this.thread, [this.reply]);

  final _RowKind kind;
  final Comment thread;
  final Comment? reply;

  Key get key => switch (kind) {
    _RowKind.thread => ValueKey('t:${thread.id}'),
    _RowKind.reply => ValueKey('r:${reply!.id}'),
    _RowKind.footer => ValueKey('f:${thread.id}'),
  };
}

/// A thread's own avatar plus its column: `avatar (32) + 12` is where a reply's
/// left edge sits under it.
const double _replyIndent = 44;

class _CommentsSectionState extends ConsumerState<CommentsSection> {
  final List<Comment> _threads = [];
  List<domain.Chip>? _chips;
  String? _continuation;
  String? _commentCount;

  /// The comment box's own submit token — null when the viewer cannot comment.
  /// Kept across pages like [_commentCount]: only the first page of a list
  /// carries the header it rides on, so a continuation must not blank it.
  String? _createParams;
  bool _loading = false;
  bool _error = false;

  late final CommentsSource _source;

  /// Bumped by every page request and by anything that supersedes one; a
  /// response is applied only while its generation is still current.
  ///
  /// `$cancel` is best-effort — the sidecar can already have written the answer
  /// — so a superseded page that lands anyway is dropped here, not merged
  /// (`FeedController` and `protocol.md` §4 have the same rule). Two things
  /// supersede a page: a re-sort, whose click is the newest word on what the
  /// list should be, and a change of video.
  int _generation = 0;
  int? _inFlight;

  /// Per-thread reply state, by the thread's comment id — see [_CommentState].
  final Map<String, _CommentState> _commentStates = {};

  /// Comments (top-level or replies) with a delete in flight.
  final Set<String> _deleting = {};

  /// A vote is in flight on these, so both buttons are disabled: a second press
  /// would race the first and the two answers could land out of order.
  final Set<String> _rating = {};

  /// Why the viewer may not vote, or null when they may. Refreshed in [build].
  ///
  /// Held as a field because the rows are built lazily by the sliver, after
  /// `build` has returned, and a `ref.watch` from there would be a watch during
  /// layout. **It is not derived from the vote tokens** — those are present on
  /// anonymous pages too, so a button gated on them would always be enabled and
  /// always fail (`architecture.md` F33 is the same mistake read off a
  /// tooltip).
  ///
  /// A **degraded** session is excluded as well as an anonymous one, and it is
  /// worth saying why that is free: `AuthState.isSignedIn` is strictly
  /// `status == authenticated`, and `degraded` is its own status fed by
  /// `auth.verify` (hard invariant 5 — `logged_in` is cookie presence, not
  /// server acceptance). So a cookie YouTube has stopped honouring disables
  /// these rather than offering a vote that would fail.
  String? _voteDisabledReason;

  /// Comments whose text is expanded past its four lines. Here for the same
  /// reason [_commentStates] is: it is state a row must not lose by scrolling.
  final Set<String> _textExpanded = {};

  @override
  void initState() {
    super.initState();
    _source = ref.read(commentsSourceProvider);
    _continuation = widget.initialContinuation;
    _fetch();
  }

  @override
  void didUpdateWidget(CommentsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) _resetForNewVideo();
  }

  @override
  void dispose() {
    _generation++;
    _cancelInFlight();
    // The rows are already unmounted (children go before their parent), so the
    // controllers they held can go now, not a frame later.
    for (final state in _commentStates.values) {
      final request = state.request;
      if (request != null) _source.cancel(request);
      state.discarded = true;
      state.dispose();
    }
    super.dispose();
  }

  /// The watch page swaps the video in place (a queue jump), and a video it has
  /// already loaded hands this widget its cached detail on the very first frame,
  /// so the section is *updated*, not rebuilt. Everything it holds belongs to the
  /// video it was showing — its threads, sort, count and, the one that bites, the
  /// comment box's token, which encodes that video's id: a comment written here
  /// would have been posted to the previous video.
  void _resetForNewVideo() {
    _generation++;
    _cancelInFlight();
    _threads.clear();
    _forgetComments();
    _chips = null;
    _commentCount = null;
    _createParams = null;
    _loading = false;
    _error = false;
    _continuation = widget.initialContinuation;
    _fetch();
  }

  void _cancelInFlight() {
    final id = _inFlight;
    if (id == null) return;
    _source.cancel(id);
    _inFlight = null;
  }

  /// Drops every thread's reply state: the list it belonged to is gone.
  void _forgetComments() {
    final gone = _commentStates.values.toList();
    _commentStates.clear();
    _deleting.clear();
    _textExpanded.clear();
    // `_rating` is deliberately *not* cleared, unlike its two neighbours. A
    // vote in flight is still in flight after a re-sort, and every completion
    // path removes its own id, so clearing here would only re-enable the
    // buttons for the rest of that request and let a second press race it.
    for (final state in gone) {
      final request = state.request;
      if (request != null) _source.cancel(request);
      state.discarded = true;
    }
    _disposeAfterFrame(gone);
  }

  /// The reply boxes that hold these controllers are still in the tree until the
  /// frame that removes them has built.
  void _disposeAfterFrame(List<_CommentState> states) {
    if (states.isEmpty) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final state in states) {
        state.dispose();
      }
    });
  }

  /// Posts a top-level comment and puts it at the top of the list, as
  /// youtube.com does whatever the sort.
  ///
  /// The sidecar answers the *created* comment, parsed from the create
  /// response, so the new row has its real id and — because YouTube issues them
  /// for an author's own comment — a delete and a reply token, and can be
  /// deleted or replied to at once. Only if a response carried no comment does
  /// this fall back to one built from what was typed, which has neither until
  /// the list is next fetched (the same trade replies make).
  ///
  /// `false` on any failure, with the reason in a snackbar: the composer keeps
  /// the typed text for exactly that case.
  Future<bool> _postComment(String text) async {
    final createParams = _createParams;
    if (createParams == null) return false;

    final messenger = ScaffoldMessenger.of(context);
    final auth = ref.read(authProvider);
    final generation = _generation;
    try {
      final created = await _source.post(createParams, text);
      // Posted, but to a video this list no longer shows: it must not be put
      // among another video's comments.
      if (!mounted || generation != _generation) return true;

      final posted =
          created ??
          Comment(
            id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
            authorName: auth.displayName,
            authorAvatarUrl: auth.accountAvatarUrl ?? '',
            text: CommentText(content: text),
            replyCount: 0,
          );
      // The server's own "0 seconds ago" reads as a bug; we know it is new.
      setState(() => _threads.insert(0, posted.copyWith(publishedText: 'Just now')));
      return true;
    } on RpcException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to comment' : e.message)),
      );
      return false;
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }

  /// Loads the page [_continuation] names.
  ///
  /// A load-more or a retry never pre-empts a load already out — that would be
  /// the same page asked twice. A [refresh] (a re-sort) does, always: it drops
  /// the list, cancels whatever was loading, and the page it asks for is the only
  /// one that may land. Before this the click was *dropped* while a page was
  /// loading — after [_applySort] had already overwritten [_continuation], so if
  /// that page then failed, "Tap to retry" appended the *new* sort's first page to
  /// the old sort's threads (`docs/tasks/27-comments.md` §3: a sort change must
  /// not merge pages).
  Future<void> _fetch({bool refresh = false}) async {
    if (!mounted) return;
    if (_loading && !refresh) return;
    final continuation = _continuation;
    if (continuation == null) return;

    _cancelInFlight();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = false;
      if (refresh) {
        _threads.clear();
        _forgetComments();
      }
    });

    final request = _source.page(continuation);
    _inFlight = request.id;

    try {
      final result = await request.response;
      if (!mounted || generation != _generation) return;
      _inFlight = null;

      setState(() {
        _threads.addAll(result.items);
        _continuation = result.continuation;
        if (result.chips != null && result.chips!.isNotEmpty) {
          _chips = result.chips?.cast<domain.Chip>();
        }
        if (result.commentCount != null) {
          _commentCount = result.commentCount;
        }
        if (result.createParams != null) {
          _createParams = result.createParams;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      _inFlight = null;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  void _applySort(String token) {
    _continuation = token;
    _fetch(refresh: true);
  }

  // ---------------------------------------------------------------------------
  // Replies
  // ---------------------------------------------------------------------------

  _CommentState _stateOf(Comment comment) => _commentStates.putIfAbsent(comment.id, _CommentState.new);

  /// How many replies to say a thread has.
  ///
  /// Ground truth once the list is *complete*: covers both a locally added
  /// optimistic reply (higher than the page-load count) and a deleted one
  /// (lower) — the thread's `replyCount` is a snapshot from page load and is
  /// never revised by either, on this app or on youtube.com itself.
  ///
  /// Only complete, though. While a "Show more replies" token remains the list is
  /// a prefix, and its length would report 10 for a 962-reply thread.
  int _replyCountFor(Comment thread) {
    final state = _commentStates[thread.id];
    if (state == null) return thread.replyCount;
    final listIsComplete = state.loadedOnce && state.continuation == null;
    final advertisedOrLoaded = thread.replyCount > state.replies.length ? thread.replyCount : state.replies.length;
    return listIsComplete ? state.replies.length : advertisedOrLoaded;
  }

  void _toggleReplies(Comment comment) {
    final state = _stateOf(comment);
    if (state.expanded) {
      setState(() => state.expanded = false);
      return;
    }
    setState(() => state.expanded = true);
    _loadRepliesOnce(comment);
  }

  /// The auto-load every expand path shares: fetch the first page exactly
  /// once. Never re-triggered by the list being empty — that is also true right
  /// after deleting the last reply, and re-fetching then would just replay the
  /// stale-count/empty-result mismatch this method exists to avoid. "Show more
  /// replies" is unaffected: that button calls [_loadReplies] directly, and
  /// genuine pagination still has a real `continuation` to follow.
  void _loadRepliesOnce(Comment comment) {
    final state = _stateOf(comment);
    if (state.loadedOnce || state.loading) return;
    if (comment.replyCount > 0 || comment.repliesContinuation != null) _loadReplies(comment);
  }

  Future<void> _loadReplies(Comment comment) async {
    final state = _stateOf(comment);
    if (state.loading) return;
    final token = comment.repliesContinuation;
    if (token == null) return;

    if (!mounted) return;
    setState(() {
      state.loading = true;
      state.error = false;
    });

    final request = _source.page(state.continuation ?? token);
    state.request = request.id;
    try {
      final result = await request.response;
      state.request = null;
      if (mounted && !state.discarded) {
        setState(() {
          state.replies.addAll(result.items);
          state.continuation = result.continuation;
          state.loading = false;
          state.loadedOnce = true;
        });
      }
    } catch (e) {
      state.request = null;
      if (mounted && !state.discarded) {
        setState(() {
          state.loading = false;
          state.error = true;
        });
      }
    }
  }

  void _startReply(Comment thread) {
    final state = _stateOf(thread);
    state.draft ??= TextEditingController();
    state.focus ??= FocusNode();
    setState(() {
      state.replying = true;
      state.expanded = true;
    });
    _loadRepliesOnce(thread);
    // Not `autofocus`: a row that scrolls away and back is rebuilt, and a rebuilt
    // autofocus field would take the focus back from wherever the user went.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && !state.discarded) state.focus?.requestFocus();
    });
  }

  void _cancelReply(Comment thread) {
    final state = _stateOf(thread);
    state.draft?.clear();
    setState(() => state.replying = false);
  }

  /// Posts the reply, then shows it immediately rather than waiting on a
  /// refetch — the sidecar's `action.replyToComment` deliberately answers
  /// `{}` (protocol.md §3.4), the same fire-and-forget shape every other
  /// write here uses, so the reply shown is built from what was just typed
  /// and the signed-in account, not from a server echo. It carries no real
  /// `id`/`deleteParams` until the thread is reloaded — acceptable for the
  /// same reason the Save-to-playlist dialog accepts the same gap (Task 25).
  Future<void> _submitReply(Comment thread) async {
    final state = _stateOf(thread);
    final text = state.draft?.text.trim() ?? '';
    final replyParams = thread.replyParams;
    if (text.isEmpty || replyParams == null || state.posting) return;

    final messenger = ScaffoldMessenger.of(context);
    final auth = ref.read(authProvider);

    setState(() => state.posting = true);
    try {
      await _source.reply(replyParams, text);
      if (!mounted || state.discarded) return;
      setState(() {
        state.replies.add(
          Comment(
            id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
            authorName: auth.displayName,
            authorAvatarUrl: auth.accountAvatarUrl ?? '',
            text: CommentText(content: text),
            replyCount: 0,
            depth: thread.depth + 1,
            publishedText: 'Just now',
          ),
        );
        state.draft?.clear();
        state.replying = false;
        state.posting = false;
      });
    } on RpcException catch (e) {
      if (!mounted || state.discarded) return;
      setState(() => state.posting = false);
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to reply' : e.message)));
    } on Object catch (e) {
      if (!mounted || state.discarded) return;
      setState(() => state.posting = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Deletes [comment] — a top-level thread, or a reply when [parent] is its
  /// thread — once the user has confirmed, and removes it from view only once the
  /// delete has actually succeeded. An unconfirmed delete must not disappear
  /// (`docs/tasks/25-actions.md` §4's "a failure that silently reverts looks like
  /// the click did not register" applies just as much to a comment vanishing as to
  /// a like bouncing back).
  Future<void> _confirmDelete(Comment comment, {Comment? parent}) async {
    final deleteParams = comment.deleteParams;
    if (deleteParams == null || _deleting.contains(comment.id)) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete comment'),
        content: const Text('Delete your comment permanently?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _deleting.add(comment.id));
    try {
      await _source.delete(deleteParams);
      if (!mounted) return;
      setState(() {
        _deleting.remove(comment.id);
        if (parent == null) {
          _threads.removeWhere((thread) => thread.id == comment.id);
          final gone = _commentStates.remove(comment.id);
          if (gone != null) {
            final request = gone.request;
            if (request != null) _source.cancel(request);
            gone.discarded = true;
            _disposeAfterFrame([gone]);
          }
        } else {
          _commentStates[parent.id]?.replies.removeWhere((reply) => reply.id == comment.id);
          final gone = _commentStates.remove(comment.id);
          if (gone != null) {
            final request = gone.request;
            if (request != null) _source.cancel(request);
            gone.discarded = true;
            _disposeAfterFrame([gone]);
          }
        }
      });
    } on RpcException catch (e) {
      if (!mounted) return;
      setState(() => _deleting.remove(comment.id));
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to delete' : e.message)));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _deleting.remove(comment.id));
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Vote on a comment, optimistically.
  ///
  /// The caller names the *target* rating and this picks the token, because the
  /// four blobs are transitions (`like`, `unlike`, `dislike`, `undislike`) and
  /// only this half knows what the current rating is. A press that has no token
  /// for its transition does nothing rather than guessing — the blobs are
  /// server-supplied and nothing here can build one.
  ///
  /// **The like count is deliberately left alone.** It arrives as a display
  /// string YouTube has already formatted ("4.8K"), and the sidecar ships the
  /// variant matching the current state, so the other one is not in hand. The
  /// repo's rule is that a count is a display string and not parsed; inventing
  /// "4.8K + 1" would be inventing data. It corrects itself on the next fetch.
  Future<void> _rate(Comment comment, String target, {Comment? parent}) async {
    final params = switch ((comment.myRating, target)) {
      (_, 'like') => comment.likeParams,
      ('like', 'none') => comment.unlikeParams,
      (_, 'dislike') => comment.dislikeParams,
      ('dislike', 'none') => comment.undislikeParams,
      _ => null,
    };
    if (params == null || _rating.contains(comment.id)) return;

    final messenger = ScaffoldMessenger.of(context);
    final previous = comment.myRating;
    setState(() {
      _rating.add(comment.id);
      _replaceComment(comment.id, (c) => c.copyWith(myRating: target), parent: parent);
    });

    try {
      await _source.rate(params);
      if (!mounted) return;
      setState(() => _rating.remove(comment.id));
    } on Object catch (e) {
      if (!mounted) return;
      // Put it back. An optimistic update that fails silently leaves the button
      // showing a vote the server never recorded, which is worse than no
      // optimism at all.
      setState(() {
        _rating.remove(comment.id);
        _replaceComment(comment.id, (c) => c.copyWith(myRating: previous), parent: parent);
      });
      final message = e is RpcException ? (e.code == 'AUTH_REQUIRED' ? 'Sign in to vote' : e.message) : '$e';
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Swap one comment in place, wherever it lives — a top-level thread or a
  /// reply held by its thread's state. Both lists are the section's, and a row
  /// is rebuilt from them, so this is the only way to move a rendered comment.
  void _replaceComment(String id, Comment Function(Comment) update, {Comment? parent}) {
    if (parent == null) {
      final index = _threads.indexWhere((thread) => thread.id == id);
      if (index != -1) _threads[index] = update(_threads[index]);
      return;
    }
    final replies = _commentStates[parent.id]?.replies;
    if (replies == null) return;
    final index = replies.indexWhere((reply) => reply.id == id);
    if (index != -1) replies[index] = update(replies[index]);
  }

  /// A link to one comment — `watch?v=<videoId>&lc=<commentId>`, the shape
  /// `todo.md` 40 measured against youtube.com and the one its stage 1 asks for
  /// ("a **Copy link** action on every comment"). The `watch?v=` form rather
  /// than `youtu.be/`: `lc` was measured on that one.
  ///
  /// rill cannot yet *open* such a link — that is the rest of item 40 — so for
  /// now this produces a link that works on youtube.com and will work here once
  /// the entry point lands. Worth knowing before treating it as round-tripping.
  void _copyLink(Comment comment) {
    unawaited(
      copyToClipboard(
        context,
        'https://www.youtube.com/watch?v=${widget.videoId}&lc=${comment.id}',
        'Link copied to clipboard',
      ),
    );
  }

  void _toggleText(String id) {
    setState(() {
      if (!_textExpanded.remove(id)) _textExpanded.add(id);
    });
  }

  // ---------------------------------------------------------------------------
  // The flattened list
  // ---------------------------------------------------------------------------

  /// `[thread, reply, reply, …, footer, thread, …]`.
  ///
  /// One list for one `SliverList`, so that a thread's replies are built lazily
  /// like everything else instead of eagerly inside their thread: with the replies
  /// a `Column` in a row, re-expanding a thread holding 500 mounted all 500 in one
  /// frame (345 ms measured), and a thread's expansion could not outlive its row.
  List<_Row> _flatten() {
    final rows = <_Row>[];

    void walk(Comment parent, Comment thread) {
      final state = _commentStates[parent.id];
      if (state == null || !state.expanded) return;
      for (final child in state.replies) {
        rows.add(_Row(_RowKind.reply, thread, child));
        walk(child, thread);
      }
      if (state.loading || state.error || state.continuation != null) {
        rows.add(_Row(_RowKind.footer, thread, parent));
      }
    }

    for (final thread in _threads) {
      rows.add(_Row(_RowKind.thread, thread));
      walk(thread, thread);
    }
    return rows;
  }

  Widget _buildRow(List<_Row> rows, int index) {
    final row = rows[index];
    // The thread's own bottom margin comes after its *last* row now, not after
    // itself: it used to wrap the whole block, replies included.
    final endsBlock = index == rows.length - 1 || rows[index + 1].kind == _RowKind.thread;
    return switch (row.kind) {
      _RowKind.thread => _threadRow(row.thread, endsBlock),
      _RowKind.reply => _replyRow(row.thread, row.reply!, endsBlock),
      _RowKind.footer => _footerRow(row.reply ?? row.thread),
    };
  }

  Widget _threadRow(Comment thread, bool endsBlock) {
    final state = _commentStates[thread.id];
    final replyCount = _replyCountFor(thread);
    final expanded = state?.expanded ?? false;
    final replying = state?.replying ?? false;
    final posting = state?.posting ?? false;
    final theme = Theme.of(context).colorScheme;

    const lines = 10;

    return Opacity(
      key: ValueKey('t:${thread.id}'),
      opacity: _deleting.contains(thread.id) ? 0.5 : 1.0,
      child: Padding(
        padding: EdgeInsets.only(bottom: endsBlock ? 16.0 : 0),
        child: CommentTile(
          comment: thread,
          deleting: _deleting.contains(thread.id),
          onDelete: () => _confirmDelete(thread),
          onReply: thread.replyParams != null && !replying ? () => _startReply(thread) : null,
          onRate: _voteDisabledReason == null ? (target) => _rate(thread, target) : null,
          onCopyLink: () => _copyLink(thread),
          rating: _rating.contains(thread.id),
          voteDisabledReason: _voteDisabledReason,
          textExpanded: _textExpanded.contains(thread.id),
          onToggleText: () => _toggleText(thread.id),
          below: [
            if (replying)
              Padding(
                padding: const EdgeInsets.only(top: 4.0, left: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.only(top: 6, left: 7, right: 7, bottom: 6),
                      decoration: BoxDecoration(
                        color: theme.surfaceContainerHigh.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(minHeight: 32, maxHeight: 25.0 * lines),
                      child: SilkyScroll(
                        builder: (context, controller, physics, _) => TextField(
                          controller: state!.draft,
                          focusNode: state.focus,
                          enabled: !posting,
                          minLines: 1,
                          maxLines: lines,
                          scrollController: controller,
                          scrollPhysics: physics,
                          style: const TextStyle(fontSize: 14),
                          decoration: const InputDecoration(
                            hintFadeDuration: Duration(milliseconds: 200),
                            isDense: true,
                            hintText: 'Add a reply...',
                            border: UnderlineInputBorder(),
                          ),
                          onSubmitted: (_) => _submitReply(thread),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 32,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(enabledMouseCursor: SystemMouseCursors.click),
                            onPressed: posting ? null : () => _cancelReply(thread),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: posting ? null : () => _submitReply(thread),
                            style: TextButton.styleFrom(enabledMouseCursor: SystemMouseCursors.click),
                            child: posting
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text('Reply'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (replyCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: TextButton(
                  style: TextButton.styleFrom(enabledMouseCursor: SystemMouseCursors.click),
                  onPressed: () => _toggleReplies(thread),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 4),
                      Text(expanded ? 'Hide replies' : (replyCount > 0 ? '$replyCount replies' : 'Show replies')),
                      const SizedBox(width: 4),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 16),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _replyRow(Comment thread, Comment reply, bool endsBlock) {
    final deleting = _deleting.contains(reply.id);
    final safeDepth = reply.depth > 3 ? 3 : reply.depth;
    return Opacity(
      key: ValueKey('r:${reply.id}'),
      // A reply under a thread being deleted goes down with it, as it did when it
      // was drawn inside that thread.
      opacity: deleting || _deleting.contains(thread.id) ? 0.5 : 1.0,
      child: Padding(
        // 12 above, the reply's own 16 below, and — after the block's last row —
        // the 16 the thread used to put around all of it.
        padding: EdgeInsets.only(left: _replyIndent * safeDepth, top: 12.0, bottom: endsBlock ? 32.0 : 16.0),
        child: CommentTile(
          comment: reply,
          deleting: deleting,
          onDelete: () => _confirmDelete(reply, parent: thread),
          onRate: _voteDisabledReason == null ? (target) => _rate(reply, target, parent: thread) : null,
          onCopyLink: () => _copyLink(reply),
          rating: _rating.contains(reply.id),
          voteDisabledReason: _voteDisabledReason,
          textExpanded: _textExpanded.contains(reply.id),
          onToggleText: () => _toggleText(reply.id),
        ),
      ),
    );
  }

  Widget _footerRow(Comment parent) {
    final state = _commentStates[parent.id]!;
    final Widget content;
    if (state.loading) {
      content = const Padding(
        padding: EdgeInsets.only(top: 12.0, bottom: 8.0),
        child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (state.error) {
      content = Padding(
        padding: const EdgeInsets.only(top: 8.0),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: TextButton(
            onPressed: () => _loadReplies(parent),
            child: const Text('Tap to retry'),
          ),
        ),
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.only(top: 8.0),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: TextButton(
            onPressed: () => _loadReplies(parent),
            child: const Text('Show more replies'),
          ),
        ),
      );
    }
    return Opacity(
      key: ValueKey('f:${parent.id}'),
      opacity: _deleting.contains(parent.id) ? 0.5 : 1.0,
      child: Padding(
        padding: EdgeInsets.only(left: _replyIndent * (parent.depth == 0 ? 1 : parent.depth + 1), bottom: 16.0),
        child: Align(alignment: Alignment.centerLeft, child: content),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A video with comments on and none yet still shows the box: it is how the
    // first one gets written. Nothing to show only when there is nothing to
    // read *and* nothing to write with.
    if (_threads.isEmpty && !_loading && !_error && _createParams == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final avatarUrl = ref.watch(authProvider.select((auth) => auth.accountAvatarUrl));
    final status = ref.watch(authProvider.select((auth) => auth.status));
    // `signedInActionBlocker` so the watch page's like, subscribe and Watch
    // Later say this in the same words — one sentence, written once.
    _voteDisabledReason = signedInActionBlocker(status, 'vote');
    final rows = _flatten();
    final indexByKey = {for (var i = 0; i < rows.length; i++) rows[i].key: i};

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      sliver: SliverMainAxisGroup(
        slivers: [
          if (_commentCount != null || (_chips != null && _chips!.isNotEmpty))
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_commentCount != null)
                      Text(
                        _commentCount!,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    if (_chips != null && _chips!.isNotEmpty) ...[
                      SizedBox(width: 16),
                      Wrap(
                        spacing: 8.0,
                        children: _chips!.map((c) {
                          final isSelected = c.selected;
                          return ChoiceChip(
                            label: Text(c.label),
                            selected: isSelected,
                            onSelected: (selected) {
                              if (selected) _applySort(c.token);
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (_createParams != null)
            SliverToBoxAdapter(
              key: const ValueKey('comment-composer'),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: CommentComposer(avatarUrl: avatarUrl, onPost: _postComment),
              ),
            ),
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) => _buildRow(rows, index),
            findChildIndexCallback: (key) => indexByKey[key],
          ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24.0),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (_error)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: TextButton(
                    onPressed: () => _fetch(),
                    child: const Text('Tap to retry'),
                  ),
                ),
              ),
            )
          else if (_continuation != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: TextButton(
                    onPressed: () => _fetch(),
                    child: const Text('Show more comments'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One comment — a thread's or a reply's: avatar, author, text, likes.
///
/// **Holds no state.** It used to be a `ConsumerStatefulWidget` that kept a
/// thread's expansion, its loaded replies and its reply draft, and drew the
/// replies itself; every one of those is [_CommentsSectionState]'s now, so that
/// a row scrolled out of the viewport and disposed takes nothing with it. What
/// goes under the actions row — the reply box, the "Show N replies" toggle — comes
/// in as [below].
class CommentTile extends ConsumerWidget {
  const CommentTile({
    super.key,
    required this.comment,
    this.deleting = false,
    this.onDelete,
    this.onReply,
    this.onRate,
    this.onCopyLink,
    this.rating = false,
    this.voteDisabledReason,
    this.textExpanded = false,
    this.onToggleText,
    this.below = const [],
  });

  final Comment comment;

  /// A delete of this comment is in flight: the button is disabled.
  final bool deleting;

  /// Asks to delete the comment. Only drawn for a comment that carries the token
  /// to do it with — the viewer's own.
  final VoidCallback? onDelete;

  /// Opens a reply box under the comment. Null draws no Reply button: a reply
  /// attaches to the top-level thread (youtube.com has no second level of
  /// nesting), and a signed-out viewer has no token to reply with.
  final VoidCallback? onReply;

  /// Asks for a vote — the *target* rating, not a token. Which of the comment's
  /// four blobs that becomes is [_CommentsSectionState]'s to decide, because it
  /// is the half that knows what the current rating is.
  ///
  /// Null disables both buttons. **It is not derived from the tokens**: all four
  /// are present anonymously, so a button enabled by their presence would be a
  /// button that always fails.
  final void Function(String rating)? onRate;

  /// A vote on this comment is in flight: both buttons are disabled so a second
  /// press cannot race the first.
  final bool rating;

  /// Copies a link to this comment. Built by the section, which is the half
  /// that knows the video id — `watch?v=<videoId>&lc=<commentId>`, the shape
  /// `todo.md` 40 measured. Null draws no button.
  ///
  /// The comment's *text* is not copied by a button: it is selectable, so it
  /// goes on the clipboard the way text does everywhere else.
  final VoidCallback? onCopyLink;

  /// Why the vote buttons are disabled, as the tooltip to show instead of
  /// "Like"/"Dislike". Null when they are live.
  ///
  /// A disabled control that will not say why is the complaint that produced
  /// this: the viewer cannot tell "you must sign in" from "this is broken", and
  /// the two need different actions from them.
  final String? voteDisabledReason;

  final bool textExpanded;
  final VoidCallback? onToggleText;

  final List<Widget> below;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return _HoverScope(
      builder: (hovering) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                // Empty for a comment just posted that the server has not echoed
                // back (`_postComment`'s stand-in) — `NetworkImage('')` is an image
                // error, not a blank, so it is left out instead.
                backgroundImage: comment.authorAvatarUrl.isEmpty ? null : NetworkImage(comment.authorAvatarUrl),
                onBackgroundImageError: comment.authorAvatarUrl.isEmpty ? null : (_, _) {},
                radius: 16,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          comment.authorName,
                          style: TextStyle(
                            fontWeight: comment.isUploader ? FontWeight.bold : FontWeight.w500,
                            fontSize: 13,
                            color: scheme.onSurface,
                          ),
                        ),
                        if (comment.isVerified)
                          Padding(
                            padding: const EdgeInsets.only(left: 4.0),
                            child: Icon(Icons.check_circle, size: 12, color: scheme.onSurfaceVariant),
                          ),
                        if (comment.publishedText != null) ...[
                          const SizedBox(width: 8),
                          SelectableText(
                            comment.publishedText!,
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ],
                        if (comment.deleteParams != null) ...[
                          const Spacer(),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 16),
                              tooltip: 'Delete',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                              onPressed: deleting ? null : onDelete,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    _CommentText(text: comment.text, expanded: textExpanded, onToggle: onToggleText),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Row(
              children: [
                // Pressing the active vote clears it, which is what YouTube
                // does and what the `unlike`/`undislike` tokens exist for.
                _VoteButton(
                  icon: comment.myRating == 'like' ? Icons.thumb_up : Icons.thumb_up_alt_outlined,
                  tooltip: voteDisabledReason ?? (comment.myRating == 'like' ? 'Remove like' : 'Like'),
                  active: comment.myRating == 'like',
                  onPressed: onRate == null || rating ? null : () => onRate!(comment.myRating == 'like' ? 'none' : 'like'),
                  label: comment.likeCount,
                ),
                // const SizedBox(width: 4),
                // if (comment.likeCount != null) Text(comment.likeCount!, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                _VoteButton(
                  icon: comment.myRating == 'dislike' ? Icons.thumb_down : Icons.thumb_down_alt_outlined,
                  tooltip: voteDisabledReason ?? (comment.myRating == 'dislike' ? 'Remove dislike' : 'Dislike'),
                  active: comment.myRating == 'dislike',
                  onPressed: onRate == null || rating ? null : () => onRate!(comment.myRating == 'dislike' ? 'none' : 'dislike'),
                ),
                if (comment.creatorHearted) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Creator liked this comment', // TODO get creator name from channel info
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.favorite, size: 14, color: Theme.of(context).tokens.liveBadge),
                    ),
                  ),
                ],
                if (onReply != null) ...[
                  const SizedBox(width: 8),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: TextButton(
                      style: TextButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 2), minimumSize: const Size(50, 35)),
                      onPressed: onReply,
                      child: const Text('Reply', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
                // Copy, revealed by hovering anywhere on the comment.
                //
                // Only this subtree rebuilds when the pointer enters or leaves:
                // `_HoverScope` hands down a `ValueListenable` rather than
                // calling `setState` on the tile, so hovering a comment does not
                // rebuild its avatar, its text or its vote buttons. A tile is
                // rebuilt often enough already (F34).
                if (onCopyLink != null) ...[
                  const SizedBox(width: 8),
                  _RevealOnHoverOrFocus(
                    hovering: hovering,
                    child: _VoteButton(
                      icon: Icons.link,
                      tooltip: 'Copy link to this comment',
                      active: false,
                      onPressed: onCopyLink,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: EdgeInsetsGeometry.only(left: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: below,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tracks the pointer over its subtree and hands the answer down as a
/// [ValueListenable], so only what actually depends on hover rebuilds.
///
/// `setState` here would rebuild the whole comment — avatar, text, vote
/// buttons — every time the pointer crossed a row, and a list of comments is a
/// lot of rows to cross. The notifier lets one `ValueListenableBuilder` deep in
/// the tree be the only thing that moves.
///
/// Hover state is deliberately the one thing a tile may hold: it is transient,
/// it belongs to the pointer rather than to the viewer, and losing it when a
/// row scrolls out of the viewport is correct — unlike a thread's expansion or
/// a half-typed reply, which is why those live on the section (F34).

/// Shows [child] while the pointer is over the comment **or** while it holds
/// keyboard focus, and hides it otherwise.
///
/// **Focus is half of this, and it is the half that makes the control usable
/// at all.** Measured 2026-09-21, on the real widget rather than assumed:
///
/// - `Opacity` at exactly 0 drops its subtree from semantics altogether; a
///   screen reader does not see the button at all while it is faded out.
/// - `IgnorePointer(ignoring: true)` keeps the node but strips its **tap
///   action**, so even where the node survives it cannot be activated.
/// - Neither stops it taking **focus**: focus does not go through hit testing,
///   and it is not gated on opacity either.
///
/// So hover alone gives the worst pair: Tab lands on a button that is invisible
/// *and* cannot be pressed. Revealing on focus fixes both at once — it becomes
/// visible exactly when a keyboard user reaches it, and stops being ignored, so
/// the tap action comes back.
///
/// It remains easy to miss for someone scanning rather than tabbing. That is
/// inherent to a hover-revealed control, and the reason nothing important
/// should be put behind one — copying a link is a convenience, and the comment
/// body is selectable without it.
class _RevealOnHoverOrFocus extends StatefulWidget {
  const _RevealOnHoverOrFocus({required this.hovering, required this.child});

  final ValueListenable<bool> hovering;
  final Widget child;

  @override
  State<_RevealOnHoverOrFocus> createState() => _RevealOnHoverOrFocusState();
}

class _RevealOnHoverOrFocusState extends State<_RevealOnHoverOrFocus> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.hovering,
      builder: (context, hovering, child) {
        final visible = hovering || _focused;
        return AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          // Invisible and still clickable is worse than absent — the pointer
          // would find a button nobody can see.
          child: IgnorePointer(ignoring: !visible, child: child),
        );
      },
      // Outside the builder so it is not rebuilt as the opacity changes; the
      // `Focus` here reports its descendants' focus, which is the button's.
      child: Focus(
        // Guarded: focus can move *while* this is being unmounted — a list row
        // scrolling out from under a focused button is the ordinary case — and
        // `setState` on a defunct State throws during teardown. That is F38's
        // class of bug, and it is the kind that shows up once in twenty runs.
        onFocusChange: (focused) {
          if (mounted) setState(() => _focused = focused);
        },
        child: widget.child,
      ),
    );
  }
}

class _HoverScope extends StatefulWidget {
  const _HoverScope({required this.builder});

  final Widget Function(ValueListenable<bool> hovering) builder;

  @override
  State<_HoverScope> createState() => _HoverScopeState();
}

class _HoverScopeState extends State<_HoverScope> {
  final _hovering = ValueNotifier(false);
  bool _disposed = false;

  void _set(bool value) {
    if (!_disposed) _hovering.value = value;
  }

  @override
  void dispose() {
    _disposed = true;
    _hovering.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // Same guard as the focus one below: `onExit` fires as a row is removed
      // from under the pointer, and a `ValueNotifier` written after `dispose`
      // throws. Cheap insurance against a once-in-twenty-runs teardown failure.
      onEnter: (_) => _set(true),
      onExit: (_) => _set(false),
      // `opaque: false` so the region does not swallow hover from the controls
      // inside it — the vote buttons set their own cursor.
      opaque: false,
      child: widget.builder(_hovering),
    );
  }
}

class _CommentText extends ConsumerWidget {
  const _CommentText({required this.text, required this.expanded, required this.onToggle});

  final CommentText text;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    InlineSpan contentSpan;
    if (text.commandRuns == null && text.styleRuns == null) {
      contentSpan = TextSpan(text: text.content);
    } else {
      final spans = <TextSpan>[];
      int currentOffset = 0;
      final commands = List.of(text.commandRuns ?? <CommentCommandRun>[])..sort((a, b) => a.startIndex.compareTo(b.startIndex));

      for (final run in commands) {
        if (run.startIndex > currentOffset) {
          spans.add(TextSpan(text: text.content.substring(currentOffset, run.startIndex)));
        }
        final runText = text.content.substring(run.startIndex, run.startIndex + run.length);
        final isTimestamp = run.startTimeSeconds != null;
        spans.add(
          TextSpan(
            text: runText,
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
            recognizer: isTimestamp
                ? (TapGestureRecognizer()
                    ..onTap = () {
                      ref.read(playbackEngineProvider).seek(Duration(seconds: run.startTimeSeconds!));
                    })
                : null,
          ),
        );
        currentOffset = run.startIndex + run.length;
      }
      if (currentOffset < text.content.length) {
        spans.add(TextSpan(text: text.content.substring(currentOffset)));
      }
      contentSpan = TextSpan(children: spans);
    }

    final style = TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurface);
    final span = TextSpan(style: style, children: [contentSpan]);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: span,
          maxLines: 4,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        final isOverflowing = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Selectable, so the body is copied the way text is copied
            // everywhere else — drag to select, Ctrl+C, or right-click for the
            // platform menu. `SelectionArea` rather than `SelectableText.rich`
            // because the span carries `TapGestureRecognizer`s for links and
            // timestamps, and those keep working under it.
            SelectionArea(
              child: RichText(
                text: span,
                maxLines: expanded ? null : 4,
                overflow: expanded ? TextOverflow.visible : (isOverflowing ? TextOverflow.ellipsis : TextOverflow.clip),
              ),
            ),
            if (isOverflowing)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onToggle,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4.0, bottom: 4.0, right: 16.0),
                    child: Text(
                      expanded ? 'Read less' : 'Read more',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One vote button — a 14 px glyph in a 28 px tap target.
///
/// A widget rather than two inline `IconButton`s because the pair must stay
/// identical: before this existed they were bare `Icon`s, drawn but not
/// pressable, and the thumb-down was permanently outlined because nothing read
/// a dislike at all. Keeping the shape in one place is what stops them drifting
/// apart again.
class _VoteButton extends StatelessWidget {
  const _VoteButton({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
    this.label,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback? onPressed;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      mouseCursor: onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      icon: label == null
          ? Icon(icon, size: 14, color: active ? scheme.primary : null)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: active ? scheme.primary : null),
                const SizedBox(width: 4),
                Text(label!, style: TextStyle(fontSize: 12, color: active ? scheme.primary : null)),
              ],
            ),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: label == null ? EdgeInsets.symmetric(horizontal: 6, vertical: 2) : EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      constraints: const BoxConstraints(minHeight: 35),
      onPressed: onPressed,
    );
  }
}
