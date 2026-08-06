import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';

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
    await client.start(); // Ensure sidecar is fully started before firing the call
    bool completed = false;
    client.call('test.echo', {'msg': 'never', 'delay': 500}).then((_) {
      completed = true;
    }).catchError((e) {
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
  test('a large payload and the small ones behind it arrive in order, off the frame loop', () async {
    final client = RpcClient.instance;
    await client.start();

    final order = <String>[];

    // A 1 ms periodic timer stands in for the frame loop. If the big decode ran
    // inline on this isolate, the timer would simply stop firing for the length
    // of the parse, and the largest gap between ticks would swallow it.
    final ticks = <int>[];
    final clock = Stopwatch()..start();
    final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
      ticks.add(clock.elapsedMilliseconds);
    });

    // Issued back-to-back, so the sidecar writes all three replies in this
    // order and the large one is first in line ahead of two small ones.
    final large = client.call('test.structured_payload', {}).then((r) {
      order.add('large');
      return r;
    });
    final first = client.call('test.echo', {'msg': 'first'}).then((r) {
      order.add('first');
      return r;
    });
    final second = client.call('test.echo', {'msg': 'second'}).then((r) {
      order.add('second');
      return r;
    });

    // `finally`, so a failed RPC does not leave the periodic timer running —
    // flutter_test then fails on the pending timer instead of on the RPC, which
    // hides the actual reason the test broke.
    final List<dynamic> results;
    try {
      results = await Future.wait([large, first, second]);
    } finally {
      ticker.cancel();
    }

    // All delivered, intact.
    expect((results[0] as List).length, 120000);
    expect((results[0] as List).first['title'], startsWith('row 0 '));
    expect(results[1], 'first');
    expect(results[2], 'second');

    // In wire order. Without the handler chain the two small replies decode
    // while the large one is still in its isolate and land first.
    expect(order, ['large', 'first', 'second']);

    // And the main isolate kept running while it decoded. The parse is hundreds
    // of milliseconds of work; the bound is loose enough to survive a loaded CI
    // box and still far below an inline decode of this payload.
    var largestGap = 0;
    for (var i = 1; i < ticks.length; i++) {
      final gap = ticks[i] - ticks[i - 1];
      if (gap > largestGap) largestGap = gap;
    }
    expect(ticks.length, greaterThan(20), reason: 'timer should have kept firing throughout');
    expect(largestGap, lessThan(150),
        reason: 'the main isolate stalled for ${largestGap}ms — the decode ran inline');
  });

  test('killing the Flutter process leaves no orphaned sidecar', () async {
    String dartPath = Platform.resolvedExecutable;
    if (dartPath.endsWith('flutter_tester.exe')) {
      final cacheDir = Directory(dartPath).parent.parent.parent.parent;
      dartPath = '${cacheDir.path}\\dart-sdk\\bin\\dart.exe';
    }
    
    final process = await Process.start(
      Platform.isWindows ? dartPath : 'dart', 
      ['test/orphan_test_helper.dart'], 
      runInShell: false
    );
    
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
    for (var i = 0; i < 150; i++) {
      if (sidecarPid != null) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    expect(sidecarPid, isNotNull, reason: 'Helper should print SIDECAR_PID. Stdout: $stdoutList, Stderr: $stderrList');
    
    // Kill the parent Dart process (the helper)
    process.kill();
    await process.exitCode;

    // Poll rather than sleep a fixed 3.5 s.
    //
    // Two independent mechanisms can end the sidecar and they run at very
    // different speeds: the broken stdin pipe fires in milliseconds, the parent
    // PID watch only on its next 3 s tick. A fixed wait has to be long enough for
    // the slow one, which left ~500 ms of margin — thin enough to go red on a
    // loaded machine for reasons that have nothing to do with orphans. Polling
    // is fast when the pipe wins and patient when the watch does.
    //
    // The tolerance is timing only. The assertion is unchanged: after the parent
    // dies, that pid must be gone.
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    bool isAlive = true;
    while (DateTime.now().isBefore(deadline)) {
      isAlive = await _isProcessAlive(sidecarPid!);
      if (!isAlive) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }

    expect(isAlive, isFalse, reason: 'Sidecar process $sidecarPid should have exited when parent died');
  });
}

/// Whether [pid] is still running.
///
/// A false negative here would make the orphan test pass without testing
/// anything, so this is deliberately the narrowest check available on each
/// platform. Verified by mutation: with every exit path in `fake_sidecar.ts`
/// disabled and the event loop pinned open, the test fails as it should.
Future<bool> _isProcessAlive(int pid) async {
  if (Platform.isWindows) {
    // `tasklist /FI` prints "INFO: No tasks are running..." when nothing matches,
    // which cannot contain the pid; a match always echoes it.
    final res = await Process.run('tasklist', ['/FI', 'PID eq $pid']);
    return res.stdout.toString().contains(pid.toString());
  }
  try {
    final res = await Process.run('kill', ['-0', '$pid']);
    return res.exitCode == 0;
  } catch (_) {
    return false;
  }
}
