import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/auth/cookie_jar_dump.dart';
import '../data/auth/web_session_cookies.dart';
import '../data/auth/youtube_cookies.dart';

/// `RILL_AUTH_PROBE=1` — checks Task 22's two stop conditions and exits.
///
/// Both of them are claims about a *native* component, and neither is provable
/// from a unit test or from reading a package:
///
///  1. **WebView2 can return cookies** from the login session — including
///     `HttpOnly` ones, which is the whole difficulty. Every Google session
///     cookie is `HttpOnly`, so a binding that can only reach
///     `document.cookie` can never see one.
///  2. **Sign-out can clear WebView2's cookie jar.** If it cannot, the
///     alternative is a disposable WebView profile per login, which is a design
///     change rather than a fix.
///
/// It runs against **youtube.com and the sign-in page, both signed out**, so it
/// needs no account and touches no credentials. Both set `HttpOnly` cookies to
/// an anonymous visitor, and reading one of those proves exactly the capability
/// a real login needs, without a real login.
///
/// The `HttpOnly` check reads each cookie's own `isHttpOnly` flag rather than
/// matching a name. Names were the first attempt and they were wrong: a bare
/// youtube.com load set `PREF` and `__Secure-YENID`, not the `YSC` and
/// `VISITOR_INFO1_LIVE` this probe expected — measured 2026-09-08 — so a
/// name-matched check reported a failure about the probe's own guess.
///
/// It also asserts the *negative*: an anonymous jar must not satisfy
/// [hasSessionCookies]. A completion check that fires on a signed-out jar would
/// close the login window before the user had typed anything.
///
/// Names only in the output, never values (Task 22 §5) — the same rule the
/// probe is verifying the app under.
void runAuthProbe() {
  if (Platform.environment['RILL_AUTH_PROBE'] != '1') return;
  runApp(const _AuthProbeApp());
}

class _AuthProbeApp extends StatefulWidget {
  const _AuthProbeApp();

  @override
  State<_AuthProbeApp> createState() => _AuthProbeAppState();
}

class _AuthProbeAppState extends State<_AuthProbeApp> {
  bool _ran = false;
  InAppWebViewController? _controller;

  Future<void> _probe() async {
    if (_ran) return;
    _ran = true;

    var failures = 0;
    void check(String claim, bool ok, [String detail = '']) {
      if (!ok) failures += 1;
      stderr.writeln('auth-probe: ${ok ? 'PASS' : 'FAIL'}  $claim${detail.isEmpty ? '' : '  — $detail'}');
    }

    try {
      // Give youtube.com a moment past `onLoadStop` to finish setting its jar.
      await Future<void>.delayed(const Duration(seconds: 3));

      const source = WebView2SessionCookies();
      final jar = await source.read();
      stderr.writeln('auth-probe: jar has ${jar.length} cookie(s): ${jar.keys.toList()..sort()}');

      check('stop condition 1 — WebView2 returns cookies', jar.isNotEmpty,
          '${jar.length} read');

      check('a signed-out jar is not mistaken for a session',
          !hasSessionCookies(jar.keys), 'missing ${missingCookies(jar.keys)}');

      // **The check that actually settles stop condition 1.** Every Google
      // session cookie is `HttpOnly` and therefore invisible to page script, so
      // "we can read cookies" is only the right answer if it includes those.
      // Read across both origins the login flow touches, and asserted on each
      // cookie's own flag rather than on its name.
      //
      // The sign-in page is loaded first, and signed out: it sets `HttpOnly`
      // cookies to an anonymous visitor, so this reaches the same jar a real
      // login writes into without anybody signing in.
      await _controller?.loadUrl(
        urlRequest: URLRequest(
          url: WebUri('https://accounts.google.com/ServiceLogin?service=youtube'),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 5));

      final manager = CookieManager.instance();
      final flagged = <String>[];
      for (final url in [
        WebUri('https://www.youtube.com/'),
        WebUri('https://accounts.google.com/'),
      ]) {
        final cookies = await manager.getCookies(url: url);
        for (final cookie in cookies) {
          stderr.writeln('auth-probe:   ${url.host} ${cookie.name} '
              'httpOnly=${cookie.isHttpOnly} secure=${cookie.isSecure}');
          if (cookie.isHttpOnly == true) flagged.add('${url.host}/${cookie.name}');
        }
      }
      check('HttpOnly cookies are readable', flagged.isNotEmpty, 'saw $flagged');

      // With `RILL_COOKIE_DUMP=1`: the whole jar, every domain (Task 33 §1).
      await dumpCookieJar('auth-probe before clear');

      // Task 33: sign-out deletes cookies one by one, by name and domain. Proved
      // here on two anonymous cookies — one on a dotted domain, one host-only —
      // because a delete that matches nothing also reports success.
      const store = WebView2JarStore();
      final listed = await store.list() ?? const <JarCookie>[];
      final targets = [
        ...listed.where((c) => c.domain.startsWith('.') && !c.isPartitioned).take(1),
        ...listed.where((c) => !c.domain.startsWith('.') && !c.isPartitioned).take(1),
      ];
      for (final target in targets) {
        await store.delete(target);
      }
      final remaining = await store.list() ?? const <JarCookie>[];
      bool same(JarCookie a, JarCookie b) => a.name == b.name && a.domain == b.domain;
      check(
        'one cookie can be deleted by name and domain',
        targets.length == 2 &&
            !remaining.any((c) => targets.any((t) => same(c, t))) &&
            remaining.length == listed.length - targets.length,
        'deleted ${[for (final t in targets) '${t.name} @ ${t.domain}']}, '
            '${listed.length} before, ${remaining.length} after',
      );

      await store.deleteAll();
      await dumpCookieJar('auth-probe after clear');
      final after = await source.read();
      stderr.writeln('auth-probe: after clear, jar has ${after.length} cookie(s): '
          '${after.keys.toList()..sort()}');
      check('stop condition 2 — the jar can be emptied', after.isEmpty,
          '${after.length} left');
    } on Object catch (error, stack) {
      stderr.writeln('auth-probe: THREW $error\n$stack');
      failures += 1;
    }

    stderr.writeln(failures == 0 ? 'auth-probe: ALL PASS' : 'auth-probe: $failures FAILURE(S)');
    exit(failures == 0 ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri('https://www.youtube.com/')),
          onWebViewCreated: (controller) => _controller = controller,
          onLoadStop: (_, _) => unawaited(_probe()),
          onReceivedError: (_, _, error) {
            stderr.writeln('auth-probe: navigation error $error');
            unawaited(_probe());
          },
        ),
      ),
    );
  }
}
