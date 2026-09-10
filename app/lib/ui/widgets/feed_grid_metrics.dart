import 'dart:math' as math;

/// The feed grid's geometry, in one place.
///
/// Extracted so that [FeedView] and [FeedSkeleton] cannot disagree. That is the
/// entire point: a skeleton whose column count or spacing drifts from the real
/// grid's does not fail, it *jumps* — tiles reflow the instant real content
/// arrives, which reads as a glitch and is worse than having shown a spinner.
///
/// Sharing the geometry rather than the widget is the deliberate half of this.
/// The alternatives were a `MediaTile` that accepts a null item — which makes
/// the most complex widget in the tree dual-mode, with every field guarded and
/// every interaction suppressed — and a second grid, which duplicates exactly
/// these numbers. A leaf widget each and one shared rule is the version where
/// the thing that must match is impossible to get wrong.
class FeedGridMetrics {
  const FeedGridMetrics._();

  /// The widest a tile is allowed to get before the grid adds a column.
  static const double maxTileExtent = 430.0;

  /// Between columns.
  static const double horizontalSpacing = 16.0;

  /// Between rows. A wide, single-column surface (search) sits closer to a list
  /// and stays tight; the grid gets real breathing room.
  static double verticalSpacing(bool isWideLayout) => isWideLayout ? 2.0 : 16.0;

  /// How many tiles fit across [maxWidth].
  ///
  /// A wide layout is always one. Otherwise: the number of [maxTileExtent]
  /// columns that fit, rounded *up*, so tiles shrink to fill the width rather
  /// than leaving a gutter — and never below one, because a zero-column grid
  /// renders nothing and divides by zero downstream.
  static int columnCount(double maxWidth, bool isWideLayout) {
    if (isWideLayout) return 1;
    final count =
        ((maxWidth + horizontalSpacing) / (maxTileExtent + horizontalSpacing)).ceil();
    return math.max(1, count);
  }
}
