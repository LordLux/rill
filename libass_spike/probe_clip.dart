// Probe: where does libass actually clip, and what widens the clip rect?
// Run: dart run probe_clip.dart   (from libass_spike/)
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'lib/ass_binding.dart';

void _addDllDirectory(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDir = kernel32.lookupFunction<Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final p = path.toNativeUtf16();
  setDllDir(p);
  malloc.free(p);
}

String _header(int resX, int resY) => '''
[Script Info]
ScriptType: v4.00+
PlayResX: $resX
PlayResY: $resY
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,2,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

late final LibAssBindings libass;
late final Pointer<ASS_Library> lib;
late final void Function(Pointer<ASS_Renderer>, int, int) assSetStorageSize;

class Extent {
  double minX = double.infinity, minY = double.infinity;
  double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  int count = 0;
  @override
  String toString() => count == 0
      ? '<no images>'
      : 'RAW x[${minX.toStringAsFixed(0)}..${maxX.toStringAsFixed(0)}] '
          'y[${minY.toStringAsFixed(0)}..${maxY.toStringAsFixed(0)}] '
          'w=${(maxX - minX).toStringAsFixed(0)} h=${(maxY - minY).toStringAsFixed(0)} n=$count';
}

/// Renders one dialogue and reports the union bbox in raw frame pixels.
Extent render(
  String dialogueText, {
  required int frameW,
  required int frameH,
  int mt = 0,
  int mb = 0,
  int ml = 0,
  int mr = 0,
  int useMargins = 0,
  int? storageW,
  int resX = 1920,
  int resY = 1080,
}) {
  final r = libass.ass_renderer_init(lib);
  libass.ass_set_frame_size(r, frameW, frameH);
  libass.ass_set_margins(r, mt, mb, ml, mr);
  libass.ass_set_use_margins(r, useMargins);
  if (storageW != null) assSetStorageSize(r, storageW, 1080);
  final f1 = 'Arial'.toNativeUtf8();
  final f2 = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(r, f1, f2, 1, nullptr, 1);
  malloc.free(f1);
  malloc.free(f2);

  final t = libass.ass_new_track(lib);
  final src =
      '${_header(resX, resY)}\nDialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,$dialogueText\n';
  final data = src.toNativeUtf8();
  libass.ass_process_data(t, data, data.length);
  malloc.free(data);

  final ch = malloc<Int32>();
  var img = libass.ass_render_frame(r, t, 2000, ch);
  malloc.free(ch);

  final e = Extent();
  while (img != nullptr) {
    final i = img.ref;
    if (i.w > 0 && i.h > 0) {
      final x = i.dst_x.toDouble();
      final y = i.dst_y.toDouble();
      if (x < e.minX) e.minX = x;
      if (y < e.minY) e.minY = y;
      if (x + i.w > e.maxX) e.maxX = x + i.w.toDouble();
      if (y + i.h > e.maxY) e.maxY = y + i.h.toDouble();
      e.count++;
    }
    img = i.next;
  }
  libass.ass_free_track(t);
  libass.ass_renderer_done(r);
  return e;
}

void main() {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  final dylib =
      DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll');
  libass = LibAssBindings(dylib);
  assSetStorageSize = dylib.lookupFunction<
      Void Function(Pointer<ASS_Renderer>, Int32, Int32),
      void Function(Pointer<ASS_Renderer>, int, int)>('ass_set_storage_size');

  lib = libass.ass_library_init();

  const long = 'THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG';

  print('== ref: centred at 960, frame 1920x1080, no margins ==');
  print('  ${render("{\\q2\\an5\\pos(960,540)}$long", frameW: 1920, frameH: 1080)}');

  print('\n== A. frame 1920x1080, no margins, pos(1800,540) ==');
  print('  ${render("{\\q2\\an5\\pos(1800,540)}$long", frameW: 1920, frameH: 1080)}');

  print('\n== B. frame 3920x3080, margins 1000, um=1, pos(1800,540) ==');
  print('  ${render("{\\q2\\an5\\pos(1800,540)}$long", frameW: 3920, frameH: 3080, mt: 1000, mb: 1000, ml: 1000, mr: 1000, useMargins: 1)}');
  print('  centred ctrl pos(960,540):');
  print('  ${render("{\\q2\\an5\\pos(960,540)}$long", frameW: 3920, frameH: 3080, mt: 1000, mb: 1000, ml: 1000, mr: 1000, useMargins: 1)}');

  print('\n== C. frame 3920x3080, NO margins, pos(1800,540) ==');
  print('  ${render("{\\q2\\an5\\pos(1800,540)}$long", frameW: 3920, frameH: 3080)}');
  print('  centred ctrl pos(960,540):');
  print('  ${render("{\\q2\\an5\\pos(960,540)}$long", frameW: 3920, frameH: 3080)}');

  print('\n== D. frame 3920x3080, NEGATIVE margins -1000, pos(1800,540) ==');
  print('  ${render("{\\q2\\an5\\pos(1800,540)}$long", frameW: 3920, frameH: 3080, mt: -1000, mb: -1000, ml: -1000, mr: -1000)}');
  print('  centred ctrl pos(960,540):');
  print('  ${render("{\\q2\\an5\\pos(960,540)}$long", frameW: 3920, frameH: 3080, mt: -1000, mb: -1000, ml: -1000, mr: -1000)}');

  print('\n== E. PlayRes 3920x3080 in the SCRIPT, frame 3920x3080, pos(2800,1540) ==');
  print('  ${render("{\\q2\\an5\\pos(2800,1540)}$long", frameW: 3920, frameH: 3080, resX: 3920, resY: 3080)}');

  libass.ass_library_done(lib);
  print('\nDone.');
}
