import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// How far from a viewport edge Tab leaves the focused control, in logical pixels.
const double _scrollMargin = 60;

/// Whether the user is navigating by keyboard — **on only after Tab, off at the
/// first click, tap or Escape.**
///
/// Flutter's own "highlight mode" cannot say this: it treats a *mouse* as a
/// keyboard-style interaction, so after any click it stays in `traditional` mode
/// and everything that shows focus (the ring, the scroll to a focused control, a
/// tile's lift) kept firing on mouse use. This owns the answer and pins Flutter's
/// mode to it (`alwaysTraditional` / `alwaysTouch`), so every
/// `highlightMode == traditional` check in the app means exactly "Tab was the
/// last thing the user did".
abstract final class KeyboardNavigation {
  /// Starts listening. From `main`. Safe to call again (a test binding resets
  /// the keyboard's handlers and the focus manager between tests).
  static void install() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    HardwareKeyboard.instance.removeHandler(_onKey);
    HardwareKeyboard.instance.addHandler(_onKey);
    final router = GestureBinding.instance.pointerRouter;
    if (_routed[router] != true) {
      _routed[router] = true;
      router.addGlobalRoute(_onPointer);
    }
  }

  // Per router: a test binding builds a new one for each test.
  static final Expando<bool> _routed = Expando<bool>();

  /// Whether keyboard navigation is on.
  static bool get active => FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  /// Moves focus to [node] once the frame that mounted it is done — for a menu a
  /// *keyboard* user opened. A click that opened it has no use for a focused row,
  /// and one would steal focus from wherever it was. [stillWanted] is asked again
  /// after the frame, since the menu may have closed meanwhile.
  static void focusAfterOpen(
    FocusNode node, {
    required bool Function() stillWanted,
  }) {
    if (!active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (stillWanted()) node.requestFocus();
    });
  }

  /// For widgets that show something while it is on.
  static void addListener(void Function(bool active) listener) =>
      FocusManager.instance.addHighlightModeListener((mode) => listener(mode == FocusHighlightMode.traditional));

  static void _set(bool on) {
    FocusManager.instance.highlightStrategy = on
        ? FocusHighlightStrategy.alwaysTraditional
        : FocusHighlightStrategy.alwaysTouch;
  }

  static bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      _set(true);
    } else if (event.logicalKey == LogicalKeyboardKey.escape && active && _escapeIsOurs()) {
      // Escape deselects — unless it closed something. A menu closing hands focus back to
      // what opened it, which a frame or two later is visible as focus having moved.
      final before = FocusManager.instance.primaryFocus;
      void check(int frames) {
        if (frames > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => check(frames - 1));
          WidgetsBinding.instance.scheduleFrame();
          return;
        }
        final now = FocusManager.instance.primaryFocus;
        if (active && identical(now, before) && before?.context != null) {
          _set(false);
          now!.unfocus();
        }
      }

      check(2);
    }
    // Never claims the key: Escape still closes whatever it closes, Tab still tabs.
    return false;
  }

  /// Escape belongs to whatever is open first: a menu, a dialog, an overlay or a
  /// text field closes (or releases) on this press, and focus goes back to where
  /// it came from. Only when focus sits on the page itself does it deselect.
  static bool _escapeIsOurs() {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    if (node == null || context == null || !context.mounted) return false;
    if (context.findAncestorWidgetOfExactType<EditableText>() != null) return false;
    final scope = node.nearestScope;
    final scopeContext = scope?.context;
    if (scope == null || scopeContext == null || !scopeContext.mounted) return false;
    final route = ModalRoute.of(scopeContext);
    // The miniplayer sits above the Navigator, in a scope of its own: Escape there is ours.
    if (route == null) return scope.debugLabel == 'miniplayer';
    // A page route's own scope: no menu scope, no dialog, no fullscreen layer between.
    if (route is! PageRoute) return false;
    // The route's own scope is the outermost one inside it: its parent scope is
    // outside the route. A menu's scope has the page's scope above it.
    final parentContext = scope.enclosingScope?.context;
    return parentContext == null || !parentContext.mounted || ModalRoute.of(parentContext) != route;
  }

  static void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _set(false);
  }
}

/// A focus node that the app-wide [FocusRing] does not draw around, because its
/// widget draws a ring of its own (a media tile, whose border has to grow with
/// the tile's hover animation — a ring around its resting rectangle would clip
/// into it).
class RinglessFocusNode extends FocusNode {
  RinglessFocusNode({super.debugLabel});
}

/// Tells the [FocusRing] what shape to draw around the controls below it.
///
/// **Most controls need nothing:** the ring reads the shape off the `InkWell` or
/// Material button the focus node belongs to — its `customBorder`, its
/// `borderRadius`, or a circle (see [ringStyleFor]). This is for the ones that do
/// not declare one (a bare `FocusableActionDetector`), and for [inflate].
///
/// [inflate] is how far the ring's path sits outside the control's own rectangle
/// (the stroke is 2 px, centred on the path, so the outer edge is `inflate + 1`
/// out). The default is 1. A full-bleed row — a menu item, a queue row — fills the
/// panel it sits in, and a ring outside it shows the panel behind as a gap, so
/// those say `-1`.
class FocusRingShape extends InheritedWidget {
  const FocusRingShape({
    super.key,
    this.shape,
    this.inflate,
    required super.child,
  });

  final ShapeBorder? shape;
  final double? inflate;

  @override
  bool updateShouldNotify(FocusRingShape oldWidget) => shape != oldWidget.shape || inflate != oldWidget.inflate;
}

const double _defaultInflate = 1;
final ShapeBorder _defaultShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(8),
);

/// The shape and inflate for the ring around [context]'s focus node: the nearest
/// declared one going up the tree, from a [FocusRingShape] or from an `InkWell`
/// (which every Material button, chip and `IconButton` is built on).
({ShapeBorder shape, double inflate}) ringStyleFor(BuildContext context) {
  ShapeBorder? shape;
  double? inflate;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is FocusRingShape) {
      shape ??= widget.shape;
      inflate ??= widget.inflate;
    } else if (shape == null && widget is InkResponse) {
      shape = _inkShape(widget);
    }
    return true;
  });
  return (shape: shape ?? _defaultShape, inflate: inflate ?? _defaultInflate);
}

ShapeBorder _inkShape(InkResponse ink) {
  final custom = ink.customBorder;
  if (custom != null) return custom;
  final radius = ink.borderRadius;
  if (radius != null) return RoundedRectangleBorder(borderRadius: radius);
  // An `InkWell` is a rectangle unless it says otherwise; an `InkResponse` is a circle.
  return ink.highlightShape == BoxShape.circle && ink is! InkWell
      ? const CircleBorder()
      : const RoundedRectangleBorder();
}

/// One focus ring for the whole app.
///
/// **Drawn around whatever has keyboard focus, wherever it is, instead of being
/// asked for by each widget.** Most of this app's controls are bare `InkWell`s
/// whose theme-level focus highlight is invisible, so a Tab stop could be a chip, a
/// text link or a button and look like "nothing selected" — and every new control
/// would have to remember a ring of its own. Only for keyboard focus
/// (`highlightMode == traditional`), never after a click, and never around a text
/// field (which draws its own) or a [RinglessFocusNode]. Its shape is the
/// control's own ([ringStyleFor]).
///
/// It also scrolls the focused control into view. Flutter's Tab traversal is meant
/// to, but the watch page's nested slivers and smooth-scroll view left focus
/// thousands of pixels off screen with the page not following.
///
/// **And a click moves keyboard focus to the control under it**, or the nearest one
/// when nothing there takes focus (the video surface: the play button), so the next
/// Tab continues from where the pointer just was — with no ring, since a pointer
/// did it. Only when the click itself left focus alone: a button, a dialog or a
/// menu that took focus keeps it.
class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.child});

  final Widget child;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _following = false;
  FocusNode? _node;
  Rect? _rect;
  ({ShapeBorder shape, double inflate}) _style = (
    shape: _defaultShape,
    inflate: _defaultInflate,
  );

  FocusNode? _downFocus;
  FocusScopeNode? _downScope;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
    FocusManager.instance.addHighlightModeListener(_onModeChanged);
    _onFocusChanged();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    FocusManager.instance.removeHighlightModeListener(_onModeChanged);
    super.dispose();
  }

  void _onModeChanged(FocusHighlightMode mode) => _onFocusChanged();

  bool _wantsRing(FocusNode? node) {
    if (node == null || node is FocusScopeNode || node is RinglessFocusNode)
      return false;
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional)
      return false;

    final context = node.context;
    if (context == null || !context.mounted) return false;
    // A text field draws its own.
    return context.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  void _onFocusChanged() {
    final node = FocusManager.instance.primaryFocus;
    final wants = _wantsRing(node);
    if (!wants) {
      _node = null;
      if (_rect != null && mounted) setState(() => _rect = null);
      return;
    }
    if (!identical(node, _node)) {
      _node = node;
      _style = ringStyleFor(node!.context!);
      _scrollIntoView(node);
    }
    _follow();
  }

  /// Brings the control into view once the frame that mounted it has laid out.
  void _scrollIntoView(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = node.context;
      if (!mounted ||
          context == null ||
          !context.mounted ||
          !node.hasPrimaryFocus)
        return;
      final target = context.findRenderObject();
      if (target is! RenderBox || !target.attached) return;
      // Each scrollable around it, innermost first, scrolls only if the control is
      // not already fully visible in *it* — and then only as far as needed. So the
      // player's controls do not recentre the page, and walking the queue moves the
      // queue and not the page behind it.
      BuildContext walk = context;
      for (
        var scrollable = Scrollable.maybeOf(walk);
        scrollable != null;
        scrollable = Scrollable.maybeOf(walk)
      ) {
        walk = scrollable.context;
        final viewport = walk.findRenderObject();
        if (viewport is! RenderBox || !viewport.attached) continue;
        final horizontal = axisDirectionToAxis(scrollable.axisDirection) == Axis.horizontal;
        final box = target.localToGlobal(Offset.zero, ancestor: viewport);
        final start = horizontal ? box.dx : box.dy;
        final end = start + (horizontal ? target.size.width : target.size.height);
        final extent = horizontal ? viewport.size.width : viewport.size.height;
        final size = horizontal ? target.size.width : target.size.height;
        // Room to keep around it, so the user can see what is next to the selection —
        // never more than the viewport can spare.
        final margin = math.min(
          _scrollMargin,
          math.max(0.0, (extent - size) / 2),
        );
        if (start >= margin && end <= extent - margin) continue;
        // A jump, not a glide: animated over a list of comment rows it leaves
        // "Nodes left pending" in the AXTree on every frame (measured, §F51).
        final room = extent - size;
        final wantedStart = start < margin ? margin : extent - margin - size;
        scrollable.position.ensureVisible(
          target,
          alignment: room <= 0 ? 0 : (wantedStart / room).clamp(0.0, 1.0),
          duration: Duration.zero,
        );
      }
    });
  }

  /// After every frame that happens while something is focused: the control moves
  /// while it scrolls and animates, and the ring has to move with it. A post-frame
  /// callback rather than a `Ticker`, so it never *asks* for a frame — a ring on a
  /// control that is sitting still costs nothing.
  void _follow() {
    final node = _node;
    if (node == null || !mounted) return;
    final context = node.context;
    if (context == null || !context.mounted) {
      _onFocusChanged();
      return;
    }
    final next = node.rect;
    if (next != _rect) setState(() => _rect = next);
    if (_following) return;
    _following = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _following = false;
      _follow();
    });
  }

  // ---- A click moves keyboard focus to the closest control ---------------------

  FocusScopeNode _deepestScope() {
    var scope = FocusManager.instance.rootScope;
    while (scope.focusedChild is FocusScopeNode) {
      scope = scope.focusedChild! as FocusScopeNode;
    }
    return scope;
  }

  void _onPointerDown(PointerDownEvent event) {
    _downFocus = FocusManager.instance.primaryFocus;
    _downScope = _deepestScope();
  }

  void _onPointerUp(PointerUpEvent event) {
    final position = event.position;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusClosestTo(position));
  }

  void _focusClosestTo(Offset point) {
    if (!mounted) return;
    final now = FocusManager.instance.primaryFocus;
    // The click moved focus itself — a button, a dialog or a menu took it — or opened
    // another route: leave it be.
    if (!identical(now, _downFocus) || !identical(_deepestScope(), _downScope)) return;
    if (now != null && now is! FocusScopeNode) {
      if (now.context?.findAncestorWidgetOfExactType<EditableText>() != null) return;
      if (now.rect.inflate(2).contains(point)) return;
    }

    FocusNode? best;
    var bestArea = double.infinity;
    var bestDistance = double.infinity;
    for (final candidate in _deepestScope().traversalDescendants) {
      final context = candidate.context;
      if (context == null || !context.mounted) continue;
      final rect = candidate.rect;
      if (rect.isEmpty) continue;
      if (rect.contains(point)) {
        // Under the pointer: the smallest one is the most specific.
        final area = rect.width * rect.height;
        if (bestDistance > 0 || area < bestArea) {
          best = candidate;
          bestArea = area;
          bestDistance = 0;
        }
      } else if (bestDistance > 0) {
        final dx = point.dx < rect.left
            ? rect.left - point.dx
            : (point.dx > rect.right ? point.dx - rect.right : 0.0);
        final dy = point.dy < rect.top
            ? rect.top - point.dy
            : (point.dy > rect.bottom ? point.dy - rect.bottom : 0.0);
        final distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
          best = candidate;
          bestDistance = distance;
        }
      }
    }
    // `requestFocus` after a pointer event leaves the highlight mode on "touch", so
    // no ring is drawn — which is the point: the pointer did this.
    best?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final rect = _rect;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            child: widget.child,
          ),
        ),
        if (rect != null && !rect.isEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _RingPainter(
                  rect: rect,
                  color: Theme.of(context).colorScheme.primary,
                  shape: _style.shape,
                  inflate: _style.inflate,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.rect,
    required this.color,
    required this.shape,
    required this.inflate,
  });

  final Rect rect;
  final Color color;
  final ShapeBorder shape;
  final double inflate;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      shape.getOuterPath(
        rect.inflate(inflate),
        textDirection: TextDirection.ltr,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.rect != rect ||
      old.color != color ||
      old.shape != shape ||
      old.inflate != inflate;
}
