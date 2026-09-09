/// The skeleton sits where the real grid will — Task 22 follow-up.
///
/// The only property worth testing here is the one whose failure is visible:
/// a placeholder whose column count or spacing differs from the real grid's
/// makes every tile jump the instant content arrives. That is worse than
/// having shown a spinner, and it is invisible in code review because the two
/// numbers live in different files.
///
/// So these are mostly tests of [FeedGridMetrics] — the shared rule — plus
/// enough of [FeedSkeleton] to prove it actually uses it rather than
/// re-deriving its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/theme/screen_values.dart';
import 'package:rill/ui/widgets/feed_grid_metrics.dart';
import 'package:rill/ui/widgets/feed_skeleton.dart';

Future<void> pumpSkeleton(WidgetTester tester, Size size, {bool wide = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: FeedSkeleton(isWideLayout: wide))),
  );
  // One pump only. `pumpAndSettle` never returns on a repeating animation, and
  // the skeleton pulses forever by design.
  await tester.pump();
}

void main() {
  group('FeedGridMetrics', () {
    test('a wide layout is always one column', () {
      expect(FeedGridMetrics.columnCount(2000, true), 1);
      expect(FeedGridMetrics.columnCount(320, true), 1);
    });

    test('columns are added so tiles never exceed the max extent', () {
      // Rounded up, so tiles shrink to fill the width rather than leaving a
      // gutter: `ceil((width + 16) / (430 + 16))`. 900px is three columns of
      // ~289px, not two of ~442 — the rule keeps every tile *under* the max
      // extent rather than near it. Worth pinning, because "900 is two
      // columns" is the intuitive answer and it is wrong.
      expect(FeedGridMetrics.columnCount(900, false), 3);
      expect(FeedGridMetrics.columnCount(1400, false), 4);
      expect(FeedGridMetrics.columnCount(430, false), 1);
    });

    test('never zero, however narrow', () {
      // A zero-column grid renders nothing and divides by zero downstream.
      expect(FeedGridMetrics.columnCount(0, false), greaterThanOrEqualTo(1));
      expect(FeedGridMetrics.columnCount(1, false), 1);
      expect(FeedGridMetrics.columnCount(-100, false), greaterThanOrEqualTo(1));
    });

    test('a wide layout is tighter between rows than the grid', () {
      expect(
        FeedGridMetrics.verticalSpacing(true),
        lessThan(FeedGridMetrics.verticalSpacing(false)),
      );
    });
  });

  group('FeedSkeleton', () {
    testWidgets('lays out the same number of columns the real grid would',
        (tester) async {
      // The claim the whole file exists for. If these ever disagree, tiles
      // reflow when the first page lands.
      const width = 1400.0;
      await pumpSkeleton(tester, const Size(width, 900));

      final expected = FeedGridMetrics.columnCount(width, false);
      final firstRow = tester.widgetList<Row>(find.byType(Row)).first;
      expect(firstRow.children.length, expected);
      expect(firstRow.spacing, FeedGridMetrics.horizontalSpacing);
    });

    testWidgets('one column in a wide layout', (tester) async {
      await pumpSkeleton(tester, const Size(1400, 900), wide: true);
      final firstRow = tester.widgetList<Row>(find.byType(Row)).first;
      expect(firstRow.children.length, 1);
    });

    testWidgets('fills a tall viewport rather than floating three tiles in it',
        (tester) async {
      // A fixed row count leaves a short skeleton on a tall window, which reads
      // as a feed that finished loading with three items in it.
      await pumpSkeleton(tester, const Size(1400, 400));
      final short = tester.widgetList<AspectRatio>(find.byType(AspectRatio)).length;

      await pumpSkeleton(tester, const Size(1400, 1600));
      final tall = tester.widgetList<AspectRatio>(find.byType(AspectRatio)).length;

      expect(tall, greaterThan(short));
    });

    testWidgets('placeholder thumbnails use the real tile aspect ratio',
        (tester) async {
      await pumpSkeleton(tester, const Size(1400, 900));
      final ratios = tester
          .widgetList<AspectRatio>(find.byType(AspectRatio))
          .map((a) => a.aspectRatio)
          .toSet();
      expect(ratios, {ScreenValues.normalAspectRatio});
    });

    testWidgets('animates from a single controller, not one per tile',
        (tester) async {
      // `CLAUDE.md`'s "never instantiate a player per tile", applied to
      // tickers: N tiles each driving their own animation is N tickers and N
      // rebuilds a frame, for an effect that is identical across the grid.
      await pumpSkeleton(tester, const Size(1400, 1200));
      // Scoped to the skeleton: `MaterialApp`'s own route transition is a
      // `FadeTransition` too, so an unscoped finder counts the framework's.
      expect(
        find.descendant(
          of: find.byType(FeedSkeleton),
          matching: find.byType(FadeTransition),
        ),
        findsOneWidget,
      );
      expect(tester.widgetList<AspectRatio>(find.byType(AspectRatio)).length,
          greaterThan(1));
    });

    testWidgets('is inert — not scrollable, and invisible to screen readers',
        (tester) async {
      await pumpSkeleton(tester, const Size(1400, 900));
      final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scroll.physics, isA<NeverScrollableScrollPhysics>());
      expect(
        find.descendant(
          of: find.byType(FeedSkeleton),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
    });

    testWidgets('disposes its controller without complaint', (tester) async {
      await pumpSkeleton(tester, const Size(1400, 900));
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(tester.takeException(), isNull);
    });
  });
}
