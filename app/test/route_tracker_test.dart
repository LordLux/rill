/// What the navigator observer reports, and what it deliberately ignores.
///
/// Two bugs lived here, and both were one mistake: the tracker reported *every*
/// route, popups included, and a `PopupRoute` carries no `settings.name`. So
/// opening the account menu or the share dialog set the current route to
/// `null`, which
///
///   - popped the mini-player up over the watch page (`null != 'watch'`), and
///   - lit the rail's Home item (`null` was mistaken for the home route).
///
/// The second had a twin: the home route's name is `'/'`, not `null`, so Home
/// was lit *only* while a popup covered it and never otherwise.
///
/// **Everything here drives a real `Navigator`.** The rule under test is
/// `route is PageRoute`, and the whole point is that Flutter's own dialogs and
/// menus fall on the other side of it — asserting that against hand-built
/// routes would be asserting it about my own stand-in. Pushing the real thing
/// means a change in Flutter's hierarchy fails here instead of regressing the
/// app quietly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/player_shell.dart';

late ProviderContainer container;
final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

NavigatorState get nav => navKey.currentState!;

/// Every page carries the two triggers, so a test can open a dialog or the menu
/// from whichever page is on top — the watch page is where both bugs showed.
Widget _pageBody(String name) => Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            Text('page $name'),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(content: Text('share dialog')),
              ),
              child: const Text('open dialog'),
            ),
            PopupMenuButton<int>(
              itemBuilder: (_) =>
                  const [PopupMenuItem<int>(value: 1, child: Text('Sign out'))],
              child: const Text('avatar'),
            ),
          ],
        ),
      ),
    );

MaterialPageRoute<void> page(String name) => MaterialPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => _pageBody(name),
    );

/// A `showLoginFlow`-shaped route: `fullscreenDialog: true`, no name — the
/// shape that reintroduced the mini-player bug (`player_shell.dart`,
/// `LoginPage`'s own `showLoginFlow`).
MaterialPageRoute<void> fullscreenDialogPage() => MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _pageBody('fullscreen dialog'),
    );

/// Pumps the app the tests navigate inside: a home page, and the real tracker
/// attached as a navigator observer.
Future<void> pumpApp(WidgetTester tester) async {
  container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [container.read(routeTrackerProvider)],
        home: _pageBody(homeRouteName),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String? get current => container.read(currentRouteProvider);
String? get section => container.read(sectionRouteProvider);
bool get transient => container.read(transientRouteOpenProvider);

void main() {
  // The depth counter is pure logic, so it is tested as such — no navigator, no
  // frames. Driving the observer by hand to reach these shapes leaves deferred
  // post-frame callbacks pending, which then fire into the *next* test's
  // disposed container; the failure lands on a test that has nothing to do with
  // it, which is exactly the sort of flake that takes an afternoon.
  //
  // How the observer reaches this notifier at all is covered by the
  // real-navigator groups below.
  group('TransientRouteOpen', () {
    late ProviderContainer c;

    setUp(() => c = ProviderContainer());
    tearDown(() => c.dispose());

    // Local *getters* are not a thing in Dart function bodies — `bool get open`
    // inside a `group` parses as a function declaration — so these are calls.
    bool open() => c.read(transientRouteOpenProvider);
    TransientRouteOpen notifier() => c.read(transientRouteOpenProvider.notifier);

    test('starts closed', () => expect(open(), isFalse));

    test('one open, one close', () {
      notifier().push();
      expect(open(), isTrue);
      notifier().pop();
      expect(open(), isFalse);
    });

    test('nesting keeps it set until the last one closes', () {
      notifier().push();
      notifier().push();
      notifier().pop();
      expect(open(), isTrue, reason: 'the outer one is still open');
      notifier().pop();
      expect(open(), isFalse);
    });

    test('a doubled close cannot latch it false', () {
      // `didPop` and `didRemove` can both fire for one route in some teardown
      // orders. Unclamped the depth would reach -1 and the *next* popup would
      // open with the flag still reading false — a dialog the mini-player
      // logic could then pop out from under the user.
      notifier().push();
      notifier().pop();
      notifier().pop();
      expect(open(), isFalse);

      notifier().push();
      expect(open(), isTrue, reason: 'the counter recovered rather than going negative');
    });

    test('a close with no matching open is survivable', () {
      notifier().pop();
      expect(open(), isFalse);
      notifier().push();
      expect(open(), isTrue);
    });
  });

  group('page routes', () {
    testWidgets('the home route is reported as "/" — it is not nameless',
        (tester) async {
      // The belief that it was `null` is what kept Home unlit in the rail.
      // Confirmed against the running app on 2026-09-09 as well.
      await pumpApp(tester);
      expect(current, '/');
      expect(homeRouteName, '/');
    });

    testWidgets('a pushed page is reported by name', (tester) async {
      await pumpApp(tester);
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();
      expect(current, watchRouteName);
    });

    testWidgets('popping reports what is underneath', (tester) async {
      await pumpApp(tester);
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();
      nav.pop();
      await tester.pumpAndSettle();
      expect(current, homeRouteName);
    });
  });

  group('a real dialog is invisible to the current route', () {
    testWidgets('opening one changes nothing', (tester) async {
      await pumpApp(tester);
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();

      await tester.tap(find.text('open dialog'));
      await tester.pumpAndSettle();

      expect(find.text('share dialog'), findsOneWidget);
      // The mini-player bug, exactly: this used to become `null`, and the shell
      // read that as having left the watch page.
      expect(current, watchRouteName);
      expect(transient, isTrue);
    });

    testWidgets('closing one changes nothing either', (tester) async {
      await pumpApp(tester);
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open dialog'));
      await tester.pumpAndSettle();

      nav.pop();
      await tester.pumpAndSettle();

      expect(find.text('share dialog'), findsNothing);
      expect(current, watchRouteName, reason: 'the watch page is still the page');
      expect(transient, isFalse);
    });

    testWidgets('a dialog over Home leaves Home current', (tester) async {
      // The rail bug's other half: Home used to light up only *because* a popup
      // had blanked the route out from under it.
      await pumpApp(tester);
      await tester.tap(find.text('open dialog'));
      await tester.pumpAndSettle();
      expect(current, homeRouteName);
    });
  });

  group('a fullscreen dialog page route is invisible too — this is showLoginFlow', () {
    testWidgets('opening one changes nothing', (tester) async {
      // The same bug in a different shape: `fullscreenDialog: true` is a
      // `PageRoute`, not a `PopupRoute`, and `LoginPage` carries no
      // `settings.name` — so before this was filtered, pushing it reported
      // `null`, and `PlayerShell` read that as having left the watch page
      // exactly the way an unfiltered dialog once did.
      await pumpApp(tester);
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();

      nav.push(fullscreenDialogPage());
      await tester.pumpAndSettle();

      expect(find.text('page fullscreen dialog'), findsOneWidget);
      expect(current, watchRouteName);
      expect(transient, isTrue);
    });

    testWidgets('closing one changes nothing either', (tester) async {
      await pumpApp(tester);
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();
      nav.push(fullscreenDialogPage());
      await tester.pumpAndSettle();

      nav.pop();
      await tester.pumpAndSettle();

      expect(find.text('page fullscreen dialog'), findsNothing);
      expect(current, watchRouteName, reason: 'the watch page is still the page');
      expect(transient, isFalse);
    });

    testWidgets('a fullscreen dialog over Home leaves Home current', (tester) async {
      await pumpApp(tester);
      nav.push(fullscreenDialogPage());
      await tester.pumpAndSettle();
      expect(current, homeRouteName);
    });
  });

  group('a real PopupMenuButton', () {
    testWidgets('is invisible too — this is the account menu', (tester) async {
      await pumpApp(tester);
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();

      await tester.tap(find.text('avatar'));
      await tester.pumpAndSettle();

      expect(find.text('Sign out'), findsOneWidget);
      expect(current, watchRouteName);
      expect(transient, isTrue);
    });

    testWidgets('and the flag clears when it closes', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('avatar'));
      await tester.pumpAndSettle();
      expect(transient, isTrue);

      // Dismiss by tapping the barrier.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(transient, isFalse);
    });
  });

  group('the section', () {
    testWidgets('follows ordinary pages', (tester) async {
      await pumpApp(tester);
      expect(section, homeRouteName);
      nav.push(page('subscriptions'));
      await tester.pumpAndSettle();
      expect(section, 'subscriptions');
    });

    testWidgets('a watch page opened from Home keeps Home as the section',
        (tester) async {
      await pumpApp(tester);
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();

      expect(current, watchRouteName);
      expect(section, homeRouteName,
          reason: 'opening a video does not leave the section it came from');
    });

    testWidgets('a watch page opened from subscriptions keeps subscriptions',
        (tester) async {
      await pumpApp(tester);
      nav.push(page('subscriptions'));
      await tester.pumpAndSettle();
      nav.push(page(watchRouteName));
      await tester.pumpAndSettle();

      expect(section, 'subscriptions');
    });

    testWidgets('a dialog does not change it', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('open dialog'));
      await tester.pumpAndSettle();
      expect(section, homeRouteName);
    });
  });
}
