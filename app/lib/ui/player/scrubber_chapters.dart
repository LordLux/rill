/// Chapters on the progress bar: segment geometry, the hover mapping, the
/// growth animation and the bubble. `architecture.md` §2.7 has the decisions.
///
/// Everything here is either pure or a small self-contained widget; the wiring
/// into the `Slider` is `_Scrubber` in `controls.dart`. This file imports nothing
/// from it, so the two can stay apart.
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../../domain/now_playing_track.dart';
import '../../domain/video_detail.dart';
import '../../theme/app_theme.dart' show tooltipBubbleDecoration, tooltipBubbleTextStyle;

const Key playerScrubberBubbleKey = ValueKey('player-scrubber-bubble');
const Key playerScrubberBubbleTimeKey = ValueKey('player-scrubber-bubble-time');
const Key playerScrubberBubbleTitleKey = ValueKey('player-scrubber-bubble-title');

/// Every number the bar is tuned by, in one place.
abstract final class ScrubberMetrics {
  /// The track at rest, and the segment under the pointer. Growth is symmetric
  /// about the centre line, so the bar does not shift.
  static const double trackHeight = 4;
  static const double trackHeightHovered = 7;
  static const Duration growDuration = Duration(milliseconds: 120);

  /// The outer corners of the whole bar: the first segment's left pair and the
  /// last one's right pair, all four when there is only one. Skia scales a
  /// radius down to what the height allows, so at 4 and 7 px these read as
  /// semicircular ends; tune them alongside the heights.
  static const double endRadius = 3;
  static const double endRadiusHovered = 5;

  /// Between two segments, split evenly across the boundary.
  static const double chapterGap = 2;

  /// The narrowest a segment is drawn with a gap on either side of it; below
  /// this it is drawn gapless instead.
  static const double minSegmentWidth = 4;

  /// How long before the first chapter is still "the first chapter starts the
  /// video". Past it the list is not a segmentation of this video.
  static const Duration maxLeadIn = Duration(seconds: 10);

  /// Between the bubble and the top of the hovered track.
  static const double bubbleGap = 8;

  /// The bubble keeps this far inside the bar's edges.
  static const double bubbleEdgeMargin = 4;
  static const double bubbleMaxWidth = 320;
}

/// One chapter's share of the timeline, as fractions of the duration.
class ChapterSpan {
  const ChapterSpan(this.start, this.end);

  final double start;
  final double end;
}

/// The spans a chapter list divides [duration] into — or null when it is not a
/// segmentation, which draws one plain track.
///
/// Null for: fewer than two chapters, no duration, a first chapter well past
/// the start, starts that do not strictly ascend, or a start at or past the end.
/// Time before the first chapter belongs to the first segment.
List<ChapterSpan>? chapterSpans(List<Chapter> chapters, Duration duration) {
  if (chapters.length < 2 || duration <= Duration.zero) return null;
  final durationSeconds = duration.inMilliseconds / 1000;
  if (chapters.first.startSeconds < 0 || chapters.first.startSeconds > ScrubberMetrics.maxLeadIn.inSeconds) return null;
  for (var i = 1; i < chapters.length; i++) {
    if (chapters[i].startSeconds <= chapters[i - 1].startSeconds) return null;
  }
  if (chapters.last.startSeconds >= durationSeconds) return null;

  double at(int i) => i == 0 ? 0 : chapters[i].startSeconds / durationSeconds;
  return [
    for (var i = 0; i < chapters.length; i++) ChapterSpan(at(i), i == chapters.length - 1 ? 1 : at(i + 1)),
  ];
}

/// What the bar is showing the time of: how long it is, and its chapters.
///
/// The pointer handlers and the bubble ask this rather than each re-deriving
/// "which chapter", so the segment that grows and the name in the bubble cannot
/// disagree.
class ScrubberTimeline {
  ScrubberTimeline({required this.duration, List<Chapter> chapters = const []})
    : _chapters = chapters,
      _spans = chapterSpans(chapters, duration);

  final Duration duration;
  final List<Chapter> _chapters;
  final List<ChapterSpan>? _spans;

  bool get hasChapters => _spans != null;

  /// The spans to draw: the chapters, or the whole bar as one.
  List<ChapterSpan> get segments => _spans ?? const [ChapterSpan(0, 1)];

  /// Which of [segments] holds [position].
  int segmentAt(Duration position) => _spans == null ? 0 : chapterIndexAt(_chapters, position)!;

  /// The chapter's name at [position], or null when the bar has no chapters.
  String? chapterTitleAt(Duration position) => _spans == null ? null : _chapters[segmentAt(position)].title;
}

/// Where the slider's track sits inside the scrubber's own box.
///
/// The `Slider` insets its track by the theme's `padding` (and by the thumb and
/// overlay radii only when there is none), so a pointer's x in the box is not a
/// position on the track. This is `BaseSliderTrackShape.getPreferredRect` for
/// the padded case; the tap-versus-hover test in `scrubber_chapters_test.dart`
/// is what keeps it the same as the slider's own.
({double left, double width}) scrubberTrackSpan(double boxWidth, EdgeInsets padding) =>
    (left: padding.left, width: math.max(0, boxWidth - padding.horizontal));

/// The position under a pointer at [dx] — clamped, so the ends read exactly
/// zero and [duration].
Duration trackTimeAt(double dx, {required double trackLeft, required double trackWidth, required Duration duration}) {
  if (trackWidth <= 0) return Duration.zero;
  final fraction = ((dx - trackLeft) / trackWidth).clamp(0.0, 1.0);
  return Duration(milliseconds: (fraction * duration.inMilliseconds).round());
}

/// The inverse: the x a [position] sits at.
double trackXAt(Duration position, {required double trackLeft, required double trackWidth, required Duration duration}) {
  if (duration <= Duration.zero) return trackLeft;
  final fraction = (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  return trackLeft + fraction * trackWidth;
}

/// The painted extent of each span between [trackLeft] and [trackRight].
///
/// A gap opens at a boundary only when both segments beside it can afford one:
/// a narrower segment is drawn gapless, so a many-chaptered hour on a small
/// window degrades to a plain bar rather than to slivers.
List<({double left, double right})> segmentExtents(
  List<ChapterSpan> spans,
  double trackLeft,
  double trackRight, {
  double gap = ScrubberMetrics.chapterGap,
  double minWidth = ScrubberMetrics.minSegmentWidth,
}) {
  final width = trackRight - trackLeft;
  final edges = [for (final span in spans) trackLeft + span.start * width, trackRight];
  bool affordsGap(int i) => edges[i + 1] - edges[i] >= minWidth + gap;

  return [
    for (var i = 0; i < spans.length; i++)
      (
        left: edges[i] + (i > 0 && affordsGap(i - 1) && affordsGap(i) ? gap / 2 : 0),
        right: edges[i + 1] - (i < spans.length - 1 && affordsGap(i) && affordsGap(i + 1) ? gap / 2 : 0),
      ),
  ];
}

/// What the track shape needs to draw segments.
class TrackSegments {
  const TrackSegments(this.spans, this.growth);

  final List<ChapterSpan> spans;

  /// How far each span has grown toward [ScrubberMetrics.trackHeightHovered],
  /// 0–1 and sparse: only a hovered or shrinking span has an entry.
  final Map<int, double> growth;
}

/// Paints the track as one segment per span, each with the three layers the
/// plain track has — played, buffered, remaining — clipped to its own extent,
/// so the position and the buffer sweep across the gaps continuously.
void paintSegmentedTrack(
  Canvas canvas, {
  required Rect trackRect,
  required double thumbX,
  required double? bufferX,
  required TrackSegments segments,
  required Paint played,
  required Paint buffered,
  required Paint remaining,
}) {
  final extents = segmentExtents(segments.spans, trackRect.left, trackRect.right);
  final bufferRight = bufferX == null ? thumbX : math.max(thumbX, bufferX);
  final centerY = trackRect.center.dy;

  for (var i = 0; i < extents.length; i++) {
    final grown = Curves.easeOut.transform(segments.growth[i] ?? 0);
    final height = lerpDouble(trackRect.height, ScrubberMetrics.trackHeightHovered, grown)!;
    final top = centerY - height / 2;
    final bottom = centerY + height / 2;
    final extent = extents[i];

    void fill(double from, double to, Paint paint) {
      final left = math.max(from, extent.left);
      final right = math.min(to, extent.right);
      if (right > left) canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), paint);
    }

    // Only the ends of the bar are rounded, by clipping the segment to its
    // shape: the three layers inside stay plain rects, so the position and the
    // buffer cross the rounded end without knowing about it.
    final first = i == 0;
    final last = i == extents.length - 1;
    final rounded = first || last;
    if (rounded) {
      final radius = Radius.circular(lerpDouble(ScrubberMetrics.endRadius, ScrubberMetrics.endRadiusHovered, grown)!);
      canvas.save();
      canvas.clipRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(extent.left, top, extent.right, bottom),
          topLeft: first ? radius : Radius.zero,
          bottomLeft: first ? radius : Radius.zero,
          topRight: last ? radius : Radius.zero,
          bottomRight: last ? radius : Radius.zero,
        ),
      );
    }

    fill(trackRect.left, thumbX, played);
    fill(thumbX, bufferRight, buffered);
    fill(bufferRight, trackRect.right, remaining);

    if (rounded) canvas.restore();
  }
}

/// The hover growth of each segment — one ticker for all of them.
///
/// A segment the pointer leaves shrinks from wherever it had got to rather than
/// snapping, which a single "current" value cannot do when the pointer crosses
/// two boundaries inside one animation. Idle costs nothing: the ticker stops
/// when every value has reached its goal.
class SegmentGrowth extends ChangeNotifier {
  SegmentGrowth(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  final Map<int, double> _values = {};
  late final Map<int, double> values = UnmodifiableMapView(_values);
  int? _target;
  Duration _last = Duration.zero;

  /// Grows [index], and shrinks everything else. Null shrinks it all.
  void retarget(int? index) {
    if (_target == index) return;
    _target = index;
    if (index != null) _values.putIfAbsent(index, () => 0);
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  /// Back to nothing hovered, without animating.
  void reset() {
    _target = null;
    if (_ticker.isActive) _ticker.stop();
    if (_values.isEmpty) return;
    _values.clear();
    notifyListeners();
  }

  void _tick(Duration elapsed) {
    final step = (elapsed - _last).inMicroseconds / ScrubberMetrics.growDuration.inMicroseconds;
    _last = elapsed;
    var moving = false;
    for (final index in _values.keys.toList()) {
      final goal = index == _target ? 1.0 : 0.0;
      final value = _values[index]!;
      final next = goal > value ? math.min(goal, value + step) : math.max(goal, value - step);
      if (next == 0 && index != _target) {
        _values.remove(index);
      } else {
        _values[index] = next;
      }
      if (next != goal) moving = true;
    }
    if (!moving) _ticker.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// The bubble's left edge: centred on [anchorX], kept [margin] inside a bar
/// [boxWidth] wide. A bubble wider than the room sits at the margin.
double bubbleLeft({required double anchorX, required double bubbleWidth, required double boxWidth, required double margin}) {
  final furthest = math.max(margin, boxWidth - bubbleWidth - margin);
  return (anchorX - bubbleWidth / 2).clamp(margin, furthest);
}

/// Puts the bubble above the track's centre line at [anchorX].
class ScrubberBubbleLayout extends SingleChildLayoutDelegate {
  const ScrubberBubbleLayout({required this.anchorX});

  final double anchorX;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints(
    maxWidth: math.min(math.max(0, constraints.maxWidth - 2 * ScrubberMetrics.bubbleEdgeMargin), ScrubberMetrics.bubbleMaxWidth),
  );

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    bubbleLeft(anchorX: anchorX, bubbleWidth: childSize.width, boxWidth: size.width, margin: ScrubberMetrics.bubbleEdgeMargin),
    // The box is as tall as the slider, whose track is centred in it.
    size.height / 2 - ScrubberMetrics.trackHeightHovered / 2 - ScrubberMetrics.bubbleGap - childSize.height,
  );

  @override
  bool shouldRelayout(ScrubberBubbleLayout oldDelegate) => oldDelegate.anchorX != anchorX;
}

/// The timestamp, and the chapter's name when the video has them.
class ScrubberBubble extends StatelessWidget {
  const ScrubberBubble({super.key, required this.timestamp, this.title});

  final String timestamp;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: tooltipBubbleDecoration,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                timestamp,
                key: playerScrubberBubbleTimeKey,
                // Tabular, so the bubble does not breathe as the digits change.
                style: tooltipBubbleTextStyle.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              if (title != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title!,
                    key: playerScrubberBubbleTitleKey,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tooltipBubbleTextStyle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
