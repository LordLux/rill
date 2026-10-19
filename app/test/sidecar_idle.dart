/// Waiting for the fake sidecar, in real time, until it has answered what it was
/// asked — instead of a fixed 400 ms.
///
/// **Why a fixed wait was not enough (todo 94).** A test that hands the sidecar a
/// request and then `runAsync`-waits 400 ms before `pumpAndSettle` passes while
/// the sidecar answers inside that window, and fails when it does not: the page is
/// still showing a loading indicator, which animates until the answer arrives, so
/// `pumpAndSettle` never settles and times out. Measured 2026-10-19 in
/// `scrubber_chapters_widget_test.dart` — `pumpAndSettle timed out` from
/// `settleReal`. Whether the sidecar is quick enough is a property of how loaded
/// the machine is, not of the code under test.
///
/// **Frames, not `pumpAndSettle`, while a call is out,** for exactly that reason;
/// and no fake time passes while waiting (`pump()` with no duration), so a timer a
/// test is watching is not advanced by how slow the sidecar happens to be.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';

/// Waits, pumping frames, until no call is outstanding. For a page that never
/// stops animating while it loads, where `pumpAndSettle` is the wrong tool.
Future<void> waitForSidecar(WidgetTester tester, {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (RpcClient.instance.pendingCallCount > 0 && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

/// Waits until no call is outstanding, then settles the frames once.
///
/// **Once, not until quiet.** Settling can itself start another call (the
/// captions list, after the first frames of a playing video), and waiting for
/// that one too changed what `scrubber_chapters_widget_test.dart`'s audio-only and
/// vertical-video tests saw: they ran with that call still in flight. So this
/// differs from the fixed wait it replaces only when a call was still out at the
/// moment the wait ended, which is the case that fails.
Future<void> settleWithSidecar(WidgetTester tester, {Duration timeout = const Duration(seconds: 20)}) async {
  await waitForSidecar(tester, timeout: timeout);
  await tester.pumpAndSettle();
}
