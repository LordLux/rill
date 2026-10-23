import 'dart:io';

import 'package:win32/win32.dart';

/// Ends the process now, instead of `dart:io`'s `exit()`.
///
/// `exit()` goes through the C runtime's exit, and on this app that runs
/// `flutter_inappwebview_windows`'s DLL detach, which releases a Direct3D 11 device;
/// the Intel graphics driver then spins inside that release (a debugger attach,
/// 2026-10-21, `todo.md` 97). A probe that ended with `exit(0)` therefore hung or
/// crashed on its way out and left a crash dump holding the session cookie
/// (`todo.md` 92). `main.cpp` ends the real app the same way, with `TerminateProcess`.
///
/// For the probes and diagnostics that finish by themselves. Anything that must flush
/// does it first: this runs nothing after the call.
Never hardExit(int code) {
  TerminateProcess(GetCurrentProcess(), code);
  exit(code); // Not reached; keeps the return type honest.
}
