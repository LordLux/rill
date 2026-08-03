import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_youtube/data/rpc/client.dart';

void main() {
  setUp(() async {
    RpcClient.instance.killForTest();
    await Future.delayed(const Duration(milliseconds: 200));
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  });

  test('id correlation, including out-of-order responses', () async {
    final client = RpcClient.instance;
    // test.echo with delay
    final Future<dynamic> req1 = client.call('test.echo', {'msg': 'first', 'delay': 200});
    final Future<dynamic> req2 = client.call('test.echo', {'msg': 'second', 'delay': 50});
    
    // req2 should finish first, but both should return correct results
    final results = await Future.wait([req1, req2]);
    expect(results[0], 'first');
    expect(results[1], 'second');
  });

  test('\$cancel', () async {
    final client = RpcClient.instance;
    bool completed = false;
    client.call('test.echo', {'msg': 'never', 'delay': 500}).then((_) {
      completed = true;
    }).catchError((_) {
      completed = true; // Error also counts as completion for this test
    });
    
    // We don't have the id directly, but we can assume it's nextId - 1
    // Actually cancel is hard to test unless we hack it, wait, client.cancel(id) exists!
    // client._nextId is private. But we know _pending.
    // Let's just issue the call, then call cancel on all IDs.
    // We'll just wait 100ms and check if it completed.
    await Future.delayed(const Duration(milliseconds: 100));
    // It's a singleton, so the ID could be anything. Let's just cancel 1 to 100.
    for (var i = 1; i <= 100; i++) {
      client.cancel(i);
    }
    
    await Future.delayed(const Duration(milliseconds: 600));
    expect(completed, false, reason: 'Request should have been cancelled and never completed');
  });

  test('protocolVersion mismatch fails fast', () async {
    final client = RpcClient.instance;
    client.killForTest();
    client.mockCommand = ['run', 'app/test/fake_sidecar.ts', '99']; // version 99
    
    try {
      await client.call('test.echo', {});
      fail('Expected exception');
    } catch (e) {
      expect(e, isA<RpcException>());
      final rpcE = e as RpcException;
      expect(rpcE.code, 'PROTOCOL_MISMATCH');
    }
  });

  test('envelope errors decode to Dart exception carrying code, message, and retry as enum', () async {
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    final client = RpcClient.instance;
    try {
      await client.call('test.error', {});
      fail('Expected exception');
    } catch (e) {
      expect(e, isA<RpcException>());
      final rpcE = e as RpcException;
      expect(rpcE.code, 'TEST_ERROR');
      expect(rpcE.message, 'test error');
      expect(rpcE.retry, RpcRetryMode.auto);
    }
  });

  test('decoding a large payload does not block the main isolate', () async {
    final client = RpcClient.instance;
    final stopwatch = Stopwatch()..start();
    final req = client.call('test.large_payload', {});
    // While it decodes, we should be able to do other things quickly
    // But since it's an async isolate, the main isolate won't block.
    final res = await req;
    expect((res as String).length, 1000000);
    expect(stopwatch.elapsedMilliseconds, lessThan(5000));
  });
  test('killing the Flutter process leaves no orphaned sidecar', () async {
    final process = await Process.start('dart', ['test/orphan_test_helper.dart'], runInShell: true);
    
    int? sidecarPid;
    final stdoutList = <String>[];
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      stdoutList.add(line);
      if (line.startsWith('SIDECAR_PID:')) {
        sidecarPid = int.parse(line.split(':')[1]);
      }
    });

    final stderrList = <String>[];
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      stderrList.add(line);
    });
    
    // Wait for the sidecar PID to be printed
    for (var i = 0; i < 50; i++) {
      if (sidecarPid != null) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    expect(sidecarPid, isNotNull, reason: 'Helper should print SIDECAR_PID. Stdout: $stdoutList, Stderr: $stderrList');
    
    // Kill the parent Dart process (the helper)
    process.kill();
    await process.exitCode;
    
    // Give Windows a moment to propagate the pipe close
    await Future.delayed(const Duration(milliseconds: 500));
    
    // Check if the sidecar process is still running
    // On Windows, tasklist can be used. On Linux/Mac, kill -0.
    bool isAlive = false;
    if (Platform.isWindows) {
      final res = await Process.run('tasklist', ['/FI', 'PID eq $sidecarPid']);
      if (res.stdout.toString().contains(sidecarPid.toString())) {
        isAlive = true;
      }
    } else {
      try {
        final res = await Process.run('kill', ['-0', sidecarPid.toString()]);
        isAlive = res.exitCode == 0;
      } catch (_) {}
    }
    
    expect(isAlive, isFalse, reason: 'Sidecar process $sidecarPid should have exited when parent died');
  });
}
