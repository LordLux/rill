// Probe 4: does repositionScript() move a line by exactly the requested delta?
//
// Renders each event, applies the shift, renders again, and checks the bounding
// box moved by the shift and nothing else. Runs through padScript() both times,
// i.e. exactly the path the app takes on drag-end.
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'lib/ass_binding.dart';
import 'lib/ass_padding.dart';
import 'lib/ass_reposition.dart';

void _addDllDirectory(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDir = kernel32.lookupFunction<Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final p = path.toNativeUtf16();
  setDllDir(p);
  malloc.free(p);
}

const _head = '''
[Script Info]
ScriptType: v4.00+
WrapStyle: 0
ScaledBorderAndShadow: yes
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2.5,0,2,60,60,60,1
Style: Top,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2.5,0,8,60,60,60,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

late final LibAssBindings libass;
late final Pointer<ASS_Library> lib;

class Box {
  final double x0, y0, x1, y1;
  final int n;
  const Box(this.x0, this.y0, this.x1, this.y1, this.n);
  static const none = Box(0, 0, 0, 0, 0);
  @override
  String toString() => n == 0
      ? '<none>'
      : '[${x0.toStringAsFixed(0)},${y0.toStringAsFixed(0)}'
          '..${x1.toStringAsFixed(0)},${y1.toStringAsFixed(0)}]';
}

Box renderBox(String script, int timeMs) {
  final padded = padScript(script, padX: 960, padY: 540);
  final r = libass.ass_renderer_init(lib);
  libass.ass_set_frame_size(r, padded.frameWidth, padded.frameHeight);
  libass.ass_set_margins(r, 0, 0, 0, 0);
  libass.ass_set_use_margins(r, 0);
  libass.ass_set_pixel_aspect(r, 1.0);
  final f1 = 'Arial'.toNativeUtf8();
  final f2 = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(r, f1, f2, 1, nullptr, 1);
  malloc.free(f1);
  malloc.free(f2);

  final t = libass.ass_new_track(lib);
  final data = padded.source.toNativeUtf8();
  libass.ass_process_data(t, data, data.length);
  malloc.free(data);

  final ch = malloc<Int32>();
  var img = libass.ass_render_frame(r, t, timeMs, ch);
  malloc.free(ch);

  double x0 = double.infinity, y0 = double.infinity;
  double x1 = double.negativeInfinity, y1 = double.negativeInfinity;
  var n = 0;
  while (img != nullptr) {
    final i = img.ref;
    if (i.w > 0 && i.h > 0) {
      final x = (i.dst_x - padded.padX).toDouble();
      final y = (i.dst_y - padded.padY).toDouble();
      if (x < x0) x0 = x;
      if (y < y0) y0 = y;
      if (x + i.w > x1) x1 = x + i.w;
      if (y + i.h > y1) y1 = y + i.h;
      n++;
    }
    img = i.next;
  }
  libass.ass_free_track(t);
  libass.ass_renderer_done(r);
  return n == 0 ? Box.none : Box(x0, y0, x1, y1, n);
}

var failures = 0;

void check(String label, String dialogue, double sdx, double sdy,
    {int timeMs = 2000}) {
  final before = renderBox('$_head$dialogue\n', timeMs);
  final moved = repositionScript('$_head$dialogue\n', sdx, sdy);
  final after = renderBox(moved, timeMs);

  const tol = 1.5; // libass rounds to whole pixels
  final ok = after.n == before.n &&
      (after.x0 - (before.x0 + sdx)).abs() <= tol &&
      (after.y0 - (before.y0 + sdy)).abs() <= tol &&
      (after.x1 - (before.x1 + sdx)).abs() <= tol &&
      (after.y1 - (before.y1 + sdy)).abs() <= tol;
  if (!ok) failures++;
  print('${ok ? "  ok  " : "  FAIL"} $label  shift=($sdx,$sdy)');
  print('        before $before  after $after');
  if (!ok) {
    print('        rewritten: '
        '${moved.split("\n").where((l) => l.startsWith("Dialogue")).join("\n                   ")}');
  }
}

void main() {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  final dylib =
      DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll');
  libass = LibAssBindings(dylib);
  lib = libass.ass_library_init();

  const d = 'Dialogue: 0,0:00:00.00,0:00:10.00,';
  const sdx = -180.0;
  const sdy = -90.0;

  print('reposition moves by exactly the delta:');
  check('pos an2 (YouTube shape)',
      '${d}Default,,0,0,0,,{\\an2\\pos(960,1020)}Hello there', sdx, sdy);
  check('no pos, style an2 + margins',
      '${d}Default,,0,0,0,,Auto laid out line', sdx, sdy);
  check('no pos, style an8 (top)', '${d}Top,,0,0,0,,Top aligned line', sdx, sdy);
  check('no pos, \\an7 override',
      '${d}Default,,0,0,0,,{\\an7}Corner aligned', sdx, sdy);
  check('no pos, \\an5 (middle, MarginV unused)',
      '${d}Default,,0,0,0,,{\\an5}Middle aligned', sdx, sdy);
  check('no pos, legacy \\a6 (top centre)',
      '${d}Default,,0,0,0,,{\\a6}Legacy aligned', sdx, sdy);
  check('no pos, event margins',
      '${d}Default,,300,120,240,,Event margins line', sdx, sdy);
  check('no pos, leading override block',
      '${d}Default,,0,0,0,,{\\b1\\c&H00FF00&}Bold green line', sdx, sdy);
  check('move', '${d}Default,,0,0,0,,{\\move(200,800,1700,800)}Travelling', sdx, sdy,
      timeMs: 5000);
  check('pos + org + rotation',
      '${d}Default,,0,0,0,,{\\pos(600,540)\\org(600,540)\\frz45}Spun', sdx, sdy);
  check('pos + rect clip',
      '${d}Default,,0,0,0,,{\\clip(300,300,900,900)\\pos(600,600)}Clipped', sdx, sdy);
  check('pos + vector clip',
      '${d}Default,,0,0,0,,{\\clip(m 300 300 l 900 300 900 900 300 900)\\pos(600,600)}VecClip',
      sdx, sdy);
  check('pos + scaled vector clip',
      '${d}Default,,0,0,0,,{\\clip(2, m 600 600 l 1800 600 1800 1800 600 1800)\\pos(600,600)}VecClip2',
      sdx, sdy);

  print('\nrepeated commits do not accumulate junk:');
  var script = '$_head${d}Default,,0,0,0,,{\\an2\\pos(960,1020)}Drag me\n';
  for (var i = 0; i < 4; i++) {
    script = repositionScript(script, 10, -5);
  }
  final line =
      script.split('\n').firstWhere((l) => l.startsWith('Dialogue')).trim();
  final ok = line.endsWith(r'{\an2\pos(1000,1000)}Drag me');
  if (!ok) failures++;
  print('${ok ? "  ok  " : "  FAIL"} $line');

  libass.ass_library_done(lib);
  print(failures == 0 ? '\nAll checks passed.' : '\n$failures FAILED');
}
