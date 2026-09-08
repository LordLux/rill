/// `libass-9.dll` resolution, with a fallback for the one process that has no
/// DLLs beside it: `flutter_tester.exe`.
///
/// **The shipping and `flutter run` cases already work and this file changes
/// nothing about them.** `windows/CMakeLists.txt` copies every DLL in
/// `windows/libass_bundle/` next to the built executable, and Windows always
/// searches the *loading application's* directory first — so
/// `DynamicLibrary.open('libass-9.dll')` succeeds on the very first try there,
/// before this file's fallback is ever reached.
///
/// **`flutter test` is different.** It runs inside `flutter_tester.exe`, which
/// lives deep in the Flutter SDK's own cache and has no bundled DLLs anywhere
/// near it — `LibassLayer` used to just give up and disable captions for the
/// whole test process the first time that failed (`_assUnavailable`), which is
/// correct behaviour for a genuinely missing renderer, but wrong here: the DLLs
/// are sitting in the checkout the whole time, just not on Windows' search
/// path. The fix already existed as a throwaway probe pattern
/// (`test/probe_libass_cadence.dart`, `SetDllDirectoryW` before opening); this
/// promotes it into the thing that actually needs it, and it is symlink-free —
/// Windows symlinks need Developer Mode or admin to create, and without
/// `core.symlinks` git stores one as a 20-byte text file, so a clean clone
/// would get a link that silently fails to resolve.
library;

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

/// Opens `libass-9.dll`. On the first failure, tries adding
/// `windows/libass_bundle/`'s absolute path to the process's DLL search path
/// and retries once — the same directory carries libass's own MSYS2
/// dependencies (`libfreetype-6.dll` and the rest), so one `SetDllDirectoryW`
/// call is enough for the whole chain, not just the one named DLL.
///
/// Throws the *first* error when both attempts fail, or when the fallback
/// found nothing to add — that error is the one that actually describes what
/// is missing; a "directory not found" from the fallback search is not.
DynamicLibrary openLibass() {
  try {
    return DynamicLibrary.open('libass-9.dll');
  } on Object catch (firstError) {
    if (!_ensureBundleDirOnSearchPath()) rethrow;
    try {
      return DynamicLibrary.open('libass-9.dll');
    } on Object {
      throw firstError;
    }
  }
}

/// Process-wide and tried at most once: `SetDllDirectoryW` is sticky for the
/// life of the process (and inherited by isolates spawned with `Isolate.run`,
/// which share the OS process), so a later `LibassLayer` mount that hits the
/// same catch block would otherwise repeat a filesystem walk whose answer
/// cannot have changed.
bool _dllDirectoryAdded = false;

bool _ensureBundleDirOnSearchPath() {
  if (_dllDirectoryAdded) return false;
  _dllDirectoryAdded = true;

  final bundleDir = findLibassBundleDir(
    cwd: Directory.current.path,
    hasBundleDir: (path) => File('$path/libass-9.dll').existsSync(),
  );
  if (bundleDir == null) return false;

  _addDllDirectory(bundleDir);
  return true;
}

/// Walks up from [cwd] looking for `windows/libass_bundle` — the same
/// upward-search shape `RpcClient.findSidecarRoot` uses for the sidecar tree,
/// with one deliberate difference: that function also checks beside the
/// running executable, and this one does not.
///
/// It would not help here. `windows/libass_bundle` is a *source-tree* path —
/// CMake flattens its contents directly beside the built exe rather than
/// preserving it as a subdirectory (`windows/CMakeLists.txt`), so no shipped
/// layout ever has one to find beside `Platform.resolvedExecutable`, and a
/// real app run never reaches this function anyway (see the module comment).
/// `Directory.current` is what actually matters: it is reliably the package
/// root (`app/`) under `flutter test`, which is the one case this exists for —
/// `probe_libass_cadence.dart` already relies on that same fact. The upward
/// walk is only insurance against `flutter test` being invoked from a
/// subdirectory of `app/` rather than `app/` itself.
@visibleForTesting
String? findLibassBundleDir({
  required String cwd,
  required bool Function(String path) hasBundleDir,
}) {
  var dir = Directory(cwd);
  for (var i = 0; i < 8; i++) {
    final candidate = '${dir.path}/windows/libass_bundle';
    if (hasBundleDir(candidate)) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void _addDllDirectory(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDirectoryW = kernel32.lookupFunction<Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final pathPtr = path.toNativeUtf16();
  try {
    setDllDirectoryW(pathPtr);
  } finally {
    malloc.free(pathPtr);
  }
}
