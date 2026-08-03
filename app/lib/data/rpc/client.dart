import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
  
  Map<String, dynamic>? capabilities;
  Completer<void>? _readyCompleter;
  
  final bool _isDisposed = false;
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
      final command = mockCommand ?? ['run', 'sidecar/src/main.ts'];
      _process = await Process.start('bun', command, workingDirectory: root);

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
      _handleExit();
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
          stderr.writeln('FATAL: Protocol version mismatch. Expected 1, got $version');
          exit(1);
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
    _process = null;
    
    final error = RpcException('UPSTREAM_ERROR', 'Sidecar exited', RpcRetryMode.auto);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(error);
    }

    Timer(Duration(milliseconds: _restartBackoffMs), () {
      _restartBackoffMs = (_restartBackoffMs * 2).clamp(1000, 30000);
      start();
    });
  }

  Future<dynamic> call(String method, Map<String, dynamic> params) async {
    if (_process == null) {
      await start();
    }
    // Wait for ready event if starting up
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      await _readyCompleter!.future;
    }
    
    final id = _nextId++;
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
}
