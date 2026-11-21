import 'dart:ffi';
import 'dart:io';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' show CloseHandle, GetCurrentProcess, OpenProcessToken, TOKEN_ADJUST_PRIVILEGES, TOKEN_QUERY;

/// What the sleep timer does after it has paused (Task 38, `architecture.md` §2.18).
enum SleepEndAction {
  nothing('Do nothing'),
  closeRill('Close Rill'),
  sleep('Sleep'),
  hibernate('Hibernate'),
  shutDown('Shut down'),
  restart('Restart');

  const SleepEndAction(this.label);

  final String label;

  /// The four that act on the machine, not the app: each waits out the 30 s countdown first.
  bool get isSystem => this == sleep || this == hibernate || this == shutDown || this == restart;
}

/// The end actions, behind one interface so a test can use a fake and nothing in a test can turn
/// the machine off.
abstract class SystemPower {
  /// `IsPwrSuspendAllowed`: whether the machine can sleep at all. *Sleep* is not offered otherwise.
  bool get canSleep;

  /// `IsPwrHibernateAllowed`: whether hibernation is enabled. *Hibernate* is not offered otherwise.
  bool get canHibernate;

  /// Runs [action]. Returns whether Windows took it; false is logged, never thrown, because the
  /// timer has already done its part (paused) and there is nothing better to do than say so.
  Future<bool> run(SleepEndAction action);
}

/// The real one, through FFI like `hard_exit.dart` — `package:win32` binds none of these.
///
/// **Never `EWX_FORCE` or `EWX_FORCEIFHUNG`.** An app holding unsaved work must be able to stop a
/// shutdown, and Windows then shows its own "apps are preventing shutdown" screen. Nor does
/// `SetSuspendState` get its `bForce`: it is ignored since Vista, and asking would read as intent.
/// Neither needs elevation: `SE_SHUTDOWN_NAME` is held, disabled, by every interactive user, and is
/// only switched on for this process.
class Win32SystemPower implements SystemPower {
  Win32SystemPower();

  static final DynamicLibrary _powrprof = DynamicLibrary.open('powrprof.dll');
  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

  static final int Function() _isPwrSuspendAllowed = _powrprof.lookupFunction<Uint8 Function(), int Function()>('IsPwrSuspendAllowed');
  static final int Function() _isPwrHibernateAllowed = _powrprof.lookupFunction<Uint8 Function(), int Function()>('IsPwrHibernateAllowed');
  static final int Function(int hibernate, int force, int wakeupEventsDisabled) _setSuspendState =
      _powrprof.lookupFunction<Uint8 Function(Uint8, Uint8, Uint8), int Function(int, int, int)>('SetSuspendState');
  static final int Function(int flags, int reason) _exitWindowsEx = _user32.lookupFunction<Int32 Function(Uint32, Uint32), int Function(int, int)>('ExitWindowsEx');
  static final int Function(Pointer<Utf16> system, Pointer<Utf16> name, Pointer<_Luid> luid) _lookupPrivilegeValue =
      _advapi32.lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<_Luid>), int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<_Luid>)>('LookupPrivilegeValueW');
  static final int Function(int token, int disableAll, Pointer<_TokenPrivileges> state, int length, Pointer<Void> previous, Pointer<Uint32> returned) _adjustTokenPrivileges =
      _advapi32.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<_TokenPrivileges>, Uint32, Pointer<Void>, Pointer<Uint32>),
        int Function(int, int, Pointer<_TokenPrivileges>, int, Pointer<Void>, Pointer<Uint32>)
      >('AdjustTokenPrivileges');

  static const int _ewxReboot = 0x00000002;
  static const int _ewxPowerOff = 0x00000008;

  /// `SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_MINOR_OTHER | SHTDN_REASON_FLAG_PLANNED`: what the
  /// event log records. A timer the viewer set is planned.
  static const int _reasonPlannedOther = 0x80000000;
  static const int _sePrivilegeEnabled = 0x00000002;

  @override
  bool get canSleep => _isPwrSuspendAllowed() != 0;

  @override
  bool get canHibernate => _isPwrHibernateAllowed() != 0;

  @override
  Future<bool> run(SleepEndAction action) async {
    switch (action) {
      case SleepEndAction.nothing:
        return true;
      case SleepEndAction.closeRill:
        // The window's close button's own path (bitsdojo's `CloseWindowButton`), so the session
        // snapshot and the exit run as for any close (`main.cpp`).
        appWindow.close();
        return true;
      case SleepEndAction.sleep:
      case SleepEndAction.hibernate:
        _enableShutdownPrivilege();
        final ok = _setSuspendState(action == SleepEndAction.hibernate ? 1 : 0, 0, 0) != 0;
        if (!ok) stderr.writeln('rill: sleep timer: SetSuspendState(${action.name}) was refused');
        return ok;
      case SleepEndAction.shutDown:
      case SleepEndAction.restart:
        _enableShutdownPrivilege();
        final flags = action == SleepEndAction.restart ? _ewxReboot : _ewxPowerOff;
        final ok = _exitWindowsEx(flags, _reasonPlannedOther) != 0;
        if (!ok) stderr.writeln('rill: sleep timer: ExitWindowsEx(${action.name}) was refused');
        return ok;
    }
  }

  /// Turns `SE_SHUTDOWN_NAME` on for this process's token, which both `SetSuspendState` and
  /// `ExitWindowsEx` require. Judged by what the calls after it return, not by `GetLastError`,
  /// which `installer_launcher.dart` measured unreliable across FFI.
  static void _enableShutdownPrivilege() {
    final token = calloc<IntPtr>();
    final name = 'SeShutdownPrivilege'.toNativeUtf16();
    final privileges = calloc<_TokenPrivileges>();
    try {
      if (OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, token) == 0) {
        stderr.writeln('rill: sleep timer: OpenProcessToken failed');
        return;
      }
      privileges.ref.privilegeCount = 1;
      if (_lookupPrivilegeValue(nullptr, name, Pointer<_Luid>.fromAddress(privileges.address + 4)) == 0) {
        stderr.writeln('rill: sleep timer: LookupPrivilegeValue failed');
        return;
      }
      privileges.ref.attributes = _sePrivilegeEnabled;
      if (_adjustTokenPrivileges(token.value, 0, privileges, 0, nullptr, nullptr) == 0) {
        stderr.writeln('rill: sleep timer: AdjustTokenPrivileges failed');
      }
    } finally {
      if (token.value != 0) CloseHandle(token.value);
      calloc.free(token);
      calloc.free(name);
      calloc.free(privileges);
    }
  }
}

/// `LUID`: two 32-bit halves, not one 64-bit field — the struct is 4-aligned, and inside
/// `TOKEN_PRIVILEGES` it starts at offset 4.
final class _Luid extends Struct {
  @Uint32()
  external int lowPart;
  @Int32()
  external int highPart;
}

/// `TOKEN_PRIVILEGES` with its one `LUID_AND_ATTRIBUTES`, flattened: count at 0, the LUID at 4,
/// the attributes at 12, 16 bytes in all.
final class _TokenPrivileges extends Struct {
  @Uint32()
  external int privilegeCount;
  @Uint32()
  external int luidLowPart;
  @Int32()
  external int luidHighPart;
  @Uint32()
  external int attributes;
}
