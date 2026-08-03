import 'package:native_youtube/data/rpc/client.dart';
import 'dart:io';

void main() async {
  print('HELPER STARTED');
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  try {
    await RpcClient.instance.start();
    print('SIDECAR_PID:${RpcClient.instance.processId}');
  } catch (e, st) {
    print('HELPER ERROR: $e');
    print(st);
  }
  // Stay alive until killed by the test
  await Future.delayed(const Duration(hours: 1));
}
