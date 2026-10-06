import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/auth/cookie_jar_dump.dart';

/// Task 33 §1's dump: what a line says, and that a value cannot get into one.
void main() {
  test('a line is name @ domain and the flags', () {
    const cookie = JarCookie(
      name: 'SID',
      domain: '.google.com',
      path: '/',
      isSessionOnly: false,
      isHttpOnly: true,
      isSecure: true,
      isPartitioned: false,
    );
    expect(cookie.describe(), 'SID @ .google.com (persistent, httpOnly, secure)');
  });

  test('a path other than / and a partition are named, since a delete must match them', () {
    const cookie = JarCookie(
      name: 'X',
      domain: 'accounts.google.com',
      path: '/signin',
      isSessionOnly: true,
      isHttpOnly: false,
      isSecure: false,
      isPartitioned: true,
    );
    expect(cookie.describe(), 'X @ accounts.google.com (session, partitioned, path=/signin)');
  });

  test('a value handed over the channel is not carried', () {
    final cookie = JarCookie.fromMap(const {
      'name': 'SID',
      'value': 'must-not-appear',
      'domain': '.youtube.com',
      'path': '/',
      'isSessionOnly': false,
      'isHttpOnly': true,
      'isSecure': true,
      'isPartitioned': false,
    });
    expect(cookie.describe(), isNot(contains('must-not-appear')));
  });

  test('lines are sorted by domain, then name, so two dumps diff line by line', () {
    JarCookie at(String name, String domain) => JarCookie(
          name: name,
          domain: domain,
          path: '/',
          isSessionOnly: true,
          isHttpOnly: false,
          isSecure: false,
          isPartitioned: false,
        );
    final lines = describeJar([at('b', '.youtube.com'), at('z', '.google.com'), at('a', '.youtube.com')]);
    expect(lines, [
      'z @ .google.com (session)',
      'a @ .youtube.com (session)',
      'b @ .youtube.com (session)',
    ]);
  });
}
