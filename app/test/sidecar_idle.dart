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
///
/// **A call a test holds open on purpose is waited for until [sidecarWaitLimit].**
/// The fake's delay tokens (`"foo@250"`), a request about to be cancelled and
/// `!keepalive` all stay outstanding by design, so a test that uses one passes
/// `timeout: Duration.zero` (or calls `pumpAndSettle` itself) instead of paying the
/// limit on every settle.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';

/// Well under the 30 s a test has, and many times what the fake sidecar takes on a
/// loaded machine (hundreds of milliseconds).
const Duration sidecarWaitLimit = Duration(seconds: 8);

/// Let the real (fake) sidecar answer, then settle.
///
/// `testWidgets` runs in a fake-async zone where a real subprocess's I/O never
/// progresses, so a `pump` loop waits forever on a response that cannot arrive;
/// `runAsync` steps outside it for as long as the round trip needs. This is the
/// fixed real-time delay every test had, then [settleWithSidecar]. One definition,
/// so a file cannot keep a copy that waits less.
Future<void> settleReal(WidgetTester tester, [int millis = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: millis)));
  await settleWithSidecar(tester);
}

/// Waits, pumping frames, until no call is outstanding. For a page that never
/// stops animating while it loads, where `pumpAndSettle` is the wrong tool.
Future<void> waitForSidecar(WidgetTester tester, {Duration timeout = sidecarWaitLimit}) async {
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
Future<void> settleWithSidecar(WidgetTester tester, {Duration timeout = sidecarWaitLimit}) async {
  await waitForSidecar(tester, timeout: timeout);
  await tester.pumpAndSettle();
}
