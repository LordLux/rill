import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'lib/ass_binding.dart';

void _addDllDirectory(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDir = kernel32.lookupFunction<
      Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final pathPtr = path.toNativeUtf16();
  setDllDir(pathPtr);
  malloc.free(pathPtr);
}

void main() {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  final dllPath = r'C:\msys64\msys64\mingw64\bin\libass-9.dll';
  final dylib = DynamicLibrary.open(dllPath);
  final libass = LibAssBindings(dylib);

  print('Calling ass_library_init...');
  final library = libass.ass_library_init();
  final renderer = libass.ass_renderer_init(library);
  
  final defaultFont = 'Arial'.toNativeUtf8();
  final defaultFamily = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(renderer, defaultFont, defaultFamily, 1, nullptr, 1);
  print('Done!');
}
