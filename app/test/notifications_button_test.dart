/// The title bar's notifications button is disabled, and says so.
///
/// There is no notifications source yet. The button used to be live and do
/// nothing, under a hard-coded "9+" badge — a count of nothing, which is the
/// "live control that lies" `architecture.md` §2.7 argues against.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/page_wrapper.dart';

Future<void> pumpTitleBar(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildRillTheme(kDefaultAccent),
        home: const PageWrapper(title: Text('Rill'), body: SizedBox.shrink()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows no unread count it does not have', (tester) async {
    await pumpTitleBar(tester);
    expect(find.byIcon(Icons.notifications_none), findsOneWidget);
    expect(find.text('9+'), findsNothing);
  });

  testWidgets('looks disabled, and its tooltip says why', (tester) async {
    await pumpTitleBar(tester);
    final icon = tester.widget<Icon>(find.byIcon(Icons.notifications_none));
    expect(icon.color!.a, closeTo(0.38, 0.01));
    expect(find.byTooltip('Notifications — not available yet'), findsOneWidget);
  });

  testWidgets('is not a tap target', (tester) async {
    await pumpTitleBar(tester);
    expect(
      find.ancestor(of: find.byIcon(Icons.notifications_none), matching: find.byType(InkWell)),
      findsNothing,
    );
  });

  testWidgets('an enabled title-bar icon keeps full opacity', (tester) async {
    // The control for the dimming above: the menu button is live.
    await pumpTitleBar(tester);
    final icon = tester.widget<Icon>(find.byIcon(Icons.menu));
    expect(icon.color!.a, closeTo(1.0, 0.01));
  });
}
