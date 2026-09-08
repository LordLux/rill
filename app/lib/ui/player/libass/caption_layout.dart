/// Grouping libass' flat image list back into captions, and clamping each one
/// independently.
///
/// No dart:ui here — this is pure arithmetic so it runs under the plain Dart VM
/// and can be checked offline against libass (probe_nudge.dart).
library;

/// An axis-aligned box in original-script coordinates.
class Box {
  final double left;
  final double top;
  final double right;
  final double bottom;
  const Box(this.left, this.top, this.right, this.bottom);

  double get width => right - left;
  double get height => bottom - top;

  Box union(Box o) => Box(
        left < o.left ? left : o.left,
        top < o.top ? top : o.top,
        right > o.right ? right : o.right,
        bottom > o.bottom ? bottom : o.bottom,
      );

  Box shift(double dx, double dy) =>
      Box(left + dx, top + dy, right + dx, bottom + dy);

  bool containsPoint(double x, double y, {double slack = 0}) =>
      x >= left - slack &&
      x <= right + slack &&
      y >= top - slack &&
      y <= bottom + slack;

  @override
  String toString() => 'x[${left.toStringAsFixed(0)}..'
      '${right.toStringAsFixed(0)}] y[${top.toStringAsFixed(0)}..'
      '${bottom.toStringAsFixed(0)}]';
}

/// Splits libass' image list into one group per event.
///
/// Measured against the real tracks: `ass_render_frame` walks the sorted event
/// list and appends each event's images as one contiguous block, emitting them
/// shadow -> outline -> character. So `type` is *non-increasing* within an
/// event (2… then 1… then 0…), and a new event begins exactly where `type` goes
/// back up.
///
/// Returns the group index for each image, parallel to [types].
///
/// A spatial tie-breaker was tried and removed. It cannot work in either
/// direction, and probe_gaps.dart says why: across the sample tracks the
/// largest gap *inside* one event is 0 px and the smallest gap *between* two
/// events is also 0 px — YouTube composites a caption as an invisible
/// shadow-carrying event exactly on top of a visible one, so distinct events
/// routinely coincide. There is no threshold that separates the two
/// populations. It also actively broke karaoke: `\k` colour runs sit 11 px
/// apart inside a single event and were being split into one group per
/// syllable.
///
/// The one shape this cannot see is two adjacent events that both draw fill
/// only — no border, no shadow — which produce an unbroken run of `type == 0`
/// and merge into one group. They then clamp together instead of
/// independently. Every real caption style carries an outline, so this is
/// degraded, not wrong, and there is no signal in the API to do better.
List<int> groupImages(List<int> types) {
  final groups = List<int>.filled(types.length, 0);
  var g = 0;
  for (var i = 0; i < types.length; i++) {
    if (i > 0 && types[i] > types[i - 1]) g++;
    groups[i] = g;
  }
  return groups;
}

/// Collapses per-image rects into one box per group.
List<Box> groupBoxes(List<Box> rects, List<int> groups) {
  final out = <Box>[];
  for (var i = 0; i < rects.length; i++) {
    if (groups[i] == out.length) {
      out.add(rects[i]);
    } else {
      out[groups[i]] = out[groups[i]].union(rects[i]);
    }
  }
  return out;
}

/// How far [box] has to move to sit inside `0..w × 0..h`.
///
/// Only acts on an axis where the box actually fits: a caption wider than the
/// video cannot be rescued by translation, and pushing it just swaps which edge
/// is cut.
List<double> clampOffset(Box box, double w, double h) {
  var dx = 0.0, dy = 0.0;
  if (box.width <= w) {
    if (box.left < 0) {
      dx = -box.left;
    } else if (box.right > w) {
      dx = w - box.right;
    }
  }
  if (box.height <= h) {
    if (box.top < 0) {
      dy = -box.top;
    } else if (box.bottom > h) {
      dy = h - box.bottom;
    }
  }
  return [dx, dy];
}

/// The range of horizontal drag deltas that keeps [box] inside `0..w`.
/// Returns null when the box does not fit and so cannot be constrained.
List<double>? dragRange(double lo, double hi, double extent) {
  if (hi - lo > extent) return null;
  return [-lo, extent - hi];
}
