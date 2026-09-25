/// The progress bar's chapter geometry and hover mapping — the pure half of
/// `architecture.md` §2.7's chapters. The widgets are `scrubber_chapters_widget_test.dart`.
///
/// Two of these carry the mutation that was actually run against them: the
/// hover mapping (the ends read exactly zero and the duration — break the clamp
/// or the padding offset and the first two assertions fail) and "no chapters →
/// no title" (return the first chapter's title regardless and the timeline test
/// fails).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/video_detail.dart';
import 'package:rill/ui/player/scrubber_chapters.dart';

Chapter chapter(String title, int start) => Chapter(title: title, startSeconds: start);

void main() {
  const tenMinutes = Duration(minutes: 10);
  final chapters = [chapter('Intro', 0), chapter('Explore', 90), chapter('Build', 300), chapter('Outro', 480)];

  group('chapterSpans', () {
    test('divides the duration at each start, the last running to the end', () {
      final spans = chapterSpans(chapters, tenMinutes)!;
      expect(spans.map((s) => s.start), [0, 0.15, 0.5, 0.8]);
      expect(spans.map((s) => s.end), [0.15, 0.5, 0.8, 1]);
    });

    test('time before the first chapter belongs to the first segment', () {
      final spans = chapterSpans([chapter('Intro', 5), chapter('Body', 300)], tenMinutes)!;
      expect(spans.first.start, 0);
      expect(spans.first.end, 0.5);
    });

    test('is null wherever the list is not a segmentation', () {
      expect(chapterSpans(const [], tenMinutes), isNull, reason: 'none');
      expect(chapterSpans([chapter('Only', 0)], tenMinutes), isNull, reason: 'one is not a segmentation');
      expect(chapterSpans(chapters, Duration.zero), isNull, reason: 'no duration to divide');
      expect(chapterSpans([chapter('A', 0), chapter('B', 100), chapter('C', 100)], tenMinutes), isNull,
          reason: 'equal starts — a zero-length chapter');
      expect(chapterSpans([chapter('A', 0), chapter('B', 300), chapter('C', 100)], tenMinutes), isNull,
          reason: 'not ascending');
      expect(chapterSpans([chapter('A', 120), chapter('B', 300)], tenMinutes), isNull,
          reason: 'the first chapter is well past the start');
      expect(chapterSpans([chapter('A', -1), chapter('B', 300)], tenMinutes), isNull, reason: 'before the start');
      expect(chapterSpans([chapter('A', 0), chapter('B', 600)], tenMinutes), isNull,
          reason: 'a start at the end would be a zero-width segment');
      expect(chapterSpans([chapter('A', 0), chapter('B', 900)], tenMinutes), isNull, reason: 'a start beyond the end');
    });
  });

  group('segmentExtents', () {
    // A 1000 px track and boundaries at 15%, 50% and 80%.
    final spans = chapterSpans(chapters, tenMinutes)!;

    test('splits the gap across each boundary and leaves the ends flush', () {
      final extents = segmentExtents(spans, 10, 1010);
      expect(extents.first.left, 10, reason: 'flush with the track start');
      expect(extents.last.right, 1010, reason: 'flush with the track end');
      // The boundary between the first two sits at 10 + 150.
      expect(extents[0].right, 159);
      expect(extents[1].left, 161);
      expect(extents[1].right, 509);
      expect(extents[2].left, 511);
    });

    test('a segment too narrow to afford a gap is drawn gapless, and so is its neighbour\'s edge', () {
      // Boundaries at 0, 1 s, 300 s: the first chapter is 1/600 of the track.
      final tiny = chapterSpans([chapter('A', 0), chapter('B', 1), chapter('C', 300)], tenMinutes)!;
      final extents = segmentExtents(tiny, 0, 600);
      expect(extents[0], (left: 0.0, right: 1.0), reason: 'a 1 px chapter keeps its whole 1 px');
      expect(extents[1].left, 1.0, reason: 'and abuts it: no gap was opened either side of the sliver');
      // The boundary between B and C has two wide neighbours, so it keeps its gap.
      expect(extents[1].right, 299);
      expect(extents[2].left, 301);
    });

    test('covers the track with nothing overlapping, whatever the widths', () {
      final many = [for (var i = 0; i < 200; i++) chapter('c$i', i * 3)];
      final extents = segmentExtents(chapterSpans(many, tenMinutes)!, 8, 308);
      for (var i = 0; i < extents.length; i++) {
        expect(extents[i].right, greaterThanOrEqualTo(extents[i].left), reason: 'segment $i has a width');
        if (i > 0) expect(extents[i].left, greaterThanOrEqualTo(extents[i - 1].right), reason: 'segment $i overlaps');
      }
      // 200 chapters in 300 px is 1.5 px each: nothing can afford a gap, so the
      // bar degrades to one solid track rather than to slivers.
      expect(extents.first.left, 8);
      expect(extents.last.right, 308);
      for (var i = 1; i < extents.length; i++) {
        expect(extents[i].left, closeTo(extents[i - 1].right, 1e-9), reason: 'no gap between $i and ${i - 1}');
      }
    });

    test('one whole span is the plain track', () {
      expect(segmentExtents(const [ChapterSpan(0, 1)], 8, 308), [(left: 8.0, right: 308.0)]);
    });
  });

  group('hover mapping', () {
    // A 400 px box with the scrubber's 8 px padding: the track is 8..392.
    final track = scrubberTrackSpan(400, const EdgeInsets.symmetric(horizontal: 8));

    Duration at(double dx) => trackTimeAt(dx, trackLeft: track.left, trackWidth: track.width, duration: tenMinutes);

    test('the track is the box less the padding', () {
      expect(track.left, 8);
      expect(track.width, 384);
    });

    test('the ends read exactly zero and the duration', () {
      expect(at(8), Duration.zero);
      expect(at(392), tenMinutes);
    });

    test('the middle reads the middle', () {
      expect(at(200), const Duration(minutes: 5));
      expect(at(8 + 96), const Duration(minutes: 2, seconds: 30));
    });

    test('the padding, outside the track, clamps to the ends rather than running past them', () {
      expect(at(0), Duration.zero);
      expect(at(-40), Duration.zero);
      expect(at(400), tenMinutes);
      expect(at(900), tenMinutes);
    });

    test('an empty track reads zero rather than dividing by it', () {
      expect(trackTimeAt(5, trackLeft: 8, trackWidth: 0, duration: tenMinutes), Duration.zero);
    });

    test('x is the inverse of time', () {
      for (final seconds in [0, 1, 90, 300, 599, 600]) {
        final position = Duration(seconds: seconds);
        final x = trackXAt(position, trackLeft: track.left, trackWidth: track.width, duration: tenMinutes);
        expect(at(x), position, reason: '$seconds s');
      }
    });
  });

  group('bubbleLeft', () {
    double left(double anchor, {double width = 80, double box = 400}) =>
        bubbleLeft(anchorX: anchor, bubbleWidth: width, boxWidth: box, margin: 4);

    test('centres on the anchor', () => expect(left(200), 160));

    test('stays inside the left edge', () => expect(left(2), 4));

    test('stays inside the right edge', () => expect(left(399), 400 - 80 - 4));

    test('a bubble wider than the room sits at the margin instead of running off either side', () {
      expect(left(50, width: 500), 4);
      expect(left(350, width: 500), 4);
    });
  });

  group('ScrubberTimeline', () {
    test('names the chapter a position falls in', () {
      final timeline = ScrubberTimeline(duration: tenMinutes, chapters: chapters);
      expect(timeline.hasChapters, isTrue);
      expect(timeline.chapterTitleAt(Duration.zero), 'Intro');
      expect(timeline.chapterTitleAt(const Duration(seconds: 89)), 'Intro');
      expect(timeline.chapterTitleAt(const Duration(seconds: 90)), 'Explore');
      expect(timeline.chapterTitleAt(tenMinutes), 'Outro');
      expect(timeline.segmentAt(const Duration(seconds: 400)), 2);
    });

    test('has no name to give without chapters — the bubble is a timestamp alone', () {
      final timeline = ScrubberTimeline(duration: tenMinutes);
      expect(timeline.hasChapters, isFalse);
      expect(timeline.chapterTitleAt(const Duration(minutes: 5)), isNull);
      expect(timeline.segments, hasLength(1), reason: 'the whole bar is one segment');
      expect(timeline.segmentAt(const Duration(minutes: 5)), 0);
    });

    test('a degenerate list is no chapters, not a partial one', () {
      final timeline = ScrubberTimeline(duration: tenMinutes, chapters: [chapter('Only', 0)]);
      expect(timeline.hasChapters, isFalse);
      expect(timeline.chapterTitleAt(const Duration(minutes: 5)), isNull);
    });
  });

  group('paintSegmentedTrack', () {
    // Records what is drawn, for the geometry a widget test cannot read.
    List<({Rect rect, Color color})> paint({
      required List<ChapterSpan> spans,
      Map<int, double> growth = const {},
      double thumbX = 60,
      double? bufferX = 80,
    }) {
      final canvas = TestRecordingCanvas();
      paintSegmentedTrack(
        canvas,
        trackRect: const Rect.fromLTRB(0, 4, 100, 8),
        thumbX: thumbX,
        bufferX: bufferX,
        segments: TrackSegments(spans, growth),
        played: Paint()..color = const Color(0xFF00FF00),
        buffered: Paint()..color = const Color(0xFF0000FF),
        remaining: Paint()..color = const Color(0xFFFF0000),
      );
      return [
        for (final call in canvas.invocations)
          if (call.invocation.memberName == #drawRect)
            (
              rect: call.invocation.positionalArguments[0] as Rect,
              color: (call.invocation.positionalArguments[1] as Paint).color,
            ),
      ];
    }

    const played = Color(0xFF00FF00);
    const buffered = Color(0xFF0000FF);
    const remaining = Color(0xFFFF0000);
    const halves = [ChapterSpan(0, 0.5), ChapterSpan(0.5, 1)];

    test('the three layers sweep across segments, clipped to each and skipping the gap', () {
      // Extents: 0..49 and 51..100. Played to 60, buffered to 80.
      final drawn = paint(spans: halves);
      expect(drawn, [
        (rect: const Rect.fromLTRB(0, 4, 49, 8), color: played),
        (rect: const Rect.fromLTRB(51, 4, 60, 8), color: played),
        (rect: const Rect.fromLTRB(60, 4, 80, 8), color: buffered),
        (rect: const Rect.fromLTRB(80, 4, 100, 8), color: remaining),
      ]);
    });

    test('one whole span paints exactly what the plain track does', () {
      final drawn = paint(spans: const [ChapterSpan(0, 1)]);
      expect(drawn, [
        (rect: const Rect.fromLTRB(0, 4, 60, 8), color: played),
        (rect: const Rect.fromLTRB(60, 4, 80, 8), color: buffered),
        (rect: const Rect.fromLTRB(80, 4, 100, 8), color: remaining),
      ]);
    });

    test('no buffered range draws played then remaining', () {
      final drawn = paint(spans: const [ChapterSpan(0, 1)], bufferX: null);
      expect(drawn.map((d) => d.color), [played, remaining]);
    });

    test('a grown segment is taller about the same centre line, and its neighbour is not', () {
      final drawn = paint(spans: halves, growth: {1: 1.0}, thumbX: 0, bufferX: 0);
      // Centre line y = 6. At rest 4 px tall; grown, 7.
      expect(drawn[0].rect, const Rect.fromLTRB(0, 4, 49, 8));
      expect(drawn[1].rect, Rect.fromLTRB(51, 6 - ScrubberMetrics.trackHeightHovered / 2, 100, 6 + ScrubberMetrics.trackHeightHovered / 2));
      expect(drawn[1].rect.center.dy, drawn[0].rect.center.dy);
    });

    test('a segment part-way through its growth is part-way in height', () {
      final drawn = paint(spans: halves, growth: {0: 0.5}, thumbX: 0, bufferX: 0);
      expect(drawn[0].rect.height, greaterThan(4));
      expect(drawn[0].rect.height, lessThan(ScrubberMetrics.trackHeightHovered));
    });
  });

  group('SegmentGrowth', () {
    testWidgets('grows the target over the animation and lets the rest go', (tester) async {
      final growth = SegmentGrowth(tester);
      addTearDown(growth.dispose);

      expect(growth.values, isEmpty);
      growth.retarget(2);
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration ~/ 2);
      expect(growth.values[2], allOf(greaterThan(0), lessThan(1)), reason: 'part-way');

      await tester.pump(ScrubberMetrics.growDuration * 2);
      expect(growth.values[2], 1.0, reason: 'settled');
      expect(tester.hasRunningAnimations, isFalse, reason: 'and the ticker stopped');

      growth.retarget(null);
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration * 2);
      expect(growth.values, isEmpty, reason: 'a segment that has shrunk to nothing has no entry');
    });

    testWidgets('a segment left mid-growth shrinks from where it had got to, not from full', (tester) async {
      final growth = SegmentGrowth(tester);
      addTearDown(growth.dispose);

      growth.retarget(0);
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration ~/ 2);
      final midway = growth.values[0]!;
      expect(midway, lessThan(1));

      growth.retarget(1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(growth.values[0]!, lessThanOrEqualTo(midway), reason: 'no pop back up to 1');
      expect(growth.values[1]!, greaterThan(0));

      await tester.pump(ScrubberMetrics.growDuration * 2);
      expect(growth.values, {1: 1.0});
    });

    testWidgets('reset drops everything at once', (tester) async {
      final growth = SegmentGrowth(tester);
      addTearDown(growth.dispose);
      growth.retarget(3);
      await tester.pump();
      await tester.pump(ScrubberMetrics.growDuration * 2);
      growth.reset();
      expect(growth.values, isEmpty);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
