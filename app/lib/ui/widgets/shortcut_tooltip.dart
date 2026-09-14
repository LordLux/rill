import 'package:flutter/material.dart';

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
        decoration: _bubbleDecoration,
        textStyle: _textStyle,
        child: child,
      );
    }

    final keys = keyLabel.split('+');
    if (keys.length < 2) {
      return Tooltip(
        preferBelow: false,
        decoration: _bubbleDecoration,
        waitDuration: const Duration(milliseconds: 300),
        richMessage: TextSpan(
          style: _textStyle,
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
              child: Text('+', style: _textStyle),
            ),
            const SizedBox(width: 2),
          ],
          _KeyBadge(keys[i]),
        ],
      ],
    );

    return Tooltip(
      preferBelow: false,
      decoration: _bubbleDecoration,
      waitDuration: const Duration(milliseconds: 300),
      richMessage: TextSpan(
        style: _textStyle,
        children: [
          TextSpan(text: '$label  '),
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: shortcut),
        ],
      ),
      child: child,
    );
  }
}

/// Fixed dark-on-light-text rather than left to `TooltipThemeData` — this
/// app's Material 3 theme resolves the *default* tooltip to a pale bubble
/// with dark text (the platform default follows `colorScheme.onSurface` at
/// low opacity in M3, not the flat dark-grey Material 2 always used), which
/// looked like a bug in two different ways: the plain-text tooltips read as
/// black-on-white where a dark bubble was expected, and the badge — built
/// assuming a dark bubble, white text on a white-ish translucent box — was
/// white-on-white and unreadable. Setting both explicitly makes the tooltip
/// look the same regardless of which theme or brightness the app is in,
/// which is the property an instruction badge actually needs.
const BoxDecoration _bubbleDecoration = BoxDecoration(
  color: Color(0xE6212121),
  borderRadius: BorderRadius.all(Radius.circular(6)),
);
const TextStyle _textStyle = TextStyle(color: Colors.white, fontSize: 12, height: 1.3);

/// The small rounded-corner box a keybinding sits in.
///
/// Fixed white-on-translucent rather than a `ColorScheme` role: the tooltip
/// bubble it lives inside is Flutter's stock `TooltipThemeData`, which is
/// always a dark bubble regardless of the app's own light/dark theme — a
/// role-driven colour here would risk going invisible against a bubble that
/// never follows it.
class _KeyBadge extends StatelessWidget {
  const _KeyBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 3.5),
        child: Container(
          constraints: const BoxConstraints(minWidth: 14),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 0.5),
          ),
          // Removed the Center widget and added textAlign here:
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}