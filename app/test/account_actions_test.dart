/// Account state that has to outlive the widgets showing it.
///
/// Reported: a like on the watch page reset to "no rating" on a theatre ↔
/// normal toggle, though the rating had reached YouTube. `watch_layout_state_test`
/// covers the structural half (the layout discarding `State`); this file covers
/// the half keys cannot reach — a resize across the two-column breakpoint or a
/// mini-player round trip rebuilds the widget no matter how it is keyed, and the
/// rebuilt one must still know what the user did.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/domain/video_detail.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/account_actions.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/widgets/subscribe_button.dart';

class _FakeAuth extends AuthController {
  @override
  AuthState build() => const AuthState(status: AuthStatus.authenticated, accountHandle: '@first');

  void become(AuthState next) => state = next;
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [authProvider.overrideWith(_FakeAuth.new)]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the store', () {
    test('an entry outlives whatever read it', () {
      // The whole fix in one line: nothing about a widget is involved, so no
      // rebuild can take it away.
      final c = _container();
      final sub = c.listen(ratingActionsProvider, (_, _) {});
      c.read(ratingActionsProvider.notifier).set('vid', VideoRating.like);
      sub.close();

      expect(c.read(ratingActionsProvider)['vid'], VideoRating.like);
    });

    test('restore puts back exactly what was there, including nothing', () {
      final c = _container();
      final ratings = c.read(ratingActionsProvider.notifier);

      // A failed like on a video the user had never rated this session must go
      // back to *deferring to the server*, not to an explicit "none" — which
      // would hide a like the server does have.
      ratings.set('fresh', VideoRating.like);
      ratings.restore('fresh', had: false);
      expect(c.read(ratingActionsProvider).containsKey('fresh'), isFalse);

      ratings.set('seen', VideoRating.dislike);
      ratings.set('seen', VideoRating.like);
      ratings.restore('seen', had: true, previous: VideoRating.dislike);
      expect(c.read(ratingActionsProvider)['seen'], VideoRating.dislike);
    });

    test('clear defers to the server again', () {
      final c = _container();
      c.read(watchLaterActionsProvider.notifier).set('vid', true);
      c.read(watchLaterActionsProvider.notifier).clear('vid');
      expect(c.read(watchLaterActionsProvider).containsKey('vid'), isFalse);
    });

    test("one account's actions are never shown to another", () {
      final c = _container();
      c.read(ratingActionsProvider.notifier).set('vid', VideoRating.like);
      c.read(subscriptionActionsProvider.notifier).set('chan', true);

      (c.read(authProvider.notifier) as _FakeAuth)
          .become(const AuthState(status: AuthStatus.authenticated, accountHandle: '@second'));

      expect(c.read(ratingActionsProvider), isEmpty);
      expect(c.read(subscriptionActionsProvider), isEmpty);
    });

    test('signing out drops them too', () {
      final c = _container();
      c.read(watchLaterActionsProvider.notifier).set('vid', true);
      (c.read(authProvider.notifier) as _FakeAuth).become(const AuthState(status: AuthStatus.anonymous));
      expect(c.read(watchLaterActionsProvider), isEmpty);
    });

    test('a re-verification of the same account keeps them', () {
      // `isBusy` flips on every sign-in check; that must not wipe a like.
      final c = _container();
      c.read(ratingActionsProvider.notifier).set('vid', VideoRating.like);
      (c.read(authProvider.notifier) as _FakeAuth).become(
        const AuthState(status: AuthStatus.authenticated, accountHandle: '@first', isBusy: true),
      );
      expect(c.read(ratingActionsProvider)['vid'], VideoRating.like);
    });
  });

  group('SubscribeButton follows a changed value', () {
    Widget harness(bool subscribed) => MaterialApp(
          theme: buildRillTheme(kDefaultAccent),
          home: Scaffold(
            body: Center(child: SubscribeButton(channelId: 'chan', initiallySubscribed: subscribed)),
          ),
        );

    testWidgets('a value that arrives after the first build is shown', (tester) async {
      // The watch page builds the button before `video.info` answers — so with
      // `false` — and used to ignore the real answer when it arrived, reading
      // "Subscribe" on a subscribed channel for the whole visit.
      await tester.pumpWidget(harness(false));
      expect(find.text('Subscribe'), findsOneWidget);

      await tester.pumpWidget(harness(true));
      await tester.pump();
      expect(find.text('Subscribed'), findsOneWidget);
    });

    testWidgets('and back the other way', (tester) async {
      await tester.pumpWidget(harness(true));
      await tester.pumpWidget(harness(false));
      await tester.pump();
      expect(find.text('Subscribe'), findsOneWidget);
    });
  });
}
