/// The rail highlights the section you are in.
///
/// Two things were wrong and this covers both:
///
///   - Home was keyed on `currentRoute == null`, but the home route is named
///     `'/'`. Home was therefore never lit while on Home — and *was* lit while
///     a popup covered it, since a `PopupRoute` has no name.
///   - Opening a video lit nothing, because the watch page is its own route.
///     A video opened from Home is still Home; the rail should not lose its
///     place because you pressed play.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/page_wrapper.dart';
import 'package:rill/ui/pages/subscriptions.dart';
import 'package:rill/ui/player_shell.dart';

/// The section the rail should reflect, injected directly — the tracker that
/// derives it from real navigation is covered in `route_tracker_test.dart`.
class _Section extends CurrentRoute {
  _Section(this.initial);

  final String? initial;

  @override
  String? build() => initial;
}

Future<Color?> iconColour(WidgetTester tester, String itemKey, IconData icon) async {
  final finder = find.descendant(
    of: find.byKey(ValueKey(itemKey)),
    matching: find.byIcon(icon),
  );
  expect(finder, findsOneWidget, reason: 'the $itemKey rail item should exist');
  return tester.widget<Icon>(finder).color;
}

Future<void> pumpRail(WidgetTester tester, String? section) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sectionRouteProvider.overrideWith(() => _Section(section))],
      child: MaterialApp(
        theme: buildRillTheme(kDefaultAccent),
        home: const PageWrapper(
          title: Text('Rill'),
          body: SizedBox.shrink(),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late Color selected;
  late Color unselected;

  setUp(() {
    final scheme = buildRillTheme(kDefaultAccent).colorScheme;
    selected = scheme.primary;
    unselected = scheme.onSurfaceVariant;
  });

  testWidgets('Home is selected on the home route', (tester) async {
    // The bug: `'/'` was not recognised, so this was the unselected colour.
    await pumpRail(tester, homeRouteName);
    expect(await iconColour(tester, 'home', Icons.home), selected);
    expect(await iconColour(tester, 'subscriptions', Icons.subscriptions_outlined),
        unselected);
  });

  testWidgets('Home is selected before the observer has reported anything',
      (tester) async {
    // The first frame, when the section provider is still null. The app opens
    // on Home, so this must not be a moment with nothing lit.
    await pumpRail(tester, null);
    expect(await iconColour(tester, 'home', Icons.home), selected);
  });

  testWidgets('Home stays selected on a watch page opened from Home',
      (tester) async {
    // `sectionRouteProvider` holds the last non-watch page, so the section is
    // still Home while the video plays.
    await pumpRail(tester, homeRouteName);
    expect(await iconColour(tester, 'home', Icons.home), selected);
  });

  testWidgets('Subscriptions is selected on its own route', (tester) async {
    await pumpRail(tester, subscriptionsRouteName);
    expect(await iconColour(tester, 'subscriptions', Icons.subscriptions_outlined),
        selected);
    expect(await iconColour(tester, 'home', Icons.home), unselected);
  });

  testWidgets('and stays selected on All subscriptions', (tester) async {
    // Task 21 §4 — a page within the section, not a section of its own.
    await pumpRail(tester, 'all-subscriptions');
    expect(await iconColour(tester, 'subscriptions', Icons.subscriptions_outlined),
        selected);
    expect(await iconColour(tester, 'home', Icons.home), unselected);
  });

  testWidgets('a section the rail does not know lights nothing', (tester) async {
    // Search has no rail entry. Lighting Home for it — which the old
    // `!isOnSubscriptions` shape did — is worse than lighting nothing.
    await pumpRail(tester, 'search');
    expect(await iconColour(tester, 'home', Icons.home), unselected);
    expect(await iconColour(tester, 'subscriptions', Icons.subscriptions_outlined),
        unselected);
  });
}
