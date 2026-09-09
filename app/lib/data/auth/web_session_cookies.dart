import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'youtube_cookies.dart';

/// WebView2's cookie jar, as two operations: read it, and empty it.
///
/// An interface rather than direct calls into `CookieManager`, because both of
/// Task 22's stop conditions live behind it and both need to be *testable*:
/// "the login flow can get cookies out" and "sign-out can clear the jar". A
/// fake implementation is what lets `auth_controller_test.dart` assert the
/// second without a window.
abstract class WebSessionCookies {
  /// Everything the jar would send to YouTube, by cookie name.
  Future<Map<String, String>> read();

  /// Empty the jar. Task 22 §5: a sign-out that leaves the WebView logged in
  /// means the next sign-in silently reuses the old account.
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
/// protocol instead — `Network.getCookies` for the read and
/// `Network.clearBrowserCookies` for the clear, both against WebView2's default
/// environment — and CDP returns `HttpOnly` cookies. That is what makes this
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
  Future<void> clear() async {
    final deleted = await CookieManager.instance().deleteAllCookies();
    // Said out loud because the alternative failure is silent and expensive: a
    // jar that did not clear means the *next* sign-in reuses this account with
    // no account picker and no visible difference.
    stderr.writeln('rill auth: WebView2 cookie jar cleared: $deleted');
  }
}

final webSessionCookiesProvider =
    Provider<WebSessionCookies>((ref) => const WebView2SessionCookies());
