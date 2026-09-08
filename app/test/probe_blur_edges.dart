/// Measurement probe, not a regression test — see `test/README.md`.
///
/// Settles one question with pixels instead of reasoning: **does a blurred
/// image leave a dark rim at its own edges, and which blur strategy avoids
/// it.** The artist panel's backdrop is a blurred image sitting on a flat
/// tint, and the reported artefact is a shadow along the artwork's borders.
///
/// Three candidates, all rendered over the same known background:
///
///   decal    `ImageFiltered` + `TileMode.decal`  — samples transparent black
///                                                  outside the image
///   clamp    `ImageFiltered` + `TileMode.clamp`  — repeats the edge pixel
///   backdrop `BackdropFilter` in a `Stack`       — blurs the composited
///                                                  scene behind it
///
/// The test paints a pure-white image on a pure-red ground and reads the
/// **green** channel: 255 is the image, 0 is the ground, and anything between
/// is the ground bleeding through. A clean edge holds 255 right up to the
/// boundary; a rim shows as a dip. (Red separates nothing here — white and
/// the ground both have it at full.) A `none` row renders the image with no
/// filter at all, so a broken capture cannot pass itself off as a result.
///
/// **Measured 2026-09-01**, sigma 8, at the image's left edge:
///
///   none      edge 255, worst 255   — the unfiltered reference
///   decal     edge 134, worst 134   — the reported shadow, reproduced
///   clamp     edge 255, worst 255   — no rim at all
///   backdrop  edge 134, worst 134   — identical rim to decal
///
/// So `TileMode.clamp` is the fix and `BackdropFilter` is not: blurring the
/// composited scene still blurs *across* the artwork's boundary, mixing it
/// with whatever sits behind, which is the same soft edge by another route.
/// The scans outside the image show why they differ in kind — clamp repeats
/// edge pixels into the expanded blur bounds (`-2:255`, a hard edge that the
/// surrounding clip then cuts), decal spills a fading ghost outward
/// (`-2:108`), and the clipped backdrop leaves the ground untouched
/// (`-2:0`).
///
/// Run: flutter test test/probe_blur_edges.dart --reporter expanded
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const double _kBox = 200; // the blurred image's box, centred in the capture
const double _kPad = 50; // ground visible around it
const double _kSigma = 8;
const Color _kGround = Color(0xFFFF0000);

Future<ui.Image> _solid(int w, int h, Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(w, h);
}

/// The three arrangements, each sized identically so their pixels compare.
Widget _harness(Widget blurred) => Directionality(
  textDirection: TextDirection.ltr,
  child: RepaintBoundary(
    child: Container(
      width: _kBox + _kPad * 2,
      height: _kBox + _kPad * 2,
      color: _kGround,
      child: Center(
        child: SizedBox(width: _kBox, height: _kBox, child: blurred),
      ),
    ),
  ),
);

Widget _imageFiltered(ui.Image image, TileMode tileMode) => ImageFiltered(
  imageFilter: ui.ImageFilter.blur(sigmaX: _kSigma, sigmaY: _kSigma, tileMode: tileMode),
  child: RawImage(image: image, fit: BoxFit.cover),
);

/// The image painted sharp, with a blur applied over it as a backdrop. The
/// filter reads the already-composited scene — image *and* the ground around
/// it — so its samples never run out of content the way a layer's do.
Widget _backdrop(ui.Image image) => Stack(
  fit: StackFit.expand,
  children: [
    RawImage(image: image, fit: BoxFit.cover),
    ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: _kSigma, sigmaY: _kSigma),
        child: const SizedBox.expand(),
      ),
    ),
  ],
);

void main() {
  testWidgets('measure the rim each blur strategy leaves', (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final ui.Image white;
    await tester.runAsync(() async {
      white = await _solid(200, 200, const Color(0xFFFFFFFF));
    });

    final cases = <String, Widget>{
      // Baseline: no filter at all. If this does not read as the image, the
      // capture is wrong and every other row is meaningless.
      'none': RawImage(image: white, fit: BoxFit.cover),
      'decal': _imageFiltered(white, TileMode.decal),
      'clamp': _imageFiltered(white, TileMode.clamp),
      'backdrop': _backdrop(white),
    };

    for (final entry in cases.entries) {
      await tester.pumpWidget(_harness(entry.value));
      await tester.pumpAndSettle();

      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);

      late final ByteData? bytes;
      var capturedWidth = 0;
      var capturedHeight = 0;
      await tester.runAsync(() async {
        final captured = await boundary.toImage();
        capturedWidth = captured.width;
        capturedHeight = captured.height;
        bytes = await captured.toByteData(format: ui.ImageByteFormat.rawRgba);
      });
      if (bytes == null) continue;

      final data = bytes!.buffer.asUint8List();
      final width = capturedWidth;
      String rgbaAt(int x, int y) {
        final i = (y * width + x) * 4;
        return '(${data[i]},${data[i + 1]},${data[i + 2]},${data[i + 3]})';
      }
      debugPrint(
        '  capture=${capturedWidth}x$capturedHeight bytes=${data.length} '
        'corner=${rgbaAt(2, 2)} centre=${rgbaAt(width ~/ 2, width ~/ 2)}',
      );

      // Green, not red: the ground is pure red and the image pure white, so
      // both have a full red channel and it separates nothing. Green is 255
      // in the image and 0 in the ground.
      int greenAt(int x, int y) => data[(y * width + x) * 4 + 1];

      // Geometry read off the capture, not assumed: `toImage` on this
      // boundary returns the whole view, inside which the harness box — and
      // the image inside that — sit centred. Hardcoding the padding put the
      // scan 150 px wide of the edge and made every strategy look identical.
      final centreY = capturedHeight ~/ 2;
      final left = ((capturedWidth - _kBox) / 2).round();
      final samples = <String>[];
      for (final offset in <int>[-6, -2, 0, 2, 6, 12, 24, 50]) {
        samples.add('${offset >= 0 ? "+" : ""}$offset:${greenAt(left + offset, centreY)}');
      }

      // The rim, as one number: how much ground shows through just inside the
      // edge, where a clean blur should show none at all.
      final rim = greenAt(left + 3, centreY);
      final interior = greenAt(left + 60, centreY);
      final dead = greenAt(width ~/ 2, centreY);
      // Where the blur reaches its darkest inside the image's first 20 px —
      // a rim is a local dip, and sampling one fixed offset can miss it.
      var worst = 255;
      for (var offset = 0; offset < 20; offset++) {
        final value = greenAt(left + offset, centreY);
        if (value < worst) worst = value;
      }

      // 255 = fully the image, 0 = fully the ground. A clean edge holds 255
      // right up to the boundary; a rim shows as a dip below the interior.
      debugPrint(
        '${entry.key.padRight(9)} rim=${rim.toString().padLeft(3)} '
        'interior=${interior.toString().padLeft(3)} '
        'centre=${dead.toString().padLeft(3)} '
        'worstInFirst20=${worst.toString().padLeft(3)}  scan[$samples]',
      );
    }
  });
}
