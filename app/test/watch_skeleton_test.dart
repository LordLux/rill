/// The watch skeleton, in every shape the watch page has.
///
/// It stands in for the page while `mix.start` is in flight, and it drives the
/// real `WatchLayout` so it cannot drift from the page it is standing in for.
/// What that buys has to be checked in all three shapes, because the whole
/// point is the one that is easy to forget: **two-column, theatre, and the
/// single column it collapses to under ~889 px.** An overflow in any of them is
/// a red stripe across the first second of opening a mix.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/pages/watch_layout.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/widgets/watch_skeleton.dart';

/// Playback that plays nothing.
class _SilentPlayback extends PlaybackController {
  @override
  PlaybackState build() => const PlaybackState();
}

Future<void> pumpSkeleton(
  WidgetTester tester, {
  required Size size,
  bool theatre = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // The skeleton reads what is playing (so it can stand down once something
  // is), and the real controller would try to build a media engine.
  final container = ProviderContainer(
    overrides: [playbackProvider.overrideWith(_SilentPlayback.new)],
  );
  addTearDown(container.dispose);
  if (theatre) container.read(playerViewProvider.notifier).toggleTheatre();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: WatchSkeleton())),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('renders without overflowing', () {
    // The three shapes, plus the boundary either side of the collapse point.
    for (final (label, size, theatre) in <(String, Size, bool)>[
      ('wide two-column', Size(1920, 1080), false),
      ('wide theatre', Size(1920, 1080), true),
      ('just above the collapse point', Size(900, 900), false),
      ('just below the collapse point', Size(880, 900), false),
      ('narrow single column', Size(600, 900), false),
      ('short viewport', Size(1400, 500), false),
    ]) {
      testWidgets(label, (tester) async {
        await pumpSkeleton(tester, size: size, theatre: theatre);
        expect(tester.takeException(), isNull);
        expect(find.byType(WatchSkeleton), findsOneWidget);
      });
    }
  });

  testWidgets('uses the real WatchLayout rather than its own', (tester) async {
    // The guard on the thing that keeps it honest. If someone hand-rolls the
    // layout here, the skeleton stops tracking the page's collapse point and
    // rail width, and nothing else would notice.
    await pumpSkeleton(tester, size: const Size(1920, 1080));
    expect(find.byType(WatchLayout), findsOneWidget);
  });

  testWidgets('draws a rail when the page would have one', (tester) async {
    await pumpSkeleton(tester, size: const Size(1920, 1080));
    final layout = tester.widget<WatchLayout>(find.byType(WatchLayout));
    expect(layout.geometry.isTwoColumn, isTrue);
    expect(layout.geometry.railWidth, greaterThan(0));
    expect(layout.railSlot, isNot(isA<SizedBox>()));
  });

  testWidgets('collapses the rail into one column when the page would', (tester) async {
    await pumpSkeleton(tester, size: const Size(600, 900));
    final layout = tester.widget<WatchLayout>(find.byType(WatchLayout));
    expect(layout.geometry.isTwoColumn, isFalse);
    expect(layout.geometry.railWidth, 0);
  });

  testWidgets('is inert: not scrollable, and hidden from screen readers', (tester) async {
    await pumpSkeleton(tester, size: const Size(1920, 1080));

    final scrollable = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(WatchSkeleton),
        matching: find.byType(SingleChildScrollView),
      ).first,
    );
    expect(scrollable.physics, isA<NeverScrollableScrollPhysics>());
    // What matters is that the content is inside an excluding boundary, not how
    // many `ExcludeSemantics` the layout happens to contain — the redesigned
    // skeleton has several of its own, and counting them made this brittle.
    final content = find.descendant(
      of: find.byType(WatchSkeleton),
      matching: find.byType(SingleChildScrollView),
    ).first;
    final excluders = find.ancestor(of: content, matching: find.byType(ExcludeSemantics));
    expect(excluders, findsWidgets);
    expect(
      tester.widgetList<ExcludeSemantics>(excluders).any((e) => e.excluding),
      isTrue,
      reason: 'a screen reader must not announce a page of empty boxes',
    );
  });

  testWidgets('says it is loading rather than leaving the page silent', (tester) async {
    // Excluding the placeholder boxes alone left a screen reader on a dead page
    // for the second a mix takes to arrive.
    final handle = tester.ensureSemantics();
    await pumpSkeleton(tester, size: const Size(1920, 1080));
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    handle.dispose();
  });
}
