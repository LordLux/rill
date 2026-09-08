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

  final library = libass.ass_library_init();
  final renderer = libass.ass_renderer_init(library);
  libass.ass_set_frame_size(renderer, 1920, 1080);
  
  final defaultFont = 'Arial'.toNativeUtf8();
  final defaultFamily = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(renderer, defaultFont, defaultFamily, 1, nullptr, 1);

  final track = libass.ass_new_track(library);
  final assData = '''
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,2,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello
'''.toNativeUtf8();

  libass.ass_process_data(track, assData, assData.length);
  
  final changePtr = malloc<Int32>();
  final imagePtr = libass.ass_render_frame(renderer, track, 2000, changePtr); // 2 seconds in
  
  Pointer<ASS_Image> current = imagePtr;
  while (current != nullptr) {
    final img = current.ref;
    print('Image at ' + img.dst_x.toString() + ',' + img.dst_y.toString() + ' size ' + img.w.toString() + 'x' + img.h.toString() + ' color=' + img.color.toRadixString(16));
    current = img.next;
  }
  
  print('Done!');
}
