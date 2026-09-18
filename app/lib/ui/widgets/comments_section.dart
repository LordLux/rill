import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/comment.dart';
import '../../domain/feed_item.dart' as domain;
import '../../data/comments_source.dart';
import '../../data/rpc/client.dart';
import '../auth_controller.dart';
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
      final response = await RpcClient.instance.call('action.postComment', {
        'createParams': createParams,
        'commentText': text,
      });
      // Posted, but to a video this list no longer shows: it must not be put
      // among another video's comments.
      if (!mounted || generation != _generation) return true;

      final created = response is Map ? response['comment'] : null;
      final posted = created is Map
          ? Comment.fromJson(Map<String, Object?>.from(created))
          : Comment(
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
  /// loading, and the old sort's answer then arrived and was merged in — the
  /// exact case `docs/tasks/27-comments.md` §3 says must not happen.
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

  @override
  Widget build(BuildContext context) {
    // A video with comments on and none yet still shows the box: it is how the
    // first one gets written. Nothing to show only when there is nothing to
    // read *and* nothing to write with.
    if (_threads.isEmpty && !_loading && !_error && _createParams == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final avatarUrl = ref.watch(authProvider.select((auth) => auth.accountAvatarUrl));

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
            itemCount: _threads.length,
            itemBuilder: (context, index) {
              final thread = _threads[index];
              return CommentThreadWidget(
                key: ValueKey(thread.id),
                thread: thread,
                videoId: widget.videoId,
                onDeleted: () => setState(() => _threads.removeWhere((c) => c.id == thread.id)),
              );
            },
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

class CommentThreadWidget extends ConsumerStatefulWidget {
  final Comment thread;
  final String videoId;

  /// A reply rendered under its parent — never itself offered a reply
  /// composer, matching youtube.com: a reply attaches to the top-level
  /// thread, there is no second level of nesting.
  final bool isReply;

  /// Told to remove this comment from whichever list holds it, once a
  /// delete has actually succeeded. Not called on failure — an
  /// unconfirmed delete must not disappear from view (`docs/tasks/25-actions.md`
  /// §4's "a failure that silently reverts looks like the click did not
  /// register" applies just as much to a comment vanishing as to a like
  /// bouncing back).
  final VoidCallback? onDeleted;

  const CommentThreadWidget({
    super.key,
    required this.thread,
    required this.videoId,
    this.isReply = false,
    this.onDeleted,
  });

  @override
  ConsumerState<CommentThreadWidget> createState() => _CommentThreadWidgetState();
}

class _CommentThreadWidgetState extends ConsumerState<CommentThreadWidget> {
  final List<Comment> _replies = [];
  bool _expanded = false;
  bool _loadingReplies = false;
  bool _errorReplies = false;
  String? _repliesContinuation;

  /// Set once the first reply fetch has actually completed (empty or not).
  ///
  /// Once it is set *and no "Show more replies" token remains*, `_replies.length`
  /// is the ground truth for how many replies exist, in preference to
  /// `widget.thread.replyCount`. That count is a display string baked into the
  /// page load and never revised client-side — on youtube.com too. Delete a
  /// reply there and the parent still says "1 reply"; expanding it re-sends the
  /// same replies continuation, which correctly comes back empty (the deletion
  /// was real), and nothing renders — indistinguishable from a stuck load. It
  /// also *lags* removals it never saw: measured 2026-09-18, a signed-in view
  /// still advertised a reply that someone else had removed, while the
  /// anonymous view of the same comment already said 0 (`protocol.md` §3.3).
  /// rill has better information once it has the whole list: use it, and stop
  /// re-issuing a fetch that can only ever repeat that answer.
  bool _repliesLoadedOnce = false;

  bool _replying = false;
  bool _postingReply = false;
  final _replyController = TextEditingController();
  final _replyFocusNode = FocusNode();

  bool _deleting = false;

  late final CommentsSource _source;

  /// The reply page currently out, so a thread that goes away mid-load — a
  /// re-sort disposes every one of them — releases the sidecar instead of leaving
  /// the request running for nobody. No generation guard is needed here: a
  /// thread has one reply list and no sort, and the `mounted` check already
  /// drops an answer for a thread that is gone.
  int? _repliesRequest;

  @override
  void initState() {
    super.initState();
    _source = ref.read(commentsSourceProvider);
  }

  @override
  void dispose() {
    final request = _repliesRequest;
    if (request != null) _source.cancel(request);
    _replyController.dispose();
    _replyFocusNode.dispose();
    super.dispose();
  }

  void _toggleReplies() async {
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() => _expanded = true);
    _loadRepliesOnce();
  }

  /// The auto-load every expand path shares: fetch the first page exactly
  /// once. Never re-triggered by `_replies` being empty — that is also true
  /// right after deleting the last reply, and re-fetching then would just
  /// replay the stale-count/empty-result mismatch this method exists to
  /// avoid. "Show more replies" is unaffected: that button calls
  /// [_loadReplies] directly, and genuine pagination still has a real
  /// `_repliesContinuation` to follow.
  void _loadRepliesOnce() {
    if (_repliesLoadedOnce || _loadingReplies) return;
    if (widget.thread.replyCount > 0) _loadReplies();
  }

  Future<void> _loadReplies() async {
    if (_loadingReplies) return;
    final token = widget.thread.repliesContinuation;
    if (token == null) return;

    if (!mounted) return;
    setState(() {
      _loadingReplies = true;
      _errorReplies = false;
    });

    final request = _source.page(_repliesContinuation ?? token);
    _repliesRequest = request.id;
    try {
      final result = await request.response;
      _repliesRequest = null;
      if (mounted) {
        setState(() {
          _replies.addAll(result.items);
          _repliesContinuation = result.continuation;
          _loadingReplies = false;
          _repliesLoadedOnce = true;
        });
      }
    } catch (e) {
      _repliesRequest = null;
      if (mounted) {
        setState(() {
          _loadingReplies = false;
          _errorReplies = true;
        });
      }
    }
  }

  void _startReply() {
    setState(() {
      _replying = true;
      _expanded = true;
    });
    _loadRepliesOnce();
    _replyFocusNode.requestFocus();
  }

  void _cancelReply() {
    _replyController.clear();
    setState(() => _replying = false);
  }

  /// Posts the reply, then shows it immediately rather than waiting on a
  /// refetch — the sidecar's `action.replyToComment` deliberately answers
  /// `{}` (protocol.md §3.4), the same fire-and-forget shape every other
  /// write here uses, so the reply shown is built from what was just typed
  /// and the signed-in account, not from a server echo. It carries no real
  /// `id`/`deleteParams` until the thread is reloaded — acceptable for the
  /// same reason the Save-to-playlist dialog accepts the same gap (Task 25).
  Future<void> _submitReply() async {
    final text = _replyController.text.trim();
    final replyParams = widget.thread.replyParams;
    if (text.isEmpty || replyParams == null || _postingReply) return;

    final messenger = ScaffoldMessenger.of(context);
    final auth = ref.read(authProvider);

    setState(() => _postingReply = true);
    try {
      await RpcClient.instance.call('action.replyToComment', {
        'replyParams': replyParams,
        'commentText': text,
      });
      if (!mounted) return;
      setState(() {
        _replies.add(
          Comment(
            id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
            authorName: auth.displayName,
            authorAvatarUrl: auth.accountAvatarUrl ?? '',
            text: CommentText(content: text),
            replyCount: 0,
            publishedText: 'Just now',
          ),
        );
        _replyController.clear();
        _replying = false;
        _postingReply = false;
      });
    } on RpcException catch (e) {
      if (!mounted) return;
      setState(() => _postingReply = false);
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to reply' : e.message)));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _postingReply = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmDelete() async {
    final deleteParams = widget.thread.deleteParams;
    if (deleteParams == null || _deleting) return;

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
    setState(() => _deleting = true);
    try {
      await RpcClient.instance.call('action.deleteComment', {'deleteParams': deleteParams});
      widget.onDeleted?.call();
    } on RpcException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'AUTH_REQUIRED' ? 'Sign in to delete' : e.message)));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ground truth once the list is *complete*: covers both a locally added
    // optimistic reply (higher than the page-load count) and a deleted one
    // (lower) — `widget.thread.replyCount` is a snapshot from page load and
    // is never revised by either, on this app or on youtube.com itself.
    //
    // Only complete, though. While a "Show more replies" token remains the
    // list is a prefix, and its length would report 10 for a 962-reply thread.
    final listIsComplete = _repliesLoadedOnce && _repliesContinuation == null;
    final advertisedOrLoaded = widget.thread.replyCount > _replies.length ? widget.thread.replyCount : _replies.length;
    final replyCount = listIsComplete ? _replies.length : advertisedOrLoaded;

    return Opacity(
      opacity: _deleting ? 0.5 : 1.0,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              // Empty for a comment just posted that the server has not echoed
              // back (`_postComment`'s stand-in) — `NetworkImage('')` is an image
              // error, not a blank, so it is left out instead.
              backgroundImage: widget.thread.authorAvatarUrl.isEmpty ? null : NetworkImage(widget.thread.authorAvatarUrl),
              onBackgroundImageError: widget.thread.authorAvatarUrl.isEmpty ? null : (_, _) {},
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
                        widget.thread.authorName,
                        style: TextStyle(
                          fontWeight: widget.thread.isUploader ? FontWeight.bold : FontWeight.w500,
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      if (widget.thread.isVerified)
                        Padding(
                          padding: const EdgeInsets.only(left: 4.0),
                          child: Icon(Icons.check_circle, size: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      if (widget.thread.publishedText != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          widget.thread.publishedText!,
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ],
                      if (widget.thread.deleteParams != null) ...[
                        const Spacer(),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 16),
                            tooltip: 'Delete',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            onPressed: _deleting ? null : _confirmDelete,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  _CommentTextWidget(text: widget.thread.text),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        widget.thread.isLiked ? Icons.thumb_up : Icons.thumb_up_alt_outlined,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      if (widget.thread.likeCount != null) Text(widget.thread.likeCount!, style: const TextStyle(fontSize: 12)),
                      const SizedBox(width: 16),
                      const Icon(Icons.thumb_down_alt_outlined, size: 14),
                      if (widget.thread.creatorHearted) ...[
                        const SizedBox(width: 16),
                        Icon(Icons.favorite, size: 14, color: Theme.of(context).colorScheme.error),
                      ],
                      if (!widget.isReply && widget.thread.replyParams != null && !_replying) ...[
                        const SizedBox(width: 16),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: TextButton(
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                            onPressed: _startReply,
                            child: const Text('Reply', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (_replying)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _replyController,
                              focusNode: _replyFocusNode,
                              enabled: !_postingReply,
                              autofocus: true,
                              minLines: 1,
                              maxLines: 4,
                              style: const TextStyle(fontSize: 14),
                              decoration: const InputDecoration(
                                isDense: true,
                                hintText: 'Add a reply...',
                                border: UnderlineInputBorder(),
                              ),
                              onSubmitted: (_) => _submitReply(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _postingReply ? null : _cancelReply,
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: _postingReply ? null : _submitReply,
                            child: _postingReply
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
                  if (replyCount > 0)
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: TextButton(
                        onPressed: _toggleReplies,
                        child: Text(_expanded ? 'Hide replies' : 'Show $replyCount replies'),
                      ),
                    ),
                  if (_expanded) ...[
                    for (final reply in _replies)
                      Padding(
                        padding: const EdgeInsets.only(top: 12.0),
                        child: CommentThreadWidget(
                          key: ValueKey(reply.id),
                          thread: reply,
                          videoId: widget.videoId,
                          isReply: true,
                          onDeleted: () => setState(() => _replies.removeWhere((r) => r.id == reply.id)),
                        ),
                      ),
                    if (_loadingReplies)
                      const Padding(
                        padding: EdgeInsets.only(top: 12.0, bottom: 8.0),
                        child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else if (_errorReplies)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: TextButton(
                            onPressed: _loadReplies,
                            child: const Text('Tap to retry'),
                          ),
                        ),
                      )
                    else if (_repliesContinuation != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: TextButton(
                            onPressed: _loadReplies,
                            child: const Text('Show more replies'),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentTextWidget extends ConsumerStatefulWidget {
  final CommentText text;
  const _CommentTextWidget({required this.text});

  @override
  ConsumerState<_CommentTextWidget> createState() => _CommentTextWidgetState();
}

class _CommentTextWidgetState extends ConsumerState<_CommentTextWidget> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    InlineSpan contentSpan;
    if (widget.text.commandRuns == null && widget.text.styleRuns == null) {
      contentSpan = TextSpan(text: widget.text.content);
    } else {
      final spans = <TextSpan>[];
      int currentOffset = 0;
      final commands = List.of(widget.text.commandRuns ?? <CommentCommandRun>[])..sort((a, b) => a.startIndex.compareTo(b.startIndex));

      for (final run in commands) {
        if (run.startIndex > currentOffset) {
          spans.add(TextSpan(text: widget.text.content.substring(currentOffset, run.startIndex)));
        }
        final runText = widget.text.content.substring(run.startIndex, run.startIndex + run.length);
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
      if (currentOffset < widget.text.content.length) {
        spans.add(TextSpan(text: widget.text.content.substring(currentOffset)));
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
            RichText(
              text: span,
              maxLines: _expanded ? null : 4,
              overflow: _expanded ? TextOverflow.visible : (isOverflowing ? TextOverflow.ellipsis : TextOverflow.clip),
            ),
            if (isOverflowing)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4.0, bottom: 4.0, right: 16.0),
                    child: Text(
                      _expanded ? 'Read less' : 'Read more',
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
