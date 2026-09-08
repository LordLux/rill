import 'package:flutter/material.dart';

/// `#`, then `A`–`Z` — the bucket order `AllSubscriptionsPage` sorts the
/// (already server-sorted, per `docs/protocol.md` §3.3) channel list into.
const List<String> kAlphabetIndexLetters = ['#', ...['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z']];

/// The `#`/A–Z bucket for a name, matching how the server already orders
/// `subscriptions.channels` (digits/symbols, then A–Z) — see
/// `AllSubscriptionsPage._letterOf`, which every caller of this index must
/// agree with or the index points at the wrong place.
String letterBucketOf(String name) {
  if (name.isEmpty) return '#';
  final c = name[0].toUpperCase();
  return kAlphabetIndexLetters.contains(c) ? c : '#';
}

/// A vertical A–Z rail (Task 22) — hover pops the letter under the pointer
/// into a floating bubble so the user can see where they are; pressing and
/// dragging up/down additionally fires [onActivate] for every letter the
/// pointer crosses while held, for fast letter-to-letter scrubbing. Hovering
/// without pressing never calls [onActivate] — there is nothing to jump to
/// yet, only something to preview.
///
/// Purely presentational: it knows nothing about the list being scrubbed.
/// The caller (`AllSubscriptionsPage`) turns a letter into an actual scroll
/// position, because that requires knowledge — loaded items, pagination,
/// row layout — this widget has no business holding.
class AlphabetIndex extends StatefulWidget {
  const AlphabetIndex({
    super.key,
    this.letters = kAlphabetIndexLetters,
    required this.onActivate,
  });

  final List<String> letters;
  final ValueChanged<String> onActivate;

  @override
  State<AlphabetIndex> createState() => _AlphabetIndexState();
}

class _AlphabetIndexState extends State<AlphabetIndex> {
  String? _hovered;
  bool _pressed = false;

  String _letterAt(double dy, double height) {
    final count = widget.letters.length;
    final index = (dy / height * count).floor().clamp(0, count - 1);
    return widget.letters[index];
  }

  void _onHoverMove(Offset local, double height) {
    final letter = _letterAt(local.dy, height);
    if (letter != _hovered) setState(() => _hovered = letter);
  }

  void _onPressMove(Offset local, double height, {required bool isNewPress}) {
    final letter = _letterAt(local.dy, height);
    final changed = letter != _hovered;
    if (changed) setState(() => _hovered = letter);
    // A fresh press always activates its starting letter, even if hovering
    // already landed on it — otherwise a press-without-moving does nothing.
    if (changed || isNewPress) widget.onActivate(letter);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;

        return MouseRegion(
          onHover: (e) => _onHoverMove(e.localPosition, height),
          onExit: (_) {
            if (!_pressed) setState(() => _hovered = null);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (d) {
              _pressed = true;
              _onPressMove(d.localPosition, height, isNewPress: true);
            },
            onPanUpdate: (d) => _onPressMove(d.localPosition, height, isNewPress: false),
            onPanEnd: (_) {
              _pressed = false;
              setState(() => _hovered = null);
            },
            onPanCancel: () {
              _pressed = false;
              setState(() => _hovered = null);
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  width: 20,
                  height: height,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final letter in widget.letters)
                        Expanded(
                          child: Center(
                            child: AnimatedScale(
                              duration: const Duration(milliseconds: 100),
                              scale: _hovered == letter ? 1.4 : 1.0,
                              child: Text(
                                letter,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: _hovered == letter ? FontWeight.w800 : FontWeight.w500,
                                  color: _hovered == letter ? scheme.primary : scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_hovered != null) _Bubble(letter: _hovered!, height: height, index: widget.letters.indexOf(_hovered!), count: widget.letters.length),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The big floating letter to the rail's left, vertically centred on the
/// letter it echoes — the classic iOS-contacts-style "you are here".
class _Bubble extends StatelessWidget {
  const _Bubble({required this.letter, required this.height, required this.index, required this.count});

  final String letter;
  final double height;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final segment = height / count;
    final centerY = segment * index + segment / 2;

    return Positioned(
      right: 32,
      top: (centerY - 32).clamp(0.0, height - 64),
      child: IgnorePointer(
        child: Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.inverseSurface.withValues(alpha: 0.92),
            shape: BoxShape.circle,
          ),
          child: Text(
            letter,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: scheme.onInverseSurface,
            ),
          ),
        ),
      ),
    );
  }
}
