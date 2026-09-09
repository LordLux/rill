/// Runs the Flutter test suite and fails if any file in `test/` produced no
/// tests at all.
///
/// **The failure this exists for.** `player_controls_unit_test.dart` referenced
/// `PlayerAction.toggleCaptions`, renamed in `bf2e288` on 2026-08-18. The file
/// then failed to *load*, and nineteen tests stopped running. Nothing said so.
///
/// It is worth being exact about "nothing said so", because the obvious reading
/// is wrong and would have produced the wrong guard. `flutter test` is not
/// silent here: it exits 1 and lists the file under "Failing tests" as
/// `loading <path>`. What it does not do is distinguish that from an ordinary
/// failed expectation — a whole unloadable file counts as exactly **`-1`**, one
/// tick in the summary line. The suite had two known failures at the time, so
/// `+403 -2` read as "green apart from the known ones", which is what it had
/// read as for weeks. The nineteen missing tests appear nowhere: not in the
/// count, not in the failure list, not in the exit code. Only the *total* moved,
/// and nobody compares totals between runs.
///
/// So the hazard is not "the runner is quiet". It is "the signal is one
/// indistinguishable unit, and it lands in a suite already carrying some". A
/// permanently-red check is what makes it invisible — the same shape as the
/// `no-console` lint that sat red for a session, and the reason both are worth
/// fixing rather than describing.
///
/// **Why zero-result suites rather than a committed test-count floor.** A floor
/// catches this too, but it has to be raised by hand every time anyone adds a
/// test, and the first time it is in someone's way it gets lowered instead of
/// investigated — at which point it is worse than nothing, because it looks like
/// a guard. A zero-result suite is a fact about the run that needs no
/// maintenance and has no tuning knob: a file in `test/` either produced tests
/// or it did not, and the second case is never intentional.
///
/// **The sidecar does not need this.** Measured 2026-09-10: `bun test` with an
/// unloadable file in `test/` reports `1 error` separately from the failure
/// count and exits 1. The ambiguity above is specific to `flutter test`'s
/// reporter, so this guard is app-side only and deliberately not mirrored.
///
///     cd app && dart run tool/test_suite_guard.dart
///
/// Arguments are passed through to `flutter test`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  // The repo pins its Flutter version in `.fvmrc`, so a bare `flutter` here
  // would silently test against whatever is on PATH.
  final useFvm = File('.fvmrc').existsSync() || File('../.fvmrc').existsSync();
  final executable = useFvm ? 'fvm' : 'flutter';
  final arguments = <String>[
    if (useFvm) 'flutter',
    'test',
    '--reporter',
    'json',
    ...args,
  ];

  final process = await Process.start(
    executable,
    arguments,
    // Required on Windows: `fvm` and `flutter` are both shims, not executables.
    runInShell: true,
  );
  unawaited(stderr.addStream(process.stderr));

  final suitePaths = <int, String>{};
  final testsPerSuite = <int, int>{};
  final failures = <String>[];
  var sawAnyEvent = false;

  await for (final line in process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (!line.startsWith('{')) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    sawAnyEvent = true;

    switch (decoded['type']) {
      case 'suite':
        final suite = decoded['suite'] as Map<String, Object?>?;
        final path = suite?['path'] as String?;
        final id = suite?['id'] as int?;
        if (id != null && path != null) {
          suitePaths[id] = path;
          testsPerSuite[id] ??= 0;
        }
      case 'testStart':
        final test = decoded['test'] as Map<String, Object?>?;
        final name = test?['name'] as String? ?? '';
        final suiteId = test?['suiteID'] as int?;
        // The runner synthesises a test per suite for the load itself, and one
        // per top-level fixture. Neither is a test anyone wrote.
        if (suiteId == null) continue;
        if (name.startsWith('loading ') ||
            name.startsWith('tearDownAll') ||
            name.startsWith('setUpAll')) {
          continue;
        }
        testsPerSuite[suiteId] = (testsPerSuite[suiteId] ?? 0) + 1;
      case 'testDone':
        if (decoded['result'] != 'success' && decoded['hidden'] != true) {
          failures.add('${decoded['testID']}');
        }
    }
  }

  final testExit = await process.exitCode;

  if (!sawAnyEvent) {
    stderr.writeln(
      'test_suite_guard: the runner emitted no JSON events at all — treating '
      'that as a failure rather than a pass, because a guard that cannot see '
      'the run must not bless it. Exit code was $testExit.',
    );
    exit(testExit == 0 ? 1 : testExit);
  }

  final empty = <String>[
    for (final entry in suitePaths.entries)
      if ((testsPerSuite[entry.key] ?? 0) == 0) entry.value,
  ]..sort();

  final total = testsPerSuite.values.fold<int>(0, (a, b) => a + b);
  stdout.writeln(
    'test_suite_guard: ${suitePaths.length} suites, $total tests, '
    '${failures.length} not passing.',
  );

  if (empty.isNotEmpty) {
    stderr.writeln('');
    stderr.writeln(
      'test_suite_guard: ${empty.length} file(s) in test/ produced no tests. '
      'A file that fails to compile fails to *load*, which costs every test in '
      'it while showing up as a single -1 in the summary:',
    );
    for (final path in empty) {
      stderr.writeln('  $path');
    }
    stderr.writeln(
      '\nRun `flutter test <path>` on one of them to see the compile error.',
    );
    exit(1);
  }

  exit(testExit);
}
