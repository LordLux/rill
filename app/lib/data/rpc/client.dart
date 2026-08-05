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

  String _findProjectRoot() {
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      if (Directory('${dir.path}/sidecar').existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return Directory.current.path; // fallback
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

  Future<void> _startInternal() async {
    _readyCompleter = Completer<void>();
    final root = _findProjectRoot();

    try {
      // A mock is always driven through bun — the fakes are .ts sources.
      final compiled = mockCommand == null ? _compiledSidecar(root) : null;
      final executable = compiled?.path ?? 'bun';
      final command = compiled != null
          ? const <String>[]
          : (mockCommand ?? ['run', 'sidecar/src/main.ts']);

      _process = await Process.start(executable, command, workingDirectory: root, environment: {
        'FLUTTER_PARENT_PID': pid.toString(),
      });

      _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
        _handleLine,
        onDone: _handleExit,
        onError: (e) => _handleExit(),
      );

      _process!.stderr.transform(utf8.decoder).listen((line) {
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
      _handleExit();
      if (e is RpcException && e.retry == RpcRetryMode.no) {
        rethrow;
      }
    } finally {
      _startFuture = null;
    }
  }

  void _handleLine(String line) async {
    if (line.trim().isEmpty) return;
    try {
      final msg = await Isolate.run(() => jsonDecode(line) as Map<String, dynamic>);
      
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

  void _handleExit() {
    if (_isDisposed) return;
    if (_process == null) return; // Means killForTest() was called
    _process = null;
    
    final error = RpcException('UPSTREAM_ERROR', 'Sidecar exited', RpcRetryMode.auto);
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
    capabilities = null;
    mockCommand = null;
    _isFatalError = false;
    _isDisposed = false; // Reset for next test
  }
}


