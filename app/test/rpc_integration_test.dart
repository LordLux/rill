import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';

void main() {
  test('Integration: auth.verify and playback.open end to end', () async {
    final client = RpcClient.instance;
    // Real sidecar command
    client.mockCommand = null;

    final authRes = await client.call('auth.verify', {});
    expect(authRes, isA<Map<String, dynamic>>());
    expect(authRes['state'], isNotNull);

    final pbRes = await client.call('playback.open', {'videoId': 'aqz-KE-bpKQ'});
    expect(pbRes, isA<Map<String, dynamic>>());
    expect(pbRes['sessionId'], isNotNull);
    expect(pbRes['variants'], isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Integration: a client bug arrives as BAD_REQUEST with retry no', () async {
    final client = RpcClient.instance;
    client.mockCommand = null;

    // Both halves of protocol.md §4's BAD_REQUEST row, across the real boundary:
    // an unknown method, and params that fail validation. `retry: no` is the part
    // that matters — as UPSTREAM_ERROR (`auto`) the app backed off and retried
    // four times over a request that can never succeed.
    for (final call in [
      ('does.not.exist', <String, dynamic>{}),
      ('playback.open', <String, dynamic>{}),
    ]) {
      final error = await client.call(call.$1, call.$2).then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      expect(error, isA<RpcException>(), reason: '${call.$1} should have failed');
      final rpc = error! as RpcException;
      expect(rpc.code, 'BAD_REQUEST', reason: '${call.$1} returned ${rpc.code}');
      expect(rpc.retry, RpcRetryMode.no, reason: 'a client bug must never be retried');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
