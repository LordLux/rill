// ignore_for_file: avoid_print

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'ass_binding.dart';

void _setEnvVar(String name, String value) {
  try {
    final msvcrt = DynamicLibrary.open('msvcrt.dll');
    final putenv = msvcrt.lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)>('_putenv_s');
    
    final namePtr = name.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    putenv(namePtr, valuePtr);
    malloc.free(namePtr);
    malloc.free(valuePtr);
  } catch (e) {
    print('Failed to set env var via msvcrt: $e');
  }
}

void _addDllDirectory(String path) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final setDllDir = kernel32.lookupFunction<
        Int32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    
    final pathPtr = path.toNativeUtf16();
    setDllDir(pathPtr);
    malloc.free(pathPtr);
  } catch (e) {
    print('Failed to set DLL directory: $e');
  }
}

void main() {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  _setEnvVar('FONTCONFIG_PATH', r'C:\msys64\msys64\mingw64\etc\fonts');
  _setEnvVar('FONTCONFIG_FILE', r'C:\msys64\msys64\mingw64\etc\fonts\fonts.conf');

  final dllPath = r'C:\msys64\msys64\mingw64\bin\libass-9.dll';
  final dylib = DynamicLibrary.open(dllPath);
  final libass = LibAssBindings(dylib);

  print('Calling ass_library_init...');
  final library = libass.ass_library_init();
  print('Result: \$library');

  print('Calling ass_renderer_init...');
  // ignore: unused_local_variable
  final renderer = libass.ass_renderer_init(library);
  print('Result: \$renderer');
  
  print('All good. No aborts!');
}
