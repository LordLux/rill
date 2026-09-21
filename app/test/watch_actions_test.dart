/// Like/dislike and Watch Later end to end (Task 25) — `_Actions` in
/// `lib/ui/pages/watch.dart`, driven through a fake sidecar exactly like
/// `members_slate_test.dart` drives the members slate.
///
/// What this proves: the pills seed from real state (`video.info`'s
/// `myRating`, `playlist.forVideo`'s Watch Later row), a tap is optimistic,
/// and a refused call reverts the icon rather than leaving it stuck on the
/// guess. The mutation-relevant cases (a widget that always shows "liked", a
/// pill that never reverts) are called out per test — a hardcoded answer
/// would pass the happy-path assertion and fail only the one built to catch it.
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

/// Matches `ACTION_FAIL_ID` in `fake_sidecar.ts`.
const String actionFailId = 'actionfail1';

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
bool _containerDisposed = false;

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

/// The auth state the harness builds with. Authenticated unless a test says
/// otherwise, because that is what nearly every case here is about.
AuthStatus _authStatus = AuthStatus.authenticated;

class _SignedIn extends AuthController {
  @override
  AuthState build() => AuthState(status: _authStatus, accountHandle: '@tester');
}

void main() {
  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() => RpcClient.instance.killForTestAndWait());

  setUp(() async {
    _authStatus = AuthStatus.authenticated;
    await RpcClient.instance.call('test.reset', {});
    engine = FakeEngine();
    _containerDisposed = false;
    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
        // Rating and Watch Later need an account: they are disabled, with a
        // tooltip saying why, for a signed-out *or degraded* viewer. Before
        // that gate these were pressable signed out — the call came back
        // AUTH_REQUIRED and the optimistic state reverted under a toast — so
        // this harness never had to say who was watching.
        authProvider.overrideWith(_SignedIn.new),
      ],
    );
    container.read(playbackProvider);
  });

  tearDown(disposeContainer);

  Future<void> open(WidgetTester tester, String id) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();
    openWatchIn(container, video(id));
    await tester.pump();
    await settleReal(tester);
  }

  group('an account is required, and the control says which kind of "no"', () {
    // These were pressable signed out until 2026-09-21: the optimistic rating
    // applied, `action.like` came back AUTH_REQUIRED, and it reverted under a
    // toast — a control that looks available, acts, then undoes itself. The
    // tooltip is the only place a disabled control can explain itself, so the
    // two blocked states get different sentences: a degraded session looks
    // signed in everywhere else (hard invariant 5).
    Future<List<String>> tooltipsAfterOpen(WidgetTester tester, AuthStatus status) async {
      _authStatus = status;
      await open(tester, 'vid-1');
      return tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((t) => t.message)
          .whereType<String>()
          .toList();
    }

    testWidgets('signed out, rating and Watch Later say to sign in', (tester) async {
      final tips = await tooltipsAfterOpen(tester, AuthStatus.anonymous);

      expect(tips, contains('Sign in to rate videos'));
      expect(tips, contains('Sign in to save videos'));
      expect(tips.where((t) => t == 'Like' || t == 'Dislike'), isEmpty,
          reason: 'the ordinary labels are replaced, not shown alongside');

      disposeContainer();
    });

    testWidgets('degraded, they say the session expired instead', (tester) async {
      final tips = await tooltipsAfterOpen(tester, AuthStatus.degraded);

      expect(tips, contains('Your session expired. Sign in again to rate videos'));
      expect(tips, contains('Your session expired. Sign in again to save videos'));

      disposeContainer();
    });

    testWidgets('signed in, the ordinary labels are back and nothing is blocked', (tester) async {
      final tips = await tooltipsAfterOpen(tester, AuthStatus.authenticated);

      expect(tips, contains('Like'));
      expect(tips.where((t) => t.contains('Sign in')), isEmpty);

      disposeContainer();
    });
  });


  group('like / dislike', () {
    testWidgets('liking a video fills the thumbs-up icon', (tester) async {
      await open(tester, 'vid_like_1');

      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      await settleReal(tester);

      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);

      disposeContainer();
    });

    testWidgets('liking an already-liked video removes the rating', (tester) async {
      await open(tester, 'vid_like_2');

      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      await settleReal(tester);
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);

      await tester.tap(find.byIcon(Icons.thumb_up));
      await settleReal(tester);
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsNothing);

      disposeContainer();
    });

    testWidgets('disliking while liked switches straight to disliked', (tester) async {
      await open(tester, 'vid_like_3');

      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      await settleReal(tester);
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);

      await tester.tap(find.byIcon(Icons.thumb_down_outlined));
      await settleReal(tester);
      expect(find.byIcon(Icons.thumb_down), findsOneWidget);
      expect(
        find.byIcon(Icons.thumb_up),
        findsNothing,
        reason: 'liking and disliking are mutually exclusive server-side',
      );

      disposeContainer();
    });

    testWidgets('the tooltip label flips with the rating, not just the icon', (tester) async {
      await open(tester, 'vid_like_tooltip');

      expect(tester.widget<Tooltip>(
        find.ancestor(of: find.byIcon(Icons.thumb_up_outlined), matching: find.byType(Tooltip)).first,
      ).message, 'Like');

      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      await settleReal(tester);

      expect(tester.widget<Tooltip>(
        find.ancestor(of: find.byIcon(Icons.thumb_up), matching: find.byType(Tooltip)).first,
      ).message, 'Remove like');

      disposeContainer();
    });

    testWidgets('a rating call that fails reverts the icon and says so', (tester) async {
      // Mutation guard: a button that always shows "liked" after a tap would
      // also pass every test above — this is the one that only passes if the
      // revert genuinely happens.
      await open(tester, actionFailId);

      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      await settleReal(tester);

      expect(
        find.byIcon(Icons.thumb_up_outlined),
        findsOneWidget,
        reason: 'the failed like must revert, not stick',
      );
      expect(find.byIcon(Icons.thumb_up), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);

      disposeContainer();
    });
  });

  group('upload date tooltip', () {
    testWidgets('the exact date shows as a tooltip on the relative one', (tester) async {
      // Matches fake_sidecar.ts's `video.info`: publishedText '16 years ago',
      // publishedDateText 'Dec 6, 2009' — deliberately different strings, so
      // a tooltip that just echoed the relative text back would still fail
      // this.
      await open(tester, 'vid_date_1');

      expect(find.text('16 years ago'), findsOneWidget);
      final tooltip = find.ancestor(
        of: find.text('16 years ago'),
        matching: find.byType(Tooltip),
      );
      expect(tooltip, findsOneWidget);
      expect(tester.widget<Tooltip>(tooltip).message, 'Dec 6, 2009');

      disposeContainer();
    });
  });

  group('Watch Later', () {
    testWidgets('starts unsaved, saves, and removes both ways', (tester) async {
      await open(tester, 'vid_wl_1');

      expect(find.byIcon(Icons.schedule), findsOneWidget);
      await tester.tap(find.byIcon(Icons.schedule));
      await settleReal(tester);

      expect(
        find.byIcon(Icons.check),
        findsOneWidget,
        reason: 'saved — the pill shows its active tick',
      );

      await tester.tap(find.byIcon(Icons.check));
      await settleReal(tester);

      expect(
        find.byIcon(Icons.schedule),
        findsOneWidget,
        reason: 'removed — the pill goes back to its resting icon, not stuck latched '
            '("removing is not wired up yet")',
      );
      expect(find.byIcon(Icons.check), findsNothing);

      disposeContainer();
    });

    testWidgets('a save that fails reverts the pill rather than leaving it latched', (tester) async {
      // Mutation guard: a pill that always shows "saved" after a tap passes the
      // happy path above and only fails here.
      await open(tester, actionFailId);

      await tester.tap(find.byIcon(Icons.schedule));
      await settleReal(tester);

      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);

      disposeContainer();
    });
  });
}
