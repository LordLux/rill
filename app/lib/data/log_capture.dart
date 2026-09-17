import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// The release log's path, or `null` when this process is not being logged.
///
/// Set by the release runner's launcher for the app process it starts
/// (`windows/runner/log_capture.cpp`). Only then are stdout and stderr a pipe
/// to that launcher, so only then is it safe to write [registerLogSecret]'s
/// control line — anywhere else it would print a cookie to a terminal.
final String? logFilePath = Platform.environment['RILL_LOG_FILE'];

/// Tell the launcher to strike [value] from every later line of the log.
///
/// The launcher also redacts auth-cookie-shaped pairs on its own; this adds
/// the exact values, which is what catches a cookie quoted without its name.
/// The same two rules as `sidecar/src/redact.ts`. Call it with every cookie
/// the app holds, before anything could print it.
void registerLogSecret(String value) {
  if (logFilePath == null) return;
  // One line per value: the launcher reads line by line.
  for (final line in value.split(RegExp(r'[\r\n]+'))) {
    if (line.trim().length < 8) continue;
    stderr.writeln('\u0001rill-secret $line');
  }
}

/// Send Flutter's and the zone's uncaught errors to stderr, with stacks, so
/// the release log has them. Only when there is a log: in a debug run these
/// already reach the console, and replacing the handlers would change that.
void installErrorLogging() {
  if (logFilePath == null) return;
  stderr.writeln('rill: logging to $logFilePath');

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    stderr.writeln('rill: flutter error: ${details.exceptionAsString()}\n${details.stack}');
    previous?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    stderr.writeln('rill: uncaught error: $error\n$stack');
    // Handled: it is logged, and an uncaught error does not end a Flutter app.
    return true;
  };
}

/// `RILL_LOG_TEST` — checks the release log end to end. Never set in use.
///
/// - `lines`: a registered fake secret and an unregistered cookie-shaped pair,
///   both of which must reach the file as `«redacted»`, plus a control line.
/// - `flood`: ~12 MB of lines, which must rotate the file once.
/// - `abort`: a line, then a fast fail (`0xC0000409`), which must leave both
///   that line and the launcher's `CRASHED` line in the file. It runs before
///   the credential store is read, so a crash dump Windows takes of it holds
///   no cookie.
Future<void> runLogTest(String? mode) async {
  if (mode == null || logFilePath == null) return;
  if (mode == 'lines') {
    registerLogSecret('fake-registered-secret-0123456789');
    stderr.writeln('log test: bare fake-registered-secret-0123456789 end');
    stderr.writeln('log test: pair __Secure-3PAPISID=unregistered-fake-value-42; ok=1');
    stderr.writeln('log test: control VISITOR_INFO1_LIVE=stays-visible-123 end');
  } else if (mode == 'flood') {
    // Past the launcher's 10 MB limit, so the file rotates to `.old`.
    final filler = 'x' * 200;
    for (var i = 0; i < 60000; i++) {
      stderr.writeln('log test: flood $i $filler');
      if (i % 1000 == 0) await stderr.flush();
    }
    stderr.writeln('log test: flood done');
    await stderr.flush();
  } else if (mode == 'abort') {
    // `stderr` writes are queued; the flush is what puts this one in the pipe
    // before the abort. The test is that the pipe outlives the process, not
    // Dart's buffering.
    stderr.writeln('log test: about to abort');
    await stderr.flush();
    DynamicLibrary.open('ucrtbase.dll').lookupFunction<Void Function(), void Function()>('abort')();
  }
}
