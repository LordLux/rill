import 'package:flutter/material.dart';

import '../../theme/app_theme.dart' show tooltipBubbleDecoration, tooltipBubbleForeground, tooltipBubbleShade, tooltipBubbleTextStyle;
import '../player/shortcuts.dart' show PlayerAction, playerActionKeyLabel;

/// A tooltip reading [label], with the current keybinding for [action]
/// appended as a small rounded badge — "Mute" + a boxed "M", the same shape
/// a desktop browser or youtube.com itself uses for exactly this.
///
/// [action] is optional and most call sites pass none: only the actions
/// [PlayerAction] actually covers have a keybinding to show at all — the
/// watch page's like/dislike/share/save/Watch-Later/more row has none today.
/// Passing an [action] with no entry in [playerActionKeyLabel] (or omitting
/// it) falls back to a plain text-only tooltip rather than a badge with
/// nothing in it.
class ShortcutTooltip extends StatelessWidget {
  const ShortcutTooltip({
    super.key,
    required this.label,
    this.action,
    this.silent = false,
    required this.child,
  });

  final String label;
  final PlayerAction? action;

  /// Draws the bubble with no semantics of its own ([_SilentTooltip]). For the player's
  /// control bar, where the Material tooltip's overlay node reaches the accessibility
  /// bridge orphaned (F51).
  final bool silent;
  final Widget child;

  Widget _tip({required Duration wait, required InlineSpan message, bool plain = false}) {
    if (silent) return _SilentTooltip(label: label, hoverDelay: wait, message: message, child: child);
    if (plain) {
      return Tooltip(
        message: label,
        preferBelow: false,
        decoration: tooltipBubbleDecoration,
        textStyle: tooltipBubbleTextStyle,
        child: child,
      );
    }
    return Tooltip(
      preferBelow: false,
      decoration: tooltipBubbleDecoration,
      waitDuration: wait,
      richMessage: message,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyLabel = action == null ? null : playerActionKeyLabel[action];
    if (keyLabel == null)
      return _tip(
        wait: Duration.zero,
        plain: true,
        message: TextSpan(text: label, style: tooltipBubbleTextStyle),
      );

    final keys = keyLabel.split('+');
    if (keys.length < 2) {
      return _tip(
        wait: const Duration(milliseconds: 300),
        message: TextSpan(
          style: tooltipBubbleTextStyle,
          children: [
            TextSpan(text: '$label  '),
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: _KeyBadge(keys.first)),
          ],
        ),
      );
    }

    final shortcut = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < keys.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(width: 2),
            Transform.translate(
              offset: const Offset(0, -2),
              child: Text('+', style: tooltipBubbleTextStyle),
            ),
            const SizedBox(width: 2),
          ],
          _KeyBadge(keys[i]),
        ],
      ],
    );

    return _tip(
      wait: const Duration(milliseconds: 300),
      message: TextSpan(
        style: tooltipBubbleTextStyle,
        children: [
          TextSpan(text: '$label  '),
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: shortcut),
        ],
      ),
    );
  }
}

/// A tooltip whose bubble has **no semantics**: the Material one puts a node for it in the
/// overlay, and shown from under the player's control bar (opacity, slide, ignore-pointer)
/// that node reached the Windows accessibility bridge without a parent — a burst of
/// `Failed to update ui::AXTree … will not be in the tree` for as long as it was up
/// (`architecture.md` F51). Every control already carries its own label, so a screen
/// reader loses nothing; the bubble is for the pointer.
///
/// Drawn like the Material desktop tooltip, above its target.
class _SilentTooltip extends StatelessWidget {
  const _SilentTooltip({
    required this.label,
    required this.hoverDelay,
    required this.message,
    required this.child,
  });

  /// What assistive technology is told, on the anchor — the part of a tooltip that is not the bubble.
  final String label;
  final Duration hoverDelay;
  final InlineSpan message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Not wrapped in `ExcludeSemantics`: that would drop the *control* under the tooltip from
    // the semantics tree, not just the bubble.
    return RawTooltip(
      semanticsTooltip: label,
      hoverDelay: hoverDelay,
      positionDelegate: (c) => positionDependentBox(
        size: c.overlaySize,
        childSize: c.tooltipSize,
        target: c.target,
        verticalOffset: c.targetSize.height / 2 + 4,
        preferBelow: false,
      ),
      tooltipBuilder: (context, animation) => ExcludeSemantics(
        child: FadeTransition(
          opacity: animation,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 24),
            child: DecoratedBox(
              decoration: tooltipBubbleDecoration,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text.rich(message, style: tooltipBubbleTextStyle),
              ),
            ),
          ),
        ),
      ),
      child: child,
    );
  }
}

/// The small rounded-corner box a keybinding sits in.
///
/// Painted from [tooltipBubbleForeground] / [tooltipBubbleShade] rather than a
/// `ColorScheme` role: the bubble it lives inside is fixed dark whatever the
/// app theme (`app_theme.dart` has why), and a role-driven colour here would
/// risk going invisible against a bubble that never follows it.
///
/// The bubble and text style are passed explicitly above even though the app
/// theme installs the same ones, so this widget looks right under any theme —
/// including a bare `MaterialApp` in a test.
class _KeyBadge extends StatelessWidget {
  const _KeyBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: tooltipBubbleShade.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: tooltipBubbleForeground.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 3.5),
        child: Container(
          constraints: const BoxConstraints(minWidth: 14),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: tooltipBubbleForeground.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: tooltipBubbleForeground.withValues(alpha: 0.35), width: 0.5),
          ),
          // Removed the Center widget and added textAlign here:
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: tooltipBubbleForeground,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
