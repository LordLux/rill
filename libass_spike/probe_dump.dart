// Dumps every ASS_Image rect at one instant, so cluster tolerances can be
// chosen from data instead of guessed.
//   dart run probe_dump.dart <file.ass> <ms> [dx] [dy]
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'lib/ass_binding.dart';
import 'lib/ass_padding.dart';
import 'lib/ass_reposition.dart';

void _dll(String path) {
  final k = DynamicLibrary.open('kernel32.dll');
  final f = k.lookupFunction<Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final p = path.toNativeUtf16();
  f(p);
  malloc.free(p);
}

void main(List<String> args) {
  _dll(r'C:\msys64\msys64\mingw64\bin');
  final dylib = DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll');
  final libass = LibAssBindings(dylib);
  final lib = libass.ass_library_init();

  var raw = File(args[0]).readAsStringSync();
  final ms = int.parse(args[1]);
  if (args.length > 3) {
    raw = repositionScript(raw, double.parse(args[2]), double.parse(args[3]));
  }
  final padded = padScript(raw, padX: 960, padY: 540);

  final r = libass.ass_renderer_init(lib);
  libass.ass_set_frame_size(r, padded.frameWidth, padded.frameHeight);
  libass.ass_set_margins(r, 0, 0, 0, 0);
  libass.ass_set_use_margins(r, 0);
  libass.ass_set_pixel_aspect(r, 1.0);
  final f1 = 'Arial'.toNativeUtf8();
  final f2 = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(r, f1, f2, 1, nullptr, 1);
  final t = libass.ass_new_track(lib);
  final d = padded.source.toNativeUtf8();
  libass.ass_process_data(t, d, d.length);

  final ch = malloc<Int32>();
  var img = libass.ass_render_frame(r, t, ms, ch);
  var i = 0;
  while (img != nullptr) {
    final im = img.ref;
    if (im.w > 0 && im.h > 0) {
      final x = im.dst_x - padded.padX;
      final y = im.dst_y - padded.padY;
      print('${(i++).toString().padLeft(3)}  '
          'x[${x.toString().padLeft(5)}..${(x + im.w).toString().padLeft(5)}] '
          'y[${y.toString().padLeft(5)}..${(y + im.h).toString().padLeft(5)}] '
          'w=${im.w.toString().padLeft(4)} h=${im.h.toString().padLeft(3)} '
          'type=${im.type} color=${im.color.toRadixString(16).padLeft(8, "0")}');
    }
    img = im.next;
  }
  print('PlayRes ${padded.playResX}x${padded.playResY}');
}
