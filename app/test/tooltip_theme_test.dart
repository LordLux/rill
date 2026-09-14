/// The app's tooltip bubble comes from the theme, not from each call site.
///
/// The case that motivated it is the one this file pins: a Material component
/// that builds its own `Tooltip` — `IconButton(tooltip:)` — cannot be handed a
/// `decoration`, so the only way it gets the app's dark bubble is
/// `ThemeData.tooltipTheme`. If that stops being wired, these tooltips quietly
/// go back to Material 3's pale default and nothing else notices.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/theme/app_theme.dart';

Future<void> hoverToShow(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

/// The decorated box the bubble paints, found from the message it carries.
BoxDecoration bubbleFor(WidgetTester tester, String message) {
  final box = tester.widget<Container>(
    find
        .ancestor(of: find.text(message), matching: find.byType(Container))
        .first,
  );
  return box.decoration! as BoxDecoration;
}

void main() {
  test('the theme carries the bubble', () {
    final theme = buildRillTheme(Colors.red);
    expect(theme.tooltipTheme.decoration, tooltipBubbleDecoration);
    expect(theme.tooltipTheme.textStyle, tooltipBubbleTextStyle);
  });

  testWidgets("an IconButton's own tooltip gets the app bubble", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRillTheme(Colors.red),
        home: Scaffold(
          body: Center(
            child: IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    await hoverToShow(tester, find.byType(IconButton));

    expect(find.text('Close'), findsOneWidget);
    expect(bubbleFor(tester, 'Close').color, tooltipBubbleDecoration.color);
    expect(
      tester.widget<Text>(find.text('Close')).style?.color ??
          DefaultTextStyle.of(tester.element(find.text('Close'))).style.color,
      tooltipBubbleTextStyle.color,
    );
  });

  testWidgets('a call site that passes its own decoration still wins', (tester) async {
    // The theme is a default, not a lock — `Tooltip` resolves the widget's
    // own argument first.
    const custom = BoxDecoration(color: Color(0xFF00FF00));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildRillTheme(Colors.red),
        home: const Scaffold(
          body: Center(
            child: Tooltip(
              message: 'Custom',
              decoration: custom,
              child: SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    );

    await hoverToShow(tester, find.byType(SizedBox).last);
    expect(bubbleFor(tester, 'Custom').color, custom.color);
  });
}
