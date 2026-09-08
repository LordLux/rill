// Probe 5: "it overflows but the clamp never fires".
//
// Drags a whole track by a synthetic delta (as drag-end would), then walks the
// timeline applying exactly the app's grouping and clamping, and reports every
// caption group that is left hanging outside the video.
//
//   dart run probe_nudge.dart [file.ass] [dx] [dy]
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'lib/ass_binding.dart';
import 'lib/ass_padding.dart';
import 'lib/ass_reposition.dart';
import 'lib/caption_layout.dart';

void _addDllDirectory(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDir = kernel32.lookupFunction<Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final p = path.toNativeUtf16();
  setDllDir(p);
  malloc.free(p);
}

void main(List<String> args) {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  final dylib =
      DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll');
  final libass = LibAssBindings(dylib);
  final lib = libass.ass_library_init();

  final path = args.isNotEmpty ? args[0] : 'L-BgxLtMxh0.ass';
  final ddx = args.length > 1 ? double.parse(args[1]) : 340.0;
  final ddy = args.length > 2 ? double.parse(args[2]) : -60.0;

  var raw = File(path).readAsStringSync();
  stdout.writeln('$path  synthetic drag ($ddx, $ddy)\n');
  raw = repositionScript(raw, ddx, ddy);

  final padded = padScript(raw, padX: 960, padY: 540);
  final spans = parseEventSpans(raw);
  final w = padded.playResX.toDouble();
  final h = padded.playResY.toDouble();

  stdout.writeln('events: ${spans.length}, '
      'with \\move: ${spans.where((s) => s.move != null).length}');

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

  final track = libass.ass_new_track(lib);
  final data = padded.source.toNativeUtf8();
  libass.ass_process_data(track, data, data.length);
  malloc.free(data);

  final endMs = spans.isEmpty
      ? 0
      : spans.map((s) => s.endMs).reduce((a, b) => a > b ? a : b);

  var frames = 0, groupsSeen = 0, overflowing = 0;
  var clamped = 0, exemptMoving = 0, tooBig = 0, leftHanging = 0;
  var maxActiveGroups = 0;
  final examples = <String>[];

  final ch = malloc<Int32>();
  for (var ms = 0; ms <= endMs; ms += 100) {
    var img = libass.ass_render_frame(r, track, ms, ch);
    final rects = <Box>[];
    final types = <int>[];
    while (img != nullptr) {
      final i = img.ref;
      if (i.w > 0 && i.h > 0) {
        final x = (i.dst_x - padded.padX).toDouble();
        final y = (i.dst_y - padded.padY).toDouble();
        rects.add(Box(x, y, x + i.w, y + i.h));
        types.add(i.type);
      }
      img = i.next;
    }
    if (rects.isEmpty) continue;
    frames++;

    final g = groupImages(types);
    final boxes = groupBoxes(rects, g);
    groupsSeen += boxes.length;
    if (boxes.length > maxActiveGroups) maxActiveGroups = boxes.length;

    final moving = <List<double>>[];
    for (final s in spans) {
      if (!s.contains(ms)) continue;
      final a = s.anchorAt(ms);
      if (a != null) moving.add(a);
    }

    for (final b in boxes) {
      final over = b.left < 0 || b.top < 0 || b.right > w || b.bottom > h;
      if (!over) continue;
      overflowing++;

      if (moving.any((a) => b.containsPoint(a[0], a[1], slack: 8))) {
        exemptMoving++;
        continue;
      }
      final d = clampOffset(b, w, h);
      final fixed = b.shift(d[0], d[1]);
      final stillOut =
          fixed.left < 0 || fixed.top < 0 || fixed.right > w || fixed.bottom > h;
      if (!stillOut) {
        clamped++;
      } else if (b.width > w || b.height > h) {
        tooBig++;
        if (examples.length < 8) {
          examples.add('  ${(ms / 1000).toStringAsFixed(1)}s  $b  '
              'TOO_BIG (${b.width.toStringAsFixed(0)}x'
              '${b.height.toStringAsFixed(0)} vs ${w.toInt()}x${h.toInt()})');
        }
      } else {
        leftHanging++;
        if (examples.length < 8) {
          examples.add('  ${(ms / 1000).toStringAsFixed(1)}s  $b  LEFT HANGING');
        }
      }
    }
  }
  malloc.free(ch);

  stdout.writeln('frames with content   : $frames');
  stdout.writeln('caption groups seen   : $groupsSeen '
      '(max ${maxActiveGroups} at once)');
  stdout.writeln('  overflowing         : $overflowing');
  stdout.writeln('  -> clamped back in  : $clamped');
  stdout.writeln('  -> exempt (\\move)   : $exemptMoving');
  stdout.writeln('  -> wider than video : $tooBig');
  stdout.writeln('  -> LEFT HANGING     : $leftHanging');
  if (examples.isNotEmpty) {
    stdout.writeln('\nnot rescued:');
    examples.forEach(stdout.writeln);
  }

  libass.ass_free_track(track);
  libass.ass_renderer_done(r);
  libass.ass_library_done(lib);
}

