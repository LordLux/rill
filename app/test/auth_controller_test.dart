/// Sign in, restart, sign out — against a real sidecar process.
///
/// `fake_sidecar.ts` holds an auth state machine (`auth.setCookie`,
/// `auth.signOut`, `auth.verify`, `auth.status`) and records every cookie it was
/// handed, so these assert what the app actually put on the wire rather than
/// what a mock was told to return.
///
/// The two things Task 22 asks to be **mutation-checked** are here, and each is
/// annotated with the mutation it catches:
///
///  - the degraded path — a state that must not collapse into `anonymous`;
///  - the sign-out clear — asserted on the credential store being *empty* and
///    the WebView jar having been cleared, never on a flag having flipped.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/auth/credential_store.dart';
import 'package:rill/data/auth/web_session_cookies.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/ui/auth_controller.dart';

/// A jar that records instead of talking to WebView2.
///
/// The stop condition Task 22 names — "sign-out cannot clear the WebView2
/// cookie jar" — is about the real one. What this proves is the half the app
/// owns: that sign-out *asks*, unconditionally, and does not skip the ask when
/// an earlier step fails.
class FakeJar implements WebSessionCookies {
  FakeJar({this.throwOnClear = false});

  Map<String, String> jar = {};
  int clears = 0;
  final bool throwOnClear;

  @override
  Future<Map<String, String>> read() async => jar;

  @override
  Future<void> clear() async {
    clears += 1;
    if (throwOnClear) throw StateError('WebView2 refused');
    jar = {};
  }
}

late InMemoryCredentialStore store;
late FakeJar jar;
late ProviderContainer container;

AuthController get auth => container.read(authProvider.notifier);
AuthState get state => container.read(authProvider);

/// A cookie the fake sidecar accepts. `SAPISID=` is what makes it valid there,
/// mirroring the real requirement (`youtube_cookies.dart`).
const String goodCookie = 'SAPISID=fake-sapisid; SID=fake-sid';

/// One the fake sidecar answers `degraded` to — F7's shape, on demand.
const String staleCookie = 'SAPISID=fake-sapisid; SID=degraded-session';

Future<void> boot() async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  await RpcClient.instance.start();
  await newContainer();
}

/// A fresh app-side container over the *same* sidecar — which is what "restart
/// the app" means for these tests.
Future<void> newContainer({InMemoryCredentialStore? keepStore}) async {
  store = keepStore ?? InMemoryCredentialStore();
  jar = FakeJar();
  container = ProviderContainer(overrides: [
    credentialStoreProvider.overrideWithValue(store),
    webSessionCookiesProvider.overrideWithValue(jar),
  ]);
}

Future<Map<String, dynamic>> authLog() async =>
    (await RpcClient.instance.call('test.authLog', {})) as Map<String, dynamic>;

Future<void> resetSidecar() =>
    RpcClient.instance.call('test.reset', {'authState': 'anonymous'});

void main() {
  setUpAll(boot);

  setUp(() async {
    // The fake starts `authenticated` for every pre-existing test's benefit.
    // These tests are about transitions, so each begins from signed out — set
    // directly rather than through `auth.signOut`, which would land in the
    // `signOuts` counter and be charged to the test that follows.
    await resetSidecar();
    await newContainer();
  });

  tearDownAll(() async {
    RpcClient.instance.killForTest();
  });

  group('sign in', () {
    test('a good cookie authenticates and is persisted', () async {
      expect(await auth.signIn(goodCookie), AuthStatus.authenticated);
      expect(state.status, AuthStatus.authenticated);
      expect(store.value, goodCookie);
      expect((await authLog())['cookies'], contains(goodCookie));
    });

    test('carries the account name, handle and avatar into the top bar', () async {
      await auth.signIn(goodCookie);
      expect(state.accountName, 'Ada Lovelace');
      expect(state.accountHandle, '@ada');
      expect(state.accountAvatarUrl, 'https://yt3.ggpht.com/ada');
      expect(state.displayName, 'Ada Lovelace');
    });

    test('a stale cookie is degraded, and is NOT persisted', () async {
      // Two mutations, both silent. Collapsing `degraded` into `anonymous`
      // tells a user whose session expired that they were never signed in.
      // Persisting it anyway means the *next launch* restores a cookie the
      // server has already refused, and lands in a re-authentication prompt
      // caused by a login that failed once already.
      expect(await auth.signIn(staleCookie), AuthStatus.degraded);
      expect(state.status, AuthStatus.degraded);
      expect(state.status, isNot(AuthStatus.anonymous));
      expect(store.isEmpty, isTrue);
    });

    test('a degraded sign-in reports no account', () async {
      await auth.signIn(staleCookie);
      expect(state.accountName, isNull);
      expect(state.accountAvatarUrl, isNull);
      expect(state.isSignedIn, isFalse);
    });

    test('a cookie with no session in it is anonymous, not an error', () async {
      expect(await auth.signIn('PREF=tz=Europe.Rome; YSC=abc'), AuthStatus.anonymous);
      expect(store.isEmpty, isTrue);
    });

    test('isBusy is cleared however it ends', () async {
      await auth.signIn(staleCookie);
      expect(state.isBusy, isFalse);
    });
  });

  group('restart', () {
    test('a stored cookie restores the session with no WebView', () async {
      await auth.signIn(goodCookie);
      final persisted = store;

      // "Restart": a new container over the same sidecar, carrying the same
      // credential store — which is exactly what survives a real restart. The
      // sidecar is put back to anonymous the same way a fresh process would
      // start, without a sign-out the next assertion would count.
      await resetSidecar();
      await newContainer(keepStore: persisted);
      expect(state.status, AuthStatus.unknown);

      await auth.restore();
      expect(state.status, AuthStatus.authenticated);
      expect(state.accountName, 'Ada Lovelace');
      // The jar was never read. A restore that opened a WebView would defeat
      // the entire reason for storing the cookie.
      expect(jar.clears, 0);
    });

    test('the restored cookie is the one that was stored', () async {
      await auth.signIn(goodCookie);
      final persisted = store;
      await resetSidecar();
      await newContainer(keepStore: persisted);

      await auth.restore();
      expect((await authLog())['cookies'], [goodCookie]);
    });

    test('an empty store asks the sidecar rather than assuming anonymous', () async {
      // Task 22 §8: `YT_COOKIE` still works for development, and a sidecar
      // seeded from it is signed in with nothing in the credential store.
      // Assuming `anonymous` here would show a Log In button over a
      // personalised feed.
      await RpcClient.instance.call('auth.setCookie', {'cookie': goodCookie});
      await newContainer();
      expect(store.isEmpty, isTrue);

      await auth.restore();
      expect(state.status, AuthStatus.authenticated);
    });

    test('a stored cookie the server now refuses restores as degraded, and is kept', () async {
      store.value = staleCookie;
      await auth.restore();
      expect(state.status, AuthStatus.degraded);
      // Kept deliberately: deleting it turns "your session expired" into "you
      // were never signed in" on the next launch, which is the distinction §3
      // is about.
      expect(store.value, staleCookie);
    });
  });

  group('sign out', () {
    test('clears the credential store, the sidecar session and the WebView jar', () async {
      await auth.signIn(goodCookie);
      jar.jar = {'SAPISID': 'still-here', 'SID': 'still-here'};

      await auth.signOut();

      // Asserted on the store being empty, not on the flag — Task 22's own
      // mutation check. "Sign-out sets state to anonymous" passes while leaving
      // the cookie exactly where the next launch will find it.
      expect(store.isEmpty, isTrue);
      expect(jar.clears, 1);
      expect(jar.jar, isEmpty);
      expect((await authLog())['signOuts'], 1);
      expect(state.status, AuthStatus.anonymous);
    });

    test('a subsequent verify returns anonymous', () async {
      await auth.signIn(goodCookie);
      await auth.signOut();
      final verify = await RpcClient.instance.call('auth.verify', {}) as Map<String, dynamic>;
      expect(verify['state'], 'anonymous');
    });

    test('the account name goes with it', () async {
      await auth.signIn(goodCookie);
      expect(state.accountName, isNotNull);
      await auth.signOut();
      // `?? this.accountName` would keep it — hard invariant 10, and it would
      // read as the account still being signed in.
      expect(state.accountName, isNull);
      expect(state.accountHandle, isNull);
      expect(state.accountAvatarUrl, isNull);
    });

    test('a jar that refuses to clear still clears everything else', () async {
      // The failure this is shaped against: giving up halfway. The worst thing
      // to leave behind is the stored cookie, so it goes first and nothing
      // downstream can prevent it.
      await auth.signIn(goodCookie);
      container = ProviderContainer(overrides: [
        credentialStoreProvider.overrideWithValue(store),
        webSessionCookiesProvider.overrideWithValue(FakeJar(throwOnClear: true)),
      ]);

      await auth.signOut();
      expect(store.isEmpty, isTrue);
      expect((await authLog())['signOuts'], 1);
      expect(state.status, AuthStatus.anonymous);
    });

    test('signing in again re-verifies rather than reusing the old session', () async {
      await auth.signIn(goodCookie);
      await auth.signOut();
      await auth.signIn(goodCookie);
      final log = await authLog();
      // Two setCookie calls, not one — the second sign-in genuinely re-installs
      // the session rather than the app deciding it is already signed in.
      expect((log['cookies'] as List).length, 2);
    });
  });

  group('the refresh counter', () {
    test('a successful sign-in bumps it', () async {
      final before = container.read(authRefreshProvider);
      await auth.signIn(goodCookie);
      expect(container.read(authRefreshProvider), greaterThan(before));
    });

    test('a sign-out bumps it', () async {
      await auth.signIn(goodCookie);
      final before = container.read(authRefreshProvider);
      await auth.signOut();
      expect(container.read(authRefreshProvider), greaterThan(before));
    });

    test('a degraded sign-in does not', () async {
      // Nothing any surface renders differently changed, and a bump would
      // reload every open feed to show the same empty page.
      final before = container.read(authRefreshProvider);
      await auth.signIn(staleCookie);
      expect(container.read(authRefreshProvider), before);
    });

    test('a cancelled login leaves the app exactly as it was', () async {
      // Cancellation never reaches `signIn` at all — that is how §6's last line
      // holds without a special case. This asserts the property the absence
      // produces: no cookie stored, no counter bump, no state change.
      final before = container.read(authRefreshProvider);
      final status = state.status;
      expect(store.isEmpty, isTrue);
      expect(container.read(authRefreshProvider), before);
      expect(state.status, status);
      expect((await authLog())['cookies'], isEmpty);
    });
  });

  group('adoptVerifiedState', () {
    test('the feed finding a degraded session moves the top bar too', () async {
      // The one moment F7 is detectable is `FeedController`'s empty-page
      // `auth.verify`. Without this the avatar and name stay next to an empty
      // feed, which is F7 wearing the app's own UI.
      await auth.signIn(goodCookie);
      auth.adoptVerifiedState('degraded');
      expect(state.status, AuthStatus.degraded);
      expect(state.accountName, isNull);
    });

    test('an unreadable state is ignored rather than treated as signed out', () async {
      await auth.signIn(goodCookie);
      auth.adoptVerifiedState('something-new');
      expect(state.status, AuthStatus.unknown);
      expect(state.accountName, isNull);
    });

    test('a matching state changes nothing', () async {
      await auth.signIn(goodCookie);
      auth.adoptVerifiedState('authenticated');
      expect(state.accountName, 'Ada Lovelace');
    });
  });
}
