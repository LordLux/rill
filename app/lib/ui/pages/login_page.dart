import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/web_session_cookies.dart';
import '../../data/auth/youtube_cookies.dart';
import '../auth_controller.dart';

/// Sign in to YouTube, and return whether it worked.
///
/// `true` means the sidecar measured `authenticated` and the cookie is stored.
/// `false` means cancelled or failed — and in that case **nothing changed**
/// (Task 22 §6's last line): no cookie was written, no session was replaced,
/// and the surface underneath is exactly as it was. The one path that mutates
/// anything is the one that answers `true`.
Future<bool> showLoginFlow(BuildContext context) async {
  final result = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => const LoginPage(),
    ),
  );
  return result ?? false;
}

/// A real browser engine, for the one screen that needs one.
///
/// WebView2 renders no app UI (architecture.md §2.5). It exists so that
/// Google's login — password, 2FA, passkeys, the account picker, and whatever
/// Google adds next — happens in something that implements the web, rather than
/// in something this project would have to keep reimplementing.
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  /// Where the flow starts.
  ///
  /// `ServiceLogin` with `service=youtube` rather than youtube.com's own
  /// avatar-then-sign-in journey: it is one page shorter, and it makes the
  /// account picker the first thing shown when Google has more than one session
  /// — which is what the "sign in as someone else" case needs.
  ///
  /// **`continue` lands on `robots.txt`, and that is a crash fix, not a
  /// preference.** It used to be `https://www.youtube.com/`, and the whole
  /// YouTube SPA would load in this WebView the instant the login succeeded —
  /// at exactly the moment this page tears the WebView down. Measured
  /// 2026-09-09 from a real crash (`0xc0000005` in
  /// `flutter_inappwebview_windows_plugin.dll` at RVA `0x7aff5`, which
  /// disassembles to `std::get<flutter::EncodableMap>` inside
  /// `PermissionRequestCallback::decodeResult`): the loaded page issued a
  /// permission request, and Dart's reply arrived after the native webview had
  /// been freed.
  ///
  /// `robots.txt` is a few bytes of text that asks for no permissions, plays
  /// nothing and runs no script. The cookies are set by the `SetSID` bounce
  /// *before* this target is reached, so nothing about detection changes — and
  /// it is the same page `CLAUDE.md` already tells you to park a browser on
  /// when exporting cookies by hand, for the same reason.
  static final WebUri _signIn = WebUri(
    'https://accounts.google.com/ServiceLogin'
    '?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2Frobots.txt',
  );

  /// Somewhere harmless to park the WebView before it is destroyed.
  static final WebUri _blank = WebUri('about:blank');

  /// How often the jar is checked while the user is signing in.
  ///
  /// Polling *as well as* reacting to page loads, because the completion signal
  /// is a cookie and cookies are written by requests, not by navigations: a
  /// passkey flow can finish inside one page with an XHR and never fire another
  /// `onLoadStop`. Two seconds is far below human speed and costs one CDP call.
  static const Duration _pollInterval = Duration(seconds: 2);

  Timer? _poll;
  InAppWebViewController? _controller;
  bool _checking = false;
  bool _finished = false;

  /// The login is done and the WebView is covered while the session is checked.
  ///
  /// Not the same thing as [_finished]: this says "stop showing the web page",
  /// [_finished] says "stop polling". A degraded result sets both and keeps the
  /// cover up, because the message that follows belongs on this screen and not
  /// on a feed the user was never signed in to.
  bool _handingOff = false;

  String _message = 'Waiting for you to sign in…';

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(_pollInterval, (_) => _checkCookies());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Read the jar; if the markers are there, try to actually sign in.
  ///
  /// **Cookie presence is a precondition, not the answer** — hard invariant 5.
  /// This is the whole reason the flow does not close as soon as `SAPISID`
  /// appears: `signIn` hands the header to the sidecar, which fetches home and
  /// counts tiles, and only a tile count above zero closes this page. A cookie
  /// set by a half-finished flow, or one the server declines, leaves the
  /// WebView open and the user where they were.
  Future<void> _checkCookies() async {
    if (_checking || _finished || !mounted) return;
    _checking = true;
    try {
      final jar = await ref.read(webSessionCookiesProvider).read();
      if (!hasSessionCookies(jar.keys)) {
        // Names only, never values (§5). This line is the whole diagnostic for
        // "the flow finished and nothing happened".
        stderr.writeln('rill auth: jar not ready — ${describe(jar)}');
        return;
      }

      // **Cover the WebView the instant the cookies exist.**
      //
      // Google's post-login redirect lands on `youtube.com/robots.txt` (see
      // `_signIn`), and a page of `User-agent: *` rules flashing up as the
      // login window closes reads as something having gone wrong. By this line
      // the login itself is done, so there is nothing left in there worth
      // looking at — what is left is a verification the user should see as
      // progress, not as a web page.
      //
      // **Covered, not unmounted.** Two reasons, both hard-won: cookie reads go
      // through WebView2's default environment, which needs a live webview to
      // answer, and tearing one down while a page is still loading is exactly
      // the 2026-09-09 crash. It stays mounted and alive underneath, and dies
      // only on the existing quiesce-then-pop path.
      if (mounted) setState(() => _handingOff = true);

      _setMessage('Checking with YouTube…');
      final status = await ref.read(authProvider.notifier).signIn(cookieHeader(jar));
      if (!mounted) return;

      switch (status) {
        case AuthStatus.authenticated:
          _finished = true;
          _poll?.cancel();
          await _quiesce();
          if (!mounted) return;
          Navigator.of(context).pop(true);
        case AuthStatus.degraded:
          // The cookies exist and YouTube will not honour them. Retrying the
          // same jar every two seconds would spend requests forever, so stop
          // and say so — this is `retry: no` wearing a different hat.
          _finished = true;
          _poll?.cancel();
          _uncover();
          _setMessage(
            'YouTube returned an empty feed for this session. '
            'Try signing in again, or with a different account.',
          );
        case AuthStatus.anonymous:
        case AuthStatus.unknown:
          _uncover();
          _setMessage('Not signed in yet — continue in the window above.');
      }
    } on Object catch (error) {
      // Never surfaces the cookie: the message comes from the RPC envelope,
      // which the sidecar redacts before it is written (`redact.ts`).
      stderr.writeln('rill auth: cookie check failed ($error)');
      // A throw between covering and answering would otherwise strand the user
      // behind a spinner with no page and no way back.
      _uncover();
    } finally {
      _checking = false;
    }
  }

  /// Put the web page back on screen.
  ///
  /// **Every outcome except success has to do this**, and forgetting it is a
  /// worse bug than the flash of `robots.txt` the cover exists to prevent: the
  /// messages for the other outcomes all say some version of "keep going" or
  /// "try again", and both refer to a page the cover is hiding. Only
  /// `authenticated` may leave the cover up, because from there the next thing
  /// that happens is the route closing.
  void _uncover() {
    if (!mounted || !_handingOff) return;
    setState(() => _handingOff = false);
  }

  void _setMessage(String message) {
    if (!mounted || _message == message) return;
    setState(() => _message = message);
  }

  /// Put the page to sleep before the WebView is destroyed.
  ///
  /// **Popping this route frees the native webview**, and any reply still in
  /// flight from Dart to a native callback lands on freed memory — that is the
  /// crash described on `_signIn` above, and it is a defect in the plugin's
  /// lifetime handling rather than something a caller can fix. What a caller
  /// *can* do is stop generating callbacks and give the ones outstanding a
  /// moment to land first: stop the load, navigate to a blank page, wait a
  /// frame or two.
  ///
  /// It narrows the window rather than closing it, which is why it is the
  /// second line of defence and not the first — the first is not loading a page
  /// that asks for anything.
  Future<void> _quiesce() async {
    _setMessage('Signed in. Closing…');
    try {
      await _controller?.stopLoading();
      await _controller?.loadUrl(urlRequest: URLRequest(url: _blank));
    } on Object catch (error) {
      // Best-effort by definition: the webview may already be gone.
      stderr.writeln('rill auth: could not park the webview before closing ($error)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = ref.watch(authProvider.select((s) => s.isBusy));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to YouTube'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          // Cancellation leaves the app exactly as it was — nothing has been
          // written by the time this can be pressed.
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _webView(),
                // The cover. Opaque and on top rather than replacing the
                // WebView, so the platform view underneath is never resized or
                // disposed while it is still finishing work — see `_handingOff`.
                if (_handingOff)
                  ColoredBox(
                    color: scheme.surface,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _message,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurface, fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: scheme.surfaceContainerHighest,
            child: Row(
              children: [
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _message,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The WebView, built once and kept mounted for the life of this route.
  ///
  /// Separated from [build] so the cover above it is obviously a *sibling* in a
  /// `Stack` rather than a replacement — the distinction the crash note on
  /// `_signIn` turns on.
  Widget _webView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: _signIn),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // Third-party cookies are the sign-in: accounts.google.com sets
        // them and youtube.com reads them.
        thirdPartyCookiesEnabled: true,
        // **No `userAgent` override, deliberately.** Google refuses its
        // sign-in page to user agents it reads as embedded or automated
        // — "This browser or app may not be secure" — which presents as
        // a broken login page rather than as a rejected request.
        // WebView2's default string is Edge's and is accepted; setting
        // one here is how that gets broken.
      ),
      // A page load is one of the two triggers; the timer is the other.
      // Neither is a URL match — see `youtube_cookies.dart` for why.
      onLoadStop: (_, _) => _checkCookies(),
      onWebViewCreated: (controller) => _controller = controller,
      // **Deny every permission, immediately.** This is the exact
      // callback the 2026-09-09 crash faulted inside: the page asks,
      // the plugin waits on a reply from Dart, and if the webview is
      // destroyed before that reply lands it is decoded against freed
      // memory. Answering synchronously means there is never a pending
      // one to outlive the page.
      //
      // Denying is also just correct here. A login page has no business
      // with a camera, a microphone, notifications or geolocation, and
      // an embedded WebView with no permission UI cannot ask the user
      // about it — so the only honest answer is no.
      onPermissionRequest: (_, request) async => PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      ),
    );
  }
}
