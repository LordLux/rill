// ignore_for_file: avoid_print

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:io';

void main() {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final setDllDir = kernel32.lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    final dirPtr = ('${Directory.current.parent.path}\\scratch\\dll_test').toNativeUtf16();
    setDllDir(dirPtr);

    final path = '${Directory.current.parent.path}\\scratch\\dll_test\\libass-9.dll';
    // ignore: unused_local_variable
    final lib = DynamicLibrary.open(path);
    print('Loaded successfully!');
  } catch (e) {
    print('Failed: $e');
  }
}
