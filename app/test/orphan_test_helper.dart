// ignore_for_file: avoid_print
// This helper's stdout *is* its interface: rpc_client_test parses SIDECAR_PID
// out of it. stderr would not be read.

import 'package:rill/data/rpc/client.dart';
import 'dart:io';

void main() async {
  print('HELPER STARTED');
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  try {
    await RpcClient.instance.start();
    print('SIDECAR_PID:${RpcClient.instance.processId}');
    await stdout.flush();
  } catch (e, st) {
    print('HELPER ERROR: $e');
    print(st);
    await stdout.flush();
  }
  // Stay alive until killed by the test
  await Future.delayed(const Duration(hours: 1));
}
