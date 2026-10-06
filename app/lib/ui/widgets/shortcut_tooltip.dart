import 'dart:async';

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
/// Marks the region an in-tree tooltip must stay inside — the player, which clips what hangs over
/// its edge. Without one the window is the limit.
class TooltipBounds extends StatelessWidget {
  const TooltipBounds({super.key, required this.child});

  final Widget child;

  static Rect? _of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_BoundsScope>();
    final box = scope?.boundsContext.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) => _BoundsScope(boundsContext: context, child: child);
}

class _BoundsScope extends InheritedWidget {
  const _BoundsScope({required this.boundsContext, required super.child});

  final BuildContext boundsContext;

  @override
  bool updateShouldNotify(_BoundsScope old) => false;
}

/// Which side of its control an in-tree tooltip opens on. [left] for a control inside something that
/// clips (a thumbnail's corner), where a bubble above it would be cut off.
enum TooltipSide { above, left }

class ShortcutTooltip extends StatelessWidget {
  const ShortcutTooltip({
    super.key,
    required this.label,
    this.action,
    this.silent = false,
    this.announce = true,
    this.side = TooltipSide.above,
    this.delay,
    required this.child,
  });

  final String label;
  final PlayerAction? action;

  /// Whether a [silent] tooltip also names its anchor for assistive technology. Off for a
  /// control that already says the same thing itself (the volume bar: "Volume 100%").
  final bool announce;

  /// How long the pointer rests before a [silent] bubble shows, where the default for the kind of
  /// tooltip is not right.
  final Duration? delay;

  /// Where a [silent] bubble opens.
  final TooltipSide side;

  /// Draws the bubble with no semantics of its own ([_SilentTooltip]). For the player's
  /// control bar, where the Material tooltip's overlay node reaches the accessibility
  /// bridge orphaned (F51).
  final bool silent;
  final Widget child;

  Widget _tip({required Duration wait, required InlineSpan message, bool plain = false}) {
    if (silent) return _SilentTooltip(label: announce ? label : null, hoverDelay: delay ?? wait, message: message, side: side, child: child);
    if (plain) {
      return Tooltip(
        message: label,
        excludeFromSemantics: !announce,
        preferBelow: false,
        decoration: tooltipBubbleDecoration,
        textStyle: tooltipBubbleTextStyle,
        child: child,
      );
    }
    return Tooltip(
      excludeFromSemantics: !announce,
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

/// A tooltip drawn **in the tree, not in an overlay** — the player's controls use it.
///
/// Flutter 3.44 attaches an `OverlayPortal`'s overlay child to its anchor's *semantics*
/// (`traversalParentIdentifier`), so a tooltip is a semantics subtree that must stay attached to
/// a control while that control's own subtree is being faded, clipped, re-laid-out or remounted —
/// all of which the player's bar and the watch page do. When it does not, the Windows
/// accessibility bridge is handed a node without a parent and rejects that update and every one
/// after it: `Failed to update ui::AXTree … will not be in the tree` (`architecture.md` F51;
/// reproduced as a bare, childless full-window node that lived five seconds while a user
/// clicked around the watch page). With no overlay there is nothing to orphan. The bubble sits
/// above the control, inside the player, with no semantics of its own; the control already has
/// its label, so a screen reader loses nothing.
class _SilentTooltip extends StatefulWidget {
  const _SilentTooltip({
    required this.label,
    required this.hoverDelay,
    required this.message,
    required this.side,
    required this.child,
  });

  final TooltipSide side;

  /// What assistive technology is told, on the anchor. Null: nothing.
  final String? label;
  final Duration hoverDelay;
  final InlineSpan message;
  final Widget child;

  @override
  State<_SilentTooltip> createState() => _SilentTooltipState();
}

class _SilentTooltipState extends State<_SilentTooltip> {
  Timer? _timer;
  bool _shown = false;

  /// Where the control is in the player (or window), taken when the bubble is shown; the bubble is
  /// measured and placed against it in layout, so a control at an edge keeps its bubble inside.
  _Span _span = const _Span(-_reach, _reach, 0);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _enter() {
    _timer?.cancel();
    if (_shown) return;
    _timer = Timer(widget.hoverDelay, () {
      if (!mounted) return;
      final box = context.findRenderObject();
      var span = const _Span(-_reach, _reach, 0);
      if (box is RenderBox && box.attached) {
        final left = box.localToGlobal(Offset.zero).dx;
        final bounds = TooltipBounds._of(context) ?? (Offset.zero & MediaQuery.sizeOf(context));
        // The room on each side of the control, in its own coordinates.
        span = _Span(bounds.left - left, bounds.right - left, box.size.width);
      }
      setState(() {
        _span = span;
        _shown = true;
      });
    });
  }

  void _hide() {
    _timer?.cancel();
    if (_shown && mounted) setState(() => _shown = false);
  }

  Widget _bubble() => ConstrainedBox(
    // Wraps past this, for a long label (a video's title); the short ones never reach it.
    constraints: const BoxConstraints(minHeight: 24, maxWidth: 360),
    child: DecoratedBox(
      decoration: tooltipBubbleDecoration,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text.rich(widget.message, style: tooltipBubbleTextStyle),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Not `ExcludeSemantics` around the whole: that would drop the *control* from the tree.
    final anchor = Semantics(tooltip: widget.label, child: widget.child);
    return MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _hide(),
      // A press ends it, as a Material tooltip's does.
      child: Listener(
        onPointerDown: (_) => _hide(),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            anchor,
            if (_shown)
              if (widget.side == TooltipSide.left)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: -400,
                  width: 400,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Padding(padding: const EdgeInsets.only(right: 4), child: _bubble()),
                      ),
                    ),
                  ),
                )
              else
                // Zero tall, `_reach` wide each way: the delegate puts the bubble above it and
                // inside the bounds, whatever its width (a key badge makes that unguessable).
                Positioned(
                  top: 0,
                  height: 0,
                  left: -_reach,
                  right: -_reach,
                  child: IgnorePointer(
                    child: ExcludeSemantics(child: CustomSingleChildLayout(delegate: _AboveInside(_span), child: _bubble())),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// How far an in-tree tooltip's layout box reaches either side of its control.
const double _reach = 2000;

/// The room around a control: its bounds' left and right edges, and its own width, all measured from
/// the control's left edge.
class _Span {
  const _Span(this.left, this.right, this.width);

  final double left;
  final double right;
  final double width;
}

/// Puts a bubble above its control, centred on it, then pushes it back inside the bounds. Measured
/// in layout, so it needs no guess at the bubble's width.
class _AboveInside extends SingleChildLayoutDelegate {
  const _AboveInside(this.span);

  final _Span span;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => const BoxConstraints(maxWidth: 2 * _reach, maxHeight: 200);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0;
    final centred = _reach + span.width / 2 - childSize.width / 2;
    final lo = _reach + span.left + margin;
    final hi = _reach + span.right - margin - childSize.width;
    // A bubble wider than the room favours the left edge.
    final x = hi < lo ? lo : centred.clamp(lo, hi);
    return Offset(x, -childSize.height - 6);
  }

  @override
  bool shouldRelayout(_AboveInside old) => old.span != span;
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
