import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../data/auth/credential_store.dart';
import '../data/auth/web_session_cookies.dart';
import '../data/log_capture.dart';
import '../data/rpc/client.dart';

/// The app's idea of who is signed in.
///
/// Three states, from `protocol.md` §3.1, plus one this side needs and the
/// sidecar does not: [unknown], which is "nothing has asked yet". It exists so
/// the top bar can draw the person glyph on the first frame without claiming
/// the user is anonymous — the claim it would then have to take back a moment
/// later, which reads as a flicker from signed-out to signed-in on every
/// launch.
enum AuthStatus {
  /// Startup, before `restore` has answered.
  unknown,

  /// No cookie. The ordinary, supported state — anonymous browsing works.
  anonymous,

  /// A cookie the server stopped honouring. **Not** the same message as
  /// [anonymous], and that difference is Task 22 §3's whole point: one means
  /// "your session expired, sign in again", the other means "you were never
  /// signed in".
  degraded,

  authenticated,
}

@immutable
class AuthState {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.accountName,
    this.accountHandle,
    this.accountAvatarUrl,
    this.isBusy = false,
  });

  final AuthStatus status;
  final String? accountName;
  final String? accountHandle;
  final String? accountAvatarUrl;

  /// A sign-in or sign-out is in flight. Drives a spinner, and stops a second
  /// click starting a second WebView.
  final bool isBusy;

  bool get isSignedIn => status == AuthStatus.authenticated;

  /// What the top bar shows when there is no name. Never the handle alone —
  /// a bare `@ada` in place of a name reads as a bug rather than as a fallback.
  String get displayName => accountName ?? accountHandle ?? 'Account';

  /// Sentinel for the nullable fields, per hard invariant 10: `value ?? this.value`
  /// cannot *clear* anything, so a sign-out that passes `accountName: null`
  /// would silently keep the previous account's name next to the person glyph.
  static const Object _unchanged = Object();

  AuthState copyWith({
    AuthStatus? status,
    Object? accountName = _unchanged,
    Object? accountHandle = _unchanged,
    Object? accountAvatarUrl = _unchanged,
    bool? isBusy,
  }) {
    return AuthState(
      status: status ?? this.status,
      accountName:
          identical(accountName, _unchanged) ? this.accountName : accountName as String?,
      accountHandle:
          identical(accountHandle, _unchanged) ? this.accountHandle : accountHandle as String?,
      accountAvatarUrl: identical(accountAvatarUrl, _unchanged)
          ? this.accountAvatarUrl
          : accountAvatarUrl as String?,
      isBusy: isBusy ?? this.isBusy,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AuthState &&
      other.status == status &&
      other.accountName == accountName &&
      other.accountHandle == accountHandle &&
      other.accountAvatarUrl == accountAvatarUrl &&
      other.isBusy == isBusy;

  @override
  int get hashCode =>
      Object.hash(status, accountName, accountHandle, accountAvatarUrl, isBusy);
}

/// Why an action that needs an account is unavailable, or null when it is not.
///
/// One function so every surface says the same two things in the same words,
/// and so that **degraded is never quietly folded into "signed out"**. They need
/// different actions from the viewer: a signed-out person has to sign in, a
/// degraded one has to sign in *again* because a cookie YouTube has stopped
/// honouring looks exactly like being signed in everywhere else. Hard invariant
/// 5 is the reason the distinction exists at all — `logged_in` is cookie
/// presence, not server acceptance, so `auth.verify` is what tells them apart.
///
/// [verb] completes the sentence: `'vote'`, `'rate videos'`, `'subscribe'`.
/// Written as a reason rather than a bare "unavailable" because the tooltip is
/// the only place a disabled control can explain itself.
String? signedInActionBlocker(AuthStatus status, String verb) => switch (status) {
      AuthStatus.authenticated => null,
      AuthStatus.degraded => 'Your session expired. Sign in again to $verb',
      _ => 'Sign in to $verb',
    };


/// The one place the app decides whether it is signed in.
///
/// Every state it reports was **measured by the sidecar**, never inferred from
/// a cookie being present (hard invariant 5, F7): `auth.setCookie` fetches home
/// and counts tiles before answering, and `auth.status` reports what that
/// measurement said. Nothing here maps "we have a cookie" to `authenticated`.
class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  CredentialStore get _store => ref.read(credentialStoreProvider);
  WebSessionCookies get _jar => ref.read(webSessionCookiesProvider);

  /// Startup: stored cookie → sidecar → measured state.
  ///
  /// Task 22 §6's last paragraph. A stored cookie is *installed* and then
  /// *verified*; the three outcomes are the three states, and a degraded one
  /// keeps the stored cookie rather than deleting it — deleting it would turn
  /// "your session expired" into "you were never signed in" on the next launch,
  /// which is the distinction §3 says matters.
  ///
  /// No WebView is created on this path. That is the point of storing the
  /// cookie at all.
  Future<void> restore() async {
    final cookie = await _store.read();
    if (cookie != null) registerLogSecret(cookie);
    if (cookie == null) {
      // No stored cookie is not automatically anonymous: `YT_COOKIE` may have
      // seeded the sidecar (the development path, which Task 22 §8 keeps
      // working). Ask rather than assume.
      await refresh();
      return;
    }
    state = state.copyWith(isBusy: true);
    try {
      await RpcClient.instance.call('auth.setCookie', {'cookie': cookie});
      await refresh();
    } on Object catch (error) {
      // The sidecar is down, or the network is. Neither is a signed-out user:
      // reporting `anonymous` here would offer a Log In button for a problem a
      // login cannot fix, and would be wrong again the moment it recovers.
      stderr.writeln('rill auth: restore failed ($error) — leaving state unknown');
      state = state.copyWith(isBusy: false);
    }
  }

  /// Ask the sidecar what it thinks, and adopt it.
  ///
  /// `auth.status` rather than `auth.verify`, because it answers the same state
  /// *and* the account name and picture the top bar needs, off a response the
  /// sidecar already has. `auth.verify` stays what the feed calls on an empty
  /// page (protocol.md §3.1) — that call is asking a narrower question.
  Future<void> refresh() async {
    try {
      final response = await RpcClient.instance.call('auth.status', {});
      final map = response as Map<String, dynamic>;
      state = AuthState(
        status: _statusFrom(map['state'] as String?),
        accountName: map['accountName'] as String?,
        accountHandle: map['accountHandle'] as String?,
        accountAvatarUrl: map['accountAvatarUrl'] as String?,
      );
    } on Object catch (error) {
      stderr.writeln('rill auth: status unavailable ($error)');
      state = state.copyWith(isBusy: false);
    }
  }

  /// Hand a cookie to the sidecar; persist it only if YouTube accepted it.
  ///
  /// Returns the measured state. The order is the whole of Task 22 §6 steps
  /// 5–7 and it is deliberate: **verify before persist.** Storing first and
  /// verifying after would leave a rejected cookie in the credential store,
  /// where the next launch would restore it and land in `degraded` — a
  /// re-authentication prompt caused by a login that had already failed once.
  ///
  /// A `degraded` answer is *not* persisted for the same reason. It is a real
  /// answer and the UI shows it, but a cookie the server has already refused is
  /// not worth keeping.
  Future<AuthStatus> signIn(String cookie) async {
    registerLogSecret(cookie);
    state = state.copyWith(isBusy: true);
    try {
      final response = await RpcClient.instance.call('auth.setCookie', {'cookie': cookie});
      final status = _statusFrom((response as Map<String, dynamic>)['state'] as String?);
      if (status == AuthStatus.authenticated) {
        await _store.write(cookie);
      }
      await refresh();
      state = state.copyWith(isBusy: false);
      // Only on success. A `degraded` answer changed nothing any surface
      // renders differently, and reloading every feed to show the same empty
      // page is a round trip per surface for no new information.
      if (status == AuthStatus.authenticated) {
        ref.read(authRefreshProvider.notifier).bump();
      }
      return status;
    } on Object catch (error) {
      stderr.writeln('rill auth: sign-in failed ($error)');
      state = state.copyWith(isBusy: false);
      return state.status;
    }
  }

  /// Sign out of everything, in the order that makes a partial failure safe.
  ///
  /// Four things have to go (Task 22 §5): the credential store, the sidecar's
  /// session, WebView2's own cookie jar, and any cached feed. They are done in
  /// that order and **each is attempted even if an earlier one threw** — a
  /// sign-out that gives up halfway is the failure mode the ordering is chosen
  /// against, and the worst thing to leave behind is the stored cookie, so it
  /// goes first.
  ///
  /// The cached feed is the state itself: the surfaces read `isSignedIn` and
  /// reload, which is what `signOutRefreshes` wires up at the call site.
  Future<void> signOut() async {
    state = state.copyWith(isBusy: true);

    await _attempt('credential store', () => _store.clear());
    await _attempt('sidecar session', () => RpcClient.instance.call('auth.signOut', {}));
    // The jar last, and never skipped: leaving it means the next sign-in shows
    // no account picker and silently reuses this account, which looks like the
    // login flow ignoring the user rather than like a sign-out that did not
    // finish.
    await _attempt('WebView2 cookie jar', () => _jar.clear());

    state = const AuthState(status: AuthStatus.anonymous);
    // The fourth thing §5 lists — "any cached feed". Every loaded surface
    // reloads, so the personalised feed the user just signed out of is not
    // still on screen underneath the anonymous state.
    ref.read(authRefreshProvider.notifier).bump();
  }

  Future<void> _attempt(String what, Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      // Loud, and it does not stop the rest. A half-signed-out app is worse
      // than a noisy one.
      stderr.writeln('rill auth: sign-out could not clear the $what ($error)');
    }
  }

  /// Adopt a state the feed measured, without a second round trip.
  ///
  /// `FeedController` already calls `auth.verify` when a base page comes back
  /// empty (protocol.md §3.1) — that is the one moment F7 is detectable — and
  /// the answer belongs here too, or the top bar goes on showing an account
  /// whose session the feed has just found to be dead.
  void adoptVerifiedState(String? raw) {
    final status = _statusFrom(raw);
    if (status == state.status) return;
    state = status == AuthStatus.authenticated
        ? state.copyWith(status: status)
        // Anything else means the account details are no longer true. Cleared
        // through the sentinel, not `?? this`, or they would survive.
        : AuthState(status: status);
  }

  static AuthStatus _statusFrom(String? raw) {
    switch (raw) {
      case 'authenticated':
        return AuthStatus.authenticated;
      case 'degraded':
        return AuthStatus.degraded;
      case 'anonymous':
        return AuthStatus.anonymous;
      default:
        // An older or newer sidecar. `unknown` shows the person glyph and
        // nothing else — never a login prompt for a state we cannot read.
        return AuthStatus.unknown;
    }
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

/// Who is signed in, as a value: `(signed in, account handle)`.
///
/// **Anything derived from the account must `watch` this and re-read when it
/// changes** — `AccountActions`, `videoInfoProvider`, `playlistMembershipProvider`
/// and the comments list all do (Task 31). A response fetched under one identity
/// carries that identity's `isSubscribed`, `myRating` and vote params, and
/// nothing about the response says so; reusing it after a sign-in or sign-out
/// shows the previous viewer's state, silently.
///
/// Not [AuthState] itself: `isBusy` flips on every request and would refetch the
/// open page each time. `degraded` is "not signed in" here, as everywhere else —
/// [AuthState.isSignedIn] is strictly `authenticated`.
final authIdentityProvider = Provider<(bool, String?)>(
  (ref) => ref.watch(authProvider.select((auth) => (auth.isSignedIn, auth.accountHandle))),
);

/// A counter every auth-sensitive surface watches — Task 22 §6.8.
///
/// Signing in or out changes what `feed.home` and `feed.subscriptions` return,
/// and a surface that has already loaded has no other reason to reload. A
/// counter rather than each surface listening to [authProvider] directly: the
/// account *name* arrives a moment after the state does, and watching the whole
/// state would reload every feed a second time for a change none of them
/// render.
///
/// Bumped only where the answer actually changed — a successful `signIn` and a
/// `signOut`. A cancelled login never reaches either, which is how "cancellation
/// leaves the app exactly as it was" holds without a special case.
class AuthRefresh extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final authRefreshProvider = NotifierProvider<AuthRefresh, int>(AuthRefresh.new);
