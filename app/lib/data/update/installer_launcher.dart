import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Checks the installer once more and starts it, outside the launcher's job
/// object (architecture.md §2.14).
///
/// The file is opened without `FILE_SHARE_WRITE` first and held until the
/// process exists, so nothing can rewrite it between the check and the start.
/// Returns the installer's pid; throws [InstallerLaunchException] instead of
/// starting anything that does not verify.
Future<int> launchVerifiedInstaller({
  required File installer,
  required List<String> arguments,
  required Future<bool> Function(File file) verify,
}) async {
  final path = installer.absolute.path;
  final lock = _openDenyingWrites(path);
  try {
    if (!await verify(installer)) {
      throw const InstallerLaunchException('the installer changed after it was verified');
    }
    return _start(path, arguments);
  } finally {
    CloseHandle(lock);
  }
}

class InstallerLaunchException implements Exception {
  const InstallerLaunchException(this.message);
  final String message;
  @override
  String toString() => 'InstallerLaunchException: $message';
}

int _openDenyingWrites(String path) {
  final native = path.toNativeUtf16();
  try {
    final handle = CreateFile(native, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
      throw InstallerLaunchException('could not lock the installer (error ${GetLastError()})');
    }
    return handle;
  } finally {
    free(native);
  }
}

int _start(String path, List<String> arguments) {
  // The launcher's job allows breakaway; a process started some other way (a
  // debug run inside a terminal's job, say) may sit in one that does not, and
  // there the installer outliving us is that job's business, not ours.
  const detached = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;
  final pid = _create(path, arguments, detached | CREATE_BREAKAWAY_FROM_JOB);
  if (pid != null) return pid;
  final error = GetLastError();
  if (error == ERROR_ACCESS_DENIED) {
    stderr.writeln('rill update: breakaway refused, starting the installer inside the current job');
    final fallback = _create(path, arguments, detached);
    if (fallback != null) return fallback;
  }
  throw InstallerLaunchException('could not start the installer (error ${GetLastError()})');
}

int? _create(String path, List<String> arguments, int flags) {
  final commandLine = [_quote(path), ...arguments].join(' ').toNativeUtf16();
  final startup = calloc<STARTUPINFO>()..ref.cb = sizeOf<STARTUPINFO>();
  final info = calloc<PROCESS_INFORMATION>();
  try {
    // bInheritHandles FALSE: the installer must not hold the launcher's log pipe
    // open, or the launcher waits out its drain timeout on it (§2.11).
    final ok = CreateProcess(nullptr, commandLine, nullptr, nullptr, FALSE, flags, nullptr, nullptr, startup, info);
    if (ok == 0) return null;
    CloseHandle(info.ref.hThread);
    CloseHandle(info.ref.hProcess);
    return info.ref.dwProcessId;
  } finally {
    free(commandLine);
    free(startup);
    free(info);
  }
}

String _quote(String value) => '"$value"';
