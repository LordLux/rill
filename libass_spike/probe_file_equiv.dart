// Probe 7: does padScript() change how a real file renders?
//
// Walks a whole track and compares every image, per frame, against the same
// track rendered the old way — frame == PlayRes, no padding, no rewriting.
// Anything libass was not already cropping must land on exactly the same pixel.
//
//   dart run probe_file_equiv.dart [file.ass ...]
import 'dart:ffi';
import 'dart:io';
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

late final LibAssBindings libass;
late final Pointer<ASS_Library> lib;

Pointer<ASS_Renderer> renderer(int w, int h) {
  final r = libass.ass_renderer_init(lib);
  libass.ass_set_frame_size(r, w, h);
  libass.ass_set_margins(r, 0, 0, 0, 0);
  libass.ass_set_use_margins(r, 0);
  libass.ass_set_pixel_aspect(r, 1.0);
  final f1 = 'Arial'.toNativeUtf8();
  final f2 = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(r, f1, f2, 1, nullptr, 1);
  malloc.free(f1);
  malloc.free(f2);
  return r;
}

Pointer<ASS_Track> track(String source) {
  final t = libass.ass_new_track(lib);
  final d = source.toNativeUtf8();
  libass.ass_process_data(t, d, d.length);
  malloc.free(d);
  return t;
}

/// Every image at [ms], as `x,y,w,h,color` strings in list order.
List<String> shoot(Pointer<ASS_Renderer> r, Pointer<ASS_Track> t, int ms,
    int padX, int padY) {
  final ch = malloc<Int32>();
  var img = libass.ass_render_frame(r, t, ms, ch);
  malloc.free(ch);
  final out = <String>[];
  while (img != nullptr) {
    final i = img.ref;
    if (i.w > 0 && i.h > 0) {
      out.add('${i.dst_x - padX},${i.dst_y - padY},${i.w},${i.h},'
          '${i.color.toRadixString(16)},${i.type}');
    }
    img = i.next;
  }
  return out;
}

var failures = 0;

void checkFile(String path) {
  final source = File(path).readAsStringSync();
  final spans = parseEventSpans(source);
  final padded = padScript(source, padX: 960, padY: 540);

  final plainR = renderer(padded.playResX, padded.playResY);
  final plainT = track(source);
  final padR = renderer(padded.frameWidth, padded.frameHeight);
  final padT = track(padded.source);

  final endMs = spans.isEmpty
      ? 0
      : spans.map((s) => s.endMs).reduce((a, b) => a > b ? a : b);

  var frames = 0, same = 0, croppedOnly = 0, differing = 0;
  final examples = <String>[];

  for (var ms = 0; ms <= endMs; ms += 100) {
    final a = shoot(plainR, plainT, ms, 0, 0);
    final b = shoot(padR, padT, ms, padded.padX, padded.padY);
    if (a.isEmpty && b.isEmpty) continue;
    frames++;

    if (a.join('|') == b.join('|')) {
      same++;
      continue;
    }
    // A difference is only legitimate if the padded render is the *wider* one:
    // same image count, and every padded box contains the plain box it
    // corresponds to. That is the crop being lifted, not a layout change.
    var legit = a.length == b.length;
    if (legit) {
      for (var i = 0; i < a.length; i++) {
        final pa = a[i].split(',');
        final pb = b[i].split(',');
        final ax = int.parse(pa[0]), ay = int.parse(pa[1]);
        final aw = int.parse(pa[2]), ah = int.parse(pa[3]);
        final bx = int.parse(pb[0]), by = int.parse(pb[1]);
        final bw = int.parse(pb[2]), bh = int.parse(pb[3]);
        if (pa[4] != pb[4] || pa[5] != pb[5]) legit = false;
        if (bx > ax || by > ay || bx + bw < ax + aw || by + bh < ay + ah) {
          legit = false;
        }
        if (!legit) {
          if (examples.length < 5) {
            examples.add('  ${(ms / 1000).toStringAsFixed(1)}s img$i\n'
                '     plain  $ax,$ay ${aw}x$ah  ${pa[4]} t${pa[5]}\n'
                '     padded $bx,$by ${bw}x$bh  ${pb[4]} t${pb[5]}');
          }
          break;
        }
      }
    } else if (examples.length < 5) {
      examples.add('  ${(ms / 1000).toStringAsFixed(1)}s  image count '
          '${a.length} -> ${b.length}');
    }
    if (legit) {
      croppedOnly++;
    } else {
      differing++;
    }
  }

  libass.ass_free_track(plainT);
  libass.ass_free_track(padT);
  libass.ass_renderer_done(plainR);
  libass.ass_renderer_done(padR);

  final ok = differing == 0;
  if (!ok) failures++;
  stdout.writeln('${ok ? "  ok  " : "  FAIL"} ${path.split(RegExp(r"[\\/]")).last}'
      '  $frames frames: $same identical, $croppedOnly uncropped, '
      '$differing DIFFERENT');
  examples.forEach(stdout.writeln);
}

void main(List<String> args) {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  final dylib =
      DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll');
  libass = LibAssBindings(dylib);
  lib = libass.ass_library_init();

  stdout.writeln('padded vs. unpadded, whole file:');
  final files = args.isNotEmpty
      ? args
      : [
          r'..\sidecar\scratch\out\complex_test.ass',
          'L-BgxLtMxh0.ass',
          '1S7uIQmkRzk.ass',
          'v2.ass',
          'Untitled.ass',
          'm (7).ass',
        ];
  for (final f in files) {
    if (!File(f).existsSync()) {
      stdout.writeln('  --   $f (missing)');
      continue;
    }
    checkFile(f);
  }

  libass.ass_library_done(lib);
  stdout.writeln(failures == 0 ? '\nAll checks passed.' : '\n$failures FAILED');
}
