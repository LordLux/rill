import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:meta/meta.dart';

enum RpcRetryMode {
  auto,
  user,
  no,
}

class RpcException implements Exception {
  RpcException(this.code, this.message, this.retry);

  final String code;
  final String message;
  final RpcRetryMode retry;

  @override
  String toString() => 'RpcException($code): $message (retry: ${retry.name})';
}

class RpcClient {
  RpcClient._();

  static final RpcClient instance = RpcClient._();

  /// Override this in tests to run a fake sidecar script.
  List<String>? mockCommand;

  Process? _process;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  @visibleForTesting
  int? get processId => _process?.pid;
  
  Map<String, dynamic>? capabilities;
  Completer<void>? _readyCompleter;
  
  bool _isDisposed = false;
  bool _isFatalError = false;
  int _restartBackoffMs = 1000;
  Future<void>? _startFuture;

  /// The directory holding a `sidecar/` tree, or null if there is none.
  ///
  /// Two layouts, in this order:
  ///
  ///  1. **Beside the executable.** A copied build directory is the only thing a
  ///     second machine has, and it must be able to run without a checkout, a
  ///     `bun`, or a particular working directory. `Platform.resolvedExecutable`
  ///     is where the app actually is; `Directory.current` is wherever it was
  ///     launched *from*, which for a shortcut, a `cd` elsewhere, or Explorer on
  ///     another drive is not the app at all.
  ///  2. **Up from the current directory**, for `flutter run` in a dev checkout,
  ///     where the binary lives in `sidecar/dist/` at the repo root and the cwd
  ///     is `app/`.
  ///
  /// Split out with its inputs passed in so both layouts can be tested without a
  /// filesystem — the failure this fixes ("Failed to start sidecar process" on
  /// any machine that is not this one) is invisible in a dev checkout, because
  /// there the search always succeeds.
  @visibleForTesting
  static String? findSidecarRoot({
    required String exeDir,
    required String cwd,
    required bool Function(String path) hasSidecarDir,
  }) {
    if (hasSidecarDir(exeDir)) return exeDir;

    var dir = Directory(cwd);
    for (var i = 0; i < 8; i++) {
      if (hasSidecarDir(dir.path)) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  String _findProjectRoot() {
    return findSidecarRoot(
          exeDir: File(Platform.resolvedExecutable).parent.path,
          cwd: Directory.current.path,
          hasSidecarDir: (path) => Directory('$path/sidecar').existsSync(),
        ) ??
        Directory.current.path;
  }


  /// Debug mode, without importing Flutter.
  ///
  /// **`client.dart` must not import `package:flutter/…`, and this is the line
  /// that proves it.** `test/orphan_test_helper.dart` imports this file and runs
  /// on the plain Dart VM, which has no `dart:ui`; a `package:flutter/foundation`
  /// import for `kDebugMode` therefore made that helper fail to *compile*, and
  /// the orphan test failed with "Helper should print SIDECAR_PID" — a message
  /// that points nowhere near the cause. Same shape as the `animated_vector_gen`
  /// trap in CLAUDE.md: a package re-exports `dart:ui` and drags the framework
  /// into a host that has none.
  ///
  /// The assert trick is the standard Flutter-free equivalent: the assignment
  /// runs only when asserts are enabled, which is exactly debug.
  static bool get _isDebugBuild {
    var debug = false;
    assert(debug = true);
    return debug;
  }

  /// Says so, loudly, when the running sidecar predates the source on disk.
  ///
  /// **This trap has fired seven times and cost a whole measurement run once**
  /// — the F20 bucket-rate reading was taken against a binary 17 minutes older
  /// than the fix it was supposed to be measuring, and reported the rate as
  /// having dropped. CLAUDE.md has warned about it in three places for months;
  /// prose has not stopped it, because the failure is silent and looks like a
  /// result rather than like a mistake.
  ///
  /// **Why mtime rather than a build identifier in `event.ready`.** Both were
  /// considered; mtime is what catches the cases this repo has actually hit:
  ///
  /// - **A git SHA plus a dirty flag does not work here at all.** This tree is
  ///   dirty during essentially all development, and every case we have hit was
  ///   an edit-rebuild-forget cycle *within* one dirty state. The SHA and the
  ///   flag are identical before and after such an edit, so the identifier
  ///   cannot distinguish "built before my change" from "built after" — which
  ///   is the only question being asked.
  /// - **A content hash of `sidecar/src` at build time works**, but needs a
  ///   build-step change, a generated file, and the same hash implemented twice
  ///   (TypeScript and Dart) to be comparable. It buys nothing over mtime for
  ///   any case in the record.
  /// - **mtime catches all seven**, needs no protocol change, and the number it
  ///   compares was already being logged one line above.
  ///
  /// The comparison is against the **repository's** `sidecar/src`, found by
  /// walking up from the running root — not against the source beside the
  /// binary. In a release bundle those are *both* stale copies and agree with
  /// each other, which is exactly how the trap hides. A shipped app with no
  /// repository above it finds nothing and says nothing.
  ///
  /// Known false positive: a fresh `git checkout` or clone stamps sources with
  /// the current time, so the first run after one can warn about a binary that
  /// is fine. Rebuilding is the remedy either way, so the cost is a rebuild
  /// nobody needed rather than a wrong measurement.
  void _warnIfStale(File compiled, String root) {
    if (!_isDebugBuild) return;
    try {
      final src = repoSidecarSrc(root);
      if (src == null) return;

      final builtAt = compiled.statSync().modified;
      DateTime? newest;
      String? newestPath;
      for (final entry in src.listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.ts')) continue;
        final at = entry.statSync().modified;
        if (newest == null || at.isAfter(newest)) {
          newest = at;
          newestPath = entry.path;
        }
      }
      if (newest == null || !newest.isAfter(builtAt)) return;

      final behind = newest.difference(builtAt);
      stderr.writeln('');
      stderr.writeln('!!! rill: THE SIDECAR IS STALE -- it is older than its source.');
      stderr.writeln('    running: ${compiled.path}');
      stderr.writeln('      built: ${builtAt.toIso8601String()}');
      stderr.writeln('     newest: $newestPath');
      stderr.writeln('             ${newest.toIso8601String()}  (${behind.inMinutes} min newer)');
      stderr.writeln('    Anything measured now describes the OLD sidecar. Run `rill build`.');
      stderr.writeln('');
    } on FileSystemException {
      // A diagnostic must never be the thing that breaks a launch.
    }
  }

  /// The repository's own `sidecar/src`, walking up from [root], or null when
  /// this is a shipped app rather than a checkout.
  ///
  /// [root] itself is tried first so a debug run — where the running root *is*
  /// the repository — needs no walk at all.
  @visibleForTesting
  static Directory? repoSidecarSrc(String root) {
    var dir = Directory(root);
    for (var i = 0; i < 10; i++) {
      final src = Directory('${dir.path}/sidecar/src');
      // `.git` distinguishes the checkout from a bundled copy, which also has a
      // `sidecar/src` beside it and is equally stale.
      if (src.existsSync() && Directory('${dir.path}/.git').existsSync()) return src;
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
    return null;
  }

  /// The compiled sidecar, or null when this checkout has not been built.
  ///
  /// `bun run src/main.ts` transpiles the whole module graph — youtubei.js
  /// included — on the first import that reaches it, and that cost lands on the
  /// first real call rather than on startup. Compiling moves it to build time.
  /// A dev checkout with no `dist/` still works; it is just slower.
  File? _compiledSidecar(String root) {
    final name = Platform.isWindows ? 'sidecar.exe' : 'sidecar';
    final binary = File('$root/sidecar/dist/$name');
    return binary.existsSync() ? binary : null;
  }

  Future<void> start() {
    if (_isDisposed) return Future.value();
    if (_process != null) return Future.value();
    if (_startFuture != null) return _startFuture!;
    _startFuture = _startInternal();
    return _startFuture!;
  }

  /// `Process.start`, retried through a transient Windows spawn failure.
  ///
  /// **Starting a sidecar close behind killing one can fail to spawn at all**,
  /// with `SocketException: Write failed (OS Error: The pipe is being closed,
  /// errno = 232)` raised by `Process.start` itself — the previous process's
  /// pipes are still being torn down and the new process cannot get its own.
  /// Measured at roughly one run in three across a 35-test file that restarts
  /// the sidecar per test.
  ///
  /// **It has to be retried here rather than around `start()`**, and that is the
  /// part worth remembering: `start()` caches `_startFuture`, so a caller that
  /// catches the failure and calls `start()` again is handed the *same failed
  /// future* and fails identically however many times it tries. The retry has to
  /// be inside the thing that can actually be retried. The failure also arrives
  /// as an unhandled async error rather than out of the awaited call, so in a
  /// test suite it lands on whichever test happens to be running — it read as a
  /// flaky double-click for a while, which is why this comment is this long.
  ///
  /// **Corrected after a review found the real cause.** This retry was written
  /// believing the spawn raced only the OS tearing down the previous process's
  /// pipes. It also raced *this class*: a stale `onDone` from the killed sidecar
  /// tore down the freshly started one, and the next spawn then hit a pipe that
  /// really was closing — see `_handleExit`, which now checks process identity.
  /// The retry stays, because a spawn racing the OS is still possible and the
  /// hedge costs nothing, but it is a hedge and no longer the fix.
  Future<Process> _spawn(String executable, List<String> command, String root) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await Process.start(executable, command, workingDirectory: root, environment: {
          'FLUTTER_PARENT_PID': pid.toString(),
        });
      } on Object {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      }
    }
  }

  Future<void> _startInternal() async {
    // Cleared per attempt. It was only ever reset by `killForTest`, so a mismatch
    // resolved by fixing the sidecar on disk left the flag set and suppressed
    // every future restart — supervision silently switched itself off.
    _isFatalError = false;
    _readyCompleter = Completer<void>();
    final root = _findProjectRoot();

    try {
      // A mock is always driven through bun — the fakes are .ts sources.
      final compiled = mockCommand == null ? _compiledSidecar(root) : null;
      final executable = compiled?.path ?? 'bun';
      final command = compiled != null
          ? const <String>[]
          : (mockCommand ?? ['run', 'sidecar/src/main.ts']);

      // **Say which sidecar this is, and how old.**
      //
      // `findSidecarRoot` prefers the directory beside the executable, so a
      // release build runs the copy `flutter build windows` bundled — and that
      // copy step does not re-run for an already-populated bundle. Rebuilding
      // `sidecar/dist/` therefore changes nothing the release app executes, in
      // silence. Diagnosed twice now from behaviour that looked like a
      // half-finished feature: a caption track rendering position and outline
      // but no colour, because the bundled binary predated the change that reads
      // per-segment pens. One line at startup turns "which code am I running"
      // from an archaeology exercise into something a log answers.
      if (compiled != null) {
        final at = compiled.statSync().modified.toIso8601String();
        stderr.writeln('rill: sidecar $executable (built $at)');
        _warnIfStale(compiled, root);
      } else {
        stderr.writeln('rill: sidecar via bun, from $root (no dist/ build)');
      }

      final process = await _spawn(executable, command, root);
      _process = process;

      // **Every exit handler names the process it belongs to.**
      //
      // A dying sidecar's `onDone` arrives asynchronously, and `killForTest`
      // starts the next one immediately — so by the time the *old* process's
      // stream closes, `_process` can already be the *new* one. Handlers that
      // only checked `_process != null` then tore down a healthy process:
      // pending requests failed with `UPSTREAM_ERROR`, and a restart was
      // scheduled on top of the process that was already running. It surfaced as
      // `SocketException: … The pipe is being closed` from the next spawn, on
      // whichever test happened to be running, which is why it read for a while
      // as a flaky double-click.
      //
      // Identity, not a flag: a boolean guard has to be un-set at exactly the
      // right moment and this does not.
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
        _handleLine,
        onDone: () => _handleExit(process),
        onError: (e) => _handleExit(process),
      );

      process.stderr.transform(utf8.decoder).listen((line) {
        stderr.write(line);
      });
      
      await _readyCompleter!.future;
      _restartBackoffMs = 1000;
      
      // Supervision: Re-run auth.verify after restart if capabilities already exist
      if (capabilities != null) {
        try {
          await call('auth.verify', {});
        } catch (e) {
          stderr.writeln('harness: auth.verify failed on restart: $e');
        }
      }
    } catch (e) {
      stderr.writeln('START INTERNAL CATCH: $e');
      _handleExit(null);
      if (e is RpcException && e.retry == RpcRetryMode.no) {
        rethrow;
      }
    } finally {
      _startFuture = null;
    }
  }

  /// Above this, a decode is offloaded to an isolate; below it, parsed inline.
  ///
  /// Hard invariant 9 is about a *large payload* on the frame loop, not about
  /// every message. Nearly all of them are a couple of hundred bytes — a
  /// `feed.home` result is the exception, not the rule — and spawning an isolate
  /// to parse 200 bytes costs orders of magnitude more than the parse. 64 KiB is
  /// comfortably above any envelope that is not a feed page and comfortably
  /// below one that is.
  static const int _isolateDecodeThreshold = 64 * 1024;

  /// Serialises message handling.
  ///
  /// `listen` does not await its handler, so an `async` handler returns at its
  /// first `await` and the next line starts decoding immediately. Two decodes of
  /// different sizes then finish in the wrong order. Responses are keyed by `id`
  /// so that is mostly survivable, but `event.ready` arriving after a response
  /// would break the ready gate — the one message where order is the whole
  /// contract. Chaining costs a microtask per message and makes the order the
  /// wire's order, always.
  Future<void> _handlerChain = Future<void>.value();

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    // `catchError` is not decoration. This future is the *chain*: if it ever
    // rejects, every later `.then` skips its handler and forwards the rejection
    // instead, so one throw would silently drop every remaining message for the
    // life of the process. `_decodeAndDispatch` catches its own body, so this
    // should be unreachable — which is exactly the sort of guard worth having,
    // because the failure it prevents is invisible.
    _handlerChain = _handlerChain
        .then((_) => _decodeAndDispatch(line))
        .catchError((Object e) => stderr.writeln('harness rpc: handler chain error: $e'));
  }

  Future<void> _decodeAndDispatch(String line) async {
    try {
      final msg = line.length <= _isolateDecodeThreshold
          ? jsonDecode(line) as Map<String, dynamic>
          : await Isolate.run(() => jsonDecode(line) as Map<String, dynamic>);

      if (msg['method'] == 'event.ready') {
        final params = msg['params'] as Map<String, dynamic>;
        final version = params['protocolVersion'];
        if (version != 1) {
          final errorMsg = 'FATAL: Protocol version mismatch. Expected 1, got $version';
          stderr.writeln(errorMsg);
          _isFatalError = true;
          if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
            _readyCompleter!.completeError(RpcException('PROTOCOL_MISMATCH', errorMsg, RpcRetryMode.no));
          }
          _process?.kill();
          return;
        }
        capabilities = params['capabilities'] as Map<String, dynamic>;
        if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
          _readyCompleter!.complete();
        }
        return;
      }
      
      final id = msg['id'] as int?;
      if (id != null) {
        final completer = _pending.remove(id);
        if (completer != null) {
          if (msg.containsKey('error')) {
            final err = msg['error'] as Map<String, dynamic>;
            final retryStr = err['retry'] as String?;
            final retryMode = RpcRetryMode.values.firstWhere(
              (m) => m.name == retryStr, 
              orElse: () => RpcRetryMode.no
            );
            completer.completeError(RpcException(
              err['code'] as String,
              err['message'] as String,
              retryMode,
            ));
          } else {
            completer.complete(msg['result']);
          }
        }
      }
    } catch (e) {
      stderr.writeln('harness rpc error decoding line: $e');
    }
  }

  /// [source] is the process whose stream ended, or null for a start failure.
  void _handleExit(Process? source) {
    if (_isDisposed) return;
    if (_process == null) return; // Means killForTest() was called
    // A late exit from a process that has already been replaced. Ignoring it is
    // the whole point of passing the identity in — see the listener above.
    if (source != null && !identical(source, _process)) return;
    _process = null;

    // A fatal protocol mismatch is `no`: the sidecar on disk cannot talk to this
    // build, and telling every in-flight caller to retry with backoff is telling
    // them to spend requests on a conversation that cannot happen. `auto` here
    // was a silent instruction to loop.
    final error = _isFatalError
        ? RpcException('PROTOCOL_MISMATCH', 'Sidecar protocol mismatch', RpcRetryMode.no)
        : RpcException('UPSTREAM_ERROR', 'Sidecar exited', RpcRetryMode.auto);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(error);
    }

    if (_isFatalError) return;

    Timer(Duration(milliseconds: _restartBackoffMs), () {
      _restartBackoffMs = (_restartBackoffMs * 2).clamp(1000, 30000);
      start();
    });
  }

  Future<dynamic> call(String method, Map<String, dynamic> params) =>
      callCancelable(method, params).response;

  /// A request plus the id needed to `$cancel` it.
  ///
  /// The id is allocated synchronously, before the sidecar has necessarily
  /// finished starting, so a caller that supersedes this request can cancel it
  /// even while it is still waiting on the handshake.
  ///
  /// A cancelled request's future never completes — that is the transport's
  /// contract, asserted in `rpc_client_test.dart`. Callers must therefore not
  /// treat the future as their only path forward; supersede on your own signal
  /// rather than waiting for a cancelled response that will never arrive.
  ({int id, Future<dynamic> response}) callCancelable(
    String method,
    Map<String, dynamic> params,
  ) {
    final id = _nextId++;
    return (id: id, response: _send(id, method, params));
  }

  Future<dynamic> _send(int id, String method, Map<String, dynamic> params) async {
    if (_process == null) {
      await start();
    }
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      await _readyCompleter!.future;
    }
    if (_process == null) {
      throw RpcException('START_FAILED', 'Failed to start sidecar process', RpcRetryMode.auto);
    }

    final completer = Completer<dynamic>();
    _pending[id] = completer;

    final msg = jsonEncode({'id': id, 'method': method, 'params': params});
    _process!.stdin.writeln(msg);

    return completer.future;
  }

  void cancel(int id) {
    if (_process == null) return;
    if (_pending.containsKey(id)) {
      _pending.remove(id);
      final msg = jsonEncode({
        'method': r'$cancel',
        'params': {'id': id}
      });
      _process!.stdin.writeln(msg);
    }
  }

  /// [killForTest], but waits for the process to actually be gone.
  ///
  /// **`killForTest` signals and returns; it does not wait.** A `setUp` that
  /// kills the previous sidecar and immediately starts the next one races
  /// Windows finishing the teardown of the old process's pipes, and
  /// `Process.start` then fails with `SocketException: Write failed (OS Error:
  /// The pipe is being closed, errno = 232)`. That failure surfaces as an
  /// unhandled async error rather than out of the `start()` future, so it fails
  /// **whichever test happens to be running** — it looked for a while like a
  /// flaky double-click, and no amount of retrying around `start()` caught it.
  ///
  /// Awaiting `exitCode` is the fix a fixed sleep was standing in for: fast when
  /// the process dies quickly, patient when the machine is loaded.
  Future<void> killForTestAndWait() async {
    final process = _process;
    killForTest();
    if (process == null) return;
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on Object {
      // A process that will not report its exit is not worth failing a suite
      // over; the caller's next `start()` will say so far more clearly.
    }
  }

  void killForTest() {
    _isDisposed = true; // Prevent handleExit from doing anything
    _process?.kill();
    _process = null;
    _pending.clear();
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(RpcException('KILLED', 'Killed for test', RpcRetryMode.no));
    }
    _readyCompleter = null;
    _startFuture = null;
    _handlerChain = Future<void>.value();
    capabilities = null;
    mockCommand = null;
    _isFatalError = false;
    _isDisposed = false; // Reset for next test
  }
}


