import 'package:flutter/material.dart';

import '../focus_ring.dart' show FocusRingShape;

/// The progress bar's slider: drawn and driven here, not a Material `Slider`.
///
/// **Not a `Slider`, on purpose — the same reason as `VolumeBar`.** Every `Slider` hosts its value
/// indicator in an `OverlayPortal`, and each mount of the control bar added an empty, full-window
/// semantics node under the root for it. Most of the time it left with the bar; when the bar's own
/// nodes were removed and added again while it stayed (measured 2026-10-05, node 695), the Windows
/// accessibility bridge rejected that update and every one after it, and Narrator went silent
/// (`architecture.md` F51). This has no overlay, so there is nothing to orphan.
///
/// It keeps the `Slider`'s contract — `value`, `max`, `secondaryTrackValue`, `onChanged`,
/// `onChangeEnd` — so `_Scrubber` and its seek-on-release rule are untouched, and it paints through
/// the same [SliderTrackShape] in the ambient [SliderTheme], so the chapters, the hover growth and
/// the live window look as they did.
///
/// Arrow keys are not handled here: the player's own seek shortcut takes them, as it did with a
/// `Slider`. Screen readers get a slider with increase and decrease actions.
class ScrubberBar extends StatefulWidget {
  const ScrubberBar({
    super.key,
    required this.value,
    required this.max,
    required this.secondaryTrackValue,
    required this.onChanged,
    required this.onChangeEnd,
    required this.semanticFormatterCallback,
  });

  final double value;
  final double max;

  /// The buffered position, drawn behind the thumb.
  final double secondaryTrackValue;

  /// Null disables the bar: no thumb, no drag, no tap, no focus.
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// What a screen reader is told the position is.
  final String Function(double value) semanticFormatterCallback;

  /// How far a screen reader's increase and decrease actions move the position, in `max` units.
  static const double actionFraction = 0.05;

  @override
  State<ScrubberBar> createState() => _ScrubberBarState();
}

class _ScrubberBarState extends State<ScrubberBar> with SingleTickerProviderStateMixin {
  /// Whether a press or drag is in progress, so `onChangeEnd` follows every `onChanged` run.
  bool _active = false;
  double _last = 0;

  /// 0 to 1: the halo around the thumb, which grows while the pointer is on the thumb or holds it,
  /// to say it can be grabbed.
  late final AnimationController _halo = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
  late final Animation<double> _haloCurve = CurvedAnimation(parent: _halo, curve: Curves.easeOut, reverseCurve: Curves.easeIn);
  bool _overThumb = false;

  @override
  void dispose() {
    _halo.dispose();
    super.dispose();
  }

  void _syncHalo() {
    if (_overThumb || _active) {
      _halo.forward();
    } else {
      _halo.reverse();
    }
  }

  /// Whether the pointer is on the thumb: within a hand's width of its centre.
  void _onHover(PointerEvent event, SliderThemeData theme, double fraction) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final pad = (theme.padding ?? EdgeInsets.zero).resolve(TextDirection.ltr);
    final centre = Offset(pad.left + (box.size.width - pad.horizontal) * fraction, box.size.height / 2);
    final over = _enabled && (event.localPosition - centre).distance <= _RenderScrubberTrack.thumbRadius * 2;
    if (over == _overThumb) return;
    _overThumb = over;
    _syncHalo();
  }

  bool get _enabled => widget.onChanged != null;

  SliderThemeData _theme(BuildContext context) {
    final base = SliderTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return base.copyWith(
      activeTrackColor: base.activeTrackColor ?? scheme.primary,
      inactiveTrackColor: base.inactiveTrackColor ?? scheme.surfaceContainerHighest,
      thumbColor: base.thumbColor ?? scheme.primary,
    );
  }

  /// The value under [dx], a pointer's x in the bar's box.
  double _valueAt(double dx, SliderThemeData theme) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return widget.value;
    // The track is what is left of the box after the theme's padding, as a `Slider`'s is.
    final pad = (theme.padding ?? EdgeInsets.zero).resolve(TextDirection.ltr);
    final width = box.size.width - pad.horizontal;
    if (width <= 0) return widget.value;
    return ((dx - pad.left) / width).clamp(0.0, 1.0) * widget.max;
  }

  void _change(double dx, SliderThemeData theme) {
    if (!_active) {
      _active = true;
      _syncHalo();
    }
    _last = _valueAt(dx, theme);
    widget.onChanged?.call(_last);
  }

  void _end() {
    if (!_active) return;
    _active = false;
    _syncHalo();
    widget.onChangeEnd?.call(_last);
  }

  void _step(double direction) {
    final next = (widget.value + direction * widget.max * ScrubberBar.actionFraction).clamp(0.0, widget.max);
    widget.onChanged?.call(next);
    widget.onChangeEnd?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme(context);
    final enabled = _enabled;
    final max = widget.max <= 0 ? 1.0 : widget.max;
    final value = widget.value.clamp(0.0, max);
    final formatter = widget.semanticFormatterCallback;
    final up = (value + max * ScrubberBar.actionFraction).clamp(0.0, max);
    final down = (value - max * ScrubberBar.actionFraction).clamp(0.0, max);

    return MouseRegion(
      opaque: false,
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onHover: (event) => _onHover(event, theme, value / max),
      onExit: (_) {
        if (!_overThumb) return;
        _overThumb = false;
        _syncHalo();
      },
      child: FocusRingShape(
      shape: const StadiumBorder(),
      child: Focus(
        canRequestFocus: enabled,
        child: Semantics(
          slider: true,
          enabled: enabled,
          value: formatter(value),
          increasedValue: formatter(up),
          decreasedValue: formatter(down),
          onIncrease: enabled ? () => _step(1) : null,
          onDecrease: enabled ? () => _step(-1) : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The slider's own increase/decrease are the actions; a tap or scroll one would only
            // name the bar a tap target without a label.
            excludeFromSemantics: true,
            onTapDown: enabled ? (d) => _change(d.localPosition.dx, theme) : null,
            onTapUp: enabled ? (_) => _end() : null,
            onHorizontalDragStart: enabled ? (d) => _change(d.localPosition.dx, theme) : null,
            onHorizontalDragUpdate: enabled ? (d) => _change(d.localPosition.dx, theme) : null,
            onHorizontalDragEnd: enabled ? (_) => _end() : null,
            onHorizontalDragCancel: enabled ? _end : null,
            child: Padding(
              padding: theme.padding ?? EdgeInsets.zero,
              child: AnimatedBuilder(
                animation: _haloCurve,
                builder: (context, _) => _ScrubberTrack(
                  theme: theme,
                  enabled: enabled,
                  fraction: value / max,
                  secondaryFraction: (widget.secondaryTrackValue / max).clamp(0.0, 1.0),
                  halo: _haloCurve.value,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
}

/// Paints the track through the theme's [SliderTrackShape], and the thumb.
class _ScrubberTrack extends LeafRenderObjectWidget {
  const _ScrubberTrack({
    required this.theme,
    required this.enabled,
    required this.fraction,
    required this.secondaryFraction,
    required this.halo,
  });

  final SliderThemeData theme;
  final bool enabled;
  final double fraction;
  final double secondaryFraction;
  final double halo;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderScrubberTrack(theme, enabled, fraction, secondaryFraction, halo);

  @override
  void updateRenderObject(BuildContext context, _RenderScrubberTrack renderObject) {
    renderObject
      ..theme = theme
      ..enabled = enabled
      ..fraction = fraction
      ..secondaryFraction = secondaryFraction
      ..halo = halo;
  }
}

class _RenderScrubberTrack extends RenderBox {
  _RenderScrubberTrack(this._theme, this._enabled, this._fraction, this._secondaryFraction, this._halo);

  static const double thumbRadius = 6;

  /// How far the halo grows, as a multiple of the thumb.
  static const double haloScale = 1.25;

  /// The height with nothing to take it from: what the `Slider` it replaces measured, so the control
  /// bar keeps its height.
  static const double _preferredHeight = 8;

  SliderThemeData _theme;
  SliderThemeData get theme => _theme;
  set theme(SliderThemeData value) {
    if (identical(value, _theme)) return;
    _theme = value;
    markNeedsPaint();
  }

  bool _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    markNeedsPaint();
  }

  double _fraction;
  set fraction(double value) {
    if (value == _fraction) return;
    _fraction = value;
    markNeedsPaint();
  }

  double _halo;
  set halo(double value) {
    if (value == _halo) return;
    _halo = value;
    markNeedsPaint();
  }

  double _secondaryFraction;
  set secondaryFraction(double value) {
    if (value == _secondaryFraction) return;
    _secondaryFraction = value;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => Size(
    constraints.hasBoundedWidth ? constraints.maxWidth : constraints.minWidth,
    constraints.hasBoundedHeight ? constraints.maxHeight : _preferredHeight,
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    final shape = _theme.trackShape;
    if (shape == null) return;
    final rect = shape.getPreferredRect(parentBox: this, offset: offset, sliderTheme: _theme, isEnabled: _enabled);
    final thumbCenter = Offset(rect.left + rect.width * _fraction, rect.center.dy);
    final secondary = Offset(rect.left + rect.width * _secondaryFraction, rect.center.dy);
    shape.paint(
      context,
      offset,
      parentBox: this,
      sliderTheme: _theme,
      enableAnimation: _enabled ? const AlwaysStoppedAnimation(1.0) : const AlwaysStoppedAnimation(0.0),
      textDirection: TextDirection.ltr,
      thumbCenter: thumbCenter,
      secondaryOffset: secondary,
      isEnabled: _enabled,
    );
    // No thumb while disabled: there is no position to mark.
    if (_enabled) {
      // The halo, under the thumb: from nothing to a little wider than it.
      if (_halo > 0) {
        context.canvas.drawCircle(thumbCenter, thumbRadius * haloScale * _halo, Paint()..color = _theme.thumbColor!.withValues(alpha: 0.35));
      }
      context.canvas.drawCircle(thumbCenter, thumbRadius, Paint()..color = _theme.thumbColor!);
    }
  }
}
