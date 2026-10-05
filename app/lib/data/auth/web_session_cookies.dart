import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cookie_jar_dump.dart';
import 'youtube_cookies.dart';

/// WebView2's cookie jar, as two operations: read it, and sign it out.
///
/// An interface rather than direct calls into `CookieManager`, because both of
/// Task 22's stop conditions live behind it and both need to be *testable*:
/// "the login flow can get cookies out" and "sign-out can clear the jar". A
/// fake implementation is what lets `auth_controller_test.dart` assert the
/// second without a window.
abstract class WebSessionCookies {
  /// Everything the jar would send to YouTube, by cookie name.
  Future<Map<String, String>> read();

  /// Remove every cookie that signs somebody in. Task 22 §5: a sign-out that
  /// leaves the WebView logged in means the next sign-in silently reuses the
  /// old account. Cookies that only describe the device stay (Task 33).
  Future<void> clear();
}

/// The real one, over `flutter_inappwebview`'s Windows implementation.
///
/// **This is the package the task's stop condition is about.** `webview_windows`
/// — the other Flutter WebView2 binding — exposes `clearCookies()` and no way to
/// read them: its method channel has twenty-odd methods and none of them is a
/// cookie getter, and `executeScript('document.cookie')` cannot see any of the
/// cookies that matter, because every one of Google's session cookies is
/// `HttpOnly`. That would have been the stop condition.
///
/// `flutter_inappwebview_windows` 0.6.0 reads them through the DevTools
/// protocol instead — `Network.getCookies` for the read, and `Network.deleteCookies`
/// (or `Network.clearBrowserCookies`, see [clearSessionCookies]) for the clear,
/// both against WebView2's default environment — and CDP returns `HttpOnly` cookies. That is what makes this
/// task possible at all, and it is why the dependency is this package.
class WebView2SessionCookies implements WebSessionCookies {
  const WebView2SessionCookies();

  /// The two origins Task 22 §6.4 names.
  ///
  /// Ordered: YouTube first, so [mergeJars] prefers it. `Network.getCookies`
  /// filters by URL the way a request would, so what comes back for the first
  /// is exactly the header YouTube would receive — including the `.google.com`
  /// cookies that are also scoped to it, which is most of them.
  static final WebUri _youtube = WebUri('https://www.youtube.com/');
  static final WebUri _google = WebUri('https://accounts.google.com/');

  @override
  Future<Map<String, String>> read() async {
    final manager = CookieManager.instance();
    final youtube = await _jar(manager, _youtube);
    // Only if YouTube's own jar is short. The Google read exists for the
    // window between "signed in at accounts.google.com" and "landed back on
    // youtube.com", and paying for it on every poll once YouTube's jar is
    // complete is a round trip for an answer already in hand.
    if (hasSessionCookies(youtube.keys)) return youtube;
    return mergeJars(youtube, await _jar(manager, _google));
  }

  Future<Map<String, String>> _jar(CookieManager manager, WebUri url) async {
    final cookies = await manager.getCookies(url: url);
    return {
      for (final cookie in cookies)
        if (cookie.value.toString().isNotEmpty) cookie.name: cookie.value.toString(),
    };
  }

  @override
  Future<void> clear() => clearSessionCookies(const WebView2JarStore());
}

/// The jar as sign-out needs it: list it, delete one cookie, or empty it.
///
/// Separate from [WebSessionCookies] so [clearSessionCookies] — the part with a
/// rule in it — runs against a fake in `auth_controller_test.dart`.
abstract class JarStore {
  /// Every cookie, all domains, without values; null when the jar did not answer.
  Future<List<JarCookie>?> list();

  Future<void> delete(JarCookie cookie);

  Future<void> deleteAll();
}

class WebView2JarStore implements JarStore {
  const WebView2JarStore();

  @override
  Future<List<JarCookie>?> list() => readAllJarCookies();

  @override
  Future<void> delete(JarCookie cookie) async {
    final host = cookie.domain.startsWith('.') ? cookie.domain.substring(1) : cookie.domain;
    await CookieManager.instance().deleteCookie(
      url: WebUri('https://$host${cookie.path}'),
      name: cookie.name,
      domain: cookie.domain,
      path: cookie.path,
    );
  }

  @override
  Future<void> deleteAll() async {
    await CookieManager.instance().deleteAllCookies();
  }
}

/// Sign-out's jar step: delete the cookies that sign somebody in, keep the rest.
///
/// What goes is [isSignOutCookie]; what stays includes Google's trusted-device
/// mark, so the next sign-in is not treated as a new device (`architecture.md`
/// F53). **It ends with no session cookie in the jar or with an empty jar**:
/// the jar is listed again afterwards, and a jar that cannot be listed, or
/// still holds one, is wiped whole. Losing the device mark costs a second
/// step; a surviving session cookie signs the next person in as this account.
Future<void> clearSessionCookies(JarStore store) async {
  final before = await store.list();
  if (before == null) {
    stderr.writeln('rill auth: WebView2 cookie jar could not be listed — clearing all of it');
    await store.deleteAll();
    return;
  }
  final session = [
    for (final cookie in before)
      if (isSignOutCookie(cookie.name, cookie.domain)) cookie,
  ];
  for (final cookie in session) {
    await store.delete(cookie);
  }

  final after = await store.list();
  final left = [
    for (final cookie in after ?? const <JarCookie>[])
      if (isSignOutCookie(cookie.name, cookie.domain)) '${cookie.name} @ ${cookie.domain}',
  ];
  if (after == null || left.isNotEmpty) {
    // Names and domains only, as everywhere.
    stderr.writeln(
      'rill auth: session cookies survived the sign-out '
      '(${after == null ? 'jar could not be listed' : left.join(', ')}) — clearing the whole jar',
    );
    await store.deleteAll();
    return;
  }
  stderr.writeln(
    'rill auth: WebView2 session cookies cleared: ${session.length} deleted, ${after.length} kept',
  );
}

final webSessionCookiesProvider =
    Provider<WebSessionCookies>((ref) => const WebView2SessionCookies());
