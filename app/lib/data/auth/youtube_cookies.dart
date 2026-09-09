/// Which cookies make a YouTube session, and how they become a header.
///
/// Pure, and separate from the WebView for one reason: this is the part with a
/// right answer, and it is the part that cannot be checked by looking at a
/// screen. What "the user finished signing in" *means* is a set membership
/// question, and it is answered here so that `login_page.dart` only has to
/// poll.
///
/// **Completion is keyed on cookies, never on a URL** — Task 22 §6.3. A URL
/// match is a guess about Google's redirect chain, and that chain changes with
/// the sign-in method: password, 2FA, passkey and account-picker flows land on
/// different pages, and an interstitial ("protect your account", "you're signed
/// in on a new device") lands on a page that looks final and is not. The cookie
/// jar has no such ambiguity — either the session cookies are in it or they are
/// not.
///
/// And even that is only a *precondition*. Cookie presence is exactly what hard
/// invariant 5 says never to trust: the marker set below says "there is
/// something worth trying", and `auth.verify` counting tiles says whether it
/// worked. Nothing here reports a signed-in state.
library;

/// The cookies without which an authenticated InnerTube call cannot be made.
///
/// `SAPISID` is not one marker among several — it is load-bearing. youtubei.js
/// builds the `Authorization: SAPISIDHASH …` header by hashing that exact
/// cookie (`utils/Utils.js`, `generateSidAuth`), and a header without it is
/// sent with no `Authorization` at all: HTTP 200, an anonymous feed, no error.
/// F7's shape, reached by a different road.
///
/// `SID` is the session itself. Both, or the attempt is not worth making.
const Set<String> kRequiredCookies = {'SAPISID', 'SID'};

/// Cookies worth carrying when they are there, none of them required.
///
/// Not a whitelist that filters — see [cookieHeader], which sends everything
/// the jar had for the URL, the same as a browser would. This list exists to
/// make the diagnostic in [describe] name the interesting ones rather than
/// print thirty.
const Set<String> kSessionCookies = {
  'SAPISID',
  'SID',
  'HSID',
  'SSID',
  'APISID',
  'LOGIN_INFO',
  '__Secure-1PSID',
  '__Secure-3PSID',
  '__Secure-1PAPISID',
  '__Secure-3PAPISID',
};

/// Whether [names] contains everything an authenticated call needs.
bool hasSessionCookies(Iterable<String> names) {
  final present = names.toSet();
  return kRequiredCookies.every(present.contains);
}

/// The names in [kRequiredCookies] that [names] is missing, for a log line.
List<String> missingCookies(Iterable<String> names) {
  final present = names.toSet();
  return kRequiredCookies.where((c) => !present.contains(c)).toList()..sort();
}

/// A `Cookie:` header from name → value pairs.
///
/// Everything present, not just the names above. A browser sends the whole jar
/// for the origin and YouTube reads more of it than this file knows about —
/// `PREF` carries the timezone the parser's date strings are localised in,
/// `VISITOR_INFO1_LIVE` identifies the visitor. Filtering to a list would work
/// until the day YouTube starts requiring one that is not on it, and then it
/// would fail as a degraded session rather than as a missing cookie.
///
/// Empty values are dropped: a cookie with no value is not a cookie, and one
/// in the header would produce `NAME=;` which some parsers read as a deletion.
String cookieHeader(Map<String, String> cookies) {
  final entries = cookies.entries.where((e) => e.value.isNotEmpty).toList()
    // Sorted so the same jar always produces the same header. Nothing upstream
    // requires it; it means a stored cookie compares equal to a freshly read
    // one, so "did this change" is answerable without parsing.
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// Merge two jars, preferring [primary] on a name collision.
///
/// Task 22 §6.4 asks for `.youtube.com` **and** `.google.com`. They overlap
/// heavily — Google sets `SID`, `SAPISID` and the rest on both — and where they
/// disagree the one scoped to the host the header will be sent to is the right
/// value. So YouTube's jar is [primary] and Google's fills the gaps.
///
/// The gaps are real rather than theoretical: a user who signs in at
/// `accounts.google.com` and is still on the interstitial has a populated
/// `.google.com` jar and a `.youtube.com` jar that has not been written yet.
Map<String, String> mergeJars(
  Map<String, String> primary,
  Map<String, String> secondary,
) {
  return {...secondary, ...primary};
}

/// The cookie names in a jar, sorted — for a log line that says what was found
/// without saying what any of it was.
///
/// **Names only.** Task 22 §5: never log a value, not truncated and not in a
/// probe. This function exists so that the obvious debugging move — print the
/// jar — has a safe thing to reach for. Non-session cookies are counted rather
/// than named, so the line stays short and stays about the question being
/// asked.
String describe(Map<String, String> jar) {
  final session = jar.keys.where(kSessionCookies.contains).toList()..sort();
  final others = jar.length - session.length;
  final missing = missingCookies(jar.keys);
  return '${session.join(', ')}'
      '${others > 0 ? ' (+$others other)' : ''}'
      '${missing.isEmpty ? '' : ' — missing ${missing.join(', ')}'}';
}
