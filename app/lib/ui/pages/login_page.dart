import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/web_session_cookies.dart';
import '../../data/auth/youtube_cookies.dart';
import '../../theme/screen_values.dart';
import '../auth_controller.dart';
import '../widgets/titlebar_button.dart';
import '../widgets/topbar.dart';
import '../widgets/window_controls.dart';

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
  const LoginPage({super.key, @visibleForTesting this.webViewBuilder});

  /// Replaces the WebView. `flutter test` cannot host a WebView2 platform view,
  /// so the retry logic (Task 31 §1) is only reachable with one swapped in.
  /// [onLoadStop] is what the real one calls when a page finishes loading.
  final Widget Function(BuildContext context, VoidCallback onLoadStop)? webViewBuilder;

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

  /// The waits before each *extra* sign-in attempt after a `degraded` answer —
  /// so at most `_retryBackoff.length + 1` attempts, and then the message.
  ///
  /// Two, not "until it works": a `degraded` answer is a real one and a session
  /// YouTube genuinely refuses would otherwise spend requests forever (the
  /// reasoning on the `degraded` case below). Measured 2026-10-01 by hand: the
  /// first attempt after a fresh login answered `degraded` twice running and
  /// *Try again* then succeeded with no second Google login. Whether the jar was
  /// still incomplete or YouTube had not honoured the session yet is unknown —
  /// `_logAttempt` is there to say (`todo.md` 56).
  static const List<Duration> _retryBackoff = [Duration(milliseconds: 1500), Duration(seconds: 3)];

  /// Time since this page opened, for the diagnostic lines.
  final Stopwatch _sinceOpened = Stopwatch()..start();

  /// When the jar was first seen holding the required cookies, so a log line can
  /// say how long the session had been there before YouTube was asked about it.
  Duration? _firstComplete;

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

  /// A degraded result reached a dead end — offer a way out instead of just
  /// prose, added 2026-09-30.
  ///
  /// Distinct from [_handingOff]: this is what the cover shows once it is
  /// up, not whether it is up. The button calls [_retry], which is the only
  /// thing that can move this screen forward again once [_finished] has
  /// stopped the poll — without it, a degraded session left the user on a
  /// message with no button and a `robots.txt` page underneath with nothing
  /// left to click either.
  bool _canRetry = false;

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
      var jar = await ref.read(webSessionCookiesProvider).read();
      if (!hasSessionCookies(jar.keys)) {
        // Names only, never values (§5). This line is the whole diagnostic for
        // "the flow finished and nothing happened".
        stderr.writeln('rill auth: jar not ready (+${_since(_sinceOpened.elapsed)}) — ${describe(jar)}');
        return;
      }
      _firstComplete ??= _sinceOpened.elapsed;

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

      // **Bounded retry on `degraded`** (Task 31 §1). Every attempt is a real
      // `auth.setCookie` — a count of home tiles — and the cookie is stored only
      // by `signIn` on `authenticated`, so retrying never trusts cookie presence
      // (hard invariant 5) and never persists anything unverified. The jar is
      // read afresh each time: the same header again would only repeat a
      // verdict the jar may already have outgrown.
      var status = AuthStatus.unknown;
      for (var attempt = 0; ; attempt++) {
        _logAttempt(attempt, jar);
        status = await ref.read(authProvider.notifier).signIn(cookieHeader(jar));
        if (!mounted) return;
        if (status != AuthStatus.degraded || attempt >= _retryBackoff.length) break;

        stderr.writeln(
          'rill auth: attempt ${attempt + 1} answered degraded — '
          'trying again in ${_retryBackoff[attempt].inMilliseconds} ms',
        );
        await Future<void>.delayed(_retryBackoff[attempt]);
        if (!mounted) return;
        jar = await ref.read(webSessionCookiesProvider).read();
        if (!mounted) return;
        if (!hasSessionCookies(jar.keys)) {
          // The session cookies went away between attempts — not a verdict from
          // YouTube about this jar. Go back to waiting; the poll is still running.
          stderr.writeln('rill auth: jar lost its session cookies — ${describe(jar)}');
          _uncover();
          _setMessage('Not signed in yet — continue in the window above.');
          return;
        }
      }

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
          //
          // **Stays covered — no `_uncover()`.** The page underneath is
          // `robots.txt` (see `_signIn`): a dead end with nothing left to do
          // on it, so uncovering here just showed the user that instead of
          // the explanation, with the "try signing in again" instruction
          // sitting below a page it was not talking about. `_canRetry`
          // swaps the spinner for an actual way to act on that instruction.
          _finished = true;
          _poll?.cancel();
          setState(() => _canRetry = true);
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

  /// One line per sign-in attempt: which cookie *names* the jar held and how long
  /// the page and the session had existed. Names only, never values (§5).
  ///
  /// This is what tells the two candidate causes of `degraded`-on-first-try
  /// apart: a jar missing `LOGIN_INFO` or `__Secure-*` at attempt 1 and complete
  /// at attempt 2 is an incomplete jar; the same names at both, flipping from
  /// degraded to authenticated, is YouTube not yet honouring the session.
  void _logAttempt(int attempt, Map<String, String> jar) {
    final complete = _firstComplete;
    stderr.writeln(
      'rill auth: sign-in attempt ${attempt + 1}/${_retryBackoff.length + 1} '
      'at +${_since(_sinceOpened.elapsed)}'
      '${complete == null ? '' : ' (jar complete since +${_since(complete)})'} '
      '— ${describe(jar)} | names: ${(jar.keys.toList()..sort()).join(', ')}',
    );
  }

  static String _since(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

  /// Put the web page back on screen.
  ///
  /// **Every outcome that means "keep going in the window above" has to do
  /// this** — `anonymous`/`unknown`, and the cookie-check failure — because
  /// their messages refer to a page the cover is hiding and the user
  /// actually needs to see it to act on them. `authenticated` and `degraded`
  /// are the two that do not: `authenticated` because the next thing that
  /// happens is the route closing, and `degraded` because — corrected
  /// 2026-09-30 — the page underneath by then is `robots.txt`, a dead end
  /// uncovering only used to flash up for no reason; see the `degraded` case
  /// in [_checkCookies] and [_canRetry].
  void _uncover() {
    if (!mounted || !_handingOff) return;
    setState(() => _handingOff = false);
  }

  /// Start over: back to the sign-in page, polling again.
  ///
  /// The only way out of a [_canRetry] state. `_finished` blocks
  /// [_checkCookies] outright, so it has to come back down along with
  /// [_checking]; the poll timer was cancelled on the way into `degraded`
  /// (`_checkCookies`), so it has to be recreated, not just trusted to still
  /// be running. Reloading `_signIn` matters as much as the flags — without
  /// it the WebView is still parked on `robots.txt`, and the next poll tick
  /// would just read the same jar and land right back here.
  void _retry() {
    setState(() {
      _canRetry = false;
      _finished = false;
      _checking = false;
      _handingOff = false;
    });
    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) => _checkCookies());
    _setMessage('Waiting for you to sign in…');
    unawaited(_controller?.loadUrl(urlRequest: URLRequest(url: _signIn)));
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
      // This route covers the app's top bar, which is where the window controls
      // live — so it carries its own, from the same provider (Task 31 §5).
      appBar: _LoginTitleBar(
        // Cancellation leaves the app exactly as it was — nothing has been
        // written by the time this can be pressed.
        onCancel: () => Navigator.of(context).pop(false),
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
                          if (_canRetry)
                            Icon(Icons.error_outline, size: 32, color: scheme.error)
                          else
                            const SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                          const SizedBox(height: 20),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              _message,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurface, fontSize: 16),
                            ),
                          ),
                          if (_canRetry) ...[
                            const SizedBox(height: 20),
                            FilledButton(onPressed: _retry, child: const Text('Try again')),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // **Not shown once `_canRetry` is up.** The cover already carries
          // this exact message, front and center, next to the button that
          // acts on it — repeating it down here in a narrow strip below the
          // fold is how a real failure ended up reading as background noise
          // rather than something to act on (2026-09-30). Every other state
          // this bar covers (waiting, checking, "not signed in yet") has no
          // competing copy of the message anywhere else, so it keeps this
          // bar for those.
          if (!_canRetry)
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
    final builder = widget.webViewBuilder;
    if (builder != null) return builder(context, () => unawaited(_checkCookies()));
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

/// The login page's stand-in for the top bar it covers: cancel, the title, a
/// drag region and the window buttons.
///
/// Nothing is drawn here that `TopBar` does not already draw — the drag region
/// and the cluster come from [windowControlsProvider], the same seam, so the
/// page and the bar cannot grow two sets of buttons. Present in the error state
/// too, since the bar belongs to the route and not to what the body shows.
class _LoginTitleBar extends ConsumerWidget implements PreferredSizeWidget {
  const _LoginTitleBar({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Size get preferredSize => const Size.fromHeight(ScreenValues.titlebarsHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controls = ref.watch(windowControlsProvider);

    return SizedBox(
      height: ScreenValues.titlebarsHeight,
      child: Stack(
        children: [
          Positioned.fill(child: controls.dragRegion()),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: TitleBarIconButton(
                      icon: Icons.close,
                      tooltip: 'Cancel',
                      onTap: onCancel,
                      scheme: theme.colorScheme,
                    ),
                  ),
                  const SizedBox(width: 8),
                  RillLogo(scheme: theme.colorScheme),
                ],
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Container(height: 2.5, width: 10, decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: .5), borderRadius: BorderRadius.circular(10))),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Sign in to YouTube',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Empty, so the drag region underneath receives the pan.
              const Spacer(),
              controls.buttons(theme),
            ],
          ),
        ],
      ),
    );
  }
}
