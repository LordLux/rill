import 'package:flutter/material.dart';

import '../../theme/app_theme.dart'
    show tooltipBubbleDecoration, tooltipBubbleForeground, tooltipBubbleShade, tooltipBubbleTextStyle;
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
  const ShortcutTooltip({super.key, required this.label, this.action, required this.child});

  final String label;
  final PlayerAction? action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final keyLabel = action == null ? null : playerActionKeyLabel[action];
    if (keyLabel == null) {
      return Tooltip(
        message: label,
        preferBelow: false,
        decoration: tooltipBubbleDecoration,
        textStyle: tooltipBubbleTextStyle,
        child: child,
      );
    }

    final keys = keyLabel.split('+');
    if (keys.length < 2) {
      return Tooltip(
        preferBelow: false,
        decoration: tooltipBubbleDecoration,
        waitDuration: const Duration(milliseconds: 300),
        richMessage: TextSpan(
          style: tooltipBubbleTextStyle,
          children: [
            TextSpan(text: '$label  '),
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: _KeyBadge(keys.first)),
          ],
        ),
        child: child,
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

    return Tooltip(
      preferBelow: false,
      decoration: tooltipBubbleDecoration,
      waitDuration: const Duration(milliseconds: 300),
      richMessage: TextSpan(
        style: tooltipBubbleTextStyle,
        children: [
          TextSpan(text: '$label  '),
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: shortcut),
        ],
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