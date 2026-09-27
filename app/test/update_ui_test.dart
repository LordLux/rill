/// The updater's surfaces — architecture.md §2.14. What a person sees: the
/// avatar dot, the account-menu row while a check runs, the panel it opens, and
/// the required-update banner. The controller's behaviour is asserted in
/// `update_controller_test.dart`; nothing here touches the network.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_config.dart';
import 'package:rill/domain/update/app_version.dart';
import 'package:rill/domain/update/update_manifest.dart';
import 'package:rill/domain/update/update_state.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/update_controller.dart';
import 'package:rill/ui/widgets/account_button.dart';
import 'package:rill/ui/widgets/update_banner.dart';

class _FixedAuth extends AuthController {
  _FixedAuth(this.initial);
  final AuthState initial;
  @override
  AuthState build() => initial;
}

/// Parked in one state; a manual check moves through `checking` and waits on
/// [finish], so a test can look at the row mid-check.
class FixedUpdate extends UpdateController {
  FixedUpdate(this.initial);
  final UpdateState initial;
  Completer<void> finish = Completer<void>();
  UpdatePhase result = const UpdatePhase.upToDate();

  @override
  UpdateState build() => initial;

  @override
  Future<void> checkNow({UpdateCheckOrigin origin = UpdateCheckOrigin.manual}) async {
    state = state.copyWith(phase: UpdatePhase.checking(origin: origin));
    await finish.future;
    finish = Completer<void>();
    state = state.copyWith(phase: result);
  }
}

final manifest = UpdateManifest(
  schema: 1,
  version: const AppVersion(major: 0, minor: 3, patch: 0),
  tag: 'v0.3.0',
  notes: const ['Faster home feed'],
  windowsX64: UpdateAsset(
    name: 'Rill-Setup-x64.exe',
    url: Uri.parse('https://github.com/LordLux/rill/releases/download/v0.3.0/Rill-Setup-x64.exe'),
    sha256: '0' * 64,
    size: 10,
  ),
);

UpdateManifest mandatory() => UpdateManifest(
  schema: 1,
  version: manifest.version,
  tag: manifest.tag,
  notes: manifest.notes,
  minimumVersion: manifest.version,
  windowsX64: manifest.windowsX64,
);

const current = AppVersion(major: 0, minor: 2, patch: 2);
const signedIn = AuthState(status: AuthStatus.authenticated, accountName: 'Ada Lovelace', accountHandle: '@ada');

UpdateConfig config({bool overridden = false}) => UpdateConfig.resolve(
  releaseMode: false,
  version: '0.2.2',
  prefixOverride: overridden ? 'http://127.0.0.1:8765/' : '',
);

Future<FixedUpdate> pump(
  WidgetTester tester,
  UpdateState state, {
  AuthState auth = signedIn,
  bool overridden = false,
  Widget child = const AccountButton(),
}) async {
  final controller = FixedUpdate(state);
  // Tall enough that the whole menu is on screen; the row sits near its end.
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // A fresh scope each time: a rebuilt ProviderScope keeps its first overrides.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => _FixedAuth(auth)),
        updateControllerProvider.overrideWith(() => controller),
        updateConfigProvider.overrideWithValue(config(overridden: overridden)),
      ],
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    ),
  );
  await tester.pump();
  return controller;
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Ada Lovelace'));
  await tester.pumpAndSettle();
}

UpdateState ready({String? dismissed, UpdateManifest? offer}) => UpdateState(
  phase: UpdatePhase.ready(manifest: offer ?? manifest, installerPath: r'C:\x\Rill-Setup-x64.exe'),
  currentVersion: current,
  dismissedVersion: dismissed,
);

void main() {
  testWidgets('a ready update puts a dot on the avatar and a highlighted row in the menu', (tester) async {
    await pump(tester, ready());
    expect(find.byKey(const ValueKey('update-dot')), findsOneWidget);

    await openMenu(tester);
    await tester.tap(find.text('Restart to update'));
    await tester.pumpAndSettle();
    expect(find.text('Rill 0.3.0 is ready!'), findsOneWidget);
    expect(find.text('Faster home feed'), findsOneWidget);
    expect(find.text('Full release notes'), findsOneWidget);
    // The card comes first, above the version and the switch.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('update-card'))).dy,
      lessThan(tester.getTopLeft(find.text('Version')).dy),
    );
    expect(find.widgetWithText(FilledButton, 'Restart to update'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Later'), findsOneWidget);
    expect(find.text('0.2.2'), findsOneWidget, reason: 'the running version');
  });

  testWidgets('a dismissed update loses the dot and the Later button', (tester) async {
    await pump(tester, ready(dismissed: '0.3.0'));
    expect(find.byKey(const ValueKey('update-dot')), findsNothing);
    await openMenu(tester);
    await tester.tap(find.text('Restart to update'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Later'), findsNothing);
  });

  testWidgets('signed out, there is no dot: the button opens login, not the menu', (tester) async {
    await pump(tester, ready(), auth: const AuthState(status: AuthStatus.anonymous));
    expect(find.byKey(const ValueKey('update-dot')), findsNothing);
  });

  testWidgets('checking shows a spinner in the row, then opens the result', (tester) async {
    final controller = await pump(tester, const UpdateState(phase: UpdatePhase.idle(), currentVersion: current));
    await openMenu(tester);
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    expect(find.text('Checking for updates…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    controller.finish.complete();
    await tester.pumpAndSettle();
    expect(find.text('Rill is up to date'), findsOneWidget);
    expect(find.text('Updates'), findsOneWidget, reason: 'the panel is a page of the same menu');
  });

  testWidgets('a failed manual check opens the panel with the reason and a Try again', (tester) async {
    final controller = await pump(tester, const UpdateState(phase: UpdatePhase.idle(), currentVersion: current));
    controller.result = const UpdatePhase.error(kind: UpdateErrorKind.network, message: 'HTTP 503', origin: UpdateCheckOrigin.manual);
    await openMenu(tester);
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    controller.finish.complete();
    await tester.pumpAndSettle();
    expect(find.text("Couldn't reach the update server"), findsOneWidget);
    expect(find.text('HTTP 503'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a test build says so on the panel', (tester) async {
    await pump(tester, ready(), overridden: true);
    await openMenu(tester);
    await tester.tap(find.text('Restart to update'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-test-marker')), findsOneWidget);
    expect(find.text('TEST FEED · prefix'), findsOneWidget);
  });

  testWidgets('the banner appears only for a required update, with no Later', (tester) async {
    await pump(tester, ready(), child: const UpdateBanner());
    expect(find.byKey(const ValueKey('update-banner')), findsNothing);

    await pump(tester, ready(offer: mandatory()), child: const UpdateBanner());
    expect(find.byKey(const ValueKey('update-banner')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Restart to update'), findsOneWidget);
    expect(find.text('Later'), findsNothing);
  });

  testWidgets('Later dismisses the update and goes back to the root menu', (tester) async {
    await pump(tester, ready());
    await openMenu(tester);
    await tester.tap(find.text('Restart to update'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Later'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsOneWidget, reason: 'back on the root page');
    expect(find.byKey(const ValueKey('update-dot')), findsNothing);
  });

  testWidgets("the header's refresh runs a check and spins while it does", (tester) async {
    final controller = await pump(tester, const UpdateState(phase: UpdatePhase.upToDate(), currentVersion: current));
    await openMenu(tester);
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    controller.finish.complete();
    await tester.pumpAndSettle();
    expect(find.text('Rill is up to date'), findsOneWidget);

    await tester.tap(find.byTooltip('Check for updates'));
    await tester.pump();
    expect(find.text('Checking for updates…'), findsOneWidget);
    expect(find.byTooltip('Check for updates'), findsNothing, reason: 'the button is a spinner meanwhile');
  });

  testWidgets('notes are capped at five', (tester) async {
    final long = UpdateManifest(
      schema: 1,
      version: manifest.version,
      tag: manifest.tag,
      notes: [for (var i = 1; i <= 8; i++) 'Note $i'],
      windowsX64: manifest.windowsX64,
    );
    await pump(tester, ready(offer: long));
    await openMenu(tester);
    await tester.tap(find.text('Restart to update'));
    await tester.pumpAndSettle();
    expect(find.text('Note 5'), findsOneWidget);
    expect(find.text('Note 6'), findsNothing);
  });
}
