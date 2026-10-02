import 'package:flutter/material.dart';

import '../../data/comments_source.dart' show kCommentMaxLength;

/// The "Add a comment…" box under the comment count.
///
/// **Knows nothing about RPC or the account.** The avatar and the post are
/// handed in, so the one rule worth pinning — *a failed post must never cost the
/// user what they typed* — can be tested without a sidecar: [onPost] answers
/// whether it worked, and only `true` empties the box.
///
/// Collapsed it is a single underlined line, like youtube.com's; it opens (the
/// Cancel / Comment row appears) while focused, while it holds text, and while a
/// post is out — so tapping away from a half-written comment does not hide the
/// button that would send it.
class CommentComposer extends StatefulWidget {
  const CommentComposer({super.key, required this.onPost, this.avatarUrl});

  /// The signed-in account's picture, or null for a placeholder glyph.
  final String? avatarUrl;

  /// Posts [text] — already trimmed, never empty. Resolves `true` when it was
  /// posted (the box then empties and collapses) and `false` when it was not, in
  /// which case the box keeps exactly what was typed.
  final Future<bool> Function(String text) onPost;

  @override
  State<CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<CommentComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _focus.addListener(_changed);
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _focus.removeListener(_changed);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  /// Focus is anywhere in the composer — the field *or* its Cancel and Comment
  /// buttons. It used to be the field's own focus alone, so Tab from the field
  /// onto Cancel made the buttons disappear (the field no longer had focus),
  /// focus snapped back, and a keyboard user could never reach either of them.
  bool _focusWithin = false;

  bool get _open => _focusWithin || _focus.hasFocus || _controller.text.isNotEmpty || _posting;

  /// Whitespace alone is not a comment, and a second tap while one is out must
  /// not post it twice.
  bool get _canPost => !_posting && _controller.text.trim().isNotEmpty;

  void _cancel() {
    _controller.clear();
    _focus.unfocus();
  }

  Future<void> _submit() async {
    if (!_canPost) return;
    final text = _controller.text.trim();
    setState(() => _posting = true);
    var posted = false;
    try {
      posted = await widget.onPost(text);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
    if (!mounted || !posted) return;
    _controller.clear();
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final avatarUrl = widget.avatarUrl;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (has) {
        if (_focusWithin != has) setState(() => _focusWithin = has);
      },
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl),
          onBackgroundImageError: avatarUrl == null ? null : (_, _) {},
          child: avatarUrl == null ? const Icon(Icons.person, size: 18) : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                focusNode: _focus,
                enabled: !_posting,
                minLines: 1,
                maxLines: 6,
                // YouTube refuses 10,001 characters outright (measured
                // 2026-09-21, `COMMENT_MAX_LENGTH` in the sidecar). Enforced
                // here so a long comment stops growing while it is being
                // written, rather than being refused after the send — losing a
                // wall of text to a 400 is the failure worth preventing. The
                // sidecar checks too: this field is not the only caller.
                maxLength: kCommentMaxLength,
                // The counter is noise for the length of a normal comment, so
                // it appears only once one is close enough for it to matter.
                buildCounter: (context, {required currentLength, required isFocused, maxLength}) =>
                    currentLength < kCommentMaxLength - 500
                        ? null
                        : Text(
                            '$currentLength / $maxLength',
                            style: TextStyle(
                              fontSize: 11,
                              color: currentLength >= kCommentMaxLength
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                textInputAction: TextInputAction.newline,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Add a comment...',
                  border: UnderlineInputBorder(),
                ),
              ),
              if (_open)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _posting ? null : _cancel,
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _canPost ? _submit : null,
                        child: _posting
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Comment'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
    );
  }
}
