// Measures the two gap distributions the cluster slack sits between:
// the largest gap *inside* one event, and the smallest gap *between* events.
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'lib/ass_binding.dart';
import 'lib/ass_padding.dart';
import 'lib/ass_reposition.dart';
import 'lib/caption_layout.dart';

void _dll(String p0) {
  final k = DynamicLibrary.open('kernel32.dll');
  final f = k.lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final p = p0.toNativeUtf16(); f(p); malloc.free(p);
}

late LibAssBindings libass;
late Pointer<ASS_Library> lib;

List<Box> shoot(Pointer<ASS_Renderer> r, Pointer<ASS_Track> t, int ms, int px, int py) {
  final ch = malloc<Int32>();
  var img = libass.ass_render_frame(r, t, ms, ch);
  malloc.free(ch);
  final out = <Box>[];
  while (img != nullptr) {
    final i = img.ref;
    if (i.w > 0 && i.h > 0) {
      out.add(Box((i.dst_x - px).toDouble(), (i.dst_y - py).toDouble(),
          (i.dst_x - px + i.w).toDouble(), (i.dst_y - py + i.h).toDouble()));
    }
    img = i.next;
  }
  return out;
}

Pointer<ASS_Renderer> mk(PaddedScript p) {
  final r = libass.ass_renderer_init(lib);
  libass.ass_set_frame_size(r, p.frameWidth, p.frameHeight);
  libass.ass_set_margins(r, 0, 0, 0, 0);
  libass.ass_set_use_margins(r, 0);
  libass.ass_set_pixel_aspect(r, 1.0);
  final a = 'Arial'.toNativeUtf8(); final b = 'Arial'.toNativeUtf8();
  libass.ass_set_fonts(r, a, b, 1, nullptr, 1);
  malloc.free(a); malloc.free(b);
  return r;
}
Pointer<ASS_Track> tk(String s) {
  final t = libass.ass_new_track(lib);
  final d = s.toNativeUtf8();
  libass.ass_process_data(t, d, d.length);
  malloc.free(d);
  return t;
}

/// Gap between two boxes: 0 if they overlap in both axes, else the smaller
/// separation needed to consider them adjacent (max of per-axis gaps, since a
/// split needs separation on at least one axis).
double gap(Box a, Box b) {
  final gx = a.left > b.right ? a.left - b.right : (b.left > a.right ? b.left - a.right : -1.0);
  final gy = a.top > b.bottom ? a.top - b.bottom : (b.top > a.bottom ? b.top - a.bottom : -1.0);
  if (gx < 0 && gy < 0) return 0;
  return gx > gy ? gx : gy;
}

void main(List<String> args) {
  _dll(r'C:\msys64\msys64\mingw64\bin');
  libass = LibAssBindings(DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll'));
  lib = libass.ass_library_init();

  var maxInside = 0.0; String maxInsideAt = '';
  var minBetween = double.infinity; String minBetweenAt = '';

  for (final f in args.isNotEmpty ? args : ['L-BgxLtMxh0.ass','1S7uIQmkRzk.ass','v2.ass','Untitled.ass']) {
    if (!File(f).existsSync()) continue;
    final src = File(f).readAsStringSync();
    final lines = src.split(RegExp(r'\r?\n'));
    final head = lines.where((l) => !l.trimLeft().toLowerCase().startsWith('dialogue:')).join('\n');
    final events = lines.where((l) => l.trimLeft().toLowerCase().startsWith('dialogue:')).toList();
    final spans = parseEventSpans(src);
    final endMs = spans.isEmpty ? 0 : spans.map((s) => s.endMs).reduce((a,b)=>a>b?a:b);

    for (var ms = 0; ms <= endMs; ms += 250) {
      final perEvent = <List<Box>>[];
      for (var i = 0; i < events.length; i++) {
        if (i >= spans.length || !spans[i].contains(ms)) continue;
        final p = padScript('$head\n${events[i]}\n', padX: 960, padY: 540);
        final r = mk(p); final t = tk(p.source);
        final bs = shoot(r, t, ms, p.padX, p.padY);
        libass.ass_free_track(t); libass.ass_renderer_done(r);
        if (bs.isNotEmpty) perEvent.add(bs);
      }
      // largest gap between consecutive images inside one event
      for (final bs in perEvent) {
        for (var i = 1; i < bs.length; i++) {
          var g = double.infinity;
          for (var j = 0; j < i; j++) { final x = gap(bs[i], bs[j]); if (x < g) g = x; }
          if (g > maxInside) { maxInside = g; maxInsideAt = '$f @${(ms/1000).toStringAsFixed(2)}s'; }
        }
      }
      // smallest gap between different events
      for (var a = 0; a < perEvent.length; a++) {
        for (var b = a + 1; b < perEvent.length; b++) {
          var g = double.infinity;
          for (final x in perEvent[a]) { for (final y in perEvent[b]) { final v = gap(x, y); if (v < g) g = v; } }
          if (g < minBetween) { minBetween = g; minBetweenAt = '$f @${(ms/1000).toStringAsFixed(2)}s'; }
        }
      }
    }
  }
  stdout.writeln('largest gap INSIDE one event  : ${maxInside.toStringAsFixed(0)} px   ($maxInsideAt)');
  stdout.writeln('smallest gap BETWEEN events   : ${minBetween.toStringAsFixed(0)} px   ($minBetweenAt)');
  libass.ass_library_done(lib);
}
