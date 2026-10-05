import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';
import '../focus_ring.dart' show FocusRingShape;
import '../focus_surface.dart' show ArrowKeyClaim;

/// The volume control: a 0–100 bar drawn and driven here, not a Material `Slider`.
///
/// **Not a `Slider`, on purpose.** Every `Slider` hosts a value indicator in an
/// `OverlayPortal`, and the one in the player's control bar double-parents its
/// own semantics node when it is mounted (`architecture.md` F51), which the
/// Windows accessibility bridge answers by rejecting that update and every one
/// after it. This has no overlay, so there is nothing to double-parent. The
/// scrubber stays a `Slider`: it is built with the bar and has never done it.
///
/// Keyboard: arrows and Home/End, and the arrows are claimed (`ArrowKeyClaim`) so
/// the player's own seek shortcut does not also fire. Screen readers get a slider
/// with increase/decrease actions.
class VolumeBar extends StatefulWidget {
  const VolumeBar({super.key, required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<VolumeBar> createState() => _VolumeBarState();
}

class _VolumeBarState extends State<VolumeBar> with TickerProviderStateMixin {
  static const double _step = 5;
  static const double _thumbRadius = 6;
  static const double _inset = 10;

  double get value => widget.value;

  /// 0 to 1: the halo, while the pointer is anywhere on the bar; and the thumb swelling, while it is
  /// on the thumb or holding it. The click cursor is the thumb's alone.
  late final AnimationController _halo = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
  late final AnimationController _grow = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
  late final Animation<double> _haloCurve = CurvedAnimation(parent: _halo, curve: Curves.easeOut, reverseCurve: Curves.easeIn);
  late final Animation<double> _growCurve = CurvedAnimation(parent: _grow, curve: Curves.easeOut, reverseCurve: Curves.easeIn);

  bool _overBar = false;
  bool _overThumb = false;
  bool _pressed = false;

  @override
  void dispose() {
    _halo.dispose();
    _grow.dispose();
    super.dispose();
  }

  void _sync() {
    (_overBar || _pressed ? _halo.forward() : _halo.reverse());
    (_overThumb || _pressed ? _grow.forward() : _grow.reverse());
  }

  void _onHover(PointerEvent event, double width) {
    final track = width - 2 * _inset;
    final centre = Offset(_inset + track * (value / 100).clamp(0.0, 1.0), 20);
    final over = (event.localPosition - centre).distance <= _thumbRadius * 2;
    if (_overBar && over == _overThumb) return;
    setState(() {
      _overBar = true;
      _overThumb = over;
    });
    _sync();
  }

  void _onExit() {
    if (!_overBar && !_overThumb) return;
    setState(() {
      _overBar = false;
      _overThumb = false;
    });
    _sync();
  }

  void _press(bool down) {
    if (_pressed == down) return;
    _pressed = down;
    _sync();
  }

  void _set(double next) => widget.onChanged(next.clamp(0.0, 100.0));

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp) {
      _set(value + _step);
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowDown) {
      _set(value - _step);
    } else if (key == LogicalKeyboardKey.home) {
      _set(0);
    } else if (key == LogicalKeyboardKey.end) {
      _set(100);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ArrowKeyClaim(
      child: FocusRingShape(
        shape: const StadiumBorder(),
        child: Focus(
          onKeyEvent: _onKey,
          child: Semantics(
            slider: true,
            label: 'Volume',
            value: '${value.round()}%',
            increasedValue: '${(value + _step).clamp(0, 100).round()}%',
            decreasedValue: '${(value - _step).clamp(0, 100).round()}%',
            onIncrease: () => _set(value + _step),
            onDecrease: () => _set(value - _step),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The track runs between the thumb's end stops, so 0 and 100 are reachable.
                const inset = _inset;
                final track = constraints.maxWidth - 2 * inset;
                // Mounted while it animates open, so the track can be zero-width or less.
                double fromDx(double dx) => track <= 0
                    ? value
                    : ((dx - inset) / track * 100).clamp(0.0, 100.0);
                return MouseRegion(
                  opaque: false,
                  cursor: _overThumb || _pressed ? SystemMouseCursors.click : MouseCursor.defer,
                  onHover: (event) => _onHover(event, constraints.maxWidth),
                  onExit: (_) => _onExit(),
                  child: Listener(
                    onPointerDown: (_) => _press(true),
                    onPointerUp: (_) => _press(false),
                    onPointerCancel: (_) => _press(false),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => _set(fromDx(d.localPosition.dx)),
                      onHorizontalDragUpdate: (d) => _set(fromDx(d.localPosition.dx)),
                      child: SizedBox(
                        height: 40,
                        width: constraints.maxWidth,
                        child: AnimatedBuilder(
                          animation: Listenable.merge([_haloCurve, _growCurve]),
                          builder: (context, _) => CustomPaint(
                            painter: _VolumePainter(
                              fraction: value / 100,
                              active: scheme.primary,
                              inactive: Theme.of(context).tokens.onScrim.withValues(alpha: 0.25),
                              inset: inset,
                              halo: _haloCurve.value,
                              grow: _growCurve.value,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _VolumePainter extends CustomPainter {
  _VolumePainter({
    required this.fraction,
    required this.active,
    required this.inactive,
    required this.inset,
    required this.halo,
    required this.grow,
  });

  final double fraction;
  final Color active;
  final Color inactive;
  final double inset;
  final double halo;
  final double grow;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final left = inset;
    final right = size.width - inset;
    final x = left + (right - left) * fraction.clamp(0.0, 1.0);
    final track = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(left, y), Offset(right, y), track..color = inactive);
    canvas.drawLine(Offset(left, y), Offset(x, y), track..color = active);
    // The halo, under the thumb, then the thumb a little bigger while it is hovered or held.
    if (halo > 0) canvas.drawCircle(Offset(x, y), 6 * 1.75 * halo, Paint()..color = active.withValues(alpha: 0.5));
    canvas.drawCircle(Offset(x, y), 6 * (1 + 0.3 * grow), Paint()..color = active);
  }

  @override
  bool shouldRepaint(_VolumePainter old) =>
      fraction != old.fraction ||
      active != old.active ||
      inactive != old.inactive ||
      inset != old.inset ||
      halo != old.halo ||
      grow != old.grow;
}
