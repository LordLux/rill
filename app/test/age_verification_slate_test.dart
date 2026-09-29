/// The age-verification slate — `AGE_VERIFICATION_REQUIRED`, `docs/todo.md` 54.
///
/// Reported 2026-09-28: an age-restricted video refused with `LOGIN_REQUIRED`
/// — "Sign in to confirm your age" — through the same "This video would not
/// open" / *Try again* screen as an unclassified failure, whether or not the
/// app was signed in, because the resolve ladder never distinguished this
/// case at all. This file covers the two-copy fix: `AGE_VERIFICATION_REQUIRED`
/// gets its own slate, and its wording and action depend on `AuthState.isSignedIn`
/// — a "Sign in" button when signed out, a plain explanation with no retry
/// when already signed in (`tierYtDlp` already tried with the account's real
/// cookie and YouTube still refused, `architecture.md` A12).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/player/player_slates.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';

import 'fake_engine.dart';

/// Matches `AGE_VERIFICATION_ID` in `fake_sidecar.ts`.
const String ageVerificationId = 'ageverify1';

class _FixedAuth extends AuthController {
  _FixedAuth(this.initial);
  final AuthState initial;
  @override
  AuthState build() => initial;
}

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Some Channel',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late ProviderContainer container;
bool _containerDisposed = false;

/// See `premiere_test.dart` — a container disposed in `tearDown` is disposed
/// after Flutter's pending-timer check, and the failure names a timer rather
/// than the test.
void disposeContainer() {
  if (_containerDisposed) return;
  _containerDisposed = true;
  container.dispose();
}

class TestApp extends ConsumerWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => PlayerShell(child: child ?? const SizedBox.shrink()),
      home: const Scaffold(body: SizedBox.shrink()),
    );
  }
}

Future<void> settleReal(WidgetTester tester, [int millis = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: millis)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() => RpcClient.instance.killForTestAndWait());

  setUp(() async {
    await RpcClient.instance.call('test.reset', {});
    engine = FakeEngine();
    _containerDisposed = false;
  });

  tearDown(disposeContainer);

  Future<void> openWith(WidgetTester tester, VideoItem item, AuthState auth) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
        authProvider.overrideWith(() => _FixedAuth(auth)),
      ],
    );
    container.read(playbackProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();
    openWatchIn(container, item);
    await tester.pump();
    await settleReal(tester);
  }

  testWidgets('signed out: the slate offers Sign in, not Try again', (tester) async {
    await openWith(
      tester,
      video(ageVerificationId),
      const AuthState(status: AuthStatus.anonymous),
    );

    final playback = container.read(playbackProvider);
    expect(playback.isAgeVerificationRequired, isTrue);

    expect(find.byKey(ageVerificationSlateKey), findsOneWidget);
    expect(find.text('This video would not open.'), findsNothing);
    expect(find.text('Try again'), findsNothing);

    expect(find.byKey(ageVerificationSignInKey), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(ageVerificationSignInKey)).onPressed,
      isNotNull,
      reason: 'unlike the members-only "Join" button, this one is a real, working action',
    );

    disposeContainer();
  });

  testWidgets('signed in: an explanation, and no button at all', (tester) async {
    await openWith(
      tester,
      video(ageVerificationId),
      const AuthState(status: AuthStatus.authenticated, accountName: 'Ada'),
    );

    final playback = container.read(playbackProvider);
    expect(playback.isAgeVerificationRequired, isTrue);

    expect(find.byKey(ageVerificationSlateKey), findsOneWidget);
    expect(find.text('This video would not open.'), findsNothing);
    // The whole point: this app already tried with the real account cookie
    // (tier 4), and it still failed — a *Try again* here would be the exact
    // bug `docs/todo.md` 54 reported, dressed in a new error code.
    expect(find.text('Try again'), findsNothing);
    expect(find.byKey(ageVerificationSignInKey), findsNothing);

    disposeContainer();
  });

  testWidgets('a members-only video still gets its own slate, not this one', (tester) async {
    // The two terminal-ish codes sit in the same `if` chain; this guards
    // against one swallowing the other.
    await openWith(
      tester,
      video('members1'),
      const AuthState(status: AuthStatus.authenticated),
    );

    expect(find.byKey(membersOnlySlateKey), findsOneWidget);
    expect(find.byKey(ageVerificationSlateKey), findsNothing);

    disposeContainer();
  });

  testWidgets('an ordinary failure still gets the generic failure screen', (tester) async {
    await openWith(
      tester,
      video('broken1'),
      const AuthState(status: AuthStatus.authenticated),
    );

    expect(find.byKey(ageVerificationSlateKey), findsNothing);
    expect(find.text('This video would not open.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    disposeContainer();
  });
}
