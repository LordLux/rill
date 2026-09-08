// Probe 6: does groupImages() really recover one group per event?
//
// Ground truth is libass itself: render the whole track at time T, group the
// image list, then render each active event *alone* in its own track at the
// same T and compare the boxes. If the grouping is right the two multisets are
// identical.
//
// Only valid for tracks whose events are \pos-ed — a bare event laid out alone
// would not collide with its neighbours and so would land somewhere else.
//
//   dart run probe_groups.dart [file.ass ...]
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

late final LibAssBindings libass;
late final Pointer<ASS_Library> lib;

class Shot {
  final List<Box> rects;
  final List<int> types;
  const Shot(this.rects, this.types);
}

Shot shoot(Pointer<ASS_Renderer> r, Pointer<ASS_Track> t, int ms, int padX,
    int padY) {
  final ch = malloc<Int32>();
  var img = libass.ass_render_frame(r, t, ms, ch);
  malloc.free(ch);
  final rects = <Box>[];
  final types = <int>[];
  while (img != nullptr) {
    final i = img.ref;
    if (i.w > 0 && i.h > 0) {
      final x = (i.dst_x - padX).toDouble();
      final y = (i.dst_y - padY).toDouble();
      rects.add(Box(x, y, x + i.w, y + i.h));
      types.add(i.type);
    }
    img = i.next;
  }
  return Shot(rects, types);
}

Pointer<ASS_Renderer> makeRenderer(PaddedScript p) {
  final r = libass.ass_renderer_init(lib);
  libass.ass_set_frame_size(r, p.frameWidth, p.frameHeight);
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

Pointer<ASS_Track> makeTrack(String source) {
  final t = libass.ass_new_track(lib);
  final d = source.toNativeUtf8();
  libass.ass_process_data(t, d, d.length);
  malloc.free(d);
  return t;
}

/// Splits a script into its header and its Dialogue lines.
(String, List<String>) split(String source) {
  final lines = source.split(RegExp(r'\r?\n'));
  final head = <String>[];
  final events = <String>[];
  for (final l in lines) {
    if (l.trimLeft().toLowerCase().startsWith('dialogue:')) {
      events.add(l);
    } else {
      head.add(l);
    }
  }
  return (head.join('\n'), events);
}

String key(Box b) => '${b.left.round()},${b.top.round()},'
    '${b.right.round()},${b.bottom.round()}';

var failures = 0;

/// Returns (framesChecked, framesMismatched).
List<int> measure(String source) {
  final (head, events) = split(source);
  final spans = parseEventSpans(source);
  final padded = padScript(source, padX: 960, padY: 540);
  final r = makeRenderer(padded);
  final track = makeTrack(padded.source);

  final endMs = spans.isEmpty
      ? 0
      : spans.map((s) => s.endMs).reduce((a, b) => a > b ? a : b);

  var checked = 0, mismatched = 0;
  final examples = <String>[];

  for (var ms = 0; ms <= endMs; ms += 250) {
    final shot = shoot(r, track, ms, padded.padX, padded.padY);
    if (shot.rects.isEmpty) continue;

    final g = groupImages(shot.types);
    final got = groupBoxes(shot.rects, g).map(key).toList()..sort();

    // Ground truth: one track per active event.
    final want = <String>[];
    for (var i = 0; i < events.length; i++) {
      if (i >= spans.length || !spans[i].contains(ms)) continue;
      final solo = padScript('$head\n${events[i]}\n', padX: 960, padY: 540);
      final st = makeTrack(solo.source);
      final sr = makeRenderer(solo);
      final s = shoot(sr, st, ms, solo.padX, solo.padY);
      libass.ass_free_track(st);
      libass.ass_renderer_done(sr);
      if (s.rects.isEmpty) continue;
      var b = s.rects.first;
      for (final x in s.rects.skip(1)) {
        b = b.union(x);
      }
      want.add(key(b));
    }
    want.sort();

    checked++;
    if (got.join('|') != want.join('|')) {
      mismatched++;
      if (examples.length < 4) {
        examples.add('  ${(ms / 1000).toStringAsFixed(2)}s\n'
            '     grouped: ${got.join("  ")}\n'
            '     actual : ${want.join("  ")}');
      }
    }
  }

  libass.ass_free_track(track);
  libass.ass_renderer_done(r);
  _lastExamples = examples;
  return [checked, mismatched];
}

List<String> _lastExamples = const [];

void expectExact(String label, String source) {
  final m = measure(source);
  final ok = m[1] == 0;
  if (!ok) failures++;
  stdout.writeln('${ok ? "  ok  " : "  FAIL"} $label  '
      '${m[0]} frames, ${m[1]} mismatched');
  if (!ok) _lastExamples.forEach(stdout.writeln);
}

/// A case the type heuristic provably cannot see, pinned so a libass change
/// shows up here instead of as a mystery in the UI.
void expectKnownMerge(String label, String source) {
  final m = measure(source);
  final ok = m[1] > 0;
  if (!ok) failures++;
  stdout.writeln('${ok ? "  ok  " : "  FAIL"} $label  '
      '(known limitation: expected to merge; ${m[1]}/${m[0]} frames did)');
}

const _demo = r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,2,2,10,10,10,1
Style: Title,Impact,120,&H0000FFFF,&H000000FF,&H00FFFFFF,&H80000000,1,0,0,0,100,100,5,0,1,5,0,5,10,10,10,1
Style: Karaoke,Comic Sans MS,80,&H0000FF00,&H00FFFFFF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,4,0,8,10,10,10,1
Style: Flat,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:10.00,Title,,0,0,0,,{\t(0,2000,\frz360\c&HFF00FF&)\pos(960,300)}Advanced libass Rendering!
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,{\fad(500,500)\pos(960,600)}Smooth Alpha Fading In and Out
Dialogue: 0,0:00:02.00,0:00:10.00,Default,,0,0,0,,{\move(-200,800,2000,800)}Moving across the screen...
Dialogue: 0,0:00:03.00,0:00:08.00,Karaoke,,0,0,0,,{\pos(960,200)\k50}Ka{\k50}ra{\k50}o{\k50}ke {\k50}Ef{\k50}fect!
Dialogue: 0,0:00:04.00,0:00:10.00,Default,,0,0,0,,{\pos(400,900)\org(400,900)\t(\frz3600)}Spinning
Dialogue: 0,0:00:05.00,0:00:10.00,Default,,0,0,0,,{\blur15\pos(1500,900)}Gaussian Blur
''';

/// Two events drawing fill only — Outline 0, Shadow 0 — so their images are an
/// unbroken run of `type == 0` with no boundary for groupImages() to find.
const _borderlessPair = r'''
Dialogue: 0,0:00:06.00,0:00:10.00,Flat,,0,0,0,,{\pos(300,120)}Borderless one
Dialogue: 0,0:00:06.00,0:00:10.00,Flat,,0,0,0,,{\pos(1500,120)}Borderless two
''';

void main(List<String> args) {
  _addDllDirectory(r'C:\msys64\msys64\mingw64\bin');
  final dylib =
      DynamicLibrary.open(r'C:\msys64\msys64\mingw64\bin\libass-9.dll');
  libass = LibAssBindings(dylib);
  lib = libass.ass_library_init();

  stdout.writeln('grouping vs. one-track-per-event ground truth:');
  expectExact('<demo: pos, move, karaoke, rotation, blur, fade>', _demo);
  expectKnownMerge(
      '<two adjacent fill-only events merge>', _demo + _borderlessPair);

  final files = args.isNotEmpty
      ? args
      : ['L-BgxLtMxh0.ass', '1S7uIQmkRzk.ass', 'v2.ass'];
  for (final f in files) {
    if (!File(f).existsSync()) continue;
    expectExact(f, File(f).readAsStringSync());
  }

  libass.ass_library_done(lib);
  stdout.writeln(failures == 0 ? '\nAll checks passed.' : '\n$failures FAILED');
}
