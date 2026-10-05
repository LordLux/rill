import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/auth/youtube_cookies.dart';

/// The half of the login flow that has a right answer.
///
/// Task 22 §6.3 asks what completion is keyed on and to report it. It is keyed
/// on [hasSessionCookies], and this file is where that claim is checkable —
/// nothing here needs a WebView, a window or a Google account.
void main() {
  group('hasSessionCookies', () {
    test('needs SAPISID and SID together', () {
      expect(hasSessionCookies(['SAPISID', 'SID']), isTrue);
      expect(hasSessionCookies(['SAPISID']), isFalse);
      expect(hasSessionCookies(['SID']), isFalse);
      expect(hasSessionCookies([]), isFalse);
    });

    test('SAPISID is not interchangeable with __Secure-3PAPISID', () {
      // The mutation this catches, and it is not a stylistic one: youtubei.js
      // builds `Authorization: SAPISIDHASH …` by hashing the cookie literally
      // named `SAPISID` (`utils/Utils.js`). A jar carrying only the `__Secure-`
      // variants produces a request with *no* Authorization header — HTTP 200,
      // an anonymous feed, no error. Accepting it here would close the login
      // window on a session that cannot make an authenticated call.
      expect(
        hasSessionCookies(['__Secure-3PAPISID', '__Secure-1PSID', 'HSID', 'SSID']),
        isFalse,
      );
    });

    test('a signed-out YouTube jar is not mistaken for a session', () {
      // What an anonymous visit to youtube.com actually leaves behind. If this
      // ever reads as complete, the flow closes the window before the user has
      // typed anything.
      expect(
        hasSessionCookies(['VISITOR_INFO1_LIVE', 'YSC', 'PREF', '__Secure-ROLLOUT_TOKEN']),
        isFalse,
      );
    });

    test('names what is missing, sorted', () {
      expect(missingCookies(['SID', 'HSID']), ['SAPISID']);
      expect(missingCookies(['PREF']), ['SAPISID', 'SID']);
      expect(missingCookies(['SID', 'SAPISID']), isEmpty);
    });
  });

  group('cookieHeader', () {
    test('is a Cookie header, sorted and semicolon-separated', () {
      expect(
        cookieHeader({'SID': 'sid-value', 'SAPISID': 'sap-value'}),
        'SAPISID=sap-value; SID=sid-value',
      );
    });

    test('carries everything, not just the session names', () {
      // Deliberately not filtered to a whitelist. `PREF` carries the timezone
      // the parser's date strings are localised in, and a header missing a
      // cookie YouTube starts requiring would present as a *degraded session* —
      // an empty feed with no error — rather than as a missing cookie.
      final header = cookieHeader({
        'SAPISID': 'a',
        'SID': 'b',
        'PREF': 'tz=Europe.Rome',
        'VISITOR_INFO1_LIVE': 'v',
      });
      expect(header, contains('PREF=tz=Europe.Rome'));
      expect(header, contains('VISITOR_INFO1_LIVE=v'));
    });

    test('drops empty values rather than emitting NAME=', () {
      expect(cookieHeader({'SID': 'x', 'EMPTY': ''}), 'SID=x');
    });

    test('the same jar always produces the same header', () {
      final a = cookieHeader({'SID': 'x', 'SAPISID': 'y'});
      final b = cookieHeader({'SAPISID': 'y', 'SID': 'x'});
      expect(a, b);
    });
  });

  group('isSignOutCookie', () {
    test('every cookie the reader depends on is deleted by a sign-out', () {
      // Task 33 §3. Mutation: drop any name the reader knows from
      // `kSignOutCookieNames` and this fails — that name would survive a
      // sign-out and still satisfy, or still be sent by, the next read.
      for (final name in {...kRequiredCookies, ...kSessionCookies}) {
        for (final domain in ['.youtube.com', '.google.com']) {
          expect(isSignOutCookie(name, domain), isTrue, reason: '$name @ $domain');
        }
      }
    });

    test('the country domain is matched by shape, not listed', () {
      expect(isSignOutCookie('SID', '.google.it'), isTrue);
      expect(isSignOutCookie('SID', '.google.co.uk'), isTrue);
      expect(isSignOutCookie('SID', '.google.com.br'), isTrue);
      expect(isSignOutCookie('LSID', 'accounts.google.com'), isTrue);
    });

    test('the device-trust mark and the anonymous cookies are kept', () {
      expect(isSignOutCookie('SMSV', 'accounts.google.com'), isFalse);
      expect(isSignOutCookie('__Host-GAPS', 'accounts.google.com'), isFalse);
      expect(isSignOutCookie('OTZ', 'accounts.google.com'), isFalse);
      expect(isSignOutCookie('PREF', '.youtube.com'), isFalse);
    });

    test('a session name on a domain that is not Google\'s is not ours to delete', () {
      expect(isSignOutCookie('SID', '.example.com'), isFalse);
      expect(isSignOutCookie('SID', '.notgoogle.com'), isFalse);
      expect(isSignOutCookie('SID', '.google.com.evil.example'), isFalse);
    });
  });

  group('mergeJars', () {
    test('YouTube wins a collision', () {
      // Both origins carry `SID`, and the value scoped to the host the header
      // will be sent to is the right one.
      final merged = mergeJars({'SID': 'from-youtube'}, {'SID': 'from-google'});
      expect(merged['SID'], 'from-youtube');
    });

    test('Google fills a gap', () {
      // The real case: signed in at accounts.google.com, not yet redirected
      // back, so youtube.com's jar has no SAPISID in it yet.
      final merged = mergeJars({'SID': 'y'}, {'SAPISID': 'g', 'HSID': 'g'});
      expect(hasSessionCookies(merged.keys), isTrue);
      expect(merged['SAPISID'], 'g');
    });
  });

  group('describe', () {
    test('names cookies and never values — §5', () {
      final line = describe({
        'SAPISID': 'a-real-looking-value',
        'SID': 'another-one',
        'PREF': 'tz=Europe.Rome',
      });
      expect(line, contains('SAPISID'));
      expect(line, contains('SID'));
      // The whole point of this function existing.
      expect(line, isNot(contains('a-real-looking-value')));
      expect(line, isNot(contains('another-one')));
      expect(line, isNot(contains('Europe.Rome')));
    });

    test('says what is missing, which is what the log is for', () {
      expect(describe({'SID': 'x'}), contains('missing SAPISID'));
    });

    test('counts the rest rather than listing thirty names', () {
      expect(describe({'SID': 'x', 'PREF': 'y', 'YSC': 'z'}), contains('(+2 other)'));
    });
  });
}
