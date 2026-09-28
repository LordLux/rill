/// The yt-dlp surfaces — docs/todo.md 49. What a person sees: the avatar dot,
/// the always-present yt-dlp row and its page, and the Updates page's info
/// row. The controller's behaviour is asserted in `ytdlp_controller_test.dart`;
/// nothing here touches the network or the real filesystem.
///
/// Severity (`YtDlpRowSeverity`) was revised 2026-09-28 after live testing:
/// the row is now always shown while yt-dlp is missing, in a calm colour —
/// only an actual failed download turns it red and raises the avatar's dot.
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
  testWidgets('resolved (onPath): no row, no dot, in either root page', (tester) async {
    await pump(tester, onPath);
    expect(find.byKey(const ValueKey('update-dot')), findsNothing);
    await openMenu(tester);
    expect(find.text('yt-dlp not installed'), findsNothing);
  });

  testWidgets('missing and undecided: the row shows, calmly, with no attention dot', (tester) async {
    await pump(tester, missingNoChoice);
    expect(find.byKey(const ValueKey('update-dot')), findsNothing, reason: 'that key is the update dot, not this one');
    expect(find.byTooltip('Ada Lovelace'), findsOneWidget, reason: 'an ordinary absence does not need attention');
    await openMenu(tester);
    expect(find.text('yt-dlp not installed'), findsOneWidget);
  });

  testWidgets('declined: the row still shows (a way back), still no attention dot', (tester) async {
    await pump(tester, missingDeclined);
    expect(find.byTooltip('Ada Lovelace'), findsOneWidget);
    await openMenu(tester);
    expect(find.text('yt-dlp not installed'), findsOneWidget);
  });

  testWidgets('a failed download puts the dot on the avatar and turns the row red', (tester) async {
    await pump(tester, const YtDlpState(phase: YtDlpPhase.error(message: 'HTTP 503'), choice: YtDlpChoice.download));
    expect(find.byTooltip('Ada Lovelace — needs attention'), findsOneWidget);
    await openMenu(tester, tooltip: 'Ada Lovelace — needs attention');
    expect(find.text('yt-dlp download failed'), findsOneWidget);
  });

  testWidgets('signed out, missing and undecided: the row is in the signed-out root page too', (tester) async {
    await pump(tester, missingNoChoice, auth: const AuthState(status: AuthStatus.anonymous));
    expect(find.byTooltip('Log in'), findsOneWidget, reason: 'no dot-worthy problem, so the plain tooltip');
    await openMenu(tester, tooltip: 'Log in');
    expect(find.text('yt-dlp not installed'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget, reason: 'still the first action');
  });

  testWidgets('the yt-dlp page explains it and offers both actions when undecided', (tester) async {
    await pump(tester, missingNoChoice);
    await openMenu(tester);
    await tester.tap(find.text('yt-dlp not installed'));
    await tester.pumpAndSettle();

    expect(find.text('yt-dlp is not installed'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Download yt-dlp'), findsOneWidget);
    expect(find.widgetWithText(TextButton, "I don't want it"), findsOneWidget);
  });

  testWidgets('already declined: no "I don\'t want it" button, only Download', (tester) async {
    await pump(tester, missingDeclined);
    await openMenu(tester);
    await tester.tap(find.text('yt-dlp not installed'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Download yt-dlp'), findsOneWidget);
    expect(find.widgetWithText(TextButton, "I don't want it"), findsNothing);
  });

  testWidgets('Download yt-dlp calls the controller', (tester) async {
    final controller = await pump(tester, missingNoChoice);
    await openMenu(tester);
    await tester.tap(find.text('yt-dlp not installed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download yt-dlp'));
    await tester.pump();
    expect(controller.downloadCalls, 1);
  });

  testWidgets("declining keeps the row (now without the dot) rather than clearing it", (tester) async {
    final controller = await pump(tester, missingNoChoice);
    await openMenu(tester);
    await tester.tap(find.text('yt-dlp not installed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I don't want it"));
    await tester.pumpAndSettle();

    expect(controller.declineCalls, 1);
    // FixedYtDlp.decline() only sets choice; severity stays info (still
    // missing), so the same card is still here — the row was never hidden.
    expect(find.text('yt-dlp is not installed'), findsOneWidget);
  });

  testWidgets('a downloading phase shows progress and disables the buttons', (tester) async {
    await pump(tester, const YtDlpState(phase: YtDlpPhase.downloading(received: 2048, total: 0)));
    // Not openMenu/pumpAndSettle anywhere here: the row's own spinner is
    // already an indeterminate CircularProgressIndicator, so pumpAndSettle
    // never settles even just to open the root menu.
    await tester.tap(find.byTooltip('Ada Lovelace'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Downloading yt-dlp…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Downloading…'), findsOneWidget);
    final filled = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Download yt-dlp'));
    expect(filled.onPressed, isNull);
  });

  testWidgets('an error phase shows the message and "Try again"', (tester) async {
    await pump(tester, const YtDlpState(phase: YtDlpPhase.error(message: 'HTTP 503'), choice: YtDlpChoice.download));
    await openMenu(tester, tooltip: 'Ada Lovelace — needs attention');
    await tester.tap(find.text('yt-dlp download failed'));
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
