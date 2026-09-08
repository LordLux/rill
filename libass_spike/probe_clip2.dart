// Probe 2: is the crop rect the *content* rect (frame minus margins) or the
// *frame* rect? Asymmetric margins separate the two hypotheses.
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

String render(String text,
    {required int frameW,
    required int frameH,
    int mt = 0,
    int mb = 0,
    int ml = 0,
    int mr = 0,
    int useMargins = 0,
    int resX = 1920,
    int resY = 1080}) {
  final r = libass.ass_renderer_init(lib);
  libass.ass_set_frame_size(r, frameW, frameH);
  libass.ass_set_margins(r, mt, mb, ml, mr);
  libass.ass_set_use_margins(r, useMargins);
  final f1 = 'Arial'.toNativeUtf8();
  final f2 = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(r, f1, f2, 1, nullptr, 1);
  malloc.free(f1);
  malloc.free(f2);

  final t = libass.ass_new_track(lib);
  final src =
      '${_header(resX, resY)}\nDialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,$text\n';
  final data = src.toNativeUtf8();
  libass.ass_process_data(t, data, data.length);
  malloc.free(data);

  final ch = malloc<Int32>();
  var img = libass.ass_render_frame(r, t, 2000, ch);
  malloc.free(ch);

  double minX = double.infinity, maxX = double.negativeInfinity;
  double minY = double.infinity, maxY = double.negativeInfinity;
  int n = 0;
  while (img != nullptr) {
    final i = img.ref;
    if (i.w > 0 && i.h > 0) {
      if (i.dst_x < minX) minX = i.dst_x.toDouble();
      if (i.dst_y < minY) minY = i.dst_y.toDouble();
      if (i.dst_x + i.w > maxX) maxX = (i.dst_x + i.w).toDouble();
      if (i.dst_y + i.h > maxY) maxY = (i.dst_y + i.h).toDouble();
      n++;
    }
    img = i.next;
  }
  libass.ass_free_track(t);
  libass.ass_renderer_done(r);
  if (n == 0) return '<none>';
  return 'x[${minX.toStringAsFixed(0)}..${maxX.toStringAsFixed(0)}] '
      'y[${minY.toStringAsFixed(0)}..${maxY.toStringAsFixed(0)}] '
      'w=${(maxX - minX).toStringAsFixed(0)}';
}

void main() {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  final dylib =
      DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll');
  libass = LibAssBindings(dylib);
  lib = libass.ass_library_init();

  const long = 'THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG'; // 1422px @ scale 1

  // frame 3920 wide, ml=1500 mr=500  =>  content = 1920 px at x offset 1500,
  // content right edge = 3420, frame right edge = 3920.
  print('asymmetric margins: ml=1500 mr=500, content=[1500..3420], frame=[0..3920]');
  print('  RIGHT overflow  pos(1800) -> ideal x[2589..4011]');
  print('    ${render("{\\q2\\an5\\pos(1800,540)}$long", frameW: 3920, frameH: 3080, mt: 1500, mb: 500, ml: 1500, mr: 500)}');
  print('  LEFT  overflow  pos(100)  -> ideal x[889..2311]');
  print('    ${render("{\\q2\\an5\\pos(100,540)}$long", frameW: 3920, frameH: 3080, mt: 1500, mb: 500, ml: 1500, mr: 500)}');
  print('  => content-rect crop predicts x[1500..3420] / x[1500..2311]');
  print('  => frame-rect   crop predicts x[2589..3920] / x[889..2311]');

  print('\nsame, use_margins=1');
  print('    ${render("{\\q2\\an5\\pos(1800,540)}$long", frameW: 3920, frameH: 3080, mt: 1500, mb: 500, ml: 1500, mr: 500, useMargins: 1)}');
  print('    ${render("{\\q2\\an5\\pos(100,540)}$long", frameW: 3920, frameH: 3080, mt: 1500, mb: 500, ml: 1500, mr: 500, useMargins: 1)}');

  // Control: does the padded PlayRes trick keep font size AND allow overflow?
  print('\nPlayRes-pad trick: PlayRes 3920x3080, frame 3920x3080, pos(2800,1540)');
  print('  (== video-space 1800,540 with pad 1000); ideal w=1422');
  print('    ${render("{\\q2\\an5\\pos(2800,1540)}$long", frameW: 3920, frameH: 3080, resX: 3920, resY: 3080)}');
  print('  extreme: pos(3800,1540) -- fully past the video right edge');
  print('    ${render("{\\q2\\an5\\pos(3800,1540)}$long", frameW: 3920, frameH: 3080, resX: 3920, resY: 3080)}');

  libass.ass_library_done(lib);
}
