/// **Throwaway measurement harness for Task 19 phase 5.** Not a `_test.dart`, so
/// `flutter test` does not pick it up with the suite; run it explicitly:
///
///   flutter test test/probe_libass_cadence.dart
///
/// What it measures, all against the *real* bundled `libass-9.dll` from
/// `app/windows/libass_bundle/` (hard invariant 8 — the artefact the app loads,
/// not a runtime probe of a stack that lies):
///
///  1. Round-trip wall clock of `LibassLayer._runRenderIsolate` — a fresh
///     `Isolate.run` per frame — plus the main-thread work that follows it
///     (`ui.decodeImageFromPixels` per glyph bitmap), over a real karaoke ASS
///     document at its real 200 ms step cadence.
///  2. The same over a real ASR rolling-window document.
///
/// The isolate body and the decode loop are copied verbatim from
/// `lib/ui/player/libass_layer.dart` (they are private there). If that file
/// changes, this stops measuring it.
library;

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/player/libass/ass_binding.dart';
import 'package:rill/ui/player/libass/ass_padding.dart';

// --- verbatim from libass_layer.dart -----------------------------------------

class _RawImage {
  final TransferableTypedData pixels;
  final int w;
  final int h;
  final double x;
  final double y;
  final int type;
  _RawImage(this.pixels, this.w, this.h, this.x, this.y, this.type);
}

Future<List<_RawImage>> _runRenderIsolate(
        int rendererPtr, int trackPtr, int nowMs, double padX, double padY) =>
    Isolate.run(() => _renderIsolate(rendererPtr, trackPtr, nowMs, padX, padY));

List<_RawImage> _renderIsolate(
    int rendererPtr, int trackPtr, int nowMs, double padX, double padY) {
  final dylib = DynamicLibrary.open('libass-9.dll');
  final bindings = LibAssBindings(dylib);

  final renderer = Pointer<ASS_Renderer>.fromAddress(rendererPtr);
  final track = Pointer<ASS_Track>.fromAddress(trackPtr);

  final changePtr = malloc<Int32>();
  final imagePtr = bindings.ass_render_frame(renderer, track, nowMs, changePtr);
  malloc.free(changePtr);

  final rawImages = <_RawImage>[];
  Pointer<ASS_Image> current = imagePtr;

  while (current != nullptr) {
    final img = current.ref;
    if (img.w > 0 && img.h > 0) {
      final color = img.color;
      final r = (color >> 24) & 0xFF;
      final g = (color >> 16) & 0xFF;
      final b = (color >> 8) & 0xFF;
      final a = color & 0xFF;

      final rgbaPixels = Uint8List(img.w * img.h * 4);
      final mask = img.bitmap.asTypedList(img.stride * img.h);

      for (int y = 0; y < img.h; y++) {
        for (int x = 0; x < img.w; x++) {
          final maskVal = mask[y * img.stride + x];
          final outIdx = (y * img.w + x) * 4;
          final finalAlpha = (maskVal * (255 - a)) ~/ 255;
          rgbaPixels[outIdx] = (r * finalAlpha) ~/ 255;
          rgbaPixels[outIdx + 1] = (g * finalAlpha) ~/ 255;
          rgbaPixels[outIdx + 2] = (b * finalAlpha) ~/ 255;
          rgbaPixels[outIdx + 3] = finalAlpha;
        }
      }

      rawImages.add(_RawImage(
        TransferableTypedData.fromList([rgbaPixels]),
        img.w,
        img.h,
        (img.dst_x - padX).toDouble(),
        (img.dst_y - padY).toDouble(),
        img.type,
      ));
    }
    current = img.next;
  }
  return rawImages;
}

// --- harness -----------------------------------------------------------------

void _addDllDirectory(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDir = kernel32.lookupFunction<Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final p = path.toNativeUtf16();
  setDllDir(p);
  malloc.free(p);
}

/// `flutter test`'s cwd is the package root (`app/`).
final _bundle = Directory('windows/libass_bundle').absolute.path;

const kPadX = 960;
const kPadY = 540;

/// The layer's surface in `caption_drag_test.dart` — 1920x1080, 1:1 with PlayRes.
const _lastWidth = 1920.0;
const _lastHeight = 1080.0;

String _pct(List<int> sorted, double p) {
  if (sorted.isEmpty) return 'n/a';
  final i = ((sorted.length - 1) * p).round();
  return '${(sorted[i] / 1000).toStringAsFixed(2)}ms';
}

String _stats(String label, List<int> micros) {
  final s = [...micros]..sort();
  final sum = s.fold<int>(0, (a, b) => a + b);
  return '$label  n=${s.length} '
      'min=${(s.first / 1000).toStringAsFixed(2)}ms '
      'p50=${_pct(s, 0.5)} '
      'p90=${_pct(s, 0.9)} '
      'p99=${_pct(s, 0.99)} '
      'max=${(s.last / 1000).toStringAsFixed(2)}ms '
      'mean=${(sum / s.length / 1000).toStringAsFixed(2)}ms';
}

/// Every `Start` time in an ASS document, in ms — the exact instants at which
/// what is on screen changes.
List<int> _eventStartsMs(String ass) {
  final out = <int>{};
  for (final line in ass.split(RegExp(r'\r?\n'))) {
    if (!line.trimLeft().toLowerCase().startsWith('dialogue:')) continue;
    final fields = line.substring(line.indexOf(':') + 1).split(',');
    if (fields.length < 3) continue;
    final t = _parseAssTime(fields[1].trim());
    if (t != null) out.add(t);
  }
  final list = out.toList()..sort();
  return list;
}

int? _parseAssTime(String s) {
  final m = RegExp(r'^(\d+):(\d\d):(\d\d)\.(\d\d)$').firstMatch(s);
  if (m == null) return null;
  return int.parse(m.group(1)!) * 3600000 +
      int.parse(m.group(2)!) * 60000 +
      int.parse(m.group(3)!) * 1000 +
      int.parse(m.group(4)!) * 10;
}

class _Rig {
  late final LibAssBindings libass;
  late final Pointer<ASS_Library> lib;
  late final Pointer<ASS_Renderer> renderer;
  late final Pointer<ASS_Track> track;
  late final PaddedScript padded;

  _Rig(String rawAss) {
    final dylib = DynamicLibrary.open('libass-9.dll');
    libass = LibAssBindings(dylib);
    lib = libass.ass_library_init();
    renderer = libass.ass_renderer_init(lib);
    final f = 'Arial'.toNativeUtf8();
    final fam = 'Arial'.toNativeUtf8();
    libass.ass_set_fonts(renderer, f, fam, 1, nullptr, 1);
    malloc.free(f);
    malloc.free(fam);

    padded = padScript(rawAss, padX: kPadX, padY: kPadY);
    libass.ass_set_margins(renderer, 0, 0, 0, 0);
    libass.ass_set_use_margins(renderer, 0);
    libass.ass_set_pixel_aspect(renderer, 1.0);

    track = libass.ass_new_track(lib);
    final data = padded.source.toNativeUtf8();
    libass.ass_process_data(track, data, data.length);
    malloc.free(data);

    final physW = _lastWidth * (padded.frameWidth / padded.playResX);
    final physH = _lastHeight * (padded.frameHeight / padded.playResY);
    libass.ass_set_frame_size(
        renderer, math.max(1, physW.toInt()), math.max(1, physH.toInt()));
  }

  double get physPadX => _lastWidth * (kPadX / padded.playResX);
  double get physPadY => _lastHeight * (kPadY / padded.playResY);

  void done() {
    libass.ass_free_track(track);
    libass.ass_renderer_done(renderer);
    libass.ass_library_done(lib);
  }
}

/// One full `_renderLoop` iteration's cost, split the way the loop spends it.
class _Sample {
  final int isolateUs;
  final int decodeUs;
  final int images;
  _Sample(this.isolateUs, this.decodeUs, this.images);
}

Future<_Sample> _oneFrame(_Rig rig, int nowMs) async {
  final t0 = Stopwatch()..start();
  final raws = await _runRenderIsolate(
      rig.renderer.address, rig.track.address, nowMs, rig.physPadX, rig.physPadY);
  final isolateUs = t0.elapsedMicroseconds;

  final t1 = Stopwatch()..start();
  final imgs = <ui.Image>[];
  for (final raw in raws) {
    final comp = Completer<ui.Image>();
    ui.decodeImageFromPixels(raw.pixels.materialize().asUint8List(), raw.w,
        raw.h, ui.PixelFormat.rgba8888, comp.complete);
    imgs.add(await comp.future);
  }
  final decodeUs = t1.elapsedMicroseconds;
  for (final i in imgs) {
    i.dispose();
  }
  return _Sample(isolateUs, decodeUs, raws.length);
}

void main() {
  setUpAll(() {
    _addDllDirectory(_bundle);
  });

  testWidgets('M0: the bundled libass-9.dll loads from a flutter test host',
      (tester) async {
    await tester.runAsync(() async {
      final dylib = DynamicLibrary.open('libass-9.dll');
      final b = LibAssBindings(dylib);
      final lib = b.ass_library_init();
      expect(lib, isNot(nullptr));
      final r = b.ass_renderer_init(lib);
      expect(r, isNot(nullptr));
      b.ass_renderer_done(r);
      b.ass_library_done(lib);
      // ignore: avoid_print
      print('M0: loaded $_bundle\\libass-9.dll OK');
    });
  });

  testWidgets('M1: karaoke — isolate round trip at the real 200 ms step cadence',
      (tester) async {
    await tester.runAsync(() async {
      final raw = File('test/probe_fixtures/karaoke-L-BgxLtMxh0.ass').readAsStringSync();
      final rig = _Rig(raw);
      addTearDown(rig.done);

      // The karaoke sweep in this track: 16991..18520 ms, eight steps.
      final starts = _eventStartsMs(raw).where((t) => t >= 16991 && t <= 18990).toList();
      // ignore: avoid_print
      print('M1: karaoke step starts (ms) = $starts');
      final gaps = [
        for (var i = 1; i < starts.length; i++) starts[i] - starts[i - 1]
      ];
      // ignore: avoid_print
      print('M1: karaoke step gaps (ms)   = $gaps');

      // Warm: first Isolate.run in a process pays for spawning machinery.
      await _oneFrame(rig, starts.first);

      final iso = <int>[];
      final dec = <int>[];
      var imgs = 0;
      // Ten passes over the sweep, so the sample is not one cold run.
      for (var pass = 0; pass < 10; pass++) {
        for (final t in starts) {
          final s = await _oneFrame(rig, t + 5);
          iso.add(s.isolateUs);
          dec.add(s.decodeUs);
          imgs += s.images;
        }
      }
      // ignore: avoid_print
      print(_stats('M1 isolate ', iso));
      // ignore: avoid_print
      print(_stats('M1 decode  ', dec));
      // ignore: avoid_print
      print(_stats('M1 total   ',
          [for (var i = 0; i < iso.length; i++) iso[i] + dec[i]]));
      // ignore: avoid_print
      print('M1: ${(imgs / iso.length).toStringAsFixed(1)} ASS_Image(s) per frame');
    });
  });

  testWidgets('M2: ASR rolling window — isolate round trip at real cue cadence',
      (tester) async {
    await tester.runAsync(() async {
      final raw = File('test/probe_fixtures/asr-dQw4w9WgXcQ.ass').readAsStringSync();
      final rig = _Rig(raw);
      addTearDown(rig.done);

      final starts = _eventStartsMs(raw);
      final gaps = [
        for (var i = 1; i < starts.length; i++) starts[i] - starts[i - 1]
      ]..sort();
      // ignore: avoid_print
      print('M2: ${starts.length} distinct cue starts; '
          'gap min=${gaps.first}ms p50=${gaps[gaps.length ~/ 2]}ms max=${gaps.last}ms');

      await _oneFrame(rig, starts.first);

      final iso = <int>[];
      final dec = <int>[];
      var imgs = 0;
      for (var pass = 0; pass < 4; pass++) {
        for (final t in starts) {
          final s = await _oneFrame(rig, t + 5);
          iso.add(s.isolateUs);
          dec.add(s.decodeUs);
          imgs += s.images;
        }
      }
      // ignore: avoid_print
      print(_stats('M2 isolate ', iso));
      // ignore: avoid_print
      print(_stats('M2 decode  ', dec));
      // ignore: avoid_print
      print(_stats('M2 total   ',
          [for (var i = 0; i < iso.length; i++) iso[i] + dec[i]]));
      // ignore: avoid_print
      print('M2: ${(imgs / iso.length).toStringAsFixed(1)} ASS_Image(s) per frame');
    });
  });
}
