/// The real end actions' bindings (Task 38). Every other test uses a fake, so without this a wrong
/// symbol name or signature in `system_power.dart` would surface only when a viewer's timer fired.
///
/// **Nothing here suspends or shuts down the machine:** `SetSuspendState` and `ExitWindowsEx` are
/// resolved, never called. Enabling `SE_SHUTDOWN_NAME` changes this test process's token only.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/system_power.dart';

void main() {
  test('every Win32 function resolves, and the two questions answer', () {
    Win32SystemPower.resolveAll();
    final power = Win32SystemPower();
    expect(power.canSleep, isA<bool>());
    expect(power.canHibernate, isA<bool>());
  });

  test('the shutdown privilege is enabled for this process without elevation', () {
    expect(Win32SystemPower.enableShutdownPrivilegeForTest(), isTrue);
  });
}
