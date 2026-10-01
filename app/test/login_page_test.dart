/// The login page (Task 31 §1, §5): its bounded retry of a `degraded` answer,
/// and the window controls it carries because it covers the top bar.
///
/// `flutter test` cannot host a WebView2 platform view, so the page is given a
/// stand-in through `webViewBuilder`; everything else — the poll, the jar read,
/// the retries, the cover and the message — is the real page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/auth/web_session_cookies.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/pages/login_page.dart';
import 'package:rill/ui/widgets/window_controls.dart';

const String emptyFeedMessage = 'YouTube returned an empty feed for this session.';

/// Answers `signIn` from a script and records the header it was handed. Nothing
/// else about [AuthController] is exercised here.
class ScriptedAuth extends AuthController {
  ScriptedAuth(this.script);

  final List<AuthStatus> script;
  final List<String> cookies = [];

  @override
  AuthState build() => const AuthState(status: AuthStatus.anonymous);

  @override
  Future<AuthStatus> signIn(String cookie) async {
    cookies.add(cookie);
    final status = script.length > 1 ? script.removeAt(0) : script.first;
    state = AuthState(status: status);
    return status;
  }
}

/// A jar that serves each scripted read in turn, then repeats the last.
class ScriptedJar implements WebSessionCookies {
  ScriptedJar(this.reads);

  final List<Map<String, String>> reads;
  int count = 0;

  @override
  Future<Map<String, String>> read() async {
    final index = count++;
    return reads[index < reads.length ? index : reads.length - 1];
  }

  @override
  Future<void> clear() async {}
}

const Map<String, String> completeJar = {'SAPISID': 'a', 'SID': 'b'};

/// Marks where the window controls are, so a test can ask for them.
class FakeWindowControls implements WindowControls {
  static const dragKey = ValueKey('fake-drag-region');
  static const buttonsKey = ValueKey('fake-window-buttons');

  @override
  Widget dragRegion() => const SizedBox.expand(key: dragKey);

  @override
  Widget buttons(ThemeData theme) => const SizedBox(key: buttonsKey, width: 138, height: 32);
}

/// Opens the page the way `showLoginFlow` does and records what it popped with.
class Opened {
  Object? result = 'not popped';
  bool get popped => result != 'not popped';
}

Future<Opened> openLogin(WidgetTester tester, ScriptedAuth auth, ScriptedJar jar) async {
  final opened = Opened();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        webSessionCookiesProvider.overrideWithValue(jar),
        windowControlsProvider.overrideWithValue(FakeWindowControls()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              opened.result = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  fullscreenDialog: true,
                  builder: (_) => LoginPage(webViewBuilder: (_, _) => const SizedBox.expand()),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return opened;
}

/// Lets the poll tick and the retries' waits elapse.
Future<void> elapse(WidgetTester tester, Duration total) async {
  for (var left = total; left > Duration.zero; left -= const Duration(milliseconds: 100)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('a degraded answer is retried before the message is shown (§1)', () {
    testWidgets('degraded, then authenticated: the page closes with true and never shows the message',
        (tester) async {
      // Mutation: with the retry loop removed the first `degraded` ends the flow
      // and this fails — the page stays open on the message.
      final auth = ScriptedAuth([AuthStatus.degraded, AuthStatus.authenticated]);
      final opened = await openLogin(tester, auth, ScriptedJar([completeJar]));

      var sawMessage = false;
      for (var i = 0; i < 100 && !opened.popped; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        sawMessage |= find.textContaining(emptyFeedMessage).evaluate().isNotEmpty;
      }
      await tester.pumpAndSettle();

      expect(opened.result, isTrue);
      expect(sawMessage, isFalse);
      expect(auth.cookies, hasLength(2), reason: 'every attempt is a real setCookie, never an assumption');
    });

    testWidgets('the user sees "Checking with YouTube…" throughout, not the failure', (tester) async {
      final auth = ScriptedAuth([AuthStatus.degraded, AuthStatus.authenticated]);
      await openLogin(tester, auth, ScriptedJar([completeJar]));

      await elapse(tester, const Duration(milliseconds: 2400)); // the poll, then into the wait
      expect(auth.cookies, hasLength(1));
      expect(find.text('Checking with YouTube…'), findsWidgets);
      expect(find.textContaining(emptyFeedMessage), findsNothing);
      expect(find.text('Try again'), findsNothing);

      await elapse(tester, const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('degraded three times: the message appears, after exactly three attempts', (tester) async {
      final auth = ScriptedAuth([AuthStatus.degraded]);
      final opened = await openLogin(tester, auth, ScriptedJar([completeJar]));

      await elapse(tester, const Duration(seconds: 12));

      expect(auth.cookies, hasLength(3), reason: 'one attempt and at most two extra — retrying forever is the bug');
      expect(opened.popped, isFalse);
      expect(find.textContaining(emptyFeedMessage), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('each attempt reads the jar afresh and sends what it holds now', (tester) async {
      final auth = ScriptedAuth([AuthStatus.degraded, AuthStatus.authenticated]);
      final jar = ScriptedJar([
        completeJar,
        {...completeJar, 'LOGIN_INFO': 'c'},
      ]);
      final opened = await openLogin(tester, auth, jar);

      for (var i = 0; i < 100 && !opened.popped; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();

      expect(auth.cookies.first, isNot(contains('LOGIN_INFO')));
      expect(auth.cookies.last, contains('LOGIN_INFO=c'));
    });

    testWidgets('a jar that is not complete never reaches signIn', (tester) async {
      final auth = ScriptedAuth([AuthStatus.authenticated]);
      await openLogin(tester, auth, ScriptedJar([{'SID': 'b'}]));

      await elapse(tester, const Duration(seconds: 6));

      expect(auth.cookies, isEmpty, reason: 'cookie presence is a precondition, not the answer');
    });
  });

  group('the login page carries the window controls (§5)', () {
    void expectControls() {
      expect(find.byKey(FakeWindowControls.buttonsKey), findsOneWidget);
      expect(find.byKey(FakeWindowControls.dragKey), findsOneWidget);
    }

    testWidgets('while waiting for the sign-in', (tester) async {
      await openLogin(tester, ScriptedAuth([AuthStatus.authenticated]), ScriptedJar([<String, String>{}]));

      expectControls();
    });

    testWidgets('and in the error state', (tester) async {
      // Mutation: build the bar without `windowControlsProvider` and both fail.
      final auth = ScriptedAuth([AuthStatus.degraded]);
      await openLogin(tester, auth, ScriptedJar([completeJar]));
      await elapse(tester, const Duration(seconds: 12));
      expect(find.textContaining(emptyFeedMessage), findsOneWidget);

      expectControls();
    });

    testWidgets('Cancel is still there and closes with false', (tester) async {
      final auth = ScriptedAuth([AuthStatus.authenticated]);
      final opened = await openLogin(tester, auth, ScriptedJar([<String, String>{}]));

      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect(opened.result, isFalse);
    });
  });
}
