import 'dart:io';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

/// One cookie in WebView2's jar, **without its value**.
///
/// There is no value field on purpose (Task 33: cookies are credentials). The
/// native side drops it before the method channel — `getAllCookieNames`, a
/// `rill patch` in `third_party/flutter_inappwebview_windows` — so nothing built
/// on this can log one.
@immutable
class JarCookie {
  const JarCookie({
    required this.name,
    required this.domain,
    required this.path,
    required this.isSessionOnly,
    required this.isHttpOnly,
    required this.isSecure,
    required this.isPartitioned,
  });

  factory JarCookie.fromMap(Map<Object?, Object?> map) => JarCookie(
        name: map['name'] as String? ?? '',
        domain: map['domain'] as String? ?? '',
        path: map['path'] as String? ?? '/',
        isSessionOnly: map['isSessionOnly'] == true,
        isHttpOnly: map['isHttpOnly'] == true,
        isSecure: map['isSecure'] == true,
        isPartitioned: map['isPartitioned'] == true,
      );

  final String name;
  final String domain;
  final String path;
  final bool isSessionOnly;
  final bool isHttpOnly;
  final bool isSecure;
  final bool isPartitioned;

  /// `name @ domain (session|persistent, httpOnly, secure)`, plus the path when
  /// it is not `/` and `partitioned` when it is: a delete has to match both.
  String describe() {
    final flags = [
      isSessionOnly ? 'session' : 'persistent',
      if (isHttpOnly) 'httpOnly',
      if (isSecure) 'secure',
      if (isPartitioned) 'partitioned',
      if (path != '/') 'path=$path',
    ];
    return '$name @ $domain (${flags.join(', ')})';
  }
}

const MethodChannel _channel =
    MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');

/// Every cookie in the jar, all domains, or null when the DevTools protocol
/// call failed. `Network.getAllCookies`, where [WebView2SessionCookies.read]'s
/// `Network.getCookies` only answers for the URLs it is given.
Future<List<JarCookie>?> readAllJarCookies() async {
  final raw = await _channel.invokeMethod<List<Object?>>(
    'getAllCookieNames',
    <String, Object?>{'webViewEnvironmentId': null},
  );
  if (raw == null) return null;
  return [for (final entry in raw) JarCookie.fromMap(entry! as Map<Object?, Object?>)];
}

/// The dump's lines, sorted by domain then name so two dumps diff line by line.
List<String> describeJar(List<JarCookie> cookies) {
  final sorted = [...cookies]..sort((a, b) {
      final byDomain = a.domain.compareTo(b.domain);
      return byDomain != 0 ? byDomain : a.name.compareTo(b.name);
    });
  return [for (final cookie in sorted) cookie.describe()];
}

/// `RILL_COOKIE_DUMP=1` — write the whole jar to stderr (the release log),
/// names and domains only, labelled with [moment].
///
/// Task 33 §1's measurement: one at startup, one after every sign-in and one
/// after every sign-out.
Future<void> dumpCookieJar(String moment) async {
  if (Platform.environment['RILL_COOKIE_DUMP'] != '1') return;
  try {
    final cookies = await readAllJarCookies();
    if (cookies == null) {
      stderr.writeln('cookie-dump [$moment]: FAILED — Network.getAllCookies did not answer');
      return;
    }
    stderr.writeln('cookie-dump [$moment]: BEGIN ${cookies.length} cookie(s)');
    for (final line in describeJar(cookies)) {
      stderr.writeln('cookie-dump [$moment]:   $line');
    }
    stderr.writeln('cookie-dump [$moment]: END');
  } on Object catch (error) {
    stderr.writeln('cookie-dump [$moment]: FAILED — $error');
  }
}
