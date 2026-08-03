import 'package:flutter_test/flutter_test.dart';
import 'package:native_youtube/data/rpc/client.dart';

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
  });
}
