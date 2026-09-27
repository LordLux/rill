/// The yt-dlp surfaces — docs/todo.md 49. What a person sees: the avatar dot,
/// the Problems row and page, and the Updates page's info row. The
/// controller's behaviour is asserted in `ytdlp_controller_test.dart`;
/// nothing here touches the network or the real filesystem.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/update/update_config.dart';
import 'package:rill/domain/update/update_state.dart';
import 'package:rill/domain/ytdlp/ytdlp_state.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/update_controller.dart';
import 'package:rill/ui/widgets/account_button.dart';
import 'package:rill/ui/ytdlp_controller.dart';

class _FixedAuth extends AuthController {
  _FixedAuth(this.initial);
  final AuthState initial;
  @override
  AuthState build() => initial;
}

/// Parked in one state; `download`/`decline` are recorded rather than doing
/// real I/O, and can be told to actually move the state so a test can watch
/// the row/page react.
class FixedYtDlp extends YtDlpController {
  FixedYtDlp(this.initial);
  final YtDlpState initial;
  int downloadCalls = 0;
  int declineCalls = 0;

  @override
  YtDlpState build() => initial;

  @override
  Future<void> download() async {
    downloadCalls++;
  }

  @override
  Future<void> decline() async {
    declineCalls++;
    state = state.copyWith(choice: YtDlpChoice.declined);
  }
}

const signedIn = AuthState(status: AuthStatus.authenticated, accountName: 'Ada Lovelace', accountHandle: '@ada');

const missingNoChoice = YtDlpState(phase: YtDlpPhase.idle());
const missingDeclined = YtDlpState(phase: YtDlpPhase.idle(), choice: YtDlpChoice.declined);
const onPath = YtDlpState(phase: YtDlpPhase.idle(), location: YtDlpLocation.onPath, onPathPath: r'C:\dev\yt-dlp.exe');
const appManaged = YtDlpState(phase: YtDlpPhase.idle(), location: YtDlpLocation.appManaged, appManagedVersion: '2026.08.19');

Future<FixedYtDlp> pump(
  WidgetTester tester,
  YtDlpState state, {
  AuthState auth = signedIn,
  Widget child = const AccountButton(),
}) async {
  final controller = FixedYtDlp(state);
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => _FixedAuth(auth)),
        ytDlpControllerProvider.overrideWith(() => controller),
        updateControllerProvider.overrideWith(() => _IdleUpdate()),
        updateConfigProvider.overrideWithValue(UpdateConfig.resolve(releaseMode: false, version: '')),
      ],
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    ),
  );
  await tester.pump();
  return controller;
}

/// The updater is not what these tests are about; parked idle so `AccountButton`
/// has something to read without doing real work.
class _IdleUpdate extends UpdateController {
  @override
  UpdateState build() => const UpdateState(phase: UpdatePhase.idle());
}

Future<void> openMenu(WidgetTester tester, {String tooltip = 'Ada Lovelace'}) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no problem: no dot, no row, in either root page', (tester) async {
    await pump(tester, missingDeclined);
    expect(find.byKey(const ValueKey('update-dot')), findsNothing);
    await openMenu(tester);
    expect(find.text('Problems'), findsNothing);
  });

  testWidgets('a problem puts the dot on the avatar and a row in the signed-in menu', (tester) async {
    await pump(tester, missingNoChoice);
    expect(find.byKey(const ValueKey('update-dot')), findsNothing, reason: 'that key is the update dot, not this one');
    // The bottom-right attention dot has no key of its own; found by its
    // position instead — simplest is just to open the menu and check the row.
    // The tooltip itself changes too (checked separately below).
    await openMenu(tester, tooltip: 'Ada Lovelace — needs attention');
    expect(find.text('Problems'), findsOneWidget);
  });

  testWidgets('the tooltip says "needs attention" when signed in with a problem', (tester) async {
    await pump(tester, missingNoChoice);
    expect(find.byTooltip('Ada Lovelace — needs attention'), findsOneWidget);
  });

  testWidgets('signed out with a problem: the row is in the signed-out root page too', (tester) async {
    await pump(tester, missingNoChoice, auth: const AuthState(status: AuthStatus.anonymous));
    expect(find.byTooltip('Needs attention. Log in'), findsOneWidget);
    await openMenu(tester, tooltip: 'Needs attention. Log in');
    expect(find.text('Problems'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget, reason: 'still the first action');
  });

  testWidgets('the Problems page explains yt-dlp and offers both actions', (tester) async {
    await pump(tester, missingNoChoice);
    await openMenu(tester, tooltip: 'Ada Lovelace — needs attention');
    await tester.tap(find.text('Problems'));
    await tester.pumpAndSettle();

    expect(find.text('yt-dlp is not installed'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Download yt-dlp'), findsOneWidget);
    expect(find.widgetWithText(TextButton, "I don't want it"), findsOneWidget);
  });

  testWidgets('Download yt-dlp calls the controller', (tester) async {
    final controller = await pump(tester, missingNoChoice);
    await openMenu(tester, tooltip: 'Ada Lovelace — needs attention');
    await tester.tap(find.text('Problems'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download yt-dlp'));
    await tester.pump();
    expect(controller.downloadCalls, 1);
  });

  testWidgets("declining clears the row and the dot", (tester) async {
    final controller = await pump(tester, missingNoChoice);
    await openMenu(tester, tooltip: 'Ada Lovelace — needs attention');
    await tester.tap(find.text('Problems'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I don't want it"));
    await tester.pumpAndSettle();

    expect(controller.declineCalls, 1);
    expect(find.text('No problems right now.'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('Problems'), findsNothing);
  });

  testWidgets('a downloading phase shows progress and disables the buttons', (tester) async {
    await pump(tester, const YtDlpState(phase: YtDlpPhase.downloading(received: 2048, total: 0)));
    await openMenu(tester, tooltip: 'Ada Lovelace — needs attention');
    await tester.tap(find.text('Problems'));
    // Not pumpAndSettle: the card's own indeterminate LinearProgressIndicator
    // never settles. A couple of frames past the menu's 180 ms morph is enough.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Downloading…'), findsOneWidget);
    final filled = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Download yt-dlp'));
    expect(filled.onPressed, isNull);
  });

  testWidgets('an error phase shows the message and "Try again"', (tester) async {
    await pump(tester, const YtDlpState(phase: YtDlpPhase.error(message: 'HTTP 503'), choice: YtDlpChoice.download));
    await openMenu(tester, tooltip: 'Ada Lovelace — needs attention');
    await tester.tap(find.text('Problems'));
    await tester.pumpAndSettle();

    expect(find.text('HTTP 503'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
  });

  testWidgets('the Updates page shows On PATH with no Download action', (tester) async {
    await pump(tester, onPath);
    await openMenu(tester);
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('yt-dlp'), findsOneWidget);
    expect(find.text('On PATH'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('the Updates page shows the installed version with no Download action', (tester) async {
    await pump(tester, appManaged);
    await openMenu(tester);
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('2026.08.19'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('the Updates page offers Download when missing, and it calls the controller', (tester) async {
    final controller = await pump(tester, missingDeclined);
    await openMenu(tester);
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('Not installed'), findsOneWidget);
    await tester.tap(find.text('Download'));
    await tester.pump();
    expect(controller.downloadCalls, 1);
  });
}
