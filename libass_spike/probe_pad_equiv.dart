// Probe 3: is padScript() behaviour-preserving?
//
// Renders the same events twice — once unpadded at frame == PlayRes, once
// through padScript() at frame == padded PlayRes — and compares bounding boxes
// after subtracting the pad. Anything that was not being cropped must match
// exactly. Anything that WAS being cropped must get wider.
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'lib/ass_binding.dart';
import 'lib/ass_padding.dart';

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
Style: Boxed,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,3,6,0,2,60,60,60,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

late final LibAssBindings libass;
late final Pointer<ASS_Library> lib;
late final void Function(Pointer<ASS_Renderer>, double) assSetPixelAspect;

class Box {
  final double x0, y0, x1, y1;
  final int n;
  const Box(this.x0, this.y0, this.x1, this.y1, this.n);
  static const none = Box(0, 0, 0, 0, 0);
  @override
  String toString() => n == 0
      ? '<none>'
      : '[${x0.toStringAsFixed(0)},${y0.toStringAsFixed(0)}'
          '..${x1.toStringAsFixed(0)},${y1.toStringAsFixed(0)}] n=$n';
  bool sameAs(Box o) =>
      n == o.n && x0 == o.x0 && y0 == o.y0 && x1 == o.x1 && y1 == o.y1;
}

Box renderBox(String script, int frameW, int frameH, int ox, int oy, int timeMs) {
  final r = libass.ass_renderer_init(lib);
  libass.ass_set_frame_size(r, frameW, frameH);
  libass.ass_set_margins(r, 0, 0, 0, 0);
  libass.ass_set_use_margins(r, 0);
  assSetPixelAspect(r, 1.0);
  final f1 = 'Arial'.toNativeUtf8();
  final f2 = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(r, f1, f2, 1, nullptr, 1);
  malloc.free(f1);
  malloc.free(f2);

  final t = libass.ass_new_track(lib);
  final data = script.toNativeUtf8();
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
      final x = (i.dst_x - ox).toDouble();
      final y = (i.dst_y - oy).toDouble();
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

void check(String label, String dialogue,
    {int timeMs = 2000, bool expectWider = false}) {
  final script = '$_head$dialogue\n';
  final plain = renderBox(script, 1920, 1080, 0, 0, timeMs);
  final padded = padScript(script, padX: 640, padY: 360);
  final withPad = renderBox(padded.source, padded.frameWidth,
      padded.frameHeight, padded.padX, padded.padY, timeMs);

  final same = plain.sameAs(withPad);
  final wider = withPad.n > 0 &&
      plain.n > 0 &&
      (withPad.x1 - withPad.x0) > (plain.x1 - plain.x0);

  final ok = expectWider ? wider : same;
  if (!ok) failures++;
  print('${ok ? "  ok  " : "  FAIL"} $label');
  print('        plain  $plain');
  print('        padded $withPad');
}

void main() {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  final dylib =
      DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll');
  libass = LibAssBindings(dylib);
  assSetPixelAspect = dylib.lookupFunction<
      Void Function(Pointer<ASS_Renderer>, Double),
      void Function(Pointer<ASS_Renderer>, double)>('ass_set_pixel_aspect');
  lib = libass.ass_library_init();

  const d = 'Dialogue: 0,0:00:00.00,0:00:10.00,';
  print('equivalence (padded must match plain exactly):');
  check('plain an2, style margins',
      '${d}Default,,0,0,0,,The quick brown fox jumps over the lazy dog');
  check('an8 top', '${d}Default,,0,0,0,,{\\an8}Top aligned text');
  check('an7 corner', '${d}Default,,0,0,0,,{\\an7}Corner');
  check('event margins override',
      '${d}Default,,300,120,240,,Event level margins here');
  check('pos an2 (YouTube shape)',
      '${d}Default,,0,0,0,,{\\an2\\pos(960,1020)}Hello there');
  check('blur', '${d}Default,,0,0,0,,{\\blur15\\pos(1500,540)}Gaussian');
  check('border + shadow',
      '${d}Default,,0,0,0,,{\\bord10\\shad8\\pos(400,300)}Bordered');
  check('BorderStyle 3 box', '${d}Boxed,,0,0,0,,{\\an2\\pos(960,1020)}Boxed');
  check('rotation with org',
      '${d}Default,,0,0,0,,{\\pos(600,540)\\org(600,540)\\frz45}Spinning');
  check('move (mid-flight)',
      '${d}Default,,0,0,0,,{\\move(200,800,1700,800)}Travelling',
      timeMs: 5000);
  check('rect clip',
      '${d}Default,,0,0,0,,{\\clip(300,300,900,900)\\pos(600,600)}Clipped');
  check('vector clip',
      '${d}Default,,0,0,0,,{\\clip(m 300 300 l 900 300 900 900 300 900)\\pos(600,600)}VecClip');
  check('vector clip, scaled',
      '${d}Default,,0,0,0,,{\\clip(2, m 600 600 l 1800 600 1800 1800 600 1800)\\pos(600,600)}VecClip2');
  check('wrapping long line',
      '${d}Default,,0,0,0,,{\\an2\\pos(960,1020)}${"word " * 40}');
  check('fade', '${d}Default,,0,0,0,,{\\fad(500,500)\\pos(960,600)}Fading',
      timeMs: 2000);

  print('\nthe actual bug (padded must be WIDER — plain was cropped):');
  check('overflow right',
      '${d}Default,,0,0,0,,{\\an5\\pos(1800,540)}THE QUICK BROWN FOX JUMPS OVER',
      expectWider: true);
  check('overflow left',
      '${d}Default,,0,0,0,,{\\an5\\pos(120,540)}THE QUICK BROWN FOX JUMPS OVER',
      expectWider: true);

  libass.ass_library_done(lib);
  print(failures == 0 ? '\nAll checks passed.' : '\n$failures FAILED');
}
