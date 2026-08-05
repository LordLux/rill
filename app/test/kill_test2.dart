// ignore_for_file: avoid_print
// A hand-run script for reproducing the orphan case, not a test. Its output is
// for whoever runs it.

import 'dart:io';

void main() async {
  final process = await Process.start('dart', ['test/orphan_test_helper.dart'], runInShell: true);
  await Future.delayed(Duration(seconds: 2));
  print('Helper PID: ${process.pid}');
  process.kill();
  await Future.delayed(Duration(seconds: 2));
}
