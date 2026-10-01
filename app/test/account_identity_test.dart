/// The watch page follows the account (Task 31 §2, §4).
///
/// Whatever the page shows that belongs to the *account* — subscribed, the
/// rating, a saved state — reads as none the moment there is no account, and is
/// fetched again when the account changes. The fake sidecar answers `video.info`
/// by who is asking (`SUBSCRIBED_ID`, `LIKED_ID`), as the real one does, so a
/// re-fetch is observable rather than assumed.
///
/// The auth override here is parked and moved with `adoptVerifiedState`, which
/// changes the app's idea of who is signed in *without* a round trip. That is
/// the point of the immediate-mask tests: a state that was only correct after
/// the re-fetch landed would pass them for the wrong reason, so the sidecar is
/// left answering as the signed-in account while the UI is asked to be signed out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';

import 'fake_engine.dart';

/// Matches `SUBSCRIBED_ID` / `LIKED_ID` in `fake_sidecar.ts`.
const String subscribedId = 'subbed1';
const String likedId = 'likedacct1';

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Fake Channel',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late ProviderContainer container;
bool _disposed = true;
AuthStatus startStatus = AuthStatus.authenticated;

class ParkedAuth extends AuthController {
  @override
  AuthState build() => AuthState(
        status: startStatus,
        accountHandle: startStatus == AuthStatus.authenticated ? '@tester' : null,
      );
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

AuthController get auth => container.read(authProvider.notifier);

/// Ends a test the way `watch_actions_test.dart` does: the playback controller's
/// stall watchdog is a timer, and one still pending when the tree goes fails the
/// test before any `tearDown` runs.
void disposeContainer() {
  if (_disposed) return;
  _disposed = true;
  container.dispose();
}

/// A real subprocess answers over real pipes, which the fake clock a
/// `testWidgets` body runs under never turns — so a bare `await` on the RPC
/// client hangs the test forever, with no output.
Future<T> real<T>(WidgetTester tester, Future<T> Function() call) async => (await tester.runAsync(call)) as T;

Future<List<String>> infoCalls(WidgetTester tester) => real(tester, () async {
      final log = await RpcClient.instance.call('test.infoLog', {}) as Map<String, dynamic>;
      return (log['calls'] as List<dynamic>).cast<String>();
    });

Future<int> playbackOpens(WidgetTester tester) => real(tester, () async {
      final log = await RpcClient.instance.call('test.playbackLog', {}) as Map<String, dynamic>;
      return (log['opens'] as List<dynamic>).length;
    });

void main() {
  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() => RpcClient.instance.killForTestAndWait());
  tearDown(disposeContainer);

  /// The app and the sidecar, both as [status], then the watch page on [id].
  Future<void> open(WidgetTester tester, String id, {AuthStatus status = AuthStatus.authenticated}) async {
    startStatus = status;
    await real(tester, () => RpcClient.instance.call('test.reset', {
          'authState': status == AuthStatus.authenticated ? 'authenticated' : 'anonymous',
        }));
    engine = FakeEngine();
    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
        authProvider.overrideWith(ParkedAuth.new),
      ],
    );
    _disposed = false;
    container.read(playbackProvider);

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const TestApp()));
    await tester.pumpAndSettle();
    openWatchIn(container, video(id));
    await tester.pump();
    await settleReal(tester);
  }

  /// Signed out in the app's eyes only; the sidecar is untouched.
  Future<void> signOutLocally(WidgetTester tester) async {
    auth.adoptVerifiedState('anonymous');
    await tester.pump();
  }

  Iterable<String> tooltips(WidgetTester tester) =>
      tester.widgetList<Tooltip>(find.byType(Tooltip)).map((t) => t.message).whereType<String>();

  group('sign-out: the open page stops showing the account (§2)', () {
    testWidgets('subscribed, then signed out: Subscribe, disabled, with the reason — at once', (tester) async {
      // Mutation: drop the `signedIn &&` mask in `_Meta` and this reads
      // "Subscribed" (the `/next` snapshot) until a re-fetch lands — and the
      // sidecar here would answer subscribed again anyway, so it never recovers.
      await open(tester, subscribedId);
      expect(find.text('Subscribed'), findsOneWidget);

      await signOutLocally(tester);

      expect(find.text('Subscribe'), findsOneWidget);
      expect(find.text('Subscribed'), findsNothing);
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Subscribe'));
      expect(button.onPressed, isNull);
      expect(tooltips(tester), contains('Sign in to subscribe'));
      final fill = button.style!.backgroundColor!.resolve({WidgetState.disabled})!;
      expect(fill.a, closeTo(0.38, 0.01), reason: 'visibly greyed, not merely inert');

      await settleReal(tester); // the re-fetch lands; the answer must not come back
      expect(find.text('Subscribe'), findsOneWidget);
      disposeContainer();
    });

    testWidgets('a liked video, then signed out: the rating shows as none, at once', (tester) async {
      await open(tester, likedId);
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);

      await signOutLocally(tester);

      expect(find.byIcon(Icons.thumb_up), findsNothing);
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      await settleReal(tester);
      expect(find.byIcon(Icons.thumb_up), findsNothing);
      disposeContainer();
    });

    testWidgets('degraded reads the same as signed out', (tester) async {
      await open(tester, subscribedId);

      auth.adoptVerifiedState('degraded');
      await tester.pump();

      expect(find.text('Subscribe'), findsOneWidget);
      expect(tooltips(tester), contains('Your session expired. Sign in again to subscribe'));
      disposeContainer();
    });

    testWidgets('the re-fetch keeps the page: same route, same scroll, playback not reopened', (tester) async {
      await open(tester, subscribedId);
      final opensBefore = await playbackOpens(tester);
      final pageBefore = tester.element(find.byType(Scaffold).last);
      final scrollBefore = tester.state<ScrollableState>(find.byType(Scrollable).first).position;

      await signOutLocally(tester);
      // The previous detail stays on screen while the new one loads.
      expect(find.text('Detail for $subscribedId'), findsOneWidget);
      await settleReal(tester);

      expect(find.text('Detail for $subscribedId'), findsOneWidget);
      expect(await playbackOpens(tester), opensBefore, reason: 'an identity change must not reopen the stream');
      expect(tester.element(find.byType(Scaffold).last), same(pageBefore));
      expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position, same(scrollBefore));
      disposeContainer();
    });
  });

  group('sign-in on an open page re-fetches it (§2)', () {
    testWidgets('Subscribe becomes Subscribed for a channel the account follows', (tester) async {
      // Mutation: remove `ref.watch(authIdentityProvider)` from `videoInfoProvider`
      // and the page keeps the anonymous answer — "Subscribe" for a followed
      // channel — and the second `video.info` never happens.
      await open(tester, subscribedId, status: AuthStatus.anonymous);
      expect(find.text('Subscribe'), findsOneWidget);
      expect(await infoCalls(tester), [subscribedId]);

      // The account arrives: the sidecar first (as `auth.setCookie` does), then the app.
      await real(tester, () => RpcClient.instance.call('auth.setCookie', {'cookie': 'SAPISID=x; SID=y'}));
      auth.adoptVerifiedState('authenticated');
      await tester.pump();
      await settleReal(tester);

      expect(find.text('Subscribed'), findsOneWidget);
      expect(await infoCalls(tester), [subscribedId, subscribedId]);
      disposeContainer();
    });

    testWidgets('an unchanged account does not re-fetch', (tester) async {
      await open(tester, subscribedId);

      auth.adoptVerifiedState('authenticated'); // same status: a no-op
      await tester.pump();
      await settleReal(tester);

      expect(await infoCalls(tester), [subscribedId]);
      disposeContainer();
    });
  });

  group('blocked actions look blocked (§4)', () {
    Color foreground(WidgetTester tester, IconData icon) => tester.widget<Icon>(find.byIcon(icon)).color!;

    bool tappable(WidgetTester tester, IconData icon) {
      final ink = tester.widget<InkWell>(find.ancestor(of: find.byIcon(icon), matching: find.byType(InkWell)).first);
      return ink.onTap != null;
    }

    const actions = <(String, IconData)>[
      ('like', Icons.thumb_up_outlined),
      ('dislike', Icons.thumb_down_outlined),
      ('save', Icons.playlist_add),
      ('Watch Later', Icons.schedule),
    ];

    for (final (name, icon) in actions) {
      testWidgets('signed out, $name is disabled and drawn at the disabled alpha', (tester) async {
        await open(tester, 'plain1', status: AuthStatus.anonymous);

        expect(tappable(tester, icon), isFalse);
        expect(foreground(tester, icon).a, closeTo(0.38, 0.01));
        disposeContainer();
      });

      testWidgets('signed in, $name is live and drawn at full colour', (tester) async {
        await open(tester, 'plain1');

        expect(tappable(tester, icon), isTrue);
        expect(foreground(tester, icon).a, closeTo(1.0, 0.01));
        disposeContainer();
      });
    }

    testWidgets('the like count is greyed with its thumb, not left at full colour', (tester) async {
      await open(tester, 'plain1', status: AuthStatus.anonymous);

      expect(tester.widget<Text>(find.text('1.1M')).style!.color!.a, closeTo(0.38, 0.01));
      disposeContainer();
    });
  });
}
