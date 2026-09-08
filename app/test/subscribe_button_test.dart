/// `SubscribeButton` (Task 22) — the shared pill every subscribe affordance
/// in the app now uses. Everything here exercises pure UI state (the
/// unsubscribed/subscribed pill swap, the notification-level dropdown, the
/// unsubscribe action); none of it depends on a real RPC existing yet, which
/// is the point — these keep passing unchanged once `onSubscribe` (and,
/// eventually, real unsubscribe/notification endpoints) stop being stubs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/widgets/subscribe_button.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildRillTheme(kDefaultAccent),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('unsubscribed renders a "Subscribe" pill with no dropdown affordance', (tester) async {
    await tester.pumpWidget(_harness(const SubscribeButton(channelId: 'chan_1')));
    await tester.pump();

    expect(find.text('Subscribe'), findsOneWidget);
    expect(find.text('Subscribed'), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping Subscribe with no onSubscribe hook still flips to the subscribed pill', (tester) async {
    await tester.pumpWidget(_harness(const SubscribeButton(channelId: 'chan_2')));
    await tester.pump();

    await tester.tap(find.text('Subscribe'));
    await tester.pump();

    expect(find.text('Subscribe'), findsNothing);
    expect(find.text('Subscribed'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a channelId of null renders a disabled Subscribe pill', (tester) async {
    await tester.pumpWidget(_harness(const SubscribeButton(channelId: null)));
    await tester.pump();

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('onSubscribe returning false leaves the button unsubscribed', (tester) async {
    await tester.pumpWidget(
      _harness(
        SubscribeButton(
          channelId: 'chan_3',
          onSubscribe: (_) async => false,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Subscribe'));
    await tester.pump();

    expect(find.text('Subscribe'), findsOneWidget);
    expect(find.text('Subscribed'), findsNothing);
  });

  testWidgets('onSubscribe returning true commits the subscribe and is called with the channel id', (tester) async {
    String? seenChannelId;
    await tester.pumpWidget(
      _harness(
        SubscribeButton(
          channelId: 'chan_4',
          onSubscribe: (id) async {
            seenChannelId = id;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Subscribe'));
    await tester.pump();

    expect(seenChannelId, 'chan_4');
    expect(find.text('Subscribed'), findsOneWidget);
  });

  testWidgets('the subscribed pill opens a dropdown with all three notification levels and Unsubscribe', (tester) async {
    await tester.pumpWidget(_harness(const SubscribeButton(channelId: 'chan_5', initiallySubscribed: true)));
    await tester.pump();

    await tester.tap(find.text('Subscribed'));
    await tester.pumpAndSettle();

    expect(find.text('All'), findsOneWidget);
    expect(find.text('Personalized'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
    expect(find.text('Unsubscribe'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a notification level updates the pill icon and calls the hook', (tester) async {
    String? seenChannelId;
    SubscriptionNotificationLevel? seenLevel;
    await tester.pumpWidget(
      _harness(
        SubscribeButton(
          channelId: 'chan_6',
          initiallySubscribed: true,
          onNotificationLevelChanged: (id, level) {
            seenChannelId = id;
            seenLevel = level;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Subscribed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();

    expect(seenChannelId, 'chan_6');
    expect(seenLevel, SubscriptionNotificationLevel.none);
    expect(find.byIcon(SubscriptionNotificationLevel.none.icon), findsOneWidget);
  });

  testWidgets('Unsubscribe from the dropdown reverts to the Subscribe pill and calls the hook', (tester) async {
    String? seenChannelId;
    await tester.pumpWidget(
      _harness(
        SubscribeButton(
          channelId: 'chan_7',
          initiallySubscribed: true,
          onUnsubscribe: (id) => seenChannelId = id,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Subscribed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unsubscribe'));
    await tester.pumpAndSettle();

    expect(seenChannelId, 'chan_7');
    expect(find.text('Subscribe'), findsOneWidget);
    expect(find.text('Subscribed'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
