import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';

/// `RpcClient._spawn`'s guarded zone (`todo.md` 113).
///
/// The Windows failure it guards — `SocketException: Write failed (OS Error: The pipe is
/// being closed, errno = 232)` — arrives as an unhandled async error, not out of the
/// awaited `Process.start`, so the retry around it never saw it. It could not be made to
/// happen on demand, so these tests *force* it: a starter that raises the same error from a
/// timer, which is an async error with nothing awaiting it, exactly the shape the retry
/// could not catch. Without the guard each test fails with that error as unhandled, which is
/// how the guard was mutation-checked.
void main() {
  final original = RpcClient.processStarter;
  final launched = <Process>[];

  setUp(() async {
    RpcClient.instance.killForTest();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    launched.clear();
  });

  tearDown(() async {
    RpcClient.processStarter = original;
    await RpcClient.instance.killForTestAndWait();
    for (final p in launched) {
      p.kill();
    }
  });

  SocketException pipeClosed() => SocketException(
        'Write failed',
        osError: OSError('The pipe is being closed', 232),
      );

  Future<Process> realStart(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final p = await original(exe, args, workingDirectory: workingDirectory, environment: environment);
    launched.add(p);
    return p;
  }

  test('an async pipe error before the start completes fails that attempt and is retried', () async {
    var calls = 0;
    Process? abandonedProcess;
    RpcClient.processStarter = (exe, args, {workingDirectory, environment}) {
      calls++;
      if (calls == 1) {
        Timer.run(() => throw pipeClosed());
        // The process still arrives, late, after its attempt was abandoned.
        return Future.delayed(
          const Duration(milliseconds: 150),
          () async {
            abandonedProcess = await realStart(exe, args, workingDirectory: workingDirectory, environment: environment);
            return abandonedProcess!;
          },
        );
      }
      return realStart(exe, args, workingDirectory: workingDirectory, environment: environment);
    };

    final reply = await RpcClient.instance.call('test.echo', {'msg': 'hi'});

    expect(reply, 'hi');
    expect(calls, 2, reason: 'the failed attempt is retried once, not more');
    // The abandoned attempt's process arrives after the retry succeeded; it must not be leaked.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(abandonedProcess, isNotNull);
    await abandonedProcess!.exitCode.timeout(const Duration(seconds: 10));
  });

  test('an async pipe error after the start completes is logged, not raised on whatever is running', () async {
    var calls = 0;
    RpcClient.processStarter = (exe, args, {workingDirectory, environment}) async {
      calls++;
      final p = await realStart(exe, args, workingDirectory: workingDirectory, environment: environment);
      Timer(const Duration(milliseconds: 50), () => throw pipeClosed());
      return p;
    };

    final reply = await RpcClient.instance.call('test.echo', {'msg': 'hi'});
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(reply, 'hi');
    expect(calls, 1, reason: 'a process that started is kept');
  });

  test('a stdin write that fails asynchronously, as the real pipe does, is not raised on whatever is running', () async {
    var calls = 0;
    RpcClient.processStarter = (exe, args, {workingDirectory, environment}) async {
      calls++;
      final real = await realStart(exe, args, workingDirectory: workingDirectory, environment: environment);
      // Built here, inside the guarded zone, as the real `Process.stdin` is.
      return _WriteFailsProcess(real, IOSink(_FailingConsumer(pipeClosed())));
    };

    // The write fails, so no reply ever comes: the call is allowed to time out. What is
    // under test is where the error goes, and flutter_test fails the test if it is unhandled.
    final reply = RpcClient.instance.call('test.echo', {'msg': 'hi'});
    await expectLater(reply.timeout(const Duration(seconds: 2)), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(calls, 1);
  });
}

/// A pipe whose consumer fails the way a closing Windows pipe does: asynchronously, on write.
/// A hand-built [IOSink] approximates the real pipe's sink, it is not the same object.
class _FailingConsumer implements StreamConsumer<List<int>> {
  _FailingConsumer(this.error);
  final Object error;

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      Future<void>.delayed(const Duration(milliseconds: 10), () => throw error);

  @override
  Future<dynamic> close() => Future<void>.value();
}

class _WriteFailsProcess implements Process {
  _WriteFailsProcess(this._real, this.stdin);
  final Process _real;

  @override
  final IOSink stdin;
  @override
  Stream<List<int>> get stdout => _real.stdout;
  @override
  Stream<List<int>> get stderr => _real.stderr;
  @override
  Future<int> get exitCode => _real.exitCode;
  @override
  int get pid => _real.pid;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => _real.kill(signal);
}
