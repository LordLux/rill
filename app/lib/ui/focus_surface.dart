import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/widgets.dart';

import 'focus_ring.dart';

/// The Tab order of the shell's surfaces, in the order Tab walks them.
///
/// Title bar, rail, top bar (search, then its actions), page content. The
/// window buttons are not in the walk (`NativeWindowControls.buttons`). Inside
/// the page content, the surfaces that are their own group — the queue panel and
/// the player controls — sit where they sit in reading order.
abstract final class ShellFocusOrder {
  static const NumericFocusOrder titleBar = NumericFocusOrder(1);
  static const NumericFocusOrder rail = NumericFocusOrder(2);
  static const NumericFocusOrder search = NumericFocusOrder(3);
  static const NumericFocusOrder topBarActions = NumericFocusOrder(4);
  static const NumericFocusOrder content = NumericFocusOrder(5);
}

/// The watch page's Tab order, inside the page content: player, queue, metadata,
/// comments, related videos — in both layouts. The two-column layout puts the
/// queue and the related videos in one rail beside everything else, so reading
/// order alone cannot say it; each part is numbered.
abstract final class WatchFocusOrder {
  static const NumericFocusOrder player = NumericFocusOrder(1);
  static const NumericFocusOrder queue = NumericFocusOrder(2);
  static const NumericFocusOrder meta = NumericFocusOrder(3);

  /// The description's links and "Show more", after the Subscribe button and the
  /// actions row.
  static const NumericFocusOrder description = NumericFocusOrder(3.2);

  /// The narrow layout's "Up Next / Comments" switch, between the metadata and
  /// whichever list it chose.
  static const NumericFocusOrder tabs = NumericFocusOrder(3.5);
  static const NumericFocusOrder comments = NumericFocusOrder(4);
  static const NumericFocusOrder related = NumericFocusOrder(5);
}

/// Marks a subtree whose focused widgets use the arrow keys themselves — a
/// reorder handle, a slider — so the player's global shortcuts (seek, volume) stand
/// down while one of them has focus. `PlayerShortcuts` runs before the focus
/// tree and would otherwise take every arrow press.
class ArrowKeyClaim extends InheritedWidget {
  const ArrowKeyClaim({super.key, required super.child});

  @override
  bool updateShouldNotify(ArrowKeyClaim oldWidget) => false;
}

/// `SelectionArea` that Tab walks past. A bare one is a Tab stop with no action and
/// no visible state — the "ghost" stops on the watch page (title, channel, views,
/// date, comment text) — while selecting with the mouse and Ctrl+C work as before.
class NoTabSelectionArea extends StatelessWidget {
  const NoTabSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    descendantsAreTraversable: false,
    child: SelectionArea(child: child),
  );
}

/// A tap that is also a Tab stop: Enter and Space press it, and the app-wide focus
/// ring (`focus_ring.dart`) shows it. For the bare `GestureDetector` links and
/// buttons the keyboard could not reach.
class KeyboardTap extends StatelessWidget {
  const KeyboardTap({super.key, required this.onTap, required this.child, this.label, this.borderRadius = 6});

  final VoidCallback? onTap;
  final Widget child;

  /// The focus ring's corner radius, to match what the child looks like.
  final double borderRadius;

  /// What a screen reader says; the child's own text is used when null.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: FocusRingShape(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(borderRadius)),
        child: FocusableActionDetector(
        enabled: onTap != null,
        mouseCursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
      ),
      ),
    );
  }
}

/// A surface that is a deliberate Tab group.
///
/// Reading order *inside* the group, and [order] for where the group sits among
/// its siblings under an `OrderedTraversalPolicy`. Without one, Tab order is
/// whatever the widget tree happens to be (`docs/todo.md` 38, now closed).
class FocusSurface extends StatelessWidget {
  const FocusSurface({super.key, required this.child, this.order, this.ordered = false});

  final Widget child;

  /// Null for a group nested in another group's reading order, which needs no
  /// number of its own.
  final FocusOrder? order;

  /// Whether the group's *children* carry `FocusTraversalOrder` numbers, as the
  /// watch page's main column and rail do. Anything without one falls back to
  /// reading order, which is what a plain surface uses throughout.
  final bool ordered;

  @override
  Widget build(BuildContext context) {
    final group = FocusTraversalGroup(
      policy: ordered ? OrderedTraversalPolicy() : ReadingOrderTraversalPolicy(),
      child: child,
    );
    final order = this.order;
    return order == null ? group : FocusTraversalOrder(order: order, child: group);
  }
}
