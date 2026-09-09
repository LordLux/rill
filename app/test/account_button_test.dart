/// The top bar's account surface — Task 22 §7.
///
/// Widget-level, because the claims are about what a person sees: whose name is
/// in the menu, whether the two signed-out states look the same, and whether
/// Sign Out is reachable. The controller's behaviour is asserted separately in
/// `auth_controller_test.dart`; nothing here talks to a sidecar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/widgets/account_button.dart';

/// An [AuthController] parked in one state, so a widget test can pump any of
/// them without a round trip.
class _FixedAuth extends AuthController {
  _FixedAuth(this.initial);

  final AuthState initial;

  @override
  AuthState build() => initial;
}

Future<void> pumpWith(WidgetTester tester, AuthState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith(() => _FixedAuth(state))],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: AccountButton())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const signedIn = AuthState(
  status: AuthStatus.authenticated,
  accountName: 'Ada Lovelace',
  accountHandle: '@ada',
);

void main() {
  testWidgets('anonymous keeps the person glyph', (tester) async {
    await pumpWith(tester, const AuthState(status: AuthStatus.anonymous));
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsNothing);
  });

  testWidgets('anonymous offers Log in', (tester) async {
    await pumpWith(tester, const AuthState(status: AuthStatus.anonymous));
    expect(find.byTooltip('Log in'), findsOneWidget);
  });

  testWidgets('degraded says the session expired, not that you never signed in', (tester) async {
    // Task 22 §3. The same glyph with the same words for both states is what
    // makes F7 invisible — the user's own feed goes empty and nothing on screen
    // suggests anything expired.
    await pumpWith(tester, const AuthState(status: AuthStatus.degraded));
    expect(find.byTooltip('Your session expired. Please sign in again'), findsOneWidget);
    expect(find.byTooltip('Log in'), findsNothing);
  });

  testWidgets('signed in shows the account name and handle in the menu', (tester) async {
    await pumpWith(tester, signedIn);
    // By tooltip rather than by type: the button is a
    // `PopupMenuButton<_AccountAction>` over a private enum, so `find.byType`
    // has no name to match against from out here.
    await tester.tap(find.byTooltip('Ada Lovelace'));
    await tester.pumpAndSettle();
    expect(find.text('Ada Lovelace'), findsWidgets);
    expect(find.text('@ada'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('the menu is reachable by the account name as a tooltip', (tester) async {
    await pumpWith(tester, signedIn);
    expect(find.byTooltip('Ada Lovelace'), findsOneWidget);
  });

  // `auth.status` answers `accountName: null` whenever the account menu could
  // not be read — a state the sidecar reports on purpose rather than failing on,
  // because the *state* is what matters and a name is decoration.
  //
  // Two tests rather than two pumps in one: a second `pumpWidget` reuses the
  // element tree, and Riverpod keeps the notifier the first override built — so
  // the second state never took effect and the assertion measured the first one.
  testWidgets('no name falls back to the handle', (tester) async {
    await pumpWith(
      tester,
      const AuthState(status: AuthStatus.authenticated, accountHandle: '@ada'),
    );
    expect(find.byTooltip('@ada'), findsOneWidget);
  });

  testWidgets('no name and no handle falls back to a generic label', (tester) async {
    await pumpWith(tester, const AuthState(status: AuthStatus.authenticated));
    expect(find.byTooltip('Account'), findsOneWidget);
  });

  testWidgets('a busy sign-in does not open a second flow', (tester) async {
    await pumpWith(
      tester,
      const AuthState(status: AuthStatus.anonymous, isBusy: true),
    );
    final inkWell = tester.widget<InkWell>(find.byType(InkWell).first);
    expect(inkWell.onTap, isNull);
  });
}
