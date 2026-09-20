/// Analyzes the canary fixture and the app for `no_color_literals`, and fails
/// loudly if the `rill_lints` plugin did not actually load — a state that
/// otherwise looks identical to a clean codebase.
///
/// **Why this doesn't just run `dart analyze` / `flutter analyze`.** Measured
/// during the 2026-09-16 investigation: both commands report zero plugin
/// diagnostics on a codebase with real violations, on the project's pinned
/// SDK (3.44.9 / Dart 3.12.2) *and* on a Dart 3.13.2 SDK — so this is not a
/// version-gate problem, and bumping the pin would not have fixed it. File-log
/// instrumentation dropped into the plugin for that investigation showed
/// `register()` firing and succeeding on runs that still reported "No issues
/// found!" — the plugin was never failing to load. Driving the analysis
/// server directly over its legacy `analyzer` protocol (bypassing the CLI
/// commands entirely) showed why: the plugin isolate needs 6-16s after the
/// core analyzer's own files are done to spin up, register, and re-emit
/// diagnostics for files that were already analyzed. On the pinned SDK, the
/// server's own `analysis.isAnalyzing` status flips to `false` *before* that
/// catch-up lands and never corrects itself — so anything that stops
/// listening at the first idle signal (which is what the one-shot CLI
/// commands do) misses the plugin's diagnostics outright, and how often
/// depends only on how fast the rest of the analysis pass happens to run.
///
/// So this script is a small standalone client for the *persistent* analysis
/// server (`dart language-server --protocol=analyzer`), and it does not stop
/// at the first idle signal.
///
/// **Completion is two phases, not one quiet window.** Phase 1 waits
/// specifically for the canary's own `no_color_literals` diagnostic to
/// arrive, bounded by [_hardTimeout] — if it never arrives, that is a
/// definitive failure (the plugin did not load) and nothing downstream is
/// trustworthy anyway. Only once the canary has proven the plugin is alive
/// does phase 2 start: [_quietWindow] of no further diagnostic activity while
/// idle. A single quiet-window-from-start design was tried first and
/// rejected — the canary and the app are separate analysis contexts (each
/// has its own `analysis_options.yaml`) with independent plugin-isolate
/// timing, so the canary can report while the app's own plugin context is
/// still catching up, or vice versa. Resetting the window on *any* early
/// activity (including plain core-analyzer chatter, before either plugin
/// context has produced anything) risked settling before the plugin ever
/// spoke — the same race this script exists to avoid, just relocated. With
/// the app at zero violations (since 2026-09-16), the app context never
/// produces a diagnostic to extend the window either, so the canary's own
/// arrival is the only real proof-of-life signal available — hence phase 1
/// being mandatory rather than folded into one generic timer.
///
/// **What a pass does and does not prove.** A pass means: the plugin reported
/// for the canary, then [_quietWindow] went by with nothing new, and the app
/// had nothing to say. Because the canary is a separate analysis context, it
/// is not per-file proof that the app context's plugin pass finished — the
/// margin is the quiet window, roughly twice the measured 6-16s catch-up lag.
/// That is judged good enough; if a pass ever turns out to have been hollow,
/// the fix is a positive completion signal from the app context itself, not a
/// longer window.
///
/// [_quietWindow] is 30s, not 15s: 15s is *below* the 16s upper lag the
/// paragraph above cites, which was a real bug in an earlier version of this
/// script rather than a deliberate margin.
///
/// **Two independent checks, and why both exist.** `canary/` is a fixture
/// package with exactly one `no_color_literals` violation
/// (`tool/rill_lints/canary/lib/ui/canary.dart`) and its own
/// `analysis_options.yaml` enabling the plugin by relative path. Its result
/// answers "did the plugin load at all" on its own, independent of whatever
/// the app's current violation count happens to be — a codebase that is
/// genuinely clean and a plugin that silently failed to load both report zero
/// diagnostics, and only the canary tells them apart. **The canary check
/// always runs, in every mode** — an earlier version had an `--app-only` flag
/// that skipped it, which meant a broken plugin and a clean app were
/// indistinguishable in that mode: exactly the false-green this script exists
/// to prevent. There is no flag to disable it.
///
/// The app check fails on *any* diagnostic anywhere in `app/` outside
/// `tool/` — so `lib/` and `test/` alike (not just
/// `no_color_literals` — deliberately broader than the canary check, since a
/// clean app-wide analyze is the actual end state this gate exists to prove),
/// except `type: "TODO"` comment markers, which are the analyzer's built-in
/// comment scanner rather than a lint and would otherwise make the gate
/// permanently red over tracked, deliberately-deferred work (`docs/todo.md`).
/// Everything under `app/tool/` — `rill_lints` itself and
/// the canary — is excluded from the app check by path, so the canary's own
/// deliberate violation never counts against it.
///
/// **Deduplication.** `tool/rill_lints/README.md` already documents that
/// `flutter analyze` can report each plugin diagnostic twice. This script
/// talks to the protocol directly rather than parsing CLI text, but dedupes
/// by (file, line, column, code) regardless, since nothing about the
/// analysis-server protocol guarantees a given diagnostic notification for a
/// file is never superseded by a later, identical one during the plugin's
/// catch-up.
///
/// **Process cleanup.** `fvm` and `dart`/`flutter` are shim scripts on
/// Windows, not executables — `Process.start(..., runInShell: true)` runs
/// them under a `cmd.exe` wrapper, and `Process.kill()` only reaches that
/// wrapper, not the real `dart.exe` (and the analysis server isolate) it
/// spawned underneath. Six orphaned `language-server --protocol=analyzer`
/// processes were found still running after a session of this script that
/// believed it had cleaned up after itself. Fix, in order: (1) when
/// `.fvm/flutter_sdk` exists, launch `dart.exe` from inside it directly, with
/// no shell in between, so there is no wrapper for `kill()` to fail to reach;
/// (2) regardless of that, always prefer a graceful `server.shutdown` +
/// closed stdin over `kill()` — a process that exits on its own was never at
/// risk of being orphaned in the first place; (3) `kill()` as a fallback if
/// shutdown times out; (4) `taskkill /T /F` as a last resort, since it kills
/// the whole process tree regardless of what's wrapping what.
///
///     cd app && fvm dart run tool/lint_gate.dart          # canary + app
///     cd app && fvm dart run tool/lint_gate.dart --canary-only   # fast iteration
///
/// Any other argument is a usage error (exit 2) rather than being ignored:
/// `--app-only` used to exist, and a run that silently ignored it would let
/// someone believe they had skipped the canary when they had not — or, worse,
/// that a flag they typed did something.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Applies only after the canary has proven the plugin is alive (see the
/// header). Comfortably above the 6-16s catch-up lag measured across
/// repeated warm runs on both Dart 3.12.2 and 3.13.2 — 15s was tried and was
/// *below* the upper end of that range, not above it.
const _quietWindow = Duration(seconds: 30);

/// Bounds both phase 1 (waiting for the canary to prove the plugin loaded)
/// and the overall run. Generous on purpose: a cold plugin-AOT compile alone
/// measured ~58s during the investigation, before any analysis or the
/// widened quiet window even starts. A backstop, not a tuning knob — if the
/// server never settles within this, something is actually wrong (hung
/// process, crashed isolate) and that is itself a failure worth reporting
/// loudly rather than waiting forever.
const _hardTimeout = Duration(seconds: 300);

Future<void> main(List<String> args) async {
  // The repo pins its Flutter version in `.fvmrc`, so a bare `dart` here
  // would silently analyze against whatever is on PATH. Same check
  // test_suite_guard.dart uses.
  final useFvm = File('.fvmrc').existsSync() || File('../.fvmrc').existsSync();
  final launcher = _resolveDartLauncher(useFvm);

  final appRoot = Directory.current.absolute.path;
  final canaryRoot = '$appRoot${Platform.pathSeparator}tool${Platform.pathSeparator}rill_lints${Platform.pathSeparator}canary';
  final toolRoot = '$appRoot${Platform.pathSeparator}tool';

  const knownArgs = {'--canary-only'};
  final unknownArgs = args.where((a) => !knownArgs.contains(a)).toList();
  if (unknownArgs.isNotEmpty) {
    stderr.writeln(
      'lint_gate: unrecognised argument(s): ${unknownArgs.join(' ')}. '
      'The only option is --canary-only; the canary check always runs.',
    );
    exit(2);
  }
  final canaryOnly = args.contains('--canary-only');

  if (!Directory(canaryRoot).existsSync()) {
    stderr.writeln('lint_gate: canary fixture missing at $canaryRoot');
    exit(1);
  }

  stdout.writeln('lint_gate: resolving canary package...');
  final pubGet = await Process.run(
    launcher.executable,
    launcher.args(['pub', 'get']),
    workingDirectory: canaryRoot,
    runInShell: launcher.runInShell,
  );
  if (pubGet.exitCode != 0) {
    stderr.writeln('lint_gate: `pub get` failed for the canary package:');
    stderr.writeln(pubGet.stdout);
    stderr.writeln(pubGet.stderr);
    exit(1);
  }

  final root = canaryOnly ? canaryRoot : appRoot;
  stdout.writeln(
    'lint_gate: analyzing $root — waiting for the canary to prove the '
    'plugin loaded, then ${_quietWindow.inSeconds}s of quiet (expect '
    '~30-90s; longer on a cold plugin-AOT cache)...',
  );

  final analysis = await _analyze(
    launcher: launcher,
    root: root,
    canaryRoot: canaryRoot,
  );

  if (analysis.brokenRun) {
    // A crash or a timeout produces zero diagnostics, which reads exactly
    // like a clean run — the one silent-failure shape this whole script
    // exists to rule out. Never let it fall through as a pass.
    stderr.writeln('lint_gate: analysis run did not complete normally — failing regardless of diagnostic counts.');
    exit(1);
  }

  final diagnostics = analysis.diagnostics;
  var failed = false;

  // Always checked — no flag skips this. See the header for why.
  final canaryDiags = _dedupe(
    diagnostics.where(
      (d) => _underPath(d.file, canaryRoot) && d.code == 'no_color_literals',
    ),
  );
  if (canaryDiags.length == 1) {
    stdout.writeln('lint_gate: canary — 1 no_color_literals diagnostic, as expected. Plugin loaded.');
  } else {
    failed = true;
    stderr.writeln(
      'lint_gate: canary — expected exactly 1 no_color_literals diagnostic, '
      'got ${canaryDiags.length}. ${canaryDiags.isEmpty ? "The plugin did not load." : "Unexpected extra diagnostics — investigate before trusting the app check below."}',
    );
    for (final d in canaryDiags) {
      stderr.writeln('  ${d.file}:${d.line}:${d.column} ${d.message}');
    }
  }

  if (!canaryOnly) {
    final appDiags = _dedupe(
      diagnostics.where(
        (d) =>
            _underPath(d.file, appRoot) &&
            !_underPath(d.file, toolRoot) &&
            !d.isTodoMarker,
      ),
    );
    if (appDiags.isEmpty) {
      stdout.writeln('lint_gate: app — 0 diagnostics.');
    } else {
      failed = true;
      stderr.writeln('lint_gate: app — ${appDiags.length} diagnostic(s):');
      for (final d in appDiags) {
        stderr.writeln('  ${d.file}:${d.line}:${d.column} [${d.code}] ${d.message}');
      }
    }
  }

  exit(failed ? 1 : 0);
}

/// How to launch a real `dart` binary. Resolved once and reused for both the
/// (short-lived, awaited-to-completion) `pub get` call and the persistent
/// analysis-server process — only the latter has orphan risk, but using the
/// same resolution for both avoids a second, divergent way of finding Dart.
class _DartLauncher {
  _DartLauncher(this.executable, this._baseArgs, this.runInShell);
  final String executable;
  final List<String> _baseArgs;
  final bool runInShell;

  List<String> args(List<String> rest) => [..._baseArgs, ...rest];
}

_DartLauncher _resolveDartLauncher(bool useFvm) {
  if (useFvm) {
    for (final base in ['.fvm/flutter_sdk', '../.fvm/flutter_sdk']) {
      final dartExe = File(
        '$base/bin/cache/dart-sdk/bin/dart.exe'.replaceAll('/', Platform.pathSeparator),
      );
      if (dartExe.existsSync()) {
        return _DartLauncher(dartExe.absolute.path, const [], false);
      }
    }
    // `.fvm/flutter_sdk` missing (e.g. `fvm use` was never run in this
    // checkout) — fall back to the shim. Orphan risk here is mitigated by
    // preferring graceful shutdown over kill() in `_terminate` regardless.
    return _DartLauncher('fvm', const ['dart'], true);
  }
  return _DartLauncher('dart', const [], true);
}

bool _underPath(String file, String root) {
  final normFile = file.replaceAll('\\', '/');
  final normRoot = root.replaceAll('\\', '/');
  return normFile.startsWith('$normRoot/') || normFile == normRoot;
}

class _Diagnostic {
  _Diagnostic(this.file, this.code, this.type, this.message, this.line, this.column);
  final String file;
  final String code;
  // TODO/FIXME/HACK comment markers come back as `type: "TODO"` — the
  // analyzer's built-in comment scanner, not a lint. The app carries a few,
  // each tracked in `docs/todo.md` and deliberately deferred, so counting them
  // here would make the gate permanently red for reasons that have nothing to
  // do with the plugin or with color literals.
  final String type;
  final String message;
  final int line;
  final int column;

  bool get isTodoMarker => type == 'TODO';

  String get _key => '$file:$line:$column:$code';
}

List<_Diagnostic> _dedupe(Iterable<_Diagnostic> diags) {
  final seen = <String>{};
  final result = <_Diagnostic>[];
  for (final d in diags) {
    if (seen.add(d._key)) result.add(d);
  }
  return result;
}

class _AnalysisResult {
  _AnalysisResult(this.diagnostics, this.brokenRun);
  final List<_Diagnostic> diagnostics;
  final bool brokenRun;
}

Future<_AnalysisResult> _analyze({
  required _DartLauncher launcher,
  required String root,
  required String canaryRoot,
}) async {
  final process = await Process.start(
    launcher.executable,
    launcher.args(['language-server', '--protocol=analyzer']),
    runInShell: launcher.runInShell,
  );

  final errorsByFile = <String, List<_Diagnostic>>{};
  var isAnalyzing = false;
  var timedOut = false;
  var diedEarly = false;
  var canarySeen = false;
  var idCounter = 0;
  final settled = Completer<void>();
  Timer? quietTimer;

  final stderrSub = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) => stderr.writeln('lint_gate: [server stderr] $line'));

  unawaited(process.exitCode.then((code) {
    if (!settled.isCompleted) {
      diedEarly = true;
      stderr.writeln('lint_gate: analysis server process exited early with code $code.');
      settled.complete();
    }
  }));

  void send(String method, Map<String, Object?> params) {
    final id = '${idCounter++}';
    try {
      process.stdin.add(
        utf8.encode('${jsonEncode({'id': id, 'method': method, 'params': params})}\n'),
      );
    } catch (_) {
      // Process already gone — exitCode.then above will have flagged it.
    }
  }

  // Only armed once the canary has proven the plugin fired at least once —
  // see the header's "Completion is two phases" section for why.
  void armQuietTimer() {
    quietTimer?.cancel();
    quietTimer = Timer(_quietWindow, () {
      if (!isAnalyzing && !settled.isCompleted) settled.complete();
    });
  }

  final hardTimeoutTimer = Timer(_hardTimeout, () {
    if (!settled.isCompleted) {
      timedOut = true;
      settled.complete();
    }
  });

  final sub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    Object? msg;
    try {
      msg = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (msg is! Map<String, Object?>) return;

    switch (msg['event']) {
      case 'server.connected':
        send('server.setSubscriptions', {
          'subscriptions': ['STATUS'],
        });
        send('analysis.setAnalysisRoots', {
          'included': [root],
          'excluded': <String>[],
        });
        break;
      case 'server.status':
        final params = msg['params'] as Map<String, Object?>?;
        final analysis = params?['analysis'] as Map<String, Object?>?;
        final ia = analysis?['isAnalyzing'];
        if (ia is bool) isAnalyzing = ia;
        if (canarySeen) armQuietTimer();
        break;
      case 'analysis.errors':
        final params = msg['params'] as Map<String, Object?>? ?? const {};
        final file = params['file'] as String? ?? '';
        final rawErrors = params['errors'] as List<Object?>? ?? const [];
        final parsed = [
          for (final e in rawErrors)
            if (e is Map<String, Object?>) _parseError(file, e),
        ];
        errorsByFile[file] = parsed;
        if (!canarySeen &&
            _underPath(file, canaryRoot) &&
            parsed.any((d) => d.code == 'no_color_literals')) {
          canarySeen = true;
        }
        if (canarySeen) armQuietTimer();
        break;
      case 'server.error':
        stderr.writeln('lint_gate: analysis server reported an internal error: ${jsonEncode(msg['params'])}');
        break;
    }
  });

  await settled.future;
  hardTimeoutTimer.cancel();
  quietTimer?.cancel();
  await sub.cancel();
  await stderrSub.cancel();

  if (!diedEarly) await _terminate(process);

  if (timedOut) {
    stderr.writeln(
      canarySeen
          ? 'lint_gate: the analysis server never went quiet within $_hardTimeout '
              'after the canary reported — treating this as a failure rather '
              'than guessing at partial results.'
          : 'lint_gate: the canary diagnostic never arrived within $_hardTimeout '
              '— treating this as a failure rather than guessing at partial '
              'results.',
    );
  }
  if (diedEarly) {
    stderr.writeln(
      'lint_gate: treating the early exit above as a failure rather than '
      'guessing at partial results.',
    );
  }

  return _AnalysisResult(
    errorsByFile.values.expand((v) => v).toList(),
    timedOut || diedEarly,
  );
}

/// Graceful shutdown first, `kill()` as a fallback, `taskkill /T /F` as a
/// last resort. See the header's "Process cleanup" section for why plain
/// `kill()` alone left six orphaned analysis-server processes running after
/// an earlier version of this script.
Future<void> _terminate(Process process) async {
  final exitFuture = process.exitCode;

  try {
    process.stdin.add(
      utf8.encode('${jsonEncode({'id': 'shutdown', 'method': 'server.shutdown', 'params': <String, Object?>{}})}\n'),
    );
    await process.stdin.close();
  } catch (_) {
    // Already gone.
  }

  if (await _exitedWithin(exitFuture, const Duration(seconds: 10))) return;

  process.kill(ProcessSignal.sigkill);
  if (await _exitedWithin(exitFuture, const Duration(seconds: 5))) return;

  if (Platform.isWindows) {
    await Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
  }
}

Future<bool> _exitedWithin(Future<int> exitFuture, Duration d) async {
  final result = await exitFuture.timeout(d, onTimeout: () => -1);
  return result != -1;
}

_Diagnostic _parseError(String file, Map<String, Object?> e) {
  final location = e['location'] as Map<String, Object?>? ?? const {};
  return _Diagnostic(
    file,
    e['code'] as String? ?? '(unknown)',
    e['type'] as String? ?? '',
    e['message'] as String? ?? '',
    location['startLine'] as int? ?? 0,
    location['startColumn'] as int? ?? 0,
  );
}
