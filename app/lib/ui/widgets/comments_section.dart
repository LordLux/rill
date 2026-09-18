import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/comment.dart';
import '../../domain/feed_item.dart' as domain;
import '../../data/rpc/client.dart';
import '../playback_controller.dart';

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
  bool _loading = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _continuation = widget.initialContinuation;
    _fetch();
  }

  Future<void> _fetch({bool refresh = false}) async {
    if (_loading) return;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = false;
      if (refresh) {
        _threads.clear();
      }
    });

    try {
      final response = await RpcClient.instance.call('video.comments', {
        'continuation': _continuation,
      });

      final result = CommentsResult.fromJson(response);

      if (mounted) {
        setState(() {
          _threads.addAll(result.items);
          _continuation = result.continuation;
          if (result.chips != null && result.chips!.isNotEmpty) {
            _chips = result.chips?.cast<domain.Chip>();
          }
          if (result.commentCount != null) {
            _commentCount = result.commentCount;
          }
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  void _applySort(String token) {
    _continuation = token;
    _fetch(refresh: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_threads.isEmpty && !_loading && !_error) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      sliver: SliverMainAxisGroup(
        slivers: [
          if (_commentCount != null || (_chips != null && _chips!.isNotEmpty))
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Row(
                  children: [
                    if (_commentCount != null)
                      Expanded(
                        child: Text(
                          _commentCount!,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                    if (_chips != null && _chips!.isNotEmpty)
                      Wrap(
                        spacing: 8.0,
                        children: _chips!.map((c) {
                          final isSelected = c.selected;
                          return ChoiceChip(
                            label: Text(c.label),
                            selected: isSelected,
                            onSelected: (selected) {
                              if (selected) {
                                _applySort(c.token);
                              }
                            },
                          );
                        }).toList(),
                      ),
                  ],
                ),
              ),
            ),
          SliverList.builder(
            itemCount: _threads.length,
            itemBuilder: (context, index) {
              return CommentThreadWidget(
                key: ValueKey(_threads[index].id),
                thread: _threads[index],
                videoId: widget.videoId,
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

class CommentThreadWidget extends StatefulWidget {
  final Comment thread;
  final String videoId;

  const CommentThreadWidget({
    super.key,
    required this.thread,
    required this.videoId,
  });

  @override
  State<CommentThreadWidget> createState() => _CommentThreadWidgetState();
}

class _CommentThreadWidgetState extends State<CommentThreadWidget> {
  final List<Comment> _replies = [];
  bool _expanded = false;
  bool _loadingReplies = false;
  bool _errorReplies = false;
  String? _repliesContinuation;

  void _toggleReplies() async {
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() => _expanded = true);
    if (_replies.isEmpty && widget.thread.replyCount > 0 && !_loadingReplies) {
      _loadReplies();
    }
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

    try {
      final response = await RpcClient.instance.call('video.comments', {
        'continuation': _repliesContinuation ?? token,
      });
      final result = CommentsResult.fromJson(response);
      if (mounted) {
        setState(() {
          _replies.addAll(result.items);
          _repliesContinuation = result.continuation;
          _loadingReplies = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingReplies = false;
          _errorReplies = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundImage: NetworkImage(widget.thread.authorAvatarUrl),
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
                      const Padding(
                        padding: EdgeInsets.only(left: 4.0),
                        child: Icon(Icons.check_circle, size: 12, color: Colors.grey),
                      ),
                    if (widget.thread.publishedText != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        widget.thread.publishedText!,
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
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
                    if (widget.thread.likeCount != null)
                      Text(widget.thread.likeCount!, style: const TextStyle(fontSize: 12)),
                    const SizedBox(width: 16),
                    const Icon(Icons.thumb_down_alt_outlined, size: 14),
                    if (widget.thread.creatorHearted) ...[
                      const SizedBox(width: 16),
                      const Icon(Icons.favorite, size: 14, color: Colors.red),
                    ]
                  ],
                ),
                if (widget.thread.replyCount > 0)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: TextButton(
                      onPressed: _toggleReplies,
                      child: Text(_expanded ? 'Hide replies' : 'Show ${widget.thread.replyCount} replies'),
                    ),
                  ),
                if (_expanded) ...[
                  for (final reply in _replies)
                    Padding(
                      padding: const EdgeInsets.only(top: 12.0),
                      child: CommentThreadWidget(thread: reply, videoId: widget.videoId),
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
                    )
                ]
              ],
            ),
          )
        ],
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
      final commands = List.of(widget.text.commandRuns ?? <CommentCommandRun>[])
        ..sort((a, b) => a.startIndex.compareTo(b.startIndex));

      for (final run in commands) {
        if (run.startIndex > currentOffset) {
          spans.add(TextSpan(text: widget.text.content.substring(currentOffset, run.startIndex)));
        }
        final runText = widget.text.content.substring(run.startIndex, run.startIndex + run.length);
        final isTimestamp = run.startTimeSeconds != null;
        spans.add(TextSpan(
          text: runText,
          style: TextStyle(color: isTimestamp ? Colors.blue : Theme.of(context).colorScheme.primary),
          recognizer: isTimestamp ? (TapGestureRecognizer()..onTap = () {
            ref.read(playbackEngineProvider).seek(Duration(seconds: run.startTimeSeconds!));
          }) : null,
        ));
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
                      style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500),
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
