/// Puts a whole floating panel on `silky_scroll`'s hover stack, not just the
/// scrollable inside it.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerScrollEvent;
import 'package:flutter/widgets.dart';
import 'package:silky_scroll/silky_scroll.dart';

/// Stops the page behind a floating panel from taking the wheel, for the parts
/// of that panel which are not themselves a [SilkyScroll] — its header, padding
/// and edges. See architecture §2.8 for why this joins the library's own hover
/// stack instead of adding a hover flag beside it.
///
/// A panel whose list cannot scroll steps aside rather than absorbing, or the
/// wheel goes dead over a panel that visibly cannot move. A list that *can*
/// scroll and is merely at its end still absorbs.
///
/// Every push is undone twice: `onExit`, and [State.dispose] — a `MouseRegion`
/// unmounted with the pointer inside it may never fire its exit, which is this
/// panel's whole life, and a key left on the stack outranks the page forever.
class SilkyScrollAbsorber extends StatefulWidget {
  const SilkyScrollAbsorber({super.key, required this.child});

  final Widget child;

  @override
  State<SilkyScrollAbsorber> createState() => _SilkyScrollAbsorberState();
}

class _SilkyScrollAbsorberState extends State<SilkyScrollAbsorber> {
  /// This widget's seat on the stack. A `UniqueKey` because the manager keys off
  /// identity and two absorbers must never be mistaken for each other.
  final UniqueKey _seat = UniqueKey();
  bool _pushed = false;
  bool _inside = false;

  /// Whether the panel's own scrollable has anywhere to go.
  ///
  /// Walks the subtree rather than taking a controller: the settings panel swaps
  /// pages through an `AnimatedSwitcher`, so mid-transition two lists are
  /// mounted, and one `ScrollController` on two scroll views is an assertion.
  ///
  /// **Per wheel tick as well as on enter, and that is deliberate.** The walk
  /// stops at the panel's first `Scrollable` — tens of elements, not a tree —
  /// and it is the only reading taken late enough to be right after a page swap.
  bool get _hasSomewhereToGo {
    ScrollPosition? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget is Scrollable) {
        final state = (element as StatefulElement).state;
        // The first one wins and we do not descend past it — a nested
        // scrollable inside the panel is that scrollable's own business.
        if (state is ScrollableState && state.position.hasContentDimensions) {
          found = state.position;
        }
        return;
      }
      element.visitChildren(visit);
    }

    if (!mounted) return false;
    (context as Element).visitChildren(visit);

    // No scrollable at all — nothing to defend, so let the page have it.
    if (found == null) return false;
    return found!.maxScrollExtent > 0;
  }

  void _sync() {
    final want = _inside && _hasSomewhereToGo;
    if (want == _pushed) return;
    _pushed = want;
    if (want) {
      SilkyScrollGlobalManager.instance.enteredKey(_seat);
    } else {
      SilkyScrollGlobalManager.instance.exitKey(_seat);
    }
  }

  void _setInside(bool inside) {
    _inside = inside;
    _sync();
    // Re-checked after the frame: the panel's fade-in and the pointer arriving
    // are often the same gesture, and the extent is not final until it lays out.
    if (inside) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync();
      });
    }
  }

  /// Hands a wheel delta to the page for a panel that cannot use it.
  ///
  /// Delivered, not merely released: a `SilkyScroll` takes the top of the hover
  /// stack whether or not it has any extent, so the page keeps deferring to it
  /// either way. `delegateMouseWheel` is the library's own hook for this and
  /// keeps the page's easing identical to scrolling it anywhere else.
  void _delegateToPage(double delta) {
    final position = Scrollable.maybeOf(context)?.position;
    if (position == null) return;
    if (position is SilkyScrollPosition) {
      position.delegateMouseWheel(delta);
      return;
    }
    // A plain Flutter `Scrollable` ancestor would have taken the event itself,
    // so this is only reached in a test harness or a future non-silky page.
    position.pointerScroll(delta);
  }

  @override
  void dispose() {
    _inside = false;
    _sync();
    // Belt and braces: `detachKey` also clears the manager's `reserveKey` if
    // this seat happened to be holding it, which `exitKey` alone does not.
    SilkyScrollGlobalManager.instance.detachKey(_seat);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // Not opaque, or the controls' own hover region stops waking and they fade
      // out from under an open menu. `SilkyScroll` uses the same setting.
      opaque: false,
      onEnter: (_) => _setInside(true),
      onExit: (_) => _setInside(false),
      // A list can start and stop being scrollable under a stationary pointer —
      // the queue grows, the settings panel walks to the quality ladder — and
      // this is the event for an extent change without a scroll.
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _sync();
          return false; // An observation; anything above gets it too.
        },
        child: Listener(
          onPointerSignal: (event) {
            // Mouse only: trackpad and touch are already forwarded at the edge
            // by `edgeForwardingMode`, and would move the page twice.
            if (event is! PointerScrollEvent) return;
            if (event.kind != PointerDeviceKind.mouse) return;
            // **Asked fresh, not read off `_pushed`.** That cached answer is
            // computed on hover-enter and on a metrics change, and the metrics
            // change for a page swap arrives while the `AnimatedSwitcher` still
            // has both lists mounted — so it can resolve the outgoing one and
            // conclude there is nothing to scroll. By wheel time only the new
            // list is there. `settings_menu_test` pins exactly this.
            if (_hasSomewhereToGo) return;
            _delegateToPage(event.scrollDelta.dy);
          },
          child: widget.child,
        ),
      ),
    );
  }
}
