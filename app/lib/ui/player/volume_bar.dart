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

  static const double _step = 5;

  /// The thumb's radius, and how far the halo grows past it as a multiple.
  static const double _thumbRadius = 6;
  static const double _haloScale = 1.75;

  @override
  State<VolumeBar> createState() => _VolumeBarState();
}

class _VolumeBarState extends State<VolumeBar> with SingleTickerProviderStateMixin {
  double get value => widget.value;

  static const double _step = VolumeBar._step;

  /// 0 to 1: a halo that grows around the thumb while the pointer is on it or holds it, to say it can
  /// be grabbed.
  late final AnimationController _halo = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
  late final Animation<double> _haloCurve = CurvedAnimation(parent: _halo, curve: Curves.easeOut, reverseCurve: Curves.easeIn);
  bool _overThumb = false;
  bool _pressed = false;

  @override
  void dispose() {
    _halo.dispose();
    super.dispose();
  }

  void _syncHalo() {
    if (_overThumb || _pressed) {
      _halo.forward();
    } else {
      _halo.reverse();
    }
  }

  void _setOver(bool over) {
    if (over == _overThumb) return;
    _overThumb = over;
    _syncHalo();
  }

  void _setPressed(bool pressed) {
    if (pressed == _pressed) return;
    _pressed = pressed;
    _syncHalo();
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
                const inset = 10.0;
                final track = constraints.maxWidth - 2 * inset;
                // Mounted while it animates open, so the track can be zero-width or less.
                double fromDx(double dx) => track <= 0
                    ? value
                    : ((dx - inset) / track * 100).clamp(0.0, 100.0);
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onHover: (event) {
                    final thumbX = inset + (track <= 0 ? 0 : track * value / 100);
                    _setOver((event.localPosition - Offset(thumbX, 20)).distance <= VolumeBar._thumbRadius * 2);
                  },
                  onExit: (_) => _setOver(false),
                  child: Listener(
                    onPointerDown: (_) => _setPressed(true),
                    onPointerUp: (_) => _setPressed(false),
                    onPointerCancel: (_) => _setPressed(false),
                    child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _set(fromDx(d.localPosition.dx)),
                  onHorizontalDragUpdate: (d) =>
                      _set(fromDx(d.localPosition.dx)),
                  child: SizedBox(
                    height: 40,
                    width: constraints.maxWidth,
                    child: CustomPaint(
                      painter: _VolumePainter(
                        fraction: value / 100,
                        active: scheme.primary,
                        inactive: Theme.of(
                          context,
                        ).tokens.onScrim.withValues(alpha: 0.25),
                        inset: inset,
                        halo: _haloCurve,
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
  }) : super(repaint: halo);

  final double fraction;
  final Color active;
  final Color inactive;
  final double inset;
  final Animation<double> halo;

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
    if (halo.value > 0) {
      canvas.drawCircle(
        Offset(x, y),
        VolumeBar._thumbRadius * VolumeBar._haloScale * halo.value,
        Paint()..color = active.withValues(alpha: 0.5),
      );
    }
    canvas.drawCircle(Offset(x, y), VolumeBar._thumbRadius, Paint()..color = active);
  }

  @override
  bool shouldRepaint(_VolumePainter old) =>
      fraction != old.fraction ||
      active != old.active ||
      inactive != old.inactive ||
      inset != old.inset;
}
